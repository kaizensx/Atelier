import AppKit
import ApplicationServices
import SwiftUI

// Reserve Dock Space. While the Atelier Dock stands in for the macOS Dock, the system's
// visible frame no longer leaves room for a dock, so zoomed and tiled windows reach under
// the bar. With Reserve on, Atelier watches windows through Accessibility and, when one is
// zoomed, tiled against the dock's edge, or dropped so that it overlaps the bar, fits it to
// the screen minus the dock's thickness and a margin.
//
// Cost: one AXObserver per app, on a thread of its own, never the main thread. It hears
// only window created, moved, resized and focus changes; each event reads one window's
// frame. Full-screen windows, panels, sheets and the apps the user excepts are left alone,
// and nothing happens while the pointer is still held down.

// MARK: - Main side

/// Decides whether the engine runs and tells it where the dock is.
@MainActor
final class DockReserve {
    static let shared = DockReserve()
    private var started = false
    private(set) var active = false

    /// Called when the dock shows, hides or moves, and when the setting changes.
    func update() {
        let dock = OwnDock.shared
        let prefs = dock.reserve
        let wanted = dock.enabled && prefs.mode == .reserve && (!dock.autoHide || prefs.whileHidden) && AXIsProcessTrusted()
        guard wanted, let screen = dock.currentScreen, let main = NSScreen.screens.first else {
            if active { DockReserveEngine.shared.configure(nil, exceptions: []) }
            active = false
            return
        }
        startWatching()
        let edge = dock.placedEdge
        let bar = dock.stage.scene.bar
        let cross = edge.horizontal ? bar.height : bar.width
        // Beside the macOS Dock, and always at the top, the bar starts at the visible edge.
        let full = screen.frame, visible = screen.visibleFrame
        let inset: Double = switch edge {
        case .top: full.maxY - visible.maxY
        case .bottom: dock.replacesSystemDock ? 0 : visible.minY - full.minY
        case .left: dock.replacesSystemDock ? 0 : visible.minX - full.minX
        case .right: dock.replacesSystemDock ? 0 : full.maxX - visible.maxX
        }
        let thickness = inset + dock.appearance.gap + (cross > 1 ? cross : dock.tile * (1 + 2 * dock.appearance.padding)) + prefs.margin
        let height = main.frame.maxY
        let place = DockReserveScreen(full: DockReserveMath.ax(screen.frame, mainHeight: height),
                                      visible: DockReserveMath.ax(screen.visibleFrame, mainHeight: height),
                                      edge: edge, thickness: thickness)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { (pid: $0.processIdentifier, bundle: $0.bundleIdentifier ?? "") }
        let first = !active
        active = true
        DockReserveEngine.shared.configure(place, exceptions: Set(prefs.exceptions))
        if first { DockReserveEngine.shared.watch(apps, sweep: true) }
    }

    private func startWatching() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            let entry = (pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "")
            MainActor.assumeIsolated {
                guard DockReserve.shared.active else { return }
                DockReserveEngine.shared.watch([entry], sweep: false)
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            DockReserveEngine.shared.forget(pid)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard DockReserve.shared.active else { return }
                DockReserveEngine.shared.poke(pid)
            }
        }
    }
}

// MARK: - Engine

/// Lives on its own thread with its own run loop. `config` is shared under a lock; every
/// other field is touched on that thread only.
final class DockReserveEngine: @unchecked Sendable {
    static let shared = DockReserveEngine()

    private let lock = NSLock()
    private var screen: DockReserveScreen?
    private var exceptions: Set<String> = []

    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var thread: Thread?

    // Engine thread only.
    private var observers: [pid_t: AXObserver] = [:]
    private var bundles: [pid_t: String] = [:]
    private var watched: Set<CFHashCode> = []
    private var adjusted: [CFHashCode: (count: Int, since: CFAbsoluteTime)] = [:]
    private var heldFrames: [CFHashCode: CGRect] = [:]
    private var waiting: Set<CFHashCode> = []

    private init() {}

    func configure(_ screen: DockReserveScreen?, exceptions: Set<String>) {
        lock.lock()
        self.screen = screen
        self.exceptions = exceptions
        lock.unlock()
        if screen == nil { perform { self.teardown() } }
    }

    private var snapshot: (screen: DockReserveScreen?, exceptions: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (screen, exceptions)
    }

    func watch(_ apps: [(pid: pid_t, bundle: String)], sweep: Bool) {
        perform {
            for app in apps { self.observe(app.pid, bundle: app.bundle, sweep: sweep) }
        }
    }

    func forget(_ pid: pid_t) {
        perform {
            if let observer = self.observers.removeValue(forKey: pid), let loop = self.loop {
                CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self.bundles[pid] = nil
        }
    }

    /// An app came to the front: check its focused window once.
    func poke(_ pid: pid_t) {
        perform {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            if let window = Self.element(app, kAXFocusedWindowAttribute) { self.check(window, pid: pid) }
        }
    }

    // MARK: Thread

    private func perform(_ block: @escaping @Sendable () -> Void) {
        startThread()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    private func startThread() {
        // Held until the run loop exists, so no caller ever finds it missing. The thread
        // itself never takes the lock.
        lock.lock()
        defer { lock.unlock() }
        if thread == nil {
            let thread = Thread { [self] in
                self.loop = CFRunLoopGetCurrent()
                // A far-off timer keeps the run loop alive with nothing else in it.
                let keep = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), keep, .defaultMode)
                self.ready.signal()
                while true { CFRunLoopRun() }
            }
            thread.name = "Atelier Reserve Dock Space"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
            ready.wait()
        }
    }

    private func teardown() {
        for observer in observers.values {
            if let loop { CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        }
        observers = [:]
        bundles = [:]
        watched = []
        adjusted = [:]
        heldFrames = [:]
        waiting = []
    }

    // MARK: Observing

    private func observe(_ pid: pid_t, bundle: String, sweep: Bool) {
        guard observers[pid] == nil, snapshot.screen != nil, let loop else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            DockReserveEngine.shared.event(element, notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        bundles[pid] = bundle
        for window in Self.elements(app, kAXWindowsAttribute) {
            register(window, observer: observer)
            if sweep { check(window, pid: pid) }
        }
    }

    private func register(_ window: AXUIElement, observer: AXObserver) {
        let key = CFHash(window)
        guard watched.insert(key).inserted else { return }
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, nil)
        }
    }

    private func event(_ element: AXUIElement, _ name: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch name {
        case kAXUIElementDestroyedNotification:
            let key = CFHash(element)
            watched.remove(key)
            adjusted[key] = nil
            heldFrames[key] = nil
        case kAXWindowCreatedNotification:
            if let observer = observers[pid] { register(element, observer: observer) }
            check(element, pid: pid)
        default:
            if name == kAXFocusedWindowChangedNotification, let observer = observers[pid] { register(element, observer: observer) }
            check(element, pid: pid)
        }
    }

    // MARK: Fitting

    private func check(_ window: AXUIElement, pid: pid_t) {
        let (screen, exceptions) = snapshot
        guard let screen, !exceptions.contains(bundles[pid] ?? "") else { return }
        let key = CFHash(window)
        guard let frame = Self.frame(window) else { return }
        // Mid-drag or mid-resize: wait for the pointer to let go, then look once.
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            if heldFrames[key] == nil { heldFrames[key] = frame }
            later(window, pid: pid, key: key)
            return
        }
        let before = heldFrames.removeValue(forKey: key)
        guard (Self.string(window, kAXSubroleAttribute) ?? kAXStandardWindowSubrole) == kAXStandardWindowSubrole,
              Self.bool(window, "AXFullScreen") != true, Self.bool(window, kAXMinimizedAttribute) != true else { return }
        let resized = before.map { abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 } ?? false
        guard let target = DockReserveMath.fit(frame, on: screen, resized: resized) else { return }
        // An app that refuses the size would answer every fit with another event.
        let now = CFAbsoluteTimeGetCurrent()
        var record = adjusted[key] ?? (0, now)
        if now - record.since > 3 { record = (0, now) }
        guard record.count < 3 else { return }
        record.count += 1
        adjusted[key] = record
        Self.set(window, target)
    }

    private func later(_ window: AXUIElement, pid: pid_t, key: CFHashCode) {
        guard waiting.insert(key).inserted, let loop else { return }
        let box = WindowBox(window: window)
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0, 0, 0) { _ in
            DockReserveEngine.shared.waiting.remove(key)
            DockReserveEngine.shared.check(box.window, pid: pid)
        }
        CFRunLoopAddTimer(loop, timer, .defaultMode)
    }

    // MARK: AX

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func set(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        // Shrinking first keeps a window that grows downward from crossing the band on its way.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }
}

private struct WindowBox: @unchecked Sendable {
    let window: AXUIElement
}

// MARK: - Settings

/// The Maximised Windows part of Position and Behaviour.
struct DockReserveSettings: View {
    @ObservedObject private var dock = OwnDock.shared
    @State private var apps: [(bundle: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DockSubhead(text: "Maximised Windows")
            Segments(selection: $dock.reserve.mode, options: DockReservePrefs.Mode.allCases.map { ($0, $0.title) })
            Text(dock.reserve.mode == .reserve
                 ? "Zoomed and tiled windows stop above the dock, as they do beside the macOS Dock. A window dropped onto the bar moves clear of it. Full-screen windows are left alone."
                 : "Windows can reach under the dock, the way they do with the macOS Dock hidden.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if dock.reserve.mode == .reserve {
                if dock.autoHide {
                    SettingRow(title: "Also While Auto-hidden", detail: "Keep the room even while the dock is out of sight.",
                               density: .compact) {
                        LuxSwitch(isOn: $dock.reserve.whileHidden, label: "Also While Auto-hidden", tint: DockHubHue.tint)
                    }
                }
                DockSliderRow(title: "Margin", value: $dock.reserve.margin, range: 0...24,
                              text: "\(Int(dock.reserve.margin.rounded())) pt")
                exceptionsList
                DockNeedsAccess()
            }
        }
        .task {
            // After the first frame: the card opens without listing apps.
            await Task.yield()
            apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .map { ($0.bundleIdentifier ?? "", $0.localizedName ?? $0.bundleIdentifier ?? "App") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var exceptionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps That Overlap").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                Spacer()
                Menu {
                    ForEach(apps.filter { !dock.reserve.exceptions.contains($0.bundle) }, id: \.bundle) { app in
                        Button(app.name) { dock.reserve.exceptions.append(app.bundle) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Add App").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(DS.Ink.primary).padding(.horizontal, 10).frame(height: 26)
                    .background(DS.Ink.fillStrong, in: .capsule)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if dock.reserve.exceptions.isEmpty {
                Text("None. Add an app whose windows should reach under the dock.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
            ForEach(dock.reserve.exceptions, id: \.self) { bundle in
                HStack {
                    Text(apps.first { $0.bundle == bundle }?.name ?? Self.name(bundle)).font(DS.body).foregroundStyle(DS.Ink.primary)
                    Spacer()
                    Button { dock.reserve.exceptions.removeAll { $0 == bundle } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                            .frame(width: 22, height: 22).background(DS.Ink.fill, in: .circle)
                    }
                    .buttonStyle(Pressable(scale: 0.92)).accessibilityLabel("Stop excepting \(bundle)")
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(DS.Ink.fill, in: .rect(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private static func name(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
    }
}
