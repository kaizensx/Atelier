import AppKit
import ApplicationServices
import DockCore

// Everything the Atelier Dock learns through Accessibility. All reads happen off the main
// thread with short messaging timeouts, so a hung app can never stall the dock.

/// An Accessibility element that may cross threads. AX elements are immutable references to
/// another process's objects, and the AX API may be called from any thread.
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
}

// MARK: - Reading

enum DockAX {
    nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// An attribute that holds another element, checked to really be one. An app can answer
    /// with anything, and a wrong type would crash the first call that used it.
    nonisolated static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    nonisolated static func application(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    struct Window: Sendable {
        var ref: AXRef
        var title: String
        var minimized: Bool
        /// Stable for the life of the window: equal elements hash equally.
        var key: UInt
    }

    /// The app's windows, front to back as the app reports them. Sheets, panels and
    /// untitled helper windows are left out.
    nonisolated static func windows(_ pid: pid_t) -> [Window] {
        let app = application(pid)
        guard let list = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.compactMap { window -> Window? in
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            guard subrole == nil || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { return nil }
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            let minimized = (attribute(window, kAXMinimizedAttribute) as? Bool) ?? false
            guard !title.isEmpty || minimized else { return nil }
            return Window(ref: AXRef(element: window), title: title.isEmpty ? "Untitled" : title, minimized: minimized,
                          key: CFHash(window))
        }
    }

    // MARK: Acting

    nonisolated static func raise(_ ref: AXRef) {
        let window = ref.element
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Walks the app's windows. Forward brings the one at the back to the front; backward
    /// sends the front one to the back. Either way every window comes round in turn. The list
    /// AX gives runs front to back. Returns false when the app shows no window.
    nonisolated static func cycle(_ pid: pid_t, forward: Bool) -> Bool {
        let shown = windows(pid).filter { !$0.minimized }
        guard let last = shown.last else { return false }
        if shown.count == 1 || forward {
            raise(last.ref)
        } else {
            for index in (1..<shown.count).reversed() { raise(shown[index].ref) }
        }
        return true
    }

    /// The app's own "New Window" command: a menu item titled New…Window, or the one bound to
    /// ⌘N. Read only; `press` runs it.
    nonisolated static func newWindowItem(_ pid: pid_t) -> (ref: AXRef, title: String)? {
        let app = application(pid, timeout: 0.4)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        var commandN: (AXRef, String)?
        // The first menu is the app menu; New Window lives in File, or in the menus after it.
        for top in children(bar).dropFirst().prefix(4) {
            for menu in children(top) {
                for item in children(menu) {
                    guard (attribute(item, kAXEnabledAttribute) as? Bool) != false else { continue }
                    let title = attribute(item, kAXTitleAttribute) as? String ?? ""
                    let key = attribute(item, "AXMenuItemCmdChar") as? String ?? ""
                    let modifiers = attribute(item, "AXMenuItemCmdModifiers") as? Int ?? -1
                    if title.hasPrefix("New"), title.contains("Window") { return (AXRef(element: item), title) }
                    if commandN == nil, key == "N", modifiers == 0, title.hasPrefix("New") { commandN = (AXRef(element: item), title) }
                }
            }
            if commandN != nil { break }
        }
        return commandN.map { (ref: $0.0, title: $0.1) }
    }

    nonisolated static func press(_ ref: AXRef) {
        AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
    }

    /// The window server's number for an AX window, so a window picture and the window it
    /// shows can be matched. Resolved at run time; nil when the call is not there.
    nonisolated static func windowID(_ ref: AXRef) -> CGWindowID? {
        typealias Get = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var id: CGWindowID = 0
        return unsafeBitCast(symbol, to: Get.self)(ref.element, &id) == .success && id != 0 ? id : nil
    }

    /// A few of the app's own menu commands, for its tile's menu: ones with a key equivalent,
    /// from the menus after the app menu, File first. Read only; `press` runs one.
    nonisolated static func menuCommands(_ pid: pid_t, limit: Int = 5) -> [(ref: AXRef, title: String, keys: String)] {
        let app = application(pid, timeout: 0.3)
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        let skipped: Set<String> = ["Close", "Close Window", "Close All", "Quit", "Hide", "Minimize", "Minimise", "Print…",
                                    "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Delete", "Page Setup…", "Zoom",
                                    "Enter Full Screen", "Exit Full Screen", "Bring All to Front"]
        var found: [(ref: AXRef, title: String, keys: String)] = []
        var seen = Set<String>()
        for top in children(bar).dropFirst().prefix(5) {
            for menu in children(top) {
                for item in children(menu) {
                    guard found.count < limit else { return found }
                    guard (attribute(item, kAXEnabledAttribute) as? Bool) != false,
                          let title = attribute(item, kAXTitleAttribute) as? String, !title.isEmpty,
                          !skipped.contains(title), seen.insert(title).inserted,
                          let key = attribute(item, "AXMenuItemCmdChar") as? String, !key.isEmpty,
                          attribute(item, "AXChildren").map({ ($0 as? [AXUIElement])?.isEmpty ?? true }) ?? true else { continue }
                    let modifiers = attribute(item, "AXMenuItemCmdModifiers") as? Int ?? 0
                    found.append((AXRef(element: item), title, menuGlyphs(modifiers) + key.uppercased()))
                }
            }
        }
        return found
    }

    /// AX menu modifiers: ⌘ is implied unless bit 3 is set; 1 shift, 2 option, 4 control.
    nonisolated private static func menuGlyphs(_ modifiers: Int) -> String {
        var text = ""
        if modifiers & 4 != 0 { text += "⌃" }
        if modifiers & 2 != 0 { text += "⌥" }
        if modifiers & 1 != 0 { text += "⇧" }
        if modifiers & 8 == 0 { text += "⌘" }
        return text
    }

    /// App Exposé for the app in front, the way the Dock's "Show All Windows" does it.
    /// Resolved at run time; false when the call is not there.
    @MainActor static func showAllWindows() -> Bool {
        typealias Send = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
        if let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
           let symbol = dlsym(library, "CoreDockSendNotification") {
            unsafeBitCast(symbol, to: Send.self)("com.apple.expose.front.awake" as CFString, nil)
            return true
        }
        // Without the private call, the Mission Control app does the same when given "2".
        let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["2"]
        return (try? process.run()) != nil
    }
}

// MARK: - The macOS Dock's badges

/// What the macOS Dock shows on its tiles, read from its Accessibility tree. This works while
/// the Dock is hidden: its tiles keep their `AXStatusLabel` (the badge) and their frames.
struct SystemDockReading: Sendable, Equatable {
    /// App path, symlinks resolved, to the badge text.
    var badges: [String: String] = [:]
    /// Apps whose tile is off the Dock's rest line: the Dock is bouncing them.
    var bouncing: Set<String> = []
    /// Folder path to download progress, 0 to 1, for folders the Dock draws a bar on.
    var progress: [String: Double] = [:]
}

enum SystemDockAX {
    /// One pass over the Dock's tiles. About a millisecond; never call it on the main thread.
    nonisolated static func read(dockPID: pid_t, orientation: String) -> SystemDockReading {
        let dock = DockAX.application(dockPID, timeout: 0.3)
        guard let list = DockAX.children(dock).first(where: { DockAX.attribute($0, kAXRoleAttribute) as? String == kAXListRole as String })
        else { return SystemDockReading() }
        var reading = SystemDockReading()
        var bases: [(path: String, base: Double)] = []
        for item in DockAX.children(list) {
            let subrole = DockAX.attribute(item, kAXSubroleAttribute) as? String ?? ""
            guard let url = DockAX.attribute(item, kAXURLAttribute) as? URL else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if subrole == "AXApplicationDockItem" {
                if let label = DockAX.attribute(item, "AXStatusLabel") as? String, !label.isEmpty { reading.badges[path] = label }
                var frame = CGRect.zero
                if let value = DockAX.attribute(item, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgRect, &frame)
                }
                if frame.width > 0 {
                    // The side of the tile that rests on the screen edge. Magnification grows
                    // tiles away from it, a bounce lifts the whole tile off it.
                    let base: Double = switch orientation {
                    case "left": frame.minX
                    case "right": frame.maxX
                    default: frame.maxY
                    }
                    bases.append((path, base))
                }
            } else if let value = DockAX.attribute(item, "AXProgressValue") as? Double, value >= 0, value <= 1 {
                reading.progress[path] = value
            }
        }
        reading.bouncing = bouncing(bases, orientation: orientation)
        return reading
    }

    /// Tiles lifted more than 3 points off the line most tiles rest on, away from the edge.
    /// A reading with many tiles off the line is the Dock sliding (auto-hide shows it for an
    /// attention request), not bounces: `OwnDockBounce` (DockCore) leaves it empty.
    nonisolated static func bouncing(_ bases: [(path: String, base: Double)], orientation: String) -> Set<String> {
        OwnDockBounce.bouncing(bases, orientation: orientation)
    }
}

/// Keeps a `SystemDockReading` current while the Atelier Dock is visible. The Dock posts no
/// Accessibility notification when a badge changes (checked on macOS 27.3: AXValueChanged,
/// AXTitleChanged and AXLayoutChanged are refused for its tiles), so this polls, off the main
/// thread, every `interval` seconds and only while running.
@MainActor
final class SystemDockReader {
    private(set) var reading = SystemDockReading()
    var changed: (() -> Void)?
    var interval = 2.5
    private var timer: Timer?
    private var busy = false
    private let queue = DispatchQueue(label: "atelier.dock.system-ax", qos: .utility)
    /// Skips polls while false, for example while the dock is slid away.
    var active = true

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if reading != SystemDockReading() {
            reading = SystemDockReading()
            changed?()
        }
    }

    /// Reads now, for example when the dock slides back in.
    func poll() {
        guard active, !busy, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        busy = true
        let pid = dock.processIdentifier
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, SystemDockPlan.domain as CFString) as? String ?? "bottom"
        queue.async { [weak self] in
            let reading = SystemDockAX.read(dockPID: pid, orientation: orientation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    guard self.timer != nil, reading != self.reading else { return }
                    self.reading = reading
                    self.changed?()
                }
            }
        }
    }
}

// MARK: - Minimised windows

struct MinimizedWindow: Sendable, Identifiable, Equatable {
    var id: String
    var pid: pid_t
    var title: String
    var appPath: String
    var ref: AXRef
    /// When it was first seen minimised, for a stable order.
    var since: Int

    static func == (a: MinimizedWindow, b: MinimizedWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.appPath == b.appPath
    }
}

/// The minimised windows of every app, kept current by one AXObserver per app: it fires when
/// a window is minimised, restored or created, and only that app is read again.
@MainActor
final class MinimizedWatcher {
    static let shared = MinimizedWatcher()

    private(set) var windows: [MinimizedWindow] = []
    var changed: (() -> Void)?
    private var perApp: [pid_t: [MinimizedWindow]] = [:]
    private var paths: [pid_t: String] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: Set<pid_t> = []
    /// Apps read once already: a window minimised after that is a new one.
    private var primed: Set<pid_t> = []
    private var counter = 0
    private var seen: [String: Int] = [:]
    private(set) var running = false
    private let queue = DispatchQueue(label: "atelier.dock.minimized", qos: .utility)

    func start(_ apps: [NSRunningApplication]) {
        guard !running, AXIsProcessTrusted() else { return }
        running = true
        for app in apps { watch(app) }
    }

    func stop() {
        guard running else { return }
        running = false
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers = [:]
        perApp = [:]
        paths = [:]
        primed = []
        if !windows.isEmpty {
            windows = []
            changed?()
        }
    }

    func watch(_ app: NSRunningApplication) {
        guard running, let path = app.bundleURL?.path, app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              observers[app.processIdentifier] == nil else { return }
        let pid = app.processIdentifier
        paths[pid] = path
        queue.async { [weak self] in
            // Registering talks to the app, so it happens here, with a short timeout.
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, element, notification, _ in
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                let restored = (notification as String) == kAXWindowDeminiaturizedNotification
                let ref = AXRef(element: element)
                MainActor.assumeIsolated {
                    // A window Atelier holds came back another way: its effect starts now, not
                    // after the re-read, while it waits parked at the edge.
                    if restored, MinimizeRedirect.shared.shrunkKeys.contains(CFHash(ref.element)) {
                        MinimizeRedirect.shared.restoredElsewhere([ref])
                    }
                    MinimizedWatcher.shared.dirty(pid)
                }
            }, &observer) == .success, let observer else { return }
            let element = DockAX.application(pid)
            for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXWindowCreatedNotification,
                         kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, nil)
            }
            let found = DockAX.windows(pid).filter(\.minimized)
            let box = ObserverBox(observer: observer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running, self.paths[pid] != nil else { return }
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(box.observer), .commonModes)
                    self.observers[pid] = box.observer
                    self.apply(pid, found)
                }
            }
        }
    }

    func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        paths[pid] = nil
        primed.remove(pid)
        guard perApp.removeValue(forKey: pid) != nil else { return }
        rebuild()
    }

    /// Something changed in one app: read its windows again, once, a moment later.
    func dirty(_ pid: pid_t) {
        guard running, paths[pid] != nil, pending.insert(pid).inserted else { return }
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            let found = DockAX.windows(pid).filter(\.minimized)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending.remove(pid)
                    guard self.running, self.paths[pid] != nil else { return }
                    self.apply(pid, found)
                }
            }
        }
    }

    private func apply(_ pid: pid_t, _ found: [DockAX.Window]) {
        guard let path = paths[pid] else { return }
        let list = found.map { window -> MinimizedWindow in
            let id = "min:\(pid):\(window.key)"
            if seen[id] == nil { counter += 1; seen[id] = counter }
            return MinimizedWindow(id: id, pid: pid, title: window.title, appPath: path, ref: window.ref, since: seen[id] ?? 0)
        }
        // Read once: from now on a newly minimised window is one minimised since.
        let wasPrimed = !primed.insert(pid).inserted
        guard list != (perApp[pid] ?? []) else { return }
        // Windows that came back by some other way than the dock: Atelier may hold them shrunk.
        let now = Set(list.map(\.id))
        let back = (perApp[pid] ?? []).filter { !now.contains($0.id) }.map(\.ref)
        if !back.isEmpty { MinimizeRedirect.shared.restoredElsewhere(back) }
        // Windows minimised since the app was first read, some way no tap sees (its Window
        // menu): Atelier holds them too, so they come back with the effect. Windows already
        // minimised when Atelier started are left as they are.
        if wasPrimed {
            let before = Set((perApp[pid] ?? []).map(\.id))
            let added = list.filter { !before.contains($0.id) }.map(\.ref)
            if !added.isEmpty { MinimizeRedirect.shared.minimizedElsewhere(added) }
        }
        perApp[pid] = list.isEmpty ? nil : list
        rebuild()
    }

    private func rebuild() {
        let all = perApp.values.flatMap { $0 }.sorted { $0.since < $1.since }
        let live = Set(all.map(\.id))
        seen = seen.filter { live.contains($0.key) }
        guard all != windows else { return }
        windows = all
        changed?()
    }
}

private struct ObserverBox: @unchecked Sendable {
    let observer: AXObserver
}
