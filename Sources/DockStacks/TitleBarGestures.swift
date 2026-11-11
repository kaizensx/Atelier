import AppKit
import ApplicationServices
import Combine
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Title Bar Gestures
//
// Swish-style: rest the pointer on a window's title bar and use two fingers. Swipe left or right
// tiles it to that half (again: on to the next display), up maximises (again: full screen), down
// restores or centres (again: minimises), a pinch in closes it and a pinch out makes it full
// screen; the diagonals take the quarters. A glass slab shows where the window will go while the
// fingers move, follows them on a spring, and the window lands there when they lift.
//
// How it hears the fingers. Atelier already reads the trackpad's raw finger stream for Trackpad
// Gestures (Multitouch.swift). This feature does not open a second stream: it asks that one to
// keep running (`TrackpadGestures.watch`, the same call the live card makes, which runs no
// action while that feature is off) and reads the newest finger frame (`touchEngine.latest`)
// once per display frame, only while a finger is down. The pure recogniser in DockCore
// (TitleBarGestureLogic.swift) turns those frames into a gesture.
//
// When it acts. Only when two fingers land while the pointer is in a title-bar band: from the
// window's top edge down `band` points (40 by default), or to the bottom of its toolbar. The
// look-up happens once, the moment two fingers anchor: a cheap window-server list first, then
// Accessibility for the window itself. Anywhere else the touch is left entirely alone, so two-
// finger scrolling is untouched.
//
// Keeping the window still. A two-finger swipe is also a scroll. While a title-bar gesture is
// recognised, an event tap drops its scroll (and pinch) events, then the momentum that follows
// the lift, so the window's content never moves under the gesture. Nothing is dropped at any
// other time; a fresh scroll always ends the momentum tail early.

/// The tap's view of the gesture, read on the main run loop (the tap's source lives there).
private nonisolated(unsafe) var titleBarTap: CFMachPort?
/// A title-bar gesture is recognised right now: its scroll and pinch events are not the window's.
private nonisolated(unsafe) var titleBarClaim = false
/// After the lift: until then, the claimed scroll's momentum is dropped too.
private nonisolated(unsafe) var titleBarTailUntil = 0.0
/// Events dropped since launch, for diagnostics.
private nonisolated(unsafe) var titleBarSwallowed = 0

/// NSEventTypeGesture and NSEventTypeMagnify: not in CGEventType, but tappable by number.
private let gestureEventType: UInt32 = 29
private let magnifyEventType: UInt32 = 30

private func titleBarTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                 _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let titleBarTap { CGEvent.tapEnable(tap: titleBarTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if titleBarClaim {
        titleBarSwallowed += 1
        return nil
    }
    // The momentum after a claimed swipe: dropped until it ends, or until a new scroll begins.
    if type == .scrollWheel, titleBarTailUntil > 0 {
        if CACurrentMediaTime() > titleBarTailUntil {
            titleBarTailUntil = 0
        } else {
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            // kCGScrollPhaseBegan (1) with no momentum: a new touch scrolling. It is the window's.
            if phase == 1 && momentum == 0 {
                titleBarTailUntil = 0
                return Unmanaged.passUnretained(event)
            }
            titleBarSwallowed += 1
            // kCGMomentumScrollPhaseEnd (3): the tail is over after this one.
            if momentum == 3 { titleBarTailUntil = 0 }
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
}

extension TitleBarGesture {
    var title: String {
        switch self {
        case .left: "Swipe Left"
        case .right: "Swipe Right"
        case .up: "Swipe Up"
        case .down: "Swipe Down"
        case .topLeft: "Swipe Up and Left"
        case .topRight: "Swipe Up and Right"
        case .bottomLeft: "Swipe Down and Left"
        case .bottomRight: "Swipe Down and Right"
        case .pinchIn: "Pinch In"
        case .pinchOut: "Pinch Out"
        }
    }

    var symbol: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        case .pinchIn: "arrow.down.right.and.arrow.up.left"
        case .pinchOut: "arrow.up.left.and.arrow.down.right"
        }
    }
}

extension TitleBarAction {
    var title: String {
        switch self {
        case .none: "Nothing"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .displayLeft: "Display on the Left"
        case .displayRight: "Display on the Right"
        case .nextDisplay: "Next Display"
        case .minimize: "Minimize"
        case .fullScreen: "Full Screen"
        case .close: "Close Window"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .maximize: "rectangle.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        case .displayLeft: "rectangle.leadinghalf.inset.filled.arrow.leading"
        case .displayRight: "rectangle.trailinghalf.inset.filled.arrow.trailing"
        case .nextDisplay: "display.2"
        case .minimize: "minus.rectangle"
        case .fullScreen: "arrow.up.backward.and.arrow.down.forward"
        case .close: "xmark.rectangle"
        }
    }

    /// The choices offered in the card's menus, grouped.
    static let tiles: [TitleBarAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight]
    static let sizes: [TitleBarAction] = [.maximize, .center, .restore]
    static let displaysGroup: [TitleBarAction] = [.displayLeft, .displayRight, .nextDisplay]
    static let window: [TitleBarAction] = [.minimize, .fullScreen, .close]
}

extension TitleBarPlan {
    /// For the preview's chip and the test hook's report.
    var label: String {
        switch self {
        case .nothing(let why): why
        case .frame: "Move"
        case .fullScreen(let on): on ? "Full Screen" : "Exit Full Screen"
        case .minimize: "Minimize"
        case .close: "Close"
        }
    }

    var report: String {
        switch self {
        case .nothing(let why): "nothing(\(why))"
        case .frame(let r, let d): "frame=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height)) display=\(d)"
        case .fullScreen(let on): "fullScreen=\(on)"
        case .minimize: "minimize"
        case .close: "close"
        }
    }
}

@MainActor
final class TitleBarGestures: ObservableObject {
    static let shared = TitleBarGestures()

    // MARK: Settings (UserDefaults, "titleBarGestures.")

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: Key.enabled); apply() } }
    /// Larger is more eager: the swipe and pinch thresholds are divided by it.
    @Published var sensitivity: Double { didSet { store.set(sensitivity, forKey: Key.sensitivity); retune() } }
    /// How far below the window's top edge the title bar reaches, in points.
    @Published var band: Double { didSet { store.set(band, forKey: Key.band) } }
    /// A toolbar below the title bar counts as title bar too (Finder, Safari, Mail, Xcode).
    @Published var includeToolbar: Bool { didSet { store.set(includeToolbar, forKey: Key.toolbar) } }
    @Published var diagonals: Bool { didSet { store.set(diagonals, forKey: Key.diagonals); retune() } }
    @Published var haptics: Bool { didSet { store.set(haptics, forKey: Key.haptics) } }
    @Published private(set) var bindings: [TitleBarGesture: TitleBarBinding]

    // MARK: Live state, for the card

    /// The last gesture committed (live or simulated), what it did, and when.
    @Published private(set) var lastFired: (gesture: TitleBarGesture, plan: String, again: Bool, at: Date)?
    @Published private(set) var lastError: String?
    @Published private(set) var trusted = AXIsProcessTrusted()

    private enum Key {
        static let enabled = "titleBarGestures.enabled"
        static let sensitivity = "titleBarGestures.sensitivity"
        static let band = "titleBarGestures.band"
        static let toolbar = "titleBarGestures.includeToolbar"
        static let diagonals = "titleBarGestures.diagonals"
        static let haptics = "titleBarGestures.haptics"
        static let bindings = "titleBarGestures.bindings"
    }

    private let store = UserDefaults.standard
    private var recognizer = TitleBarRecognizer()
    private var watching = false
    private var touchSink: AnyCancellable?
    private var source: CFRunLoopSource?
    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private let ticker = TitleBarTicker()
    private var lastTick = 0.0
    private var activationObserver: NSObjectProtocol?
    private var lastExternal: pid_t?
    private let preview = TitleBarPreview()
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // The app under the pointer may have stopped answering: a tenth of a second, not six.
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }()

    /// The window the current touch is about, found when two fingers anchored.
    private var target: Target?
    /// Frames from before Atelier first tiled a window, for Restore. Keyed by CFHash of its element.
    private var savedFrames: [Int: CGRect] = [:]
    /// What Atelier last did to each window, for the repeated-swipe cycle.
    private var commits: [Int: TitleBarCommit] = [:]
    /// A simulated gesture playing through the preview: `atelier://titlebar?simulate=`.
    private var simulation: (gesture: TitleBarGesture, target: Target, start: Double, dry: Bool)?

    // Diagnostics.
    private var anchors = 0
    private var armed = 0
    private var claims = 0
    private(set) var commitsRun = 0
    private var lastPlanReport = "-"
    private var wasClaimed = false

    private struct Target {
        let element: AXUIElement
        let pid: pid_t
        let key: Int
        let frame: CGRect
        let isFullScreen: Bool
        let movable: Bool
        let windowNumber: Int?
        let displays: [TitleBarDisplay]
        let appName: String
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Key.enabled)
        sensitivity = d.object(forKey: Key.sensitivity) as? Double ?? 1
        band = d.object(forKey: Key.band) as? Double ?? 40
        includeToolbar = d.object(forKey: Key.toolbar) as? Bool ?? true
        diagonals = d.object(forKey: Key.diagonals) as? Bool ?? true
        haptics = d.object(forKey: Key.haptics) as? Bool ?? true
        let saved = d.data(forKey: Key.bindings)
            .flatMap { try? JSONDecoder().decode([String: TitleBarBinding].self, from: $0) } ?? [:]
        var bindings: [TitleBarGesture: TitleBarBinding] = [:]
        for gesture in TitleBarGesture.allCases { bindings[gesture] = saved[gesture.rawValue] ?? .standard(gesture) }
        self.bindings = bindings
        retune()
    }

    // MARK: Lifecycle

    func resume() {
        AccessWatch.shared.start()
        if enabled { apply() }
    }

    /// Leaves the system as it was: tap removed, stream released, preview gone. Nothing this
    /// feature does persists outside Atelier's own settings.
    func restoreOnQuit() {
        stopTap()
        stopLink()
        preview.hide(immediately: true)
        if watching { TrackpadGestures.shared.watch(false); watching = false }
        touchSink = nil
        titleBarClaim = false
        titleBarTailUntil = 0
    }

    /// Unavailable without the trackpad sensor (Trackpad Gestures' own verdict: framework, a
    /// trackpad, mice excluded). Accessibility is asked for separately by the card.
    var availability: FeatureAvailability {
        let gestures = TrackpadGestures.shared.availability
        if case .unavailable = gestures { return gestures }
        return .available
    }

    var tapActive: Bool { titleBarTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    var diagnostics: String {
        "tbgOn=\(enabled) tbgTrusted=\(trusted) tbgTap=\(tapActive) tbgStream=\(TrackpadGestures.shared.running) " +
        "tbgAnchors=\(anchors) tbgArmed=\(armed) tbgClaims=\(claims) tbgCommits=\(commitsRun) " +
        "tbgSwallowed=\(titleBarSwallowed) tbgLast=\(lastFired.map { "\($0.gesture.rawValue)\($0.again ? "+again" : "")" } ?? "-") " +
        "tbgPlan=\(lastPlanReport.replacingOccurrences(of: " ", with: "_"))"
    }

    func binding(_ gesture: TitleBarGesture) -> TitleBarBinding { bindings[gesture] ?? .standard(gesture) }

    func set(_ binding: TitleBarBinding, for gesture: TitleBarGesture) {
        bindings[gesture] = binding
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { store.set(data, forKey: Key.bindings) }
    }

    func resetBindings() {
        for gesture in TitleBarGesture.allCases { set(.standard(gesture), for: gesture) }
    }

    /// The card calls this as it appears: a grant made in System Settings shows up.
    func refreshTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        apply()
    }

    private func retune() {
        var tuning = TitleBarTuning()
        tuning.sensitivity = sensitivity
        tuning.diagonals = diagonals
        recognizer.tuning = tuning
    }

    private func apply() {
        trusted = AXIsProcessTrusted()
        if enabled && !trusted {
            // Idle until the grant: no multitouch stream, no display link, no tap. AccessWatch
            // reads the flag every two seconds and calls `refreshTrust()` when it lands.
            stopTap()
            stopLink()
            touchSink = nil
            if watching { TrackpadGestures.shared.watch(false); watching = false }
            recognizer.reset()
            target = nil
            titleBarClaim = false
            titleBarTailUntil = 0
        } else if enabled {
            // The stream first: it is what this feature listens to.
            if !watching, TrackpadGestures.shared.available {
                TrackpadGestures.shared.watch(true)
                watching = true
            }
            if touchSink == nil {
                touchSink = TrackpadGestures.shared.$touching.removeDuplicates().sink { touching in
                    // @Published sends before the value lands; act on the next turn.
                    if touching { DispatchQueue.main.async { MainActor.assumeIsolated { TitleBarGestures.shared.startLink() } } }
                }
            }
            if activationObserver == nil {
                activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                    let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                    MainActor.assumeIsolated {
                        if let pid, pid != ProcessInfo.processInfo.processIdentifier { TitleBarGestures.shared.lastExternal = pid }
                    }
                }
            }
            startTap()
        } else {
            stopTap()
            stopLink()
            touchSink = nil
            if watching { TrackpadGestures.shared.watch(false); watching = false }
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil
            recognizer.reset()
            target = nil
            simulation = nil
            preview.hide(immediately: true)
            titleBarClaim = false
            titleBarTailUntil = 0
        }
        objectWillChange.send()
    }

    // MARK: The scroll tap

    private func startTap() {
        guard titleBarTap == nil else { return }
        var mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        mask |= CGEventMask(1) << gestureEventType
        mask |= CGEventMask(1) << magnifyEventType
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: titleBarTapCallback, userInfo: nil) else {
            lastError = "Couldn’t watch scrolling. Check Accessibility in System Settings."
            return
        }
        titleBarTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        lastError = nil
    }

    private func stopTap() {
        guard let tap = titleBarTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        titleBarTap = nil
        source = nil
    }

    // MARK: The frame loop

    /// Runs at display rate (120 Hz on ProMotion) while a finger is down or the preview moves.
    fileprivate func startLink() {
        guard enabled, trusted else { return }
        lastTick = CACurrentMediaTime()
        if let link { link.isPaused = false; return }
        if fallbackTimer != nil { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let next = screen?.displayLink(target: ticker, selector: #selector(TitleBarTicker.tick(_:))) {
            next.add(to: .main, forMode: .common)
            link = next
        } else {
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { TitleBarGestures.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func pauseLink() {
        link?.isPaused = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1 / 240), 1 / 20)
        lastTick = now
        if let simulation {
            stepSimulation(simulation, now: now)
        } else {
            stepTouch(now: now)
        }
        let moving = preview.step(dt: dt)
        let touching = TrackpadGestures.shared.touching || recognizer.active
        if !touching && !moving && simulation == nil { pauseLink() }
    }

    private func stepTouch(now: Double) {
        let samples = touchEngine.withLock { $0.latest }
        let reading = recognizer.feed(TouchFrame(time: now, touches: samples))
        if reading.anchored {
            anchors += 1
            target = trusted ? resolveTarget() : nil
            if target == nil { recognizer.spoil() } else { armed += 1 }
        }
        let claimed = reading.claimed && target != nil
        if claimed && !wasClaimed { claims += 1 }
        wasClaimed = claimed && recognizer.active
        titleBarClaim = claimed && recognizer.active

        if let target {
            if let gesture = reading.committed {
                commit(gesture, on: target)
                titleBarTailUntil = now + 1.0
                self.target = nil
            } else if reading.cancelled {
                preview.hide()
                titleBarTailUntil = now + 0.6
                self.target = nil
            } else if reading.active, let candidate = reading.candidate {
                let (plan, again) = TitleBarPlanner.plan(candidate, binding: binding(candidate), context: context(for: target))
                showPreview(plan, gesture: candidate, again: again, progress: reading.progress, target: target)
            } else if reading.active {
                // Back near where the fingers started: the slab shrinks back into the window.
                preview.retract(to: target.frame)
            }
        }
        if !recognizer.active {
            if target != nil {
                // Lifted below every threshold.
                preview.hide()
                if reading.claimed { titleBarTailUntil = now + 0.6 }
            }
            target = nil
            titleBarClaim = false
            wasClaimed = false
        }
    }

    private func showPreview(_ plan: TitleBarPlan, gesture: TitleBarGesture, again: Bool, progress: Double, target: Target) {
        guard let rect = plan.previewTarget(window: target.frame, displays: target.displays) else {
            preview.retract(to: target.frame)
            return
        }
        let shown = TitleBarGeometry.preview(from: target.frame, to: rect, progress: progress)
        let action = again ? binding(gesture).again : binding(gesture).first
        let style: TitleBarPreviewModel.Style = switch plan {
        case .close: .danger
        case .minimize: .quiet
        default: .tile
        }
        preview.show(rect: shown, title: action.title, symbol: action.symbol, style: style, ready: progress >= 1,
                     displays: target.displays, from: target.frame, below: target.windowNumber)
    }

    // MARK: Hit-testing

    /// The window whose title bar is under the pointer now, or nil. Two steps: the window-server
    /// list (no Accessibility, a millisecond) rules out a pointer far from any window top; only
    /// then is the app asked, once, with a tenth-of-a-second budget.
    private func resolveTarget() -> Target? {
        guard let pointer = CGEvent(source: nil)?.location else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let listed = Self.listedWindows()
        guard let top = listed.first(where: { $0.layer == 0 && $0.bounds.contains(pointer) }), top.pid != own else { return nil }
        // Generous here (toolbars can be tall); the exact band is checked below.
        guard pointer.y - top.bounds.minY <= max(band, 140) else { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(pointer.x), Float(pointer.y), &hit) == .success,
              let element = hit, let window = Self.window(containing: element) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != own else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard (Self.value(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
              let frame = Self.frame(of: window) else { return nil }
        let toolbar = includeToolbar ? Self.toolbarBottom(of: window) : nil
        guard TitleBarGeometry.inTitleBar(pointer, window: frame, band: band, toolbarBottom: toolbar) else { return nil }
        let full = (Self.value(window, "AXFullScreen") as? Bool) ?? false
        var settable = DarwinBoolean(false)
        let movable = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        let number = top.pid == pid ? top.id : WindowGeometry.windowID(pid: pid, frame: frame, in: listed)
        return Target(element: window, pid: pid, key: Self.stableKey(window), frame: frame, isFullScreen: full, movable: movable,
                      windowNumber: number, displays: Self.displays(),
                      appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App")
    }

    /// The focused window of the front app (Atelier excluded), for the test hook.
    private func frontTarget() -> Target? {
        let own = ProcessInfo.processInfo.processIdentifier
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == own { app = lastExternal.flatMap { NSRunningApplication(processIdentifier: $0) } }
        guard let app else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let raw = Self.value(element, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        guard let frame = Self.frame(of: window) else { return nil }
        let full = (Self.value(window, "AXFullScreen") as? Bool) ?? false
        var settable = DarwinBoolean(false)
        let movable = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        return Target(element: window, pid: app.processIdentifier, key: Self.stableKey(window), frame: frame, isFullScreen: full,
                      movable: movable, windowNumber: WindowGeometry.windowID(pid: app.processIdentifier, frame: frame, in: Self.listedWindows()),
                      displays: Self.displays(), appName: app.localizedName ?? "App")
    }

    private func context(for target: Target) -> TitleBarContext {
        let last = commits[target.key]
        // Restore only means something while the window is still where Atelier put it (or back
        // at its saved frame). Moved by hand since, it has no "before" any more.
        var saved = savedFrames[target.key]
        if let s = saved, !(last.map { TitleBarGeometry.matches(target.frame, $0.landed) } ?? false),
           !TitleBarGeometry.matches(target.frame, s) {
            saved = nil
        }
        return TitleBarContext(window: target.key, frame: target.frame, displays: target.displays, gap: WindowEngine.shared.gap,
                               saved: saved, isFullScreen: target.isFullScreen, last: last)
    }

    // MARK: Committing

    private func commit(_ gesture: TitleBarGesture, on target: Target) {
        let ctx = context(for: target)
        let (plan, again) = TitleBarPlanner.plan(gesture, binding: binding(gesture), context: ctx)
        lastPlanReport = plan.report
        lastFired = (gesture, plan.label, again, .now)
        lastError = nil
        switch plan {
        case .nothing:
            preview.hide()
            return
        case .frame(let rect, let display):
            guard target.movable else {
                lastError = "\(target.appName) doesn’t let this window move."
                preview.hide()
                return
            }
            // Remember where it was before Atelier first placed it, for Restore.
            let placed = ctx.last.map { TitleBarGeometry.matches(target.frame, $0.landed) } ?? false
            if !placed && ctx.saved == nil { savedFrames[target.key] = target.frame }
            let landed = place(target.element, at: rect, bounds: target.displays[display].visible)
            commits[target.key] = TitleBarCommit(window: target.key, gesture: gesture, landed: landed ?? rect)
            preview.land(on: landed ?? rect)
        case .fullScreen(let on):
            AXUIElementSetAttributeValue(target.element, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
            commits[target.key] = nil
            preview.hide()
        case .minimize:
            if !MinimizeRedirect.shared.minimizeIfActive(target.element) {
                AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
            commits[target.key] = nil
            preview.hide()
        case .close:
            if let button = Self.value(target.element, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            } else {
                lastError = "\(target.appName) has no close button on this window."
            }
            commits[target.key] = nil
            savedFrames[target.key] = nil
            preview.hide()
        }
        commitsRun += 1
        if haptics { Haptics.shared.play(.medium) }
    }

    /// Position, size, position again, then a check and one retry. Size first was wrong: a size
    /// that does not fit at the old position makes AppKit constrain the window, and some apps
    /// (TextEdit) then drop the position that follows, leaving the window where it was.
    private func place(_ window: AXUIElement, at target: CGRect, bounds: CGRect) -> CGRect? {
        for _ in 0..<2 {
            Self.set(window, origin: target.origin)
            Self.set(window, size: target.size)
            Self.set(window, origin: target.origin)
            guard let now = Self.frame(of: window) else { return nil }
            if abs(now.minX - target.minX) <= 2 && abs(now.minY - target.minY) <= 2 { break }
            usleep(40_000)
        }
        guard let actual = Self.frame(of: window) else { return nil }
        if actual.width > target.width + 2 || actual.height > target.height + 2 {
            // The app refused the size: keep the larger window on the display.
            Self.set(window, origin: WindowGeometry.settledOrigin(actual: actual.size, target: target, bounds: bounds))
            return Self.frame(of: window)
        }
        return actual
    }

    // MARK: Test hook

    /// `atelier://titlebar?simulate=left|right|up|down|topLeft|topRight|bottomLeft|bottomRight|pinchIn|pinchOut`
    /// plays the gesture on the front window (Atelier excluded) exactly as if it had come from the
    /// trackpad over its title bar: the preview grows for a quarter second, then the window moves.
    /// `dry=1` plans and reports without touching the window. Also `on=0|1`, `sensitivity=`,
    /// `band=`, `reset=1` (bindings back to defaults), `report=1`. Every call writes
    /// `$TMPDIR/atelier-titlebar.txt`: the window, the plan, and the diagnostics line.
    func handleTest(_ items: [URLQueryItem]) {
        var lines: [String] = []
        for item in items {
            let value = item.value ?? ""
            switch item.name {
            case "on": enabled = value == "1"
            case "sensitivity": if let v = Double(value) { sensitivity = min(max(v, 0.5), 2) }
            case "band": if let v = Double(value) { band = min(max(v, 20), 120) }
            case "reset": resetBindings()
            default: break
            }
        }
        let dry = items.contains { $0.name == "dry" && $0.value == "1" }
        if let raw = items.first(where: { $0.name == "simulate" })?.value {
            if let gesture = TitleBarGesture(rawValue: raw) {
                if !AXIsProcessTrusted() {
                    lines.append("error=accessibility")
                } else if let target = frontTarget() {
                    let (plan, again) = TitleBarPlanner.plan(gesture, binding: binding(gesture), context: context(for: target))
                    lines.append("app=\(target.appName) window=\(Int(target.frame.minX)),\(Int(target.frame.minY)),\(Int(target.frame.width))x\(Int(target.frame.height)) fullScreen=\(target.isFullScreen) movable=\(target.movable)")
                    lines.append("gesture=\(gesture.rawValue) again=\(again) plan=\(plan.report) dry=\(dry)")
                    lastPlanReport = plan.report
                    simulation = (gesture, target, CACurrentMediaTime(), dry)
                    startLinkForSimulation()
                } else {
                    lines.append("error=no-front-window")
                }
            } else {
                lines.append("error=unknown-gesture(\(raw)) known=\(TitleBarGesture.allCases.map(\.rawValue).joined(separator: ","))")
            }
        }
        lines.append(diagnostics)
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-titlebar.txt", atomically: true, encoding: .utf8)
    }

    private func startLinkForSimulation() {
        // The loop normally waits for a finger; a simulation runs it by itself.
        lastTick = CACurrentMediaTime()
        if link == nil && fallbackTimer == nil {
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { TitleBarGestures.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        } else {
            link?.isPaused = false
        }
    }

    private func stepSimulation(_ sim: (gesture: TitleBarGesture, target: Target, start: Double, dry: Bool), now: Double) {
        let progress = (now - sim.start) / 0.25
        let (plan, again) = TitleBarPlanner.plan(sim.gesture, binding: binding(sim.gesture), context: context(for: sim.target))
        if progress < 1 {
            showPreview(plan, gesture: sim.gesture, again: again, progress: progress, target: sim.target)
            return
        }
        simulation = nil
        if sim.dry {
            lastFired = (sim.gesture, plan.label, again, .now)
            preview.hide()
        } else {
            commit(sim.gesture, on: sim.target)
        }
    }

    // MARK: Accessibility and window-server helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              let extent = value(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The window's CGWindowID, which stays the same for the window's life; CFHash of an AX
    /// element does not survive a fresh lookup, which made Restore and "again" forget the window.
    private static func stableKey(_ window: AXUIElement) -> Int {
        typealias Get = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            var id: CGWindowID = 0
            if unsafeBitCast(symbol, to: Get.self)(window, &id) == .success, id != 0 { return Int(id) }
        }
        return Int(CFHash(window))
    }

    private static func set(_ window: AXUIElement, origin: CGPoint) {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func set(_ window: AXUIElement, size: CGSize) {
        var dimensions = size
        guard let value = AXValueCreate(.cgSize, &dimensions) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// The element's window: named directly by most elements, else found by walking up.
    private static func window(containing element: AXUIElement) -> AXUIElement? {
        if (value(element, kAXRoleAttribute) as? String) == kAXWindowRole { return element }
        if let window = value(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            return (window as! AXUIElement)
        }
        var current = element
        for _ in 0..<32 {
            guard let parent = value(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            if (value(current, kAXRoleAttribute) as? String) == kAXWindowRole { return current }
        }
        return nil
    }

    /// The bottom edge of the window's toolbar, if it has one among its direct children.
    private static func toolbarBottom(of window: AXUIElement) -> Double? {
        guard let children = value(window, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children.prefix(40) where (value(child, kAXRoleAttribute) as? String) == kAXToolbarRole {
            if let frame = frame(of: child) { return frame.maxY }
        }
        return nil
    }

    private static func listedWindows() -> [WindowGeometry.ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return WindowGeometry.ListedWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// Every display in Accessibility coordinates, its visible frame less Stage Manager's strip
    /// when the strip is showing (read from WindowManager's own preferences, never written).
    private static func displays() -> [TitleBarDisplay] {
        let height = Double(NSScreen.screens.first?.frame.height ?? 0)
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        let stage = WindowsCompatTiling.stageManagerOn(
            CFPreferencesCopyAppValue(WindowsCompatTiling.stageManagerKey as CFString, domain) as? Bool)
        let stripHidden = (CFPreferencesCopyAppValue("AutoHide" as CFString, domain) as? Bool) ?? false
        return NSScreen.screens.map { screen in
            let visible = WindowGeometry.flipped(ScreenArea.usable(screen), primaryHeight: height)
            return TitleBarDisplay(frame: WindowGeometry.flipped(screen.frame, primaryHeight: height),
                                   visible: TitleBarGeometry.usable(visible, stageManager: stage, stripHidden: stripHidden))
        }
    }
}

/// The display link's target: CADisplayLink wants a selector, and it runs on the main run loop.
private final class TitleBarTicker: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { TitleBarGestures.shared.tick() }
    }
}

// MARK: - The preview slab

@MainActor
final class TitleBarPreviewModel: ObservableObject {
    enum Style { case tile, quiet, danger }
    /// In the panel's own coordinates (top left of the area it covers).
    @Published var rect = CGRect.zero
    @Published var title = ""
    @Published var symbol = "rectangle"
    @Published var style = Style.tile
    /// The fingers have gone far enough: lifting now commits. The slab brightens.
    @Published var ready = false
    @Published var visible = false
}

/// Glass in the Window Engine's light, a hairline, and a chip naming what lifting will do.
struct TitleBarPreviewView: View {
    @ObservedObject var model: TitleBarPreviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        let tint: Color = switch model.style {
        case .tile: DS.Spectrum.windows
        case .quiet: .white
        case .danger: Color(red: 1, green: 0.36, blue: 0.34)
        }
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.clear
                .atelierGlass(.regular.tint(tint.opacity(model.ready ? 0.24 : 0.12)), in: shape)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(model.ready ? 0.8 : 0.5), .white.opacity(0.1)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: model.ready ? 1.5 : 1)
                }
                .overlay {
                    HStack(spacing: 7) {
                        Image(systemName: model.symbol).font(.system(size: 13, weight: .semibold))
                        Text(model.title).font(DS.title)
                    }
                    .foregroundStyle(DS.Ink.primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .atelierGlass(.regular, in: .capsule)
                    .opacity(model.rect.width > 160 && model.rect.height > 70 ? 1 : 0)
                    .contentTransition(.opacity)
                    .animation(DS.Motion.touch, value: model.title)
                }
                .frame(width: max(model.rect.width, 1), height: max(model.rect.height, 1))
                .scaleEffect(model.visible || reduceMotion ? 1 : 0.96)
                .opacity(model.visible ? 1 : 0)
                .animation(DS.Motion.touch, value: model.visible)
                .animation(DS.Motion.touch, value: model.ready)
                .offset(x: model.rect.minX, y: model.rect.minY)
        }
        .allowsHitTesting(false)
    }
}

/// The slab's window and its spring. The rectangle is sprung here, one step per display frame,
/// rather than by SwiftUI: a new target keeps the velocity, so the slab curves after the fingers
/// instead of restarting, and it never lags a frame behind them.
@MainActor
private final class TitleBarPreview {
    static let response = 0.2, damping = 0.86

    private let model = TitleBarPreviewModel()
    private var panel: NSPanel?
    private var area = CGRect.zero  // the panel's cover, Accessibility coordinates
    private var springs: [WindowGeometry.Spring] = []
    private var goal = CGRect.zero
    private var showing = false
    private var landing = false
    private var generation = 0
    private var orderedBelow: Int?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(rect: CGRect, title: String, symbol: String, style: TitleBarPreviewModel.Style, ready: Bool,
              displays: [TitleBarDisplay], from window: CGRect, below number: Int?) {
        generation += 1
        landing = false
        // Cover the displays of the window and of the target, so a move to the next display shows.
        var cover = CGRect.null
        for display in displays where display.frame.intersects(rect) || display.frame.intersects(window) {
            cover = cover.union(display.frame)
        }
        if cover.isNull { cover = displays.first?.frame ?? rect }
        let panel = self.panel ?? makePanel()
        let height = Double(NSScreen.screens.first?.frame.height ?? 0)
        if cover != area || !showing {
            area = cover
            panel.setFrame(WindowGeometry.flipped(cover, primaryHeight: height), display: false)
        }
        if !showing || springs.isEmpty || reduceMotion {
            // Grows out of the window it belongs to.
            let start = showing ? rect : window
            springs = [start.minX, start.minY, start.width, start.height].map { WindowGeometry.Spring(value: $0) }
            apply()
        }
        goal = rect
        model.title = title
        model.symbol = symbol
        model.style = style
        model.ready = ready
        // Ordered once per appearance, not per frame: just below the window it belongs to.
        if !showing || !panel.isVisible || orderedBelow != number {
            orderedBelow = number
            if let number {
                panel.level = .normal
                panel.order(.below, relativeTo: number)
            } else {
                panel.level = .floating
                panel.orderFrontRegardless()
            }
        }
        showing = true
        model.visible = true
    }

    /// The fingers went back: the slab shrinks into the window and fades.
    func retract(to window: CGRect) {
        guard showing else { return }
        goal = window
        model.ready = false
        model.visible = false
    }

    /// Committed: the slab settles on the window's new frame, then fades.
    func land(on rect: CGRect) {
        guard showing else { return }
        goal = rect
        model.ready = true
        landing = true
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func hide(immediately: Bool = false) {
        guard showing || immediately else { return }
        showing = false
        landing = false
        model.visible = false
        model.ready = false
        generation += 1
        let current = generation
        if immediately {
            panel?.orderOut(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// One display frame. Returns whether the slab is still moving.
    func step(dt: Double) -> Bool {
        guard showing || model.visible, springs.count == 4 else { return false }
        let targets = [goal.minX, goal.minY, goal.width, goal.height]
        if reduceMotion {
            for i in 0..<4 { springs[i] = WindowGeometry.Spring(value: targets[i]) }
        } else {
            for i in 0..<4 { springs[i].step(to: targets[i], dt: dt, response: Self.response, damping: Self.damping) }
        }
        apply()
        return (0..<4).contains { !springs[$0].isSettled(at: targets[$0]) } || landing
    }

    private func apply() {
        guard springs.count == 4 else { return }
        let rect = CGRect(x: springs[0].value, y: springs[1].value, width: max(springs[2].value, 1), height: max(springs[3].value, 1))
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { model.rect = rect.offsetBy(dx: -area.minX, dy: -area.minY) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.level = .normal
        panel.contentView = NSHostingView(rootView: TitleBarPreviewView(model: model))
        self.panel = panel
        return panel
    }
}
