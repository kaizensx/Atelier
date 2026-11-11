import AppKit
import AVFoundation
import ApplicationServices
import DockCore
import QuartzCore
import ScreenCaptureKit

// MARK: - Minimise into the Atelier Dock
//
// The genie is drawn by the Dock process and always flies to the macOS Dock, hidden or not.
// No public API moves its target, and Atelier never injects code into the Dock. So while the
// Atelier Dock replaces the macOS one, Atelier takes the minimise itself:
//
//   1. an event tap sees a click on a window's yellow button, or ⌘M, and keeps it;
//   2. a picture of the window plays the minimise effect into the Atelier Dock's tile (Genie,
//      Scale or Suck as macOS is set, or one of Atelier's own), drawn by Atelier at display rate
//      (OwnDockMinimizeEffects.swift, meshes from DockCore's MinimizeEffects);
//   3. the real window, hidden under the effect's first frame, is parked at its own size against
//      the edge the hidden macOS Dock is on and minimised there through Accessibility. macOS
//      still animates it to that Dock, and no window can leave the screen entirely (its app
//      keeps the title bar on), so the hidden Dock is set to Scale while replaced (SystemDock):
//      the system's animation then only slides along the edge, a title bar high, for a fifth of
//      a second, and the Veil, a picture of that strip taken just before, covers it from just
//      under the Atelier Dock. Measured in recordings, the numbers are in DockCore's
//      MinimizeHandoff;
//   4. coming back, the effect leaves the tile at once; the window stays minimised until the
//      system's short return to the parked spot can finish under the Veil just before the
//      effect's last frame, then takes its frame under that frame. Never seen at the edge.
//
// The effect aims at the tile as the bar draws it each frame: the window's own tile (the bar
// makes room for it as the minimise starts) or the app's tile.
//
// A window brought back another way (its app's Window menu, Mission Control) comes back to the
// parked spot, and the effect brings it out from there. One minimised through its app's Window
// menu, which no tap sees, is taken in afterwards, so every way back plays the effect.
// When anything fails, the system minimise runs.

@MainActor
final class MinimizeRedirect {
    static let shared = MinimizeRedirect()

    /// Frames of windows Atelier shrank, by AX window key, with the picture taken on the way.
    private var saved: [UInt: (frame: CGRect, image: CGImage?, window: AXUIElement, path: String?)] = [:]
    private var busy: Set<UInt> = []
    /// The last thing that happened, for atelier://diag.
    var note = "idle"

    /// For atelier://diag: the last thing that happened, and where each held window's tile is
    /// (its centre, top-left based like a click), so a test can click it.
    var diagnostics: String {
        let tiles = saved.values.compactMap { entry -> String? in
            guard let rect = tile(for: entry.window, path: entry.path) else { return nil }
            let screen = NSScreen.screens.first?.frame.height ?? 0
            return "\(Int(rect.midX)),\(Int(screen - rect.midY))"
        }
        return note + " tiles=" + (tiles.isEmpty ? "-" : tiles.joined(separator: ";"))
    }

    /// The tap is on.
    var active: Bool { tapOn || !saved.isEmpty }

    var enabledPreference: Bool {
        UserDefaults.standard.object(forKey: "ownDock.minimizeIntoDock") as? Bool ?? true
    }

    /// On while the Atelier Dock replaces the macOS Dock and Accessibility is allowed.
    func update() {
        let want = wanted
        want ? start() : stop()
        OwnDock.shared.refreshSources()
    }

    private var wanted: Bool { enabledPreference && OwnDock.shared.replacesSystemDock && AXIsProcessTrusted() }

    /// Called every few seconds by `DockPermissions`: a tap that could not be made (the grant
    /// was still landing) is tried again, so minimising lands in this Dock without a relaunch.
    func ensureTap() {
        guard wanted, !MinimizeTap.shared.alive else { return }
        MinimizeTap.shared.stop()
        start()
    }

    private func start() {
        ClickThroughWindows.start()
        MinimizeTap.shared.start()
        tapOn = true
    }

    private func stop() {
        MinimizeTap.shared.stop()
        tapOn = false
    }

    private var tapOn = false

    /// From the tap's thread, once a click on a yellow button or ⌘M was kept.
    func minimizeFromTap(_ ref: AXRef, slow: Bool = false) {
        note = "tap: minimize asked"
        minimize(ref.element, slow: slow)
    }

    /// Atelier's own ways to minimise (the dock's swipe, title-bar gestures) come here, so they
    /// play the effect too. False when the Atelier Dock is not taking minimises.
    func minimizeIfActive(_ window: AXUIElement) -> Bool {
        guard tapOn, OwnDock.shared.replacesSystemDock else { return false }
        minimize(window)
        return true
    }

    /// ⌘M is the frontmost app's Minimize only when its focused window has a minimise button.
    private func focusedMinimizableWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.minimizableWindow(pid: app.processIdentifier)
    }

    /// The first standard window of the app with a minimise button. Safe off the main thread.
    nonisolated static func minimizableWindow(pid: pid_t) -> AXUIElement? {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let element = DockAX.application(pid, timeout: 0.15)
        // Finder's focused "window" can be the desktop. The first standard window with a
        // minimise button, focused first, is the one ⌘M minimises.
        var candidates: [AXUIElement] = []
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = DockAX.element(element, name) { candidates.append(value) }
        }
        candidates += (DockAX.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for window in candidates {
            guard DockAX.attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole as String,
                  (DockAX.attribute(window, kAXMinimizedAttribute) as? Bool) != true,
                  let button = Self.minimizeButton(window),
                  (DockAX.attribute(button, kAXEnabledAttribute) as? Bool) != false else { continue }
            return window
        }
        _ = app
        return nil
    }

    /// The window's minimise button, by attribute or, failing that, among its children.
    nonisolated static func minimizeButton(_ window: AXUIElement) -> AXUIElement? {
        if let button = DockAX.element(window, kAXMinimizeButtonAttribute) { return button }
        return DockAX.children(window).first { DockAX.attribute($0, kAXSubroleAttribute) as? String == kAXMinimizeButtonSubrole as String }
    }

    // MARK: Minimise

    /// atelier://mintest: the same path as the yellow button, on the frontmost app's window,
    /// for checking a build without a hand on the mouse. `up` brings the newest one back.
    func test(up: Bool) {
        if up {
            guard let entry = saved.values.first else { note = "restore test: none saved"; return }
            _ = restore(entry.window)
        } else if let window = focusedMinimizableWindow() {
            minimize(window)
        }
    }

    /// The edge the Atelier Dock is on, which the effect runs toward.
    private var dockEdge: MinimizeEdge {
        MinimizeEdge(rawValue: OwnDock.shared.stage.scene.edge.rawValue) ?? .bottom
    }

    /// The tile a window goes into or comes out of, as the bar draws it right now: the
    /// window's own tile when the bar shows minimised windows, else its app's tile. The
    /// effect asks again every frame, so it lands where the tile is, even while the bar
    /// is still making room for it.
    private func tile(for window: AXUIElement, path: String?) -> CGRect? {
        if OwnDock.shared.showsMinimizedWindows, let rect = OwnDock.shared.tileRect(id: Self.tileID(window)) { return rect }
        return OwnDock.shared.minimizeTarget(appPath: path)
    }

    static func tileID(_ window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return MinimizeHandoff.tileID(pid: pid, key: CFHash(window))
    }

    private func minimize(_ window: AXUIElement, slow: Bool = false) {
        let key = CFHash(window)
        let path = Self.appPath(window)
        guard !busy.contains(key), let frame = Self.frame(window), let target = tile(for: window, path: path) else {
            note = "minimize fallback: frame=\(Self.frame(window) != nil) target=\(OwnDock.shared.minimizeTarget(appPath: path) != nil)"
            Self.setMinimized(window, true)
            return
        }
        busy.insert(key)
        note = "minimize: capturing"
        let t0 = CACurrentMediaTime()
        let effect = MinimizeEffectSetting.current
        let ref = AXRef(element: window)
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        // The bar makes room for the window's tile now, as the macOS Dock does, so the effect
        // flies into the tile where it will be, not where the last tile was.
        if OwnDock.shared.showsMinimizedWindows {
            MinimizedWatcher.shared.expect(ref, pid: pid, title: DockAX.attribute(window, kAXTitleAttribute) as? String ?? "")
        }
        Task { @MainActor in
            // Both pictures at once: the window, and the edge without it (for the Veil).
            async let picture = Self.picture(ref.element, frame: frame)
            async let covering = Veil.make(near: target, excluding: ref.element)
            let image = await picture
            let t1 = CACurrentMediaTime()
            note = "minimize: captured \(image != nil)"
            guard let image, let overlay = MinimizeOverlay(image: image, window: Self.cocoa(frame), tile: target, effect: effect,
                                                           edge: dockEdge, track: { self.tile(for: ref.element, path: path) }) else {
                // No picture (Screen Recording is off): the window flies into the Atelier Dock
                // itself, then is minimised there. Never the full genie to the hidden Dock.
                saved[key] = (frame, image, window, path)
                let veil = await covering
                await Self.shrink(window, from: frame, onto: target, veil: veil)
                note = "minimized: shrunk without a picture (screen recording \(ScreenRecordingFlag.allowed))"
                busy.remove(key)
                return
            }
            saved[key] = (frame, image, window, path)
            // macOS still animates the real window to the hidden macOS Dock. It is parked at its
            // own size against that edge, where its app keeps only the title bar on screen, and
            // the hidden Dock is set to Scale, so the system's animation slides along the edge
            // for a fifth of a second. The Veil, a picture of that strip just taken, lies over it
            // just under the Atelier Dock, which stays live above.
            let veil = await covering
            // The effect's first frame covers the window exactly before the window moves.
            overlay.show(progress: 0)
            veil?.show()
            try? await Task.sleep(for: .milliseconds(MinimizeHandoff.veilSettle))
            let t2 = CACurrentMediaTime()
            Self.setFrame(window, Self.parkRect(window: frame.size, target: target))
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else {
                // The app refused: the window goes back where it was, as if nothing happened.
                Self.setFrame(window, frame)
                overlay.close()
                veil?.hide(after: 0)
                saved[key] = nil
                MinimizedWatcher.shared.unexpect(ref, pid: pid)
                busy.remove(key)
                note = "minimize refused (\(result.rawValue)): left as it was"
                return
            }
            // The Veil covers the system's animation only, never the whole effect (slow motion).
            veil?.hide(after: MinimizeHandoff.systemAnimation)
            await overlay.play(restoring: false, slow: slow)
            overlay.close()
            note = String(format: "minimized (%@%@): window picture %.0f ms, veil %.0f ms, effect %.0f ms", effect.rawValue,
                          slow ? ", slow" : "", (t1 - t0) * 1000, (t2 - t1) * 1000, (CACurrentMediaTime() - t2) * 1000)
            busy.remove(key)
        }
    }

    /// Where a window waits while minimised: at its own size, against the edge the hidden
    /// macOS Dock is on, level with the Atelier Dock's slot. Accessibility coordinates.
    static func parkRect(window size: CGSize, target: CGRect) -> CGRect {
        let slotScreen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        return MinimizeHandoff.parkRect(window: size, target: ax(target), screen: ax(slotScreen?.frame ?? target), edge: systemEdge)
    }

    /// Moves and shrinks the window onto the slot a few frames at a time, parks it against
    /// the hidden Dock's edge and minimises it there. Accessibility only.
    private static func shrink(_ window: AXUIElement, from frame: CGRect, onto target: CGRect, veil: Veil?) async {
        let slot = ax(target)
        for step in OwnDockMinimizeShrink.frames(from: frame, to: OwnDockMinimizeShrink.aim(slot: slot)) {
            setFrame(window, step)
            try? await Task.sleep(for: .milliseconds(16))
        }
        veil?.show()
        try? await Task.sleep(for: .milliseconds(MinimizeHandoff.veilSettle))
        setFrame(window, parkRect(window: frame.size, target: target))
        setMinimized(window, true)
        veil?.hide(after: MinimizeHandoff.systemAnimation)
    }

    /// From the Atelier Dock's window tile. Returns false when Atelier did not shrink this
    /// window, and the dock restores it the ordinary way. Shift held is slow motion.
    func restore(_ window: AXUIElement, slow: Bool = false) -> Bool {
        let key = CFHash(window)
        guard let entry = saved[key], let start = tile(for: window, path: entry.path) else {
            note = "restore: not held (\(saved.count) held)"
            return false
        }
        // Already on its way back (the app's tile and the window's tile can both ask).
        guard !busy.contains(key) else { return true }
        busy.insert(key)
        let effect = MinimizeEffectSetting.current
        let path = entry.path
        Task { @MainActor in
            // The effect starts at once from the tile. The real window stays minimised and parked
            // until the system's short return to the parked spot can just finish under the
            // Veil before the effect's last frame; then it takes its frame under that frame.
            let overlay = entry.image.flatMap {
                MinimizeOverlay(image: $0, window: Self.cocoa(entry.frame), tile: start, effect: effect, edge: dockEdge,
                                track: { self.tile(for: window, path: path) })
            }
            let t0 = CACurrentMediaTime()
            var veil: Veil?
            var called = t0
            if let overlay {
                overlay.show(progress: 1)
                let call = MinimizeHandoff.restoreCall(duration: MinimizeTiming.duration(effect, restoring: true, slow: slow))
                async let played: Void = overlay.play(restoring: true, slow: slow)
                // The Veil's picture is taken just before it is needed, never seconds before.
                let lead = call - 0.1 - (CACurrentMediaTime() - t0)
                if lead > 0 { try? await Task.sleep(for: .seconds(lead)) }
                veil = await Veil.make(near: start, excluding: nil)
                veil?.show()
                try? await Task.sleep(for: .milliseconds(MinimizeHandoff.veilSettle))
                let wait = call - (CACurrentMediaTime() - t0)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                called = CACurrentMediaTime()
                Self.setMinimized(window, false)
                await played
                // The effect holds its last frame until the system's return is surely over.
                let settle = MinimizeHandoff.systemArrival - (CACurrentMediaTime() - called)
                if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
                Self.setFrame(window, entry.frame)
            } else {
                // No picture to fly: the real window comes back under the Veil and flies out of
                // the slot itself, a few frames, Accessibility only.
                veil = await Veil.make(near: start, excluding: nil)
                veil?.show()
                try? await Task.sleep(for: .milliseconds(MinimizeHandoff.veilSettle))
                called = CACurrentMediaTime()
                Self.setMinimized(window, false)
                try? await Task.sleep(for: .seconds(MinimizeHandoff.systemArrival))
                let aim = OwnDockMinimizeShrink.aim(slot: Self.ax(start))
                for step in OwnDockMinimizeShrink.frames(from: aim, to: entry.frame) {
                    Self.setFrame(window, step)
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            NSRunningApplication(processIdentifier: pid)?.activate()
            // The window draws at its frame under the last frame of the effect, then both go.
            overlay?.close(after: 0.07)
            veil?.hide(after: MinimizeHandoff.veilHold(since: CACurrentMediaTime() - called))
            saved[key] = nil
            busy.remove(key)
            note = String(format: "restored (%@%@) picture=%@ veil=%@ in %.0f ms", effect.rawValue, slow ? ", slow" : "",
                          entry.image != nil ? "yes" : "no", veil != nil ? "yes" : "no", (CACurrentMediaTime() - t0) * 1000)
        }
        return true
    }

    /// Whether Atelier holds this window minimised, so its tile brings it back with the effect.
    func holds(_ window: AXUIElement) -> Bool { saved[CFHash(window)] != nil }

    /// The app's tile was clicked. When every window it has on screen is one Atelier shrank,
    /// the newest comes back with the flight. Returns false when there is none.
    func restoreNewest(appPath: String, slow: Bool = false) -> Bool {
        let held = saved.filter { $0.value.path == appPath }
        guard let first = held.first else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(first.value.window, &pid)
        let shown = DockAX.windows(pid).contains { !$0.minimized }
        guard !shown else { return false }
        // The newest is the one minimised last: the highest tile order the watcher gave it.
        let order = Dictionary(MinimizedWatcher.shared.windows.map { ($0.id, $0.since) }, uniquingKeysWith: max)
        let newest = held.max { (order[Self.tileID($0.value.window)] ?? 0) < (order[Self.tileID($1.value.window)] ?? 0) }
        return restore((newest ?? first).value.window, slow: slow)
    }

    /// The watcher saw these windows come back some other way (the app's Window menu, Mission
    /// Control, the app reopening). They return to where they were parked, against the edge;
    /// from there the effect brings them out of the tile and they get their frame back.
    func restoredElsewhere(_ windows: [AXRef]) {
        for ref in windows {
            let key = CFHash(ref.element)
            guard !busy.contains(key), let entry = saved.removeValue(forKey: key) else { continue }
            let path = entry.path
            guard let image = entry.image, let start = tile(for: ref.element, path: path),
                  let overlay = MinimizeOverlay(image: image, window: Self.cocoa(entry.frame), tile: start,
                                                effect: MinimizeEffectSetting.current, edge: dockEdge,
                                                track: { self.tile(for: ref.element, path: path) }) else {
                Self.setFrame(ref.element, entry.frame)
                continue
            }
            busy.insert(key)
            // The effect starts at once; the Veil joins it over the parked title bar as soon as
            // its picture is taken.
            overlay.show(progress: 1)
            Task { @MainActor in
                async let covering = Veil.make(near: start, excluding: ref.element)
                async let played: Void = overlay.play(restoring: true, slow: false)
                let veil = await covering
                veil?.show()
                await played
                Self.setFrame(ref.element, entry.frame)
                overlay.close(after: 0.07)
                veil?.hide(after: 0.05)
                busy.remove(key)
                note = "restored elsewhere with the effect"
            }
        }
    }

    /// The watcher saw these windows minimised some other way (the app's Window ▸ Minimize,
    /// which no tap sees). The system's animation has already run; from now on they are held
    /// like the others: their frame and a picture are kept, they wait parked against the edge,
    /// and every way back plays the effect.
    func minimizedElsewhere(_ windows: [AXRef]) {
        guard tapOn, OwnDock.shared.replacesSystemDock else { return }
        for ref in windows {
            let key = CFHash(ref.element)
            guard !busy.contains(key), saved[key] == nil, let frame = Self.frame(ref.element) else { continue }
            let path = Self.appPath(ref.element)
            guard let target = OwnDock.shared.minimizeTarget(appPath: path) else { continue }
            busy.insert(key)
            Task { @MainActor in
                // A minimised window still has its pixels: the picture is of it as it was.
                let image = await Self.picture(minimized: ref.element, frame: frame)
                saved[key] = (frame, image, ref.element, path)
                Self.setFrame(ref.element, Self.parkRect(window: frame.size, target: target))
                busy.remove(key)
                note = "adopted a window minimised elsewhere, picture=\(image != nil)"
            }
        }
    }

    /// At quit: every window still held shrunk gets its frame back while it stays minimised,
    /// so nothing comes back tiny once Atelier is gone.
    func releaseAll() {
        for entry in saved.values { Self.setFrame(entry.window, entry.frame) }
        saved = [:]
    }

    /// Keys of windows Atelier holds shrunk, so the watcher knows which to report.
    var shrunkKeys: Set<UInt> { Set(saved.keys) }
    // MARK: AX helpers

    static func appPath(_ window: AXUIElement) -> String? {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = DockAX.attribute(window, kAXPositionAttribute), let size = DockAX.attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        // Some apps place first and size after.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    static func setMinimized(_ window: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// AX frames are top-left based on the main display; Cocoa's are bottom-left.
    static func cocoa(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func ax(_ rect: CGRect) -> CGRect { cocoa(rect) }

    /// The edge the hidden macOS Dock is on, which is where the system's genie always goes.
    static var systemEdge: DockCompat.Edge {
        DockCompat.edge(orientation: CFPreferencesCopyAppValue("orientation" as CFString, SystemDockPlan.domain as CFString) as? String)
    }

    /// How to take pictures of part of the screen as it looks under a window at `level`: the
    /// windows shown now, but one (the window going away) and Atelier's own panels at that
    /// level or above (the dock, the effect, the Veil itself). Atelier's panels below it
    /// (wallpapers, dimming, borders) stay in, or they would blink. Nil without Screen Recording.
    static func capture(of rect: CGRect, excluding window: AXUIElement?, level: Int) async -> (SCContentFilter, SCStreamConfiguration)? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
        let id = window.flatMap { DockAX.windowID(AXRef(element: $0)) }
        let me = ProcessInfo.processInfo.processIdentifier
        let going = window.flatMap { Self.frame($0) } ?? .null
        let kept = content.windows.filter {
            !MinimizeHandoff.leftOutOfVeil(own: $0.owningApplication?.processID == me, layer: $0.windowLayer, veilLevel: level,
                                           isMinimising: id != nil && $0.windowID == id, frame: $0.frame, minimising: going)
        }
        // The windows there now, by name: the Veil, made after, is never in its own picture.
        let filter = SCContentFilter(display: display, including: kept)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        // sourceRect is in the display's own points, top-left based.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        return (filter, config)
    }

    /// A picture of a window that is already minimised: the window server keeps its pixels.
    static func picture(minimized window: AXUIElement, frame: CGRect) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), let id = DockAX.windowID(AXRef(element: window)),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let shown = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = (NSScreen.screens.first { $0.frame.intersects(cocoa(frame)) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shown),
                                                           configuration: config)
    }

    static func picture(_ window: AXUIElement, frame: CGRect) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), let id = DockAX.windowID(AXRef(element: window)),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let shown = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let config = SCStreamConfiguration()
        // The window's own screen: a Retina laptop beside a standard display has two scales.
        let cocoaFrame = cocoa(frame)
        let scale = (NSScreen.screens.first { $0.frame.intersects(cocoaFrame) } ?? NSScreen.main)?.backingScaleFactor ?? 2
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shown),
                                                           configuration: config)
    }
}

/// The event tap, on a thread of its own. Its Accessibility hit test on every click used to run
/// on the main thread and held the Studio's frames up to 150 ms at a time.
final class MinimizeTap: @unchecked Sendable {
    static let shared = MinimizeTap()
    private let lock = NSLock()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var thread: Thread?
    /// Touched only on the tap's thread.
    private var swallowUp = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard thread == nil else { return }
        let thread = Thread { [self] in run() }
        thread.name = "Atelier Minimise Tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// The tap exists and is listening.
    var alive: Bool {
        lock.lock(); defer { lock.unlock() }
        return port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
        port = nil
        loop = nil
        thread = nil
    }

    private func run() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            MinimizeTap.shared.handle(type, event)
        }, userInfo: nil) else {
            // Not allowed yet: forget this thread so a later start can try again.
            lock.lock()
            thread = nil
            lock.unlock()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        self.port = port
        loop = CFRunLoopGetCurrent()
        lock.unlock()
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            TapRevoke.disabled(type)
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .leftMouseDown:
            if let window = Self.minimizeButtonWindow(at: event.location) {
                swallowUp = true
                // Shift-click is slow motion, as in macOS.
                send(window, slow: event.flags.contains(.maskShift))
                return nil
            }
        case .leftMouseUp:
            if swallowUp { swallowUp = false; return nil }
        case .keyDown:
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            guard DockCompat.isMinimizeKey(characters: Self.characters(event),
                                           keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                           commandOnly: flags == .maskCommand,
                                           autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0),
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let window = MinimizeRedirect.minimizableWindow(pid: pid) else { break }
            send(window)
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// The characters the key types on the current layout, read from the event itself.
    private static func characters(_ event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return length > 0 ? String(utf16CodeUnits: buffer, count: min(length, buffer.count)) : nil
    }

    /// The process whose normal window is frontmost under the point (screen coordinates,
    /// top-left origin, as event locations are). Nil over the desktop or menu bar.
    static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let ownWindow = (window[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier
            // Atelier's click-through overlays (XDR Boost, effects, tints) cover the whole screen
            // but never take a click: they are not what is under the pointer.
            if ownWindow, ClickThroughWindows.contains(number) { continue }
            // Atelier's own panels (dock, widgets) sit above layer 0 and count as its.
            if layer != 0 {
                if ownWindow { return ProcessInfo.processInfo.processIdentifier }
                continue
            }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func send(_ window: AXUIElement, slow: Bool = false) {
        let ref = AXRef(element: window)
        DispatchQueue.main.async { MainActor.assumeIsolated { MinimizeRedirect.shared.minimizeFromTap(ref, slow: slow) } }
    }

    /// The window whose minimise button is under the pointer; nil for Atelier's own windows.
    static func minimizeButtonWindow(at point: CGPoint) -> AXUIElement? {
        // Never ask Accessibility about Atelier's own windows from this thread: the request
        // is answered in-process, on the asking thread, and walks SwiftUI views off the main
        // thread (that crashed). The window server's list says whose window is under the point.
        guard let owner = Self.windowOwner(at: point), owner != ProcessInfo.processInfo.processIdentifier else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid == owner,
              DockAX.attribute(hit, kAXSubroleAttribute) as? String == kAXMinimizeButtonSubrole as String,
              (DockAX.attribute(hit, kAXEnabledAttribute) as? Bool) != false,
              let window = DockAX.element(hit, kAXWindowAttribute) else { return nil }
        return window
    }
}


/// A picture of the strip along the edge the hidden macOS Dock is on, laid over the system's
/// own minimise animation while it runs. It sits just under the Atelier Dock's level: the
/// system animates the real window at its own level, so it runs beneath the Veil, unseen,
/// while the Atelier Dock and Atelier's effect stay live above it. Only that strip is covered,
/// for the fifth of a second the animation takes, and the picture is not a still: a capture
/// stream of every window but the one going away plays in it, a frame behind the screen, so
/// what lies under it (a window dimming as focus moves, a video) keeps moving and nothing
/// jumps when it goes. A still taken just before covers the moment the stream starts.
@MainActor
final class Veil {
    static var level: Int { Int(CGWindowLevelForKey(.dockWindow)) - 1 }
    private let panel: NSPanel
    fileprivate let feed: VeilFeed

    private init(image: CGImage, rect: CGRect, screen: NSScreen?, filter: SCContentFilter, config: SCStreamConfiguration) {
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.level = NSWindow.Level(rawValue: Self.level)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        // The picture is drawn as the screen draws its pixels, one for one.
        if let space = screen?.colorSpace { panel.colorSpace = space }
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        view.layer?.contentsScale = screen?.backingScaleFactor ?? 2
        feed = VeilFeed(filter: filter, config: config)
        feed.layer.frame = view.bounds
        feed.layer.videoGravity = .resize
        view.layer?.addSublayer(feed.layer)
        panel.contentView = view
        panel.setFrame(rect, display: false)
    }

    /// The strip along the hidden Dock's edge of the screen `target` is on, its first picture
    /// taken. Nil without Screen Recording.
    static func make(near target: CGRect, excluding window: AXUIElement?) async -> Veil? {
        // Off only for recordings that compare with and without it.
        guard UserDefaults.standard.object(forKey: "ownDock.minimizeVeil") as? Bool ?? true else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        guard let screen else { return nil }
        let strip = MinimizeHandoff.veilStrip(screen: screen.frame, edge: MinimizeRedirect.systemEdge)
        guard let (filter, config) = await MinimizeRedirect.capture(of: strip, excluding: window, level: level),
              let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let veil = Veil(image: image, rect: strip, screen: screen, filter: filter, config: config)
        // The stream starts now, while the Veil is still clear, so it is live when it shows.
        veil.feed.start()
        return veil
    }

    /// At once: its first picture was taken a moment ago, so it matches what it lies on, and
    /// the window may move under it a frame later. Its stream, started when it was made, is
    /// live by then.
    func show() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        feed.start()
    }

    func hide(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = MinimizeHandoff.veilFade
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    self.feed.stop()
                    self.panel.orderOut(nil)
                    self.panel.close()
                }
            })
        }
    }
}

/// The Veil's capture stream: frames go straight from the capture queue to a display layer.
final class VeilFeed: NSObject, SCStreamOutput, @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    nonisolated(unsafe) private let renderer: AVSampleBufferVideoRenderer
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "atelier.minimize.veil", qos: .userInteractive)

    @MainActor init(filter: SCContentFilter, config: SCStreamConfiguration) {
        self.filter = filter
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_32BGRA
        self.config = config
        renderer = layer.sampleBufferRenderer
        super.init()
        layer.preventsDisplaySleepDuringVideoPlayback = false
    }

    @MainActor func start() {
        guard stream == nil else { return }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        guard (try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)) != nil else { return }
        self.stream = stream
        Task { try? await stream.startCapture() }
    }

    @MainActor func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        renderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
              let first = attachments.first else { return }
        // Idle frames carry no new picture.
        if let raw = first[SCStreamFrameInfo.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        first[kCMSampleAttachmentKey_DisplayImmediately] = true
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }
}


/// Atelier's windows that ignore the mouse, by window number, readable from any thread: the
/// event taps run off the main thread and must not treat a full-screen overlay as the window
/// a click landed on.
enum ClickThroughWindows {
    nonisolated(unsafe) private static var ids: Set<UInt32> = []
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timer: Timer?

    static func contains(_ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    /// Refreshes the set now and twice a second from then on (overlays come and go).
    @MainActor static func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { refresh() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor static func refresh() {
        let now = Set(NSApp.windows.filter { $0.isVisible && $0.ignoresMouseEvents }.map { UInt32($0.windowNumber) })
        lock.lock(); ids = now; lock.unlock()
    }
}
