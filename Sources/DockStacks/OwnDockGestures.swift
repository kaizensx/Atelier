import AppKit
import ApplicationServices
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Gestures & Peek for the Atelier Dock
//
// What Dock Peek (`SystemDockPeek`) gives Apple's Dock, on the Atelier Dock:
//
// - Swipe up on an app's tile: App Exposé for that app (or bring back a minimised window).
// - Swipe down: minimise its front window (or hide the app).
// - Pinch in: quit it, after a second pinch. Off unless asked for.
// - Close and minimise buttons on the window pictures of Live Peek, minimised windows included.
// - Without Screen Recording, Live Peek still lists every window, with the app's icon and the
//   window's title, and a click still brings it forward. Window pictures need Screen Recording:
//   ScreenCaptureKit (and every older capture call) only returns other apps' windows with it.
//
// No event tap and no system change: the Atelier Dock's own panel already receives the scroll
// and magnify events over its tiles (`DockInputView`), so OwnDock hands them here first.
// `SystemDockGestureClassifier` (DockCore) recognises the swipe and pinch, the same one Dock Peek
// uses; `OwnDockSwipeRouter` keeps sideways scrolling and the mouse wheel for Scroll for Windows.

/// What the button layer on the window card draws. Apart from the engine so only it redraws.
@MainActor
final class OwnDockGesturesStage: ObservableObject {
    /// The button under the pointer on the hot picture.
    @Published var lit: OwnDockPeekButtons.Button?
}

@MainActor
final class OwnDockGestures: ObservableObject {
    static let shared = OwnDockGestures()

    enum Key {
        static let enabled = "dockGestures.enabled"
        static let up = "dockGestures.up"
        static let down = "dockGestures.down"
        static let pinch = "dockGestures.pinch"
        static let buttons = "dockGestures.buttons"
    }

    /// The whole feature.
    @Published var enabled: Bool {
        didSet {
            store.set(enabled, forKey: Key.enabled)
            if !enabled { reset(); hidePill(); pinned = nil }
        }
    }
    @Published var settings: OwnDockGestureSettings {
        didSet {
            store.set(settings.up.rawValue, forKey: Key.up)
            store.set(settings.down.rawValue, forKey: Key.down)
            store.set(settings.pinch, forKey: Key.pinch)
            if !settings.pinch { hidePill() }
        }
    }
    /// Close and minimise buttons on the window pictures.
    @Published var buttons: Bool { didSet { store.set(buttons, forKey: Key.buttons) } }

    let stage = OwnDockGesturesStage()

    private let store = UserDefaults.standard
    private var router = OwnDockSwipeRouter()
    private var classifier = SystemDockGestureClassifier()
    private var quitConfirm = SystemDockQuitConfirm()
    private var gestureTile: String?

    // Counters and last values, for `diagnostics` and the test hook.
    private(set) var performed = 0
    private(set) var swallowed = 0
    private(set) var passed = 0
    private(set) var lastGesture: String?
    private(set) var lastRoute: String?
    private(set) var buttonPresses = 0
    /// The tile whose card a test pinned open, and until when.
    private(set) var pinned: (path: String, until: Double)?

    private var pill: NSPanel?
    private var pillModel = OwnDockPillModel()
    private var pillTimer: Timer?
    private var quitTarget: String?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        settings = OwnDockGestureSettings(
            up: (defaults.string(forKey: Key.up)).flatMap(OwnDockGestureAction.init(rawValue:)) ?? .expose,
            down: (defaults.string(forKey: Key.down)).flatMap(OwnDockGestureAction.init(rawValue:)) ?? .minimize,
            pinch: defaults.bool(forKey: Key.pinch))
        buttons = defaults.object(forKey: Key.buttons) as? Bool ?? true
    }

    // MARK: Life cycle

    /// Nothing runs on its own: OwnDock hands over events. Kept for the house pattern.
    func resume() {}

    /// Nothing about the system is changed; quitting only takes the confirm pill down.
    func restoreOnQuit() {
        hidePill()
        pill?.orderOut(nil)
        pill = nil
    }

    private func reset() {
        router.reset()
        classifier.reset()
        gestureTile = nil
    }

    /// The window card lists windows without pictures, with icons and titles (Accessibility only).
    var titleCards: Bool { enabled && AXIsProcessTrusted() }

    /// The card's buttons are drawn and clickable. Read at display rate, so the grant is cached.
    var buttonsActive: Bool { enabled && buttons && trusted }

    private var trustedValue = false
    private var trustedAt = -Double.infinity

    /// `AXIsProcessTrusted`, read at most every two seconds.
    private var trusted: Bool {
        let now = CACurrentMediaTime()
        if now - trustedAt > 2 {
            trustedValue = AXIsProcessTrusted()
            trustedAt = now
        }
        return trustedValue
    }

    // MARK: Events from the dock

    /// A scroll over the Atelier Dock. True takes it; false leaves it to Scroll for Windows.
    /// `slot` is the app tile under the pointer, nil anywhere else.
    func scroll(_ event: NSEvent, slot: DockSlot?) -> Bool {
        guard enabled, settings.swipes, let slot, slot.kind == .app, slot.running, trusted else {
            if gestureTile != nil { reset() }
            return false
        }
        if slot.id != gestureTile {
            reset()
            gestureTile = slot.id
        }
        let now = CACurrentMediaTime()
        let phase = Self.phase(event)
        let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        let route = router.route(dx: dx, dy: dy, continuous: event.hasPreciseScrollingDeltas, phase: phase,
                                 swipes: settings.swipes, at: now)
        lastRoute = "\(route)"
        guard route != .scroll else {
            passed += 1
            return false
        }
        swallowed += 1
        // In the device's own sense: positive when the fingers move away, whatever Natural
        // Scrolling says.
        let upward = event.isDirectionInvertedFromDevice ? -dy : dy
        if let gesture = classifier.scroll(upward: upward, sideways: dx, continuous: true, phase: phase, at: now),
           let kind = OwnDockGestureKind(gesture), kind != .pinch {
            perform(kind, slot: slot)
        }
        return true
    }

    /// A pinch over the Atelier Dock. `slot` as for `scroll`.
    func magnify(_ event: NSEvent, slot: DockSlot?) {
        guard enabled, settings.pinch, let slot, slot.kind == .app, slot.running else { return }
        if slot.id != gestureTile {
            reset()
            gestureTile = slot.id
        }
        if classifier.magnify(Double(event.magnification), phase: Self.phase(event), at: CACurrentMediaTime()) == .quit {
            perform(.pinch, slot: slot)
        }
    }

    private static func phase(_ event: NSEvent) -> SystemDockScrollPhase {
        if !event.momentumPhase.isEmpty { return .momentum }
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }

    // MARK: Acting

    private func runningApp(_ path: String) -> NSRunningApplication? {
        guard !path.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
    }

    /// Does what the gesture is set to, to the tile's app. Quit asks for a second pinch first.
    @discardableResult
    private func perform(_ kind: OwnDockGestureKind, slot: DockSlot, confirmed: Bool = false) -> Bool {
        let action = settings.action(kind)
        guard action != .none, let app = runningApp(slot.path),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let pid = app.processIdentifier
        let name = app.localizedName ?? slot.title
        lastGesture = "\(kind.rawValue)=\(action.rawValue):\(name)"
        performed += 1
        switch action {
        case .none:
            return false
        case .expose:
            Self.appExpose(app)
        case .restore:
            if !MinimizeRedirect.shared.restoreNewest(appPath: slot.path) {
                app.activate()
                Task.detached(priority: .userInitiated) {
                    if let window = DockAX.windows(pid).first(where: \.minimized) { DockAX.raise(window.ref) }
                    await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
                }
            }
        case .minimize:
            Task.detached(priority: .userInitiated) {
                let element = DockAX.application(pid)
                let focused = DockAX.element(element, kAXFocusedWindowAttribute)
                let target = focused.flatMap { window -> AXUIElement? in
                    (DockAX.attribute(window, kAXMinimizedAttribute) as? Bool) == true ? nil : window
                } ?? DockAX.windows(pid).first { !$0.minimized }?.ref.element
                if let target { AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
                await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
            }
        case .hide:
            app.hide()
        case .quit:
            // The Finder has no Quit; quitting it would only restart it.
            guard app.bundleIdentifier != "com.apple.finder" else { return false }
            if confirmed || quitConfirm.pinch(slot.path, at: CACurrentMediaTime()) {
                hidePill()
                app.terminate()
            } else {
                showPill(name, slot: slot)
            }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        OwnDock.shared.gestureFeedback(slot.id)
        return true
    }

    /// App Exposé for one app: it comes to the front, then the Mission Control app is asked for
    /// App Exposé (argument 2), which shows the front app's windows. The same request the
    /// Trackpad Gestures and Hot Corners use; nothing is typed.
    private static func appExpose(_ app: NSRunningApplication) {
        app.activate()
        Task { @MainActor in
            // App Exposé shows the front app, so wait (briefly) until it is.
            for _ in 0..<12 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(40))
            }
            let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
            guard FileManager.default.isExecutableFile(atPath: binary) else { NSSound.beep(); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["2"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    // MARK: The quit confirm

    private func showPill(_ name: String, slot: DockSlot) {
        quitTarget = slot.path
        pillModel.name = name
        guard let tile = OwnDock.shared.gestureTileRect(slot.id) else { return }
        let panel = makePill()
        let size = SystemDockPeekPill.size, pad = 16.0
        let edge = OwnDock.shared.placedEdge
        var origin: NSPoint = switch edge {
        case .bottom: NSPoint(x: tile.midX - size.width / 2, y: tile.maxY + 18)
        case .top: NSPoint(x: tile.midX - size.width / 2, y: tile.minY - 18 - size.height)
        case .left: NSPoint(x: tile.maxX + 18, y: tile.midY - size.height / 2)
        case .right: NSPoint(x: tile.minX - 18 - size.width, y: tile.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(tile) }) {
            let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        panel.setFrame(NSRect(x: origin.x - pad, y: origin.y - pad, width: size.width + pad * 2, height: size.height + pad * 2),
                       display: false)
        panel.orderFrontRegardless()
        withAnimation(DS.Motion.gentle(DS.Motion.arrive)) { pillModel.visible = true }
        pillTimer?.invalidate()
        let timer = Timer(timeInterval: quitConfirm.window, repeats: false) { _ in
            MainActor.assumeIsolated { OwnDockGestures.shared.hidePill() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pillTimer = timer
    }

    private func hidePill() {
        pillTimer?.invalidate()
        pillTimer = nil
        quitConfirm.cancel()
        quitTarget = nil
        guard pillModel.visible else { return }
        withAnimation(DS.Motion.gentle(DS.Motion.exit)) { pillModel.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                let gestures = OwnDockGestures.shared
                if !gestures.pillModel.visible { gestures.pill?.orderOut(nil) }
            }
        }
    }

    private func makePill() -> NSPanel {
        if let pill { return pill }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = OwnDockPillHost(rootView: OwnDockPillRoot(model: pillModel, quit: {
            OwnDockGestures.shared.quitFromPill()
        }))
        host.sizingOptions = []
        panel.contentView = host
        pill = panel
        return panel
    }

    private func quitFromPill() {
        guard let path = quitTarget, let app = runningApp(path) else { hidePill(); return }
        let slot = DockSlot(id: "gesture.quit", kind: .app, path: path, title: app.localizedName ?? "", running: true)
        perform(.pinch, slot: slot, confirmed: true)
    }

    // MARK: Buttons on the window card

    /// The cell of the picture `index` and that picture, in panel points.
    private func cell(_ index: Int, peek: DockPeek, scene: DockScene) -> (CGRect, DockThumb)? {
        let count = min(peek.thumbs.count, DockPeekLayout.most)
        guard index < count else { return nil }
        let card = DockPeekLayout.frame(count: peek.thumbs.count, scene: scene)
        let cell = DockPeekLayout.cellFrame(index, count: count, edge: scene.edge).offsetBy(dx: card.minX, dy: card.minY)
        return (cell, peek.thumbs[index])
    }

    /// Every frame the pointer is on the window card (nil when it is not): lights the button under it.
    func pointer(_ point: CGPoint?) {
        guard let point else {
            if stage.lit != nil { stage.lit = nil }
            return
        }
        var lit: OwnDockPeekButtons.Button?
        let dock = OwnDock.shared
        if buttonsActive, let peek = dock.stage.peek, let hot = dock.stage.peekHot,
           let (cell, thumb) = cell(hot, peek: peek, scene: dock.stage.scene) {
            lit = OwnDockPeekButtons.hit(point, cell: cell, minimized: thumb.minimized)
        }
        if stage.lit != lit { stage.lit = lit }
    }

    /// A click on the window card. True when it pressed a close or minimise button; false leaves
    /// the click to the card (it brings the window forward).
    func cardClick(_ point: CGPoint, peek: DockPeek, scene: DockScene) -> Bool {
        guard buttonsActive, let index = DockPeekLayout.hit(point, count: peek.thumbs.count, scene: scene),
              let (cell, thumb) = cell(index, peek: peek, scene: scene),
              let button = OwnDockPeekButtons.hit(point, cell: cell, minimized: thumb.minimized) else { return false }
        press(button, thumb: thumb)
        return true
    }

    private func press(_ button: OwnDockPeekButtons.Button, thumb: DockThumb) {
        let dock = OwnDock.shared
        guard let ref = dock.gesturePeekRef(thumb.id) else { NSSound.beep(); return }
        let pid = dock.gesturePeekPID
        buttonPresses += 1
        switch button {
        case .close:
            Task.detached(priority: .userInitiated) {
                if let close = DockAX.element(ref.element, kAXCloseButtonAttribute) {
                    AXUIElementPerformAction(close, kAXPressAction as CFString)
                }
                await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
            }
            guard var peek = dock.stage.peek else { return }
            peek.thumbs.removeAll { $0.id == thumb.id }
            dock.stage.peekHot = nil
            stage.lit = nil
            // The last window: the card fades out as it is, rather than turning into the info card.
            if peek.thumbs.isEmpty { dock.gestureFeedback(nil) } else { dock.stage.peek = peek }
        case .minimize:
            Task.detached(priority: .userInitiated) {
                AXUIElementSetAttributeValue(ref.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
            }
            guard var peek = dock.stage.peek, let at = peek.thumbs.firstIndex(where: { $0.id == thumb.id }) else { return }
            peek.thumbs[at].minimized = true
            dock.stage.peek = peek
            stage.lit = nil
        }
    }

    /// Without Screen Recording the window card's open windows carry no title (the window server
    /// redacts names): they take the title Accessibility reports for the same window.
    static func titled(_ thumbs: [DockThumb], from found: [(AXRef, String, Bool, CGWindowID?)]) -> [DockThumb] {
        thumbs.map { thumb in
            guard !thumb.minimized, let title = found.first(where: { $0.3 == thumb.id })?.1, !title.isEmpty else { return thumb }
            var thumb = thumb
            thumb.title = title
            return thumb
        }
    }

    // MARK: A card held open by the test hook

    /// For `updatePeek`: true keeps a card the test hook opened, until the pointer comes to the dock.
    func holdsPeek(inside: Bool) -> Bool {
        guard let pinned else { return false }
        if inside || CACurrentMediaTime() > pinned.until {
            self.pinned = nil
            return false
        }
        return true
    }

    // MARK: Availability, diagnostics, tests

    var notes: [FeatureAvailability] {
        var notes: [FeatureAvailability] = []
        if !AXIsProcessTrusted() {
            notes.append(.limited("Needs Accessibility in System Settings › Privacy & Security, to act on windows"))
        }
        if !DockWindowShots.shared.allowed {
            notes.append(.limited("Window pictures need Screen Recording; without it the card shows each window's icon and title"))
        }
        if !OwnDock.shared.enabled {
            notes.append(.limited("Works on the Atelier Dock; turn it on in the Dock chapter"))
        }
        return notes
    }

    var diagnostics: String {
        let dock = OwnDock.shared
        return "dockGestures=\(enabled) up=\(settings.up.rawValue) down=\(settings.down.rawValue) pinch=\(settings.pinch) " +
            "buttons=\(buttons) trusted=\(AXIsProcessTrusted()) screenCapture=\(DockWindowShots.shared.allowed) " +
            "ownDock=\(dock.enabled) ownDockReplaces=\(dock.replacesSystemDock) previews=\(dock.hub.windowPreviews) " +
            "scrollWindows=\(dock.appearance.scrollWindows) performed=\(performed) swallowed=\(swallowed) passed=\(passed) " +
            "buttonPresses=\(buttonPresses) last=\(lastGesture ?? "-") route=\(lastRoute ?? "-") " +
            "card=\(dock.stage.peek.map { "\($0.title):\($0.thumbs.count)" } ?? "-") pinned=\(pinned?.path ?? "-")"
    }

    /// `atelier://dockgestures?…`, for checking a build from the command line. `report` writes
    /// `$TMPDIR/atelier-dockgestures.txt`.
    ///
    /// - `simulate=swipeUp|swipeDown|pinch&app=ID` — does what that gesture is set to, to the app
    ///   (bundle id or name). `pinch` arms the confirm like a first pinch; `confirm=1` quits at once.
    /// - `feed=up|down|left|right&app=ID` — sends a made-up two-finger scroll through the real
    ///   router and classifier, as the dock would: up/down should act, left/right should not.
    /// - `show=ID` — opens the Atelier Dock's card at that app's tile and holds it for 20 s
    ///   (until the pointer comes to the dock). `hide` takes it down.
    /// - `button=close|minimize&index=N` — presses that button on picture N of the open card.
    /// - `report` — settings, counters and what the open card lists.
    /// - `on=1|0`, `up=expose|restore|none`, `down=minimize|hide|none`, `pinch=1|0`, `buttons=1|0`.
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let target = value("app").flatMap(findApp)
        for item in items {
            switch (item.name, item.value ?? "") {
            case ("on", let on): enabled = on == "1"
            case ("up", let name): if let action = OwnDockGestureAction(rawValue: name) { settings.up = action }
            case ("down", let name): if let action = OwnDockGestureAction(rawValue: name) { settings.down = action }
            case ("pinch", let on): settings.pinch = on == "1"
            case ("buttons", let on): buttons = on == "1"
            case ("simulate", let name):
                guard let kind = OwnDockGestureKind(rawValue: name), let slot = target.flatMap(slot) else { break }
                perform(kind, slot: slot, confirmed: value("confirm") == "1")
            case ("feed", let direction):
                guard let slot = target.flatMap(slot) else { break }
                feed(direction, slot: slot)
            case ("show", let name):
                guard let app = findApp(name), let path = app.bundleURL?.path else { break }
                if OwnDock.shared.gestureShowPeek(path) { pinned = (path, CACurrentMediaTime() + 20) }
            case ("hide", _):
                pinned = nil
                hidePill()
                OwnDock.shared.gestureFeedback(nil)
            case ("button", let name):
                guard let button = OwnDockPeekButtons.Button(rawValue: name), let peek = OwnDock.shared.stage.peek else { break }
                let index = value("index").flatMap(Int.init) ?? 0
                if peek.thumbs.indices.contains(index) { press(button, thumb: peek.thumbs[index]) }
            case ("report", _):
                report()
            default:
                break
            }
        }
    }

    private func findApp(_ name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == name || $0.localizedName?.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    private func slot(_ app: NSRunningApplication) -> DockSlot? {
        guard let path = app.bundleURL?.path else { return nil }
        let id = OwnDock.shared.stage.scene.tiles.first { $0.slot.kind == .app && $0.slot.path == path }?.id ?? "gesture.test"
        return DockSlot(id: id, kind: .app, path: path, title: app.localizedName ?? "", running: true)
    }

    /// A two-finger scroll of 12 steps of 6 points, through the router and classifier. The result
    /// lands in `lastRoute` and `lastGesture`.
    private func feed(_ direction: String, slot: DockSlot) {
        let step: (dx: Double, dy: Double) = switch direction {
        case "up": (0, 6)
        case "down": (0, -6)
        case "left": (-6, 0)
        default: (6, 0)
        }
        reset()
        gestureTile = slot.id
        var routes: [OwnDockSwipeRouter.Route] = []
        let start = CACurrentMediaTime()
        let phases: [SystemDockScrollPhase] = [.began] + Array(repeating: .changed, count: 12) + [.ended]
        for (index, phase) in phases.enumerated() {
            let now = start + Double(index) * 0.008
            let dx = phase == .ended ? 0 : step.dx, dy = phase == .ended ? 0 : step.dy
            let route = router.route(dx: dx, dy: dy, continuous: true, phase: phase, swipes: settings.swipes, at: now)
            routes.append(route)
            guard route != .scroll else { continue }
            if let gesture = classifier.scroll(upward: dy, sideways: dx, continuous: true, phase: phase, at: now),
               let kind = OwnDockGestureKind(gesture) {
                perform(kind, slot: slot)
            }
        }
        let counts = Dictionary(grouping: routes, by: { "\($0)" }).mapValues(\.count)
        lastRoute = "feed-\(direction):" + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    private func report() {
        let dock = OwnDock.shared
        var lines = [diagnostics]
        if let peek = dock.stage.peek {
            lines.append("cardTitle=\(peek.title) status=\(peek.status) label=\(peek.label) rows=\(peek.rows.count) shown=\(dock.stage.scene.peekShow > 0.5)")
            for (index, thumb) in peek.thumbs.enumerated() {
                lines.append("thumb \(index) id=\(thumb.id) minimised=\(thumb.minimized) picture=\(thumb.image != nil) " +
                             "axRef=\(dock.gesturePeekRef(thumb.id) != nil) title=\(thumb.title)")
            }
        } else {
            lines.append("card=-")
        }
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-dockgestures.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - Screen Recording, read cheaply

/// Screen Recording, read at most every two seconds: the window card asks for every picture it
/// draws, at display rate. Never cached for longer, so a grant made while Atelier runs is seen
/// within two seconds, with no relaunch.
///
/// `CGPreflightScreenCaptureAccess` can go on answering false for the rest of the process's
/// life after the owner turns Screen Recording on. The window server says it sooner: without
/// the grant it leaves other apps' window names out of its list, with it they are there. Neither
/// read ever asks the user for anything.
@MainActor
enum ScreenRecordingFlag {
    private static var value = false
    private static var at = -Double.infinity

    static var allowed: Bool {
        let now = CACurrentMediaTime()
        if now - at > 2 {
            value = CGPreflightScreenCaptureAccess() || otherWindowNamesVisible()
            at = now
        }
        return value
    }

    /// True when the window list names a window of another app, which it does only with Screen
    /// Recording allowed. Normal windows only: the system's own processes are left out.
    private static func otherWindowNamesVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let system: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center"]
        return list.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != me,
                  !system.contains(window[kCGWindowOwnerName as String] as? String ?? ""),
                  let name = window[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }
}

// MARK: - Views

/// Close and minimise on the picture under the pointer, drawn over `DockThumbCard` in its own
/// coordinates. Drawing only: the dock's input view hit tests the same rects (`OwnDockPeekButtons`).
struct OwnDockPeekButtonsOverlay: View {
    let peek: DockPeek
    let edge: OwnDockEdge
    let hot: Int?
    @ObservedObject private var stage = OwnDockGestures.shared.stage

    var body: some View {
        let count = min(peek.thumbs.count, DockPeekLayout.most)
        let size = DockPeekLayout.size(count: count, edge: edge)
        ZStack(alignment: .topLeading) {
            if let hot, hot < count, OwnDockGestures.shared.buttonsActive {
                let cell = DockPeekLayout.cellFrame(hot, count: count, edge: edge)
                ForEach(OwnDockPeekButtons.rects(cell: cell, minimized: peek.thumbs[hot].minimized), id: \.0) { button, rect in
                    WindowButtonFace(symbol: button == .close ? "xmark" : "minus",
                                     tint: button == .close ? WindowButtonFace.closeTint : WindowButtonFace.minimizeTint,
                                     lit: stage.lit == button)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(DS.Motion.touch, value: hot)
        .animation(DS.Motion.hover, value: stage.lit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class OwnDockPillModel: ObservableObject {
    @Published var name = ""
    @Published var visible = false
}

private struct OwnDockPillRoot: View {
    @ObservedObject var model: OwnDockPillModel
    let quit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SystemDockPeekPill(name: model.name, quit: quit)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible || reduceMotion ? 1 : 0.94)
            .environment(\.colorScheme, .dark)
    }
}

/// Clicks land on the pill even though Atelier is not the active app.
private final class OwnDockPillHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
