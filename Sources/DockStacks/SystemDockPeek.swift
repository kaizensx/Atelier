import AppKit
import ApplicationServices
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Dock Peek for the macOS Dock
//
// Apple's own Dock, with Live Peek added from outside: no injection, SIP stays on.
//
// - Hover: an AXObserver on the Dock process watches its icon list for
//   kAXSelectedChildrenChangedNotification. The Dock "selects" the icon under the pointer, so the
//   selection is the hovered icon; its AXURL names the app and its AXFrame says where to put the
//   card. `SystemDockHoverMachine` (DockCore) decides when the card shows and hides.
// - Windows: the app's AXWindows, matched to window-server numbers with the private
//   `_AXUIElementGetWindow` (resolved at run time by `DockAX.windowID`, nil when missing), then
//   pictured by the same ScreenCaptureKit stills the Atelier Dock's Live Peek takes
//   (`DockWindowShots`), and drawn by its card (`DockThumbCard`).
// - Gestures: one active CGEventTap on scroll, magnify and mouse-down events. It acts only when
//   the pointer is on a running app's Dock icon; everywhere else every event passes untouched.
//   `SystemDockGestureClassifier` turns movement into at most one gesture per swipe or pinch.
//
// Never shown while the Atelier Dock stands in for the macOS Dock (that Dock has its own peek),
// and never while the Atelier Dock's own peek is on screen: one peek at a time. Nothing about the
// system is changed, so quitting only has to take the tap and the observer down.

private nonisolated(unsafe) var peekTap: CFMachPort?

/// NSEvent's gesture and magnify event types. CGEventType has no case for them.
private let gestureEventType: UInt32 = 29
private let magnifyEventType: UInt32 = 30

private func peekTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                             _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TapRevoke.disabled(type)
        if let peekTap { CGEvent.tapEnable(tap: peekTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // The tap's source is on the main run loop, so this is the main thread.
    nonisolated(unsafe) let seen = event
    let raw = type.rawValue
    let swallow = MainActor.assumeIsolated { SystemDockPeek.shared.tapped(raw, seen) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// One icon on the macOS Dock, as its Accessibility element describes it.
struct SystemDockIcon: Sendable, Equatable {
    /// The file the icon stands for, symlinks resolved.
    var path: String
    var title: String
    /// Global, top-left origin, as AX reports it.
    var frame: CGRect
    /// An application tile (not a folder, the Trash, a minimised window or a separator).
    var isApp: Bool
}

private struct PeekObserverBox: @unchecked Sendable {
    let observer: AXObserver
}

/// What the card on screen shows. Kept apart from the engine so only the card redraws.
@MainActor
final class SystemDockPeekStage: ObservableObject {
    @Published var peek: DockPeek?
    @Published var edge = OwnDockEdge.bottom
    @Published var notch: Double?
    @Published var hot: Int?
    @Published var visible = false
    /// "Pinch again to quit …": the app's name while the confirm is armed.
    @Published var quitPrompt: String?
    /// The room around the card for its shadow and notch, in points.
    let pad = 24.0
}

@MainActor
final class SystemDockPeek: ObservableObject {
    static let shared = SystemDockPeek()

    enum Key {
        static let enabled = "systemDockPeek.enabled"
        static let previews = "systemDockPeek.previews"
        static let delay = "systemDockPeek.hoverDelay"
        static let gesture = "systemDockPeek.gesture."
    }

    /// The whole feature: the hover card and the gestures.
    @Published var enabled: Bool { didSet { store.set(enabled, forKey: Key.enabled); reconcile() } }
    /// The hover card. Off leaves only the gestures.
    @Published var previews: Bool { didSet { store.set(previews, forKey: Key.previews); if !previews { hideCard() } } }
    /// Seconds of hovering before the card shows.
    @Published var hoverDelay: Double {
        didSet { store.set(hoverDelay, forKey: Key.delay); machine.delay = hoverDelay }
    }
    /// Which gestures act. All on by default except pinch-to-quit, which only confirms anyway.
    @Published private(set) var gestures: Set<SystemDockGesture>

    let stage = SystemDockPeekStage()

    // Counters and last values, for `diagnostics` and the test hook.
    private(set) var shows = 0
    private(set) var performed = 0
    private(set) var lastGesture: String?
    private(set) var hovered: SystemDockIcon?

    private let store = UserDefaults.standard
    private let queue = DispatchQueue(label: "atelier.dockpeek.ax", qos: .userInitiated)
    private var machine: SystemDockHoverMachine
    private var classifier = SystemDockGestureClassifier()
    private var quitConfirm = SystemDockQuitConfirm()
    private var gestureIcon: String?
    private var orientation = SystemDockOrientation.bottom

    private var dockPID: pid_t?
    private var dockList: AXRef?
    private var observer: AXObserver?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var hoverTimer: Timer?
    private var promptTimer: Timer?
    /// Every app icon on the Dock with its frame, for hit testing gestures.
    private var icons: [SystemDockIcon] = []
    private var selectionBusy = false
    private var selectionAgain = false

    private var panel: NSPanel?
    /// Bumped by every show and hide, so late window lists and pictures for an old card are dropped.
    private var request = 0
    private var refs: [CGWindowID: AXRef] = [:]
    private var shownPID: pid_t?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Key.enabled)
        previews = defaults.object(forKey: Key.previews) as? Bool ?? true
        let delay = defaults.object(forKey: Key.delay) as? Double ?? 0.3
        hoverDelay = delay
        machine = SystemDockHoverMachine(delay: delay)
        var on = Set<SystemDockGesture>()
        for gesture in SystemDockGesture.allCases {
            let stored = defaults.object(forKey: Key.gesture + gesture.rawValue) as? Bool
            if stored ?? (gesture != .quit) { on.insert(gesture) }
        }
        gestures = on
    }

    func isOn(_ gesture: SystemDockGesture) -> Bool { gestures.contains(gesture) }

    func set(_ gesture: SystemDockGesture, on: Bool) {
        if on { gestures.insert(gesture) } else { gestures.remove(gesture) }
        store.set(on, forKey: Key.gesture + gesture.rawValue)
        reconcile()
    }

    // MARK: Life cycle

    func resume() {
        InputTrust.watch()
        reconcile()
    }

    /// Nothing about the system is changed; quitting only takes the tap and observer down.
    func restoreOnQuit() {
        teardown()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Whether the feature can run right now.
    private var wanted: Bool { enabled && AXIsProcessTrusted() && !OwnDock.shared.replacesSystemDock }

    /// Brings the observer, tap and watchdog in line with the settings, the Accessibility grant,
    /// the Atelier Dock and the Dock process (it restarts with a new pid after `killall Dock`).
    private func reconcile() {
        if enabled, watchdog == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { SystemDockPeek.shared.reconcile() } }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !enabled {
            watchdog?.invalidate()
            watchdog = nil
        }
        guard wanted else {
            teardown()
            return
        }
        _ = CFPreferencesAppSynchronize(SystemDockPlan.domain as CFString)
        orientation = SystemDockOrientation(
            preference: CFPreferencesCopyAppValue("orientation" as CFString, SystemDockPlan.domain as CFString) as? String)
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if pid != dockPID || observer == nil { attach(pid) }
        let wantsTap = !gestures.isEmpty || previews
        if wantsTap { installTap() } else { removeTap() }
        if shownPID != nil, ownPeekVisible { hideCard() }
    }

    private func teardown() {
        detach()
        removeTap()
        hoverTimer?.invalidate()
        hoverTimer = nil
        machine = SystemDockHoverMachine(delay: hoverDelay)
        hovered = nil
        icons = []
        hideCard()
    }

    // MARK: Watching the Dock

    private func attach(_ pid: pid_t?) {
        detach()
        dockPID = pid
        guard let pid else { return }
        queue.async {
            let app = DockAX.application(pid, timeout: 0.3)
            guard let list = DockAX.children(app).first(where: { DockAX.attribute($0, kAXRoleAttribute) as? String == kAXListRole as String })
            else { return }
            var created: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, _ in
                MainActor.assumeIsolated { SystemDockPeek.shared.selectionChanged() }
            }, &created) == .success, let created else { return }
            guard AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, nil) == .success else { return }
            let icons = Self.readIcons(list)
            let box = PeekObserverBox(observer: created), ref = AXRef(element: list)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let peek = SystemDockPeek.shared
                    guard peek.dockPID == pid, peek.observer == nil, peek.wanted else { return }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(box.observer), .commonModes)
                    peek.observer = box.observer
                    peek.dockList = ref
                    peek.icons = icons
                }
            }
        }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
        dockPID = nil
    }

    /// The Dock's selection changed: read it, off the main thread, and coalesce bursts.
    fileprivate func selectionChanged() {
        guard let list = dockList else { return }
        if selectionBusy { selectionAgain = true; return }
        selectionBusy = true
        let wantsIcons = !gestures.isEmpty
        queue.async {
            let selected = (DockAX.attribute(list.element, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first
            let icon = selected.flatMap(Self.icon)
            let all = wantsIcons ? Self.readIcons(list.element) : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let peek = SystemDockPeek.shared
                    peek.selectionBusy = false
                    if wantsIcons, !all.isEmpty { peek.icons = all }
                    peek.hoverChanged(icon)
                    if peek.selectionAgain {
                        peek.selectionAgain = false
                        peek.selectionChanged()
                    }
                }
            }
        }
    }

    nonisolated private static func icon(_ item: AXUIElement) -> SystemDockIcon? {
        guard let url = DockAX.attribute(item, kAXURLAttribute) as? URL else { return nil }
        let subrole = DockAX.attribute(item, kAXSubroleAttribute) as? String ?? ""
        var frame = CGRect.zero
        if let value = DockAX.attribute(item, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgRect, &frame)
        }
        return SystemDockIcon(path: url.resolvingSymlinksInPath().standardizedFileURL.path,
                              title: DockAX.attribute(item, kAXTitleAttribute) as? String ?? url.deletingPathExtension().lastPathComponent,
                              frame: frame, isApp: subrole == "AXApplicationDockItem")
    }

    nonisolated private static func readIcons(_ list: AXUIElement) -> [SystemDockIcon] {
        DockAX.children(list).compactMap(icon).filter(\.isApp)
    }

    private func runningApp(_ path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    // MARK: Hover

    private func hoverChanged(_ icon: SystemDockIcon?) {
        let app = icon.flatMap { $0.isApp ? runningApp($0.path) : nil }
        hovered = app == nil ? nil : icon
        if hovered?.path != gestureIcon { classifier.reset() }
        if stage.quitPrompt != nil, hovered?.path != quitTarget { cancelQuitPrompt() }
        machine.hover(hovered?.path, at: CACurrentMediaTime())
        drive()
    }

    /// Acts on the machine's state: shows, switches or hides the card, and wakes for the next deadline.
    private func drive() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let deadline = machine.deadline {
            let timer = Timer(timeInterval: max(deadline - CACurrentMediaTime(), 0.005), repeats: false) { _ in
                MainActor.assumeIsolated {
                    let peek = SystemDockPeek.shared
                    peek.machine.tick(at: CACurrentMediaTime())
                    peek.drive()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
        let shown = machine.shown
        if shown == nil {
            if stage.quitPrompt == nil { hideCard() }
        } else if shown != stage.peek?.id, let icon = hovered, icon.path == shown {
            present(icon)
        }
    }

    /// The Atelier Dock's own Live Peek is on screen.
    private var ownPeekVisible: Bool {
        let own = OwnDock.shared
        return own.enabled && own.stage.peek != nil && own.stage.scene.peekShow > 0.05
    }

    private func present(_ icon: SystemDockIcon) {
        guard previews, wanted, !ownPeekVisible, let app = runningApp(icon.path) else { return }
        request += 1
        let token = request
        let pid = app.processIdentifier
        if shownPID != pid { refs = [:] }
        shownPID = pid
        let title = app.localizedName ?? icon.title
        queue.async {
            let found = Self.windows(pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SystemDockPeek.shared.show(found, icon: icon, title: title, token: token) }
            }
        }
    }

    private struct FoundWindow: Sendable {
        var ref: AXRef
        var id: CGWindowID?
        var title: String
        var minimized: Bool
        var aspect: Double
    }

    /// The app's windows, open ones first, then minimised ones, front to back as AX lists them.
    nonisolated private static func windows(_ pid: pid_t) -> [FoundWindow] {
        let all = DockAX.windows(pid).map { window -> FoundWindow in
            var size = CGSize.zero
            if let value = DockAX.attribute(window.ref.element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            return FoundWindow(ref: window.ref, id: DockAX.windowID(window.ref), title: window.title, minimized: window.minimized,
                               aspect: size.height > 1 ? size.width / size.height : 1.5)
        }
        return all.filter { !$0.minimized } + all.filter(\.minimized)
    }

    private func show(_ found: [FoundWindow], icon: SystemDockIcon, title: String, token: Int) {
        guard token == request, machine.shown == icon.path, wanted, !ownPeekVisible else { return }
        guard !found.isEmpty else {
            // Nothing to peek at: the Dock's own name label is enough.
            hideCard(keepMachine: true)
            return
        }
        let shots = DockWindowShots.shared
        var thumbs: [DockThumb] = []
        for (index, window) in found.prefix(DockPeekLayout.most).enumerated() {
            let id = window.id ?? CGWindowID(UInt32.max - UInt32(index))
            refs[id] = window.ref
            thumbs.append(DockThumb(id: id, title: window.title, minimized: window.minimized, aspect: window.aspect,
                                    image: window.id.flatMap { shots.cached($0) }))
        }
        let open = found.filter { !$0.minimized }.count, minimised = found.count - open
        var parts = [open == 1 ? "1 window" : "\(open) windows"]
        if minimised > 0 { parts.append("\(minimised) minimised") }
        var peek = DockPeek(id: icon.path, title: title, status: parts.joined(separator: " · "), path: icon.path)
        peek.thumbs = thumbs
        let first = stage.peek == nil || !stage.visible
        stage.peek = peek
        stage.hot = nil
        shows += 1
        place(icon, count: thumbs.count)
        if first { reveal() }
        let pixels = Int(DockPeekLayout.cell.width * (panel?.screen?.backingScaleFactor ?? 2))
        let ids = found.prefix(DockPeekLayout.most).compactMap(\.id)
        Task { @MainActor in
            await shots.capture(ids, width: pixels) { id, image in
                let peek = SystemDockPeek.shared
                guard peek.request == token, var shown = peek.stage.peek,
                      let index = shown.thumbs.firstIndex(where: { $0.id == id }) else { return }
                shown.thumbs[index].image = image
                shown.thumbs[index].aspect = image.size.width / max(image.size.height, 1)
                peek.stage.peek = shown
            }
        }
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
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
        let host = FirstMouseHostingView(rootView: SystemDockPeekRoot(stage: stage, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private var actions: SystemDockPeekActions {
        SystemDockPeekActions(
            hover: { inside in SystemDockPeek.shared.cardHover(inside) },
            hot: { index in SystemDockPeek.shared.stage.hot = index },
            open: { index in SystemDockPeek.shared.raise(index) },
            close: { index in SystemDockPeek.shared.closeWindow(index) },
            minimize: { index in SystemDockPeek.shared.minimizeWindow(index) },
            quit: { SystemDockPeek.shared.quitPrompted() })
    }

    /// The screen an icon is on, with its frame and the part below the menu bar, both top-left origin.
    private func screen(for icon: CGRect) -> (screen: NSScreen, full: CGRect, bounds: CGRect)? {
        guard let primary = NSScreen.screens.first?.frame.height else { return nil }
        let center = CGPoint(x: icon.midX, y: icon.midY)
        let screens = NSScreen.screens.map { ($0, SystemDockPeekPlacement.flipped($0.frame, primaryHeight: primary)) }
        guard let (screen, full) = screens.first(where: { $0.1.contains(center) }) ?? screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        var bounds = full
        bounds.origin.y += menuBar
        bounds.size.height -= menuBar
        return (screen, full, bounds)
    }

    private func edge(_ orientation: SystemDockOrientation) -> OwnDockEdge {
        switch orientation {
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
    }

    /// Puts the panel beside the icon, sized for `count` pictures (or for the quit pill alone).
    private func place(_ icon: SystemDockIcon, count: Int?) {
        guard let (_, full, bounds) = screen(for: icon.frame), let primary = NSScreen.screens.first?.frame.height else { return }
        var side = orientation
        // A Dock on another screen's edge than the preference suggests (it moved with the pointer).
        if side == .bottom, icon.frame.maxY < full.maxY - icon.frame.height * 2 {
            side = SystemDockPeekPlacement.orientation(icon: icon.frame, screen: full)
        }
        let edge = edge(side)
        let size = count.map { DockPeekLayout.size(count: $0, edge: edge) } ?? SystemDockPeekPill.size
        let placed = SystemDockPeekPlacement.place(card: size, icon: icon.frame, bounds: bounds, orientation: side,
                                                   corner: DS.Radius.card + DockPeekLayout.notch)
        stage.edge = edge
        stage.notch = count == nil ? nil : placed.notch
        let outer = placed.frame.insetBy(dx: -stage.pad, dy: -stage.pad)
        let panel = makePanel()
        panel.setFrame(SystemDockPeekPlacement.flipped(outer, primaryHeight: primary), display: false)
    }

    private func reveal() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        withAnimation(DS.Motion.gentle(DS.Motion.arrive)) { stage.visible = true }
    }

    /// Takes the card down. `keepMachine` leaves the hover state alone (the app had no windows).
    private func hideCard(keepMachine: Bool = false) {
        request += 1
        shownPID = nil
        refs = [:]
        if !keepMachine, machine.shown != nil { machine.dismiss() }
        guard stage.visible || stage.peek != nil || stage.quitPrompt != nil else { return }
        withAnimation(DS.Motion.gentle(DS.Motion.exit)) { stage.visible = false }
        stage.hot = nil
        stage.quitPrompt = nil
        promptTimer?.invalidate()
        promptTimer = nil
        let token = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            MainActor.assumeIsolated {
                let peek = SystemDockPeek.shared
                guard peek.request == token, !peek.stage.visible else { return }
                peek.stage.peek = nil
                peek.panel?.orderOut(nil)
            }
        }
    }

    private func cardHover(_ inside: Bool) {
        machine.card(inside: inside, at: CACurrentMediaTime())
        if !inside { stage.hot = nil }
        drive()
    }

    // MARK: Acting on windows in the card

    private func thumb(_ index: Int) -> (DockThumb, AXRef)? {
        guard let peek = stage.peek, peek.thumbs.indices.contains(index), let ref = refs[peek.thumbs[index].id] else { return nil }
        return (peek.thumbs[index], ref)
    }

    /// The picture was clicked: that window comes to the front, out of the Dock if minimised.
    private func raise(_ index: Int) {
        guard let (_, ref) = thumb(index), let pid = shownPID else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        queue.async { DockAX.raise(ref) }
        machine.dismiss()
        hideCard()
    }

    private func closeWindow(_ index: Int) {
        guard let (thumb, ref) = thumb(index) else { return }
        queue.async {
            if let button = DockAX.element(ref.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
        removeThumb(thumb.id)
    }

    private func minimizeWindow(_ index: Int) {
        guard let (thumb, ref) = thumb(index), !thumb.minimized else { return }
        queue.async { AXUIElementSetAttributeValue(ref.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        guard var peek = stage.peek, let at = peek.thumbs.firstIndex(where: { $0.id == thumb.id }) else { return }
        peek.thumbs[at].minimized = true
        stage.peek = peek
    }

    private func removeThumb(_ id: CGWindowID) {
        guard var peek = stage.peek else { return }
        peek.thumbs.removeAll { $0.id == id }
        refs[id] = nil
        stage.hot = nil
        if peek.thumbs.isEmpty {
            machine.dismiss()
            hideCard()
            return
        }
        stage.peek = peek
        if let icon = hovered ?? icons.first(where: { $0.path == peek.id }) { place(icon, count: peek.thumbs.count) }
    }

    // MARK: Gestures

    /// Every event the tap sees. True swallows it. Cheap unless the pointer is on a Dock icon.
    fileprivate func tapped(_ type: UInt32, _ event: CGEvent) -> Bool {
        guard wanted else { return false }
        let point = event.location
        let icon: SystemDockIcon?
        if let hovered, hovered.frame.insetBy(dx: -4, dy: -4).contains(point) { icon = hovered }
        else if hovered != nil, let index = SystemDockHit.index(at: point, in: icons.map(\.frame)) { icon = icons[index] }
        else { icon = nil }
        // The Dock reports a hover only while the pointer is on it, so no hovered icon means
        // the pointer is elsewhere and the event is none of this feature's business.
        guard let icon else {
            if gestureIcon != nil { classifier.reset(); gestureIcon = nil }
            return false
        }
        if icon.path != gestureIcon { classifier.reset(); gestureIcon = icon.path }
        let now = CACurrentMediaTime()
        switch type {
        case CGEventType.leftMouseDown.rawValue, CGEventType.rightMouseDown.rawValue, CGEventType.otherMouseDown.rawValue:
            // A click on the icon opens the app or its menu: the card gets out of the way.
            if machine.shown != nil { machine.dismiss(); drive() }
            cancelQuitPrompt()
            return false
        case CGEventType.scrollWheel.rawValue:
            guard let ns = NSEvent(cgEvent: event) else { return false }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let phase = Self.phase(ns)
            let dy = Double(ns.scrollingDeltaY), dx = Double(ns.scrollingDeltaX)
            let upward = ns.isDirectionInvertedFromDevice ? -dy : dy
            let relevant: Set<SystemDockGesture> = continuous ? [.minimize, .restore] : [.hide, .show]
            guard !gestures.isDisjoint(with: relevant) else { return false }
            if let gesture = classifier.scroll(upward: upward, sideways: dx, continuous: continuous, phase: phase, at: now),
               gestures.contains(gesture) {
                perform(gesture, path: icon.path)
            }
            return true
        case gestureEventType, magnifyEventType:
            guard gestures.contains(.quit), let ns = NSEvent(cgEvent: event), ns.type == .magnify else { return false }
            if classifier.magnify(Double(ns.magnification), phase: Self.phase(ns), at: now) == .quit {
                perform(.quit, path: icon.path)
            }
            return true
        default:
            return false
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

    private func installTap() {
        guard peekTap == nil else { return }
        var mask: CGEventMask = 0
        for type in [CGEventType.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown] { mask |= 1 << CGEventMask(type.rawValue) }
        mask |= 1 << CGEventMask(gestureEventType) | 1 << CGEventMask(magnifyEventType)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: peekTapCallback, userInfo: nil) else { TapRevoke.creationFailed(); return }
        peekTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        guard let tap = peekTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        peekTap = nil
        tapSource = nil
    }

    var tapActive: Bool { peekTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Does what a gesture means to the app at `path`. Quit asks for a second pinch first.
    @discardableResult
    private func perform(_ gesture: SystemDockGesture, path: String, confirmed: Bool = false) -> Bool {
        guard let app = runningApp(path), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let pid = app.processIdentifier
        lastGesture = gesture.rawValue + ":" + (app.localizedName ?? path)
        performed += 1
        switch gesture {
        case .minimize:
            queue.async {
                let element = DockAX.application(pid)
                let focused = DockAX.element(element, kAXFocusedWindowAttribute)
                let target = focused.flatMap { window -> AXUIElement? in
                    (DockAX.attribute(window, kAXMinimizedAttribute) as? Bool) == true ? nil : window
                } ?? DockAX.windows(pid).first { !$0.minimized }?.ref.element
                if let target { AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            }
        case .restore:
            app.activate()
            queue.async {
                if let window = DockAX.windows(pid).first(where: \.minimized) { DockAX.raise(window.ref) }
            }
        case .hide:
            app.hide()
        case .show:
            app.unhide()
        case .quit:
            // The Finder has no Quit; quitting it would only restart it.
            guard app.bundleIdentifier != "com.apple.finder" else { return false }
            let name = app.localizedName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if confirmed || quitConfirm.pinch(name, at: CACurrentMediaTime()) {
                cancelQuitPrompt()
                machine.dismiss()
                hideCard()
                app.terminate()
            } else {
                showQuitPrompt(name, path: path)
            }
        }
        if gesture != .quit, machine.shown != nil {
            // The card would show a stale state: drop it until the next hover.
            machine.dismiss()
            drive()
        }
        return true
    }

    private func showQuitPrompt(_ name: String, path: String) {
        stage.quitPrompt = name
        quitTarget = path
        if stage.peek == nil || !stage.visible, let icon = hovered ?? icons.first(where: { $0.path == path }) {
            request += 1
            place(icon, count: nil)
            reveal()
        }
        promptTimer?.invalidate()
        let timer = Timer(timeInterval: quitConfirm.window, repeats: false) { _ in
            MainActor.assumeIsolated { SystemDockPeek.shared.cancelQuitPrompt() }
        }
        RunLoop.main.add(timer, forMode: .common)
        promptTimer = timer
    }

    private var quitTarget: String?

    private func cancelQuitPrompt() {
        promptTimer?.invalidate()
        promptTimer = nil
        quitConfirm.cancel()
        guard stage.quitPrompt != nil else { return }
        withAnimation(DS.Motion.gentle(DS.Motion.exit)) { stage.quitPrompt = nil }
        if stage.peek == nil { hideCard() }
    }

    /// The Quit button in the confirm pill.
    private func quitPrompted() {
        guard let path = quitTarget else { return }
        perform(.quit, path: path, confirmed: true)
    }

    // MARK: Availability, diagnostics, tests

    /// What the card says is missing, most important first.
    var notes: [FeatureAvailability] {
        var notes: [FeatureAvailability] = []
        if !AXIsProcessTrusted() {
            notes.append(.limited("Needs Accessibility in System Settings › Privacy & Security, to read the Dock and act on windows"))
        }
        if previews, !DockWindowShots.shared.allowed {
            notes.append(.limited("Window pictures need Screen Recording; without it the card shows titles only"))
        }
        if OwnDock.shared.replacesSystemDock {
            notes.append(.limited("Resting while the Atelier Dock replaces the macOS Dock; its own Live Peek takes over"))
        }
        return notes
    }

    var diagnostics: String {
        "dockPeek=\(enabled) previews=\(previews) trusted=\(AXIsProcessTrusted()) screenCapture=\(DockWindowShots.shared.allowed) " +
            "observer=\(observer != nil) dockPID=\(dockPID.map(String.init) ?? "-") tap=\(tapActive) orientation=\(orientation.rawValue) " +
            "icons=\(icons.count) hovered=\(hovered?.title ?? "-") shown=\(stage.visible ? stage.peek?.title ?? "pill" : "-") " +
            "windows=\(stage.peek?.thumbs.count ?? 0) shows=\(shows) gestures=\(gestures.map(\.rawValue).sorted().joined(separator: ",")) " +
            "performed=\(performed) last=\(lastGesture ?? "-") ownDockReplaces=\(OwnDock.shared.replacesSystemDock)"
    }

    /// `atelier://dockpeek?…`, for checking a build without hovering by hand. The result of
    /// `report` lands in `$TMPDIR/atelier-dockpeek.txt`.
    ///
    /// - `report` — the hovered icon and the windows its card would show; with `app=Name`
    ///   (a localised name or bundle id) that app's windows instead.
    /// - `simulate=minimize|restore|hide|show|quit&app=Name` — performs the gesture on the app.
    ///   `quit` arms the confirm like a first pinch; add `confirm=1` to quit at once.
    /// - `show=Name` — shows the card at that app's Dock icon, as a hover would. `hide` takes it down.
    /// - `on=1|0`, `previews=1|0`, `delay=0.5`, `gesture=minimize:0` — settings.
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let target = value("app").flatMap(findApp)
        for item in items {
            switch (item.name, item.value ?? "") {
            case ("on", let on): enabled = on == "1"
            case ("previews", let on): previews = on == "1"
            case ("delay", let seconds): if let seconds = Double(seconds) { hoverDelay = min(max(seconds, 0), 2) }
            case ("gesture", let spec):
                let parts = spec.split(separator: ":").map(String.init)
                if let gesture = parts.first.flatMap(SystemDockGesture.init(rawValue:)) { set(gesture, on: parts.last != "0") }
            case ("simulate", let name):
                guard let gesture = SystemDockGesture(rawValue: name), let path = target?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
                else { break }
                perform(gesture, path: path, confirmed: value("confirm") == "1")
            case ("show", let name):
                guard let app = findApp(name), let path = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path else { break }
                testShow(path)
            case ("hide", _):
                machine = SystemDockHoverMachine(delay: hoverDelay)
                hideCard()
            case ("report", _):
                report(target)
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

    /// Shows the card for the app as if its icon were hovered, reading the icon frame from the Dock.
    private func testShow(_ path: String) {
        guard wanted, let list = dockList else { return }
        queue.async {
            let all = Self.readIcons(list.element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let peek = SystemDockPeek.shared
                    peek.icons = all
                    guard let icon = all.first(where: { $0.path == path }) else { return }
                    peek.hovered = icon
                    peek.machine = SystemDockHoverMachine(delay: 0, grace: 3600)
                    peek.machine.hover(icon.path, at: CACurrentMediaTime())
                    peek.machine.delay = peek.hoverDelay
                    peek.drive()
                }
            }
        }
    }

    private func report(_ app: NSRunningApplication?) {
        let icon = hovered
        let pid = app?.processIdentifier ?? icon.flatMap { runningApp($0.path)?.processIdentifier }
        let header = [diagnostics,
                      "hoveredIcon=\(icon.map { "\($0.title) \($0.path) frame=\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-")",
                      "target=\(app?.localizedName ?? icon?.title ?? "-") pid=\(pid.map(String.init) ?? "-")"]
        let file = NSTemporaryDirectory() + "atelier-dockpeek.txt"
        queue.async {
            let found = pid.map(Self.windows) ?? []
            let lines = header + found.prefix(DockPeekLayout.most).map {
                "window id=\($0.id.map(String.init) ?? "-") minimised=\($0.minimized) aspect=\(String(format: "%.2f", $0.aspect)) title=\($0.title)"
            } + ["windowsTotal=\(found.count)"]
            try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}

/// Clicks land on the card even though Atelier is not the active app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
