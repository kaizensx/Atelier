import AppKit
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
//   2. a picture of the window flies into the Atelier Dock, drawn by Atelier at display rate;
//   3. the real window, hidden under that picture, is shrunk onto the Atelier Dock's slot
//      and minimised there through Accessibility, so the system's own genie is a few pixels;
//   4. coming back, the same in reverse, and the window gets its frame back.
//
// A window brought back another way (its app's Window menu, Mission Control) gets its frame
// back the moment Atelier sees it restored. When anything fails, the system minimise runs.

@MainActor
final class MinimizeRedirect {
    static let shared = MinimizeRedirect()

    /// Frames of windows Atelier shrank, by AX window key, with the picture taken on the way.
    private var saved: [UInt: (frame: CGRect, image: CGImage?, window: AXUIElement, path: String?)] = [:]
    private var busy: Set<UInt> = []
    /// The last thing that happened, for atelier://diag.
    var note = "idle"

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
        MinimizeTap.shared.start()
        tapOn = true
    }

    private func stop() {
        MinimizeTap.shared.stop()
        tapOn = false
    }

    private var tapOn = false

    /// From the tap's thread, once a click on a yellow button or ⌘M was kept.
    func minimizeFromTap(_ ref: AXRef) {
        note = "tap: minimize asked"
        minimize(ref.element)
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

    private func minimize(_ window: AXUIElement) {
        let key = CFHash(window)
        let path = Self.appPath(window)
        guard !busy.contains(key), let frame = Self.frame(window), let target = OwnDock.shared.minimizeTarget(appPath: path) else {
            note = "minimize fallback: frame=\(Self.frame(window) != nil) target=\(OwnDock.shared.minimizeTarget(appPath: path) != nil)"
            Self.setMinimized(window, true)
            return
        }
        busy.insert(key)
        note = "minimize: capturing"
        let t0 = CACurrentMediaTime()
        Task { @MainActor in
            let image = await Self.picture(window, frame: frame)
            let t1 = CACurrentMediaTime()
            note = "minimize: captured \(image != nil)"
            guard let image else {
                // No picture (Screen Recording is off): the window flies into the Atelier Dock
                // itself, then is minimised there. Never the full genie to the hidden Dock.
                saved[key] = (frame, nil, window, path)
                await Self.shrink(window, from: frame, onto: target)
                note = "minimized: shrunk without a picture (screen recording \(ScreenRecordingFlag.allowed))"
                busy.remove(key)
                return
            }
            saved[key] = (frame, image, window, path)
            // The system still draws its genie from where the window ends up to the hidden
            // macOS Dock: a still picture of the bottom of the screen, taken without the window,
            // covers that band until it is over. Only Atelier's picture is seen going in.
            let band = Self.coverBand(target: target)
            let cover = await Self.picture(of: band, excluding: window).map { BandCover(image: $0, rect: band) }
            cover?.show()
            let t2 = CACurrentMediaTime()
            let flight = MinimizeFlight(image: image, from: Self.cocoa(frame), to: target)
            // Under the picture: shrink the real window onto the dock slot, then minimise it.
            // As small as the app allows and as low as macOS lets it go, centred on the slot:
            // the system's own genie then starts almost off screen, behind the Atelier Dock,
            // and is over before it can be seen running down to the hidden macOS Dock.
            // Parked against the edge the hidden macOS Dock is on, of the screen the slot is on,
            // so a Dock on the left or right, or a slot on another display, works the same.
            let slotScreen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
            let park = DockCompat.parkRect(target: Self.ax(target), screen: Self.ax(slotScreen?.frame ?? target),
                                           edge: Self.systemEdge)
            Self.setFrame(window, park)
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            note = "minimize: set minimized \(result.rawValue)"
            await flight.run(reverse: false)
            cover?.hide(after: 0.45)
            note = String(format: "minimized: window picture %.0f ms, band %.0f ms, flight %.0f ms", (t1 - t0) * 1000, (t2 - t1) * 1000, (CACurrentMediaTime() - t2) * 1000)
            busy.remove(key)
        }
    }

    /// Moves and shrinks the window onto the slot a few frames at a time, parks it against
    /// the hidden Dock's edge and minimises it there. Accessibility only.
    private static func shrink(_ window: AXUIElement, from frame: CGRect, onto target: CGRect) async {
        let slot = ax(target)
        for step in OwnDockMinimizeShrink.frames(from: frame, to: OwnDockMinimizeShrink.aim(slot: slot)) {
            setFrame(window, step)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let slotScreen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        setFrame(window, DockCompat.parkRect(target: slot, screen: ax(slotScreen?.frame ?? target), edge: systemEdge))
        setMinimized(window, true)
    }

    /// From the Atelier Dock's window tile. Returns false when Atelier did not shrink this
    /// window, and the dock restores it the ordinary way.
    func restore(_ window: AXUIElement) -> Bool {
        let key = CFHash(window)
        guard let entry = saved[key], let target = OwnDock.shared.minimizeTarget(appPath: entry.path) else { return false }
        busy.insert(key)
        Task { @MainActor in
            let flight = entry.image.map { MinimizeFlight(image: $0, from: Self.cocoa(entry.frame), to: target) }
            flight?.show(atTarget: true)
            Self.setMinimized(window, false)
            await flight?.run(reverse: true, shown: true)
            Self.setFrame(window, entry.frame)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            flight?.finish(after: 0.08)
            saved[key] = nil
            busy.remove(key)
        }
        return true
    }

    /// The app's tile was clicked. When every window it has on screen is one Atelier shrank,
    /// the newest comes back with the flight. Returns false when there is none.
    func restoreNewest(appPath: String) -> Bool {
        guard let entry = saved.values.filter({ $0.path == appPath }).last else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(entry.window, &pid)
        let shown = DockAX.windows(pid).contains { !$0.minimized }
        guard !shown else { return false }
        return restore(entry.window)
    }

    /// The watcher saw these windows come back. Any Atelier shrank gets its frame again.
    func restoredElsewhere(_ windows: [AXRef]) {
        for ref in windows {
            let key = CFHash(ref.element)
            guard !busy.contains(key), let entry = saved.removeValue(forKey: key) else { continue }
            Self.setFrame(ref.element, entry.frame)
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

    /// The bottom of the screen the genie crosses: full width, from the bottom edge to a little
    /// above the dock's slot. Cocoa coordinates.
    static func coverBand(target: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        // The genie's warp reaches well past the parked window: cover a deep band along the edge.
        return DockCompat.coverBand(target: target, screen: screen?.frame ?? .zero, edge: systemEdge)
    }

    /// The edge the hidden macOS Dock is on, which is where the system's genie always goes.
    static var systemEdge: DockCompat.Edge {
        DockCompat.edge(orientation: CFPreferencesCopyAppValue("orientation" as CFString, SystemDockPlan.domain as CFString) as? String)
    }

    /// A picture of part of the screen with one window left out of it.
    static func picture(of rect: CGRect, excluding window: AXUIElement) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), let id = DockAX.windowID(AXRef(element: window)),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
        let left = content.windows.filter { $0.windowID == id }
        let filter = SCContentFilter(display: display, excludingWindows: left)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        // sourceRect is in the display's own points, top-left based.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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

/// The picture's flight, in a click-through panel over everything, animated by Core Animation.
@MainActor
final class MinimizeFlight {
    private let panel: NSPanel
    private let layer = CALayer()
    private let from: CGRect
    private let to: CGRect
    private let area: CGRect

    init(image: CGImage, from: CGRect, to: CGRect) {
        self.from = from
        self.to = to
        area = from.union(to).insetBy(dx: -20, dy: -20)
        panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: area.size))
        host.wantsLayer = true
        panel.contentView = host
        layer.contents = image
        layer.contentsGravity = .resize
        layer.cornerRadius = 12
        layer.masksToBounds = true
        layer.frame = local(from)
        host.layer?.addSublayer(layer)
    }

    private func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - area.minX, y: rect.minY - area.minY, width: rect.width, height: rect.height)
    }

    func show(atTarget: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = local(atTarget ? to : from)
        layer.opacity = atTarget ? 0 : 1
        CATransaction.commit()
        panel.orderFrontRegardless()
    }

    /// Down into the dock, or back out of it. Ease-in going down, a soft ease-out coming back.
    func run(reverse: Bool, shown: Bool = false) async {
        if !shown { show(atTarget: reverse) }
        let start = local(reverse ? to : from), end = local(reverse ? from : to)
        let duration = reverse ? 0.34 : 0.38
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        // Moves at once and speeds into the tile; it stays solid until the last quarter,
        // so the eye follows it all the way into the dock.
        CATransaction.setAnimationTimingFunction(reverse ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                                                         : CAMediaTimingFunction(controlPoints: 0.45, 0.1, 0.7, 1))
        let bounds = CABasicAnimation(keyPath: "bounds.size")
        // NSValue, not CGSize/CGPoint: Core Animation silently ignores Swift structs here.
        bounds.fromValue = NSValue(size: start.size)
        bounds.toValue = NSValue(size: end.size)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: start.midX, y: start.midY))
        position.toValue = NSValue(point: CGPoint(x: end.midX, y: end.midY))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = reverse ? [0.3, 1, 1] : [1, 1, 0]
        fade.keyTimes = reverse ? [0, 0.3, 1] : [0, 0.75, 1]
        layer.frame = end
        layer.opacity = reverse ? 1 : 0
        layer.add(bounds, forKey: "bounds")
        layer.add(position, forKey: "position")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
        try? await Task.sleep(for: .seconds(duration))
        if !reverse { panel.orderOut(nil) }
    }

    func finish(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [panel] in panel.orderOut(nil) }
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
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .leftMouseDown:
            if let window = Self.minimizeButtonWindow(at: event.location) {
                swallowUp = true
                send(window)
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
            // Atelier's own panels (dock, widgets, overlays) sit above layer 0 and count as its.
            if layer != 0 {
                if (window[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier { return ProcessInfo.processInfo.processIdentifier }
                continue
            }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func send(_ window: AXUIElement) {
        let ref = AXRef(element: window)
        DispatchQueue.main.async { MainActor.assumeIsolated { MinimizeRedirect.shared.minimizeFromTap(ref) } }
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


/// A still picture of the screen's bottom band, shown over the system's genie while it runs.
@MainActor
final class BandCover {
    private let panel: NSPanel

    init(image: CGImage, rect: CGRect) {
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }

    func hide(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [panel] in panel.orderOut(nil) }
    }
}
