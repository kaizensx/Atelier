import AppKit
import ApplicationServices
import SwiftUI
import DockCore

// MARK: - Window Switcher
//
// ⌘Tab switches apps, and an app with five windows is one stop. In the spirit of AltTab, this
// lists every window instead: hold the modifier, press Tab, and a glass panel shows each one as
// its app's icon, its title and a small drawing of its shape. Let go to bring the highlighted
// window forward. Nothing is captured from the screen; titles and shapes come from
// Accessibility, the stacking order from the window server's public window list.
//
// A keyboard tap watches for the chord and swallows only it, plus the keys that steer the
// panel while it is open. Turning the feature off removes the tap.

/// The tap and its state are read by the C callback, which runs outside any actor but always
/// on the main run loop.
private nonisolated(unsafe) var switchTap: CFMachPort?
private nonisolated(unsafe) var switchShortcut = SwitcherShortcut.optionTab
/// True from the first press of the chord until a window is picked or the switcher is cancelled.
private nonisolated(unsafe) var switching = false
/// Whether the chord's modifier was down at the last flags change, so a fresh press can be told
/// from a second modifier joining in.
private nonisolated(unsafe) var modifierDown = false
/// Keys whose press the tap swallowed; their release is swallowed too, so no app sees half a key.
private nonisolated(unsafe) var swallowedUps: Set<Int64> = []

private let shiftMask = CGEventFlags.maskShift.rawValue

private func switchCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                            _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TapRevoke.disabled(type)
        if let switchTap { CGEvent.tapEnable(tap: switchTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags.rawValue
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    switch type {
    case .keyDown:
        if switchShortcut.matches(keyCode: code, flags: flags) {
            let backward = flags & shiftMask != 0
            // The tap's run loop source is on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { WindowSwitcher.shared.press(backward: backward) }
            swallowedUps.insert(code)
            return nil
        }
        guard switching else { return Unmanaged.passUnretained(event) }
        let handled = MainActor.assumeIsolated { WindowSwitcher.shared.steer(code) }
        if handled {
            swallowedUps.insert(code)
            return nil
        }
        return Unmanaged.passUnretained(event)
    case .keyUp:
        return swallowedUps.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
    case .flagsChanged:
        let down = flags & switchShortcut.modifier != 0
        defer { modifierDown = down }
        if down, !modifierDown, !switching {
            MainActor.assumeIsolated { WindowSwitcher.shared.prefetch() }
        } else if !down, switching {
            MainActor.assumeIsolated { WindowSwitcher.shared.released() }
        }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

/// One window in the switcher. Everything here may cross threads.
struct SwitcherWindow: Sendable, Identifiable {
    var id: String
    var ref: AXRef?
    var pid: pid_t
    var windowID: CGWindowID?
    var title: String
    var appName: String
    var size: CGSize
    var minimized = false
    var hidden = false
    /// Not on screen and neither minimised nor hidden: on another Space.
    var elsewhere = false
    /// Set for Atelier's own windows, which are handled through AppKit rather than Accessibility.
    var ownNumber: Int?

    /// The small word under the title, when the window is not simply there.
    var note: String? {
        if minimized { return "Minimized" }
        if hidden { return "Hidden" }
        if elsewhere { return "Another Space" }
        return nil
    }
}

/// The running apps to look at, read on the main thread and handed to the background read.
private struct SwitcherApp: Sendable {
    let pid: pid_t
    let name: String
    let hidden: Bool
}

/// Gathers windows from several threads at once.
private final class SwitcherCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SwitcherWindow] = []

    func add(_ more: [SwitcherWindow]) {
        lock.lock()
        items += more
        lock.unlock()
    }

    var all: [SwitcherWindow] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// What the panel draws. Kept apart from the settings object, so steering the panel does not
/// redraw the settings card behind it.
@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selected = 0
    @Published var columns = 1
    var icons: [pid_t: NSImage] = [:]
}

enum SwitcherMetrics {
    static let cardWidth = 150.0
    static let cardHeight = 152.0
    static let spacing = 10.0
    static let padding = 16.0
}

@MainActor
final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "switcher.enabled"); apply() } }
    @Published var shortcut: SwitcherShortcut {
        didSet {
            store.set(shortcut.rawValue, forKey: "switcher.shortcut")
            cancel()
            switchShortcut = shortcut
            modifierDown = false
            snapshot = nil
        }
    }
    /// Also list windows the window server keeps on other Spaces.
    @Published var allSpaces: Bool { didSet { store.set(allSpaces, forKey: "switcher.allSpaces"); snapshot = nil } }

    /// For tests: times the panel opened, and windows picked from it.
    private(set) var shown = 0
    private(set) var picks = 0
    /// Milliseconds from the chord to the panel on screen, last time.
    private(set) var openMs = 0
    var tapActive: Bool { switchTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var diagnostics: String {
        "switchTap=\(tapActive) switchShown=\(shown) switchPicks=\(picks) switchOpenMs=\(openMs)"
    }

    let model = SwitcherModel()
    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    private var panel: NSPanel?
    private var watchdog: Timer?

    private struct Session {
        var backward: Bool
        var started: Date
        /// Presses that came before the list did, applied once it arrives.
        var pendingSteps = 0
        /// The modifier was let go before the list arrived: pick as soon as it does.
        var released = false
        var loaded = false
    }
    private var session: Session?
    private var selection = SwitcherSelection(count: 0, columns: 1)

    /// The last list read, and when. Reading starts as soon as the modifier goes down, so by the
    /// time Tab follows the windows are usually already known.
    private var snapshot: (date: Date, windows: [SwitcherWindow])?
    private var fetching = false
    private var waiters: [@MainActor ([SwitcherWindow]) -> Void] = []

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "switcher.enabled")
        shortcut = UserDefaults.standard.string(forKey: "switcher.shortcut").flatMap(SwitcherShortcut.init(rawValue:)) ?? .optionTab
        allSpaces = UserDefaults.standard.bool(forKey: "switcher.allSpaces")
        switchShortcut = shortcut
    }

    func resume() { if enabled { apply() } }

    /// Accessibility just arrived: a tap made before it went away is made again, and one that
    /// was waiting for it starts.
    func rearm() {
        guard enabled else { return }
        removeTap()
        apply()
    }

    private func apply() {
        if enabled {
            guard switchTap == nil, AXIsProcessTrusted() else { objectWillChange.send(); return }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                                   | 1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: switchCallback, userInfo: nil) else { TapRevoke.creationFailed(); return }
            switchTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            removeTap()
        }
        objectWillChange.send()
    }

    private func removeTap() {
        guard let tap = switchTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        switchTap = nil
        source = nil
        cancel()
        swallowedUps.removeAll()
        snapshot = nil
        model.icons.removeAll()
    }

    // MARK: The chord

    /// The modifier just went down. Reading the windows now hides the read behind the time it
    /// takes to reach for Tab. ⌘` lists one app, which is quick to read on the press itself, and
    /// ⌘ goes down far too often to read on each.
    fileprivate func prefetch() {
        guard !shortcut.frontAppOnly else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.date) < 0.5 { return }
        fetch { _ in }
    }

    /// The chord was pressed: open the switcher, or move along when it is open.
    fileprivate func press(backward: Bool) {
        if session == nil {
            session = Session(backward: backward, started: Date())
            switching = true
            if let snapshot, Date().timeIntervalSince(snapshot.date) < 0.8, !shortcut.frontAppOnly {
                present(snapshot.windows)
            } else {
                fetch { WindowSwitcher.shared.present($0) }
            }
        } else if session?.loaded == true {
            move { $0.step(backward ? -1 : 1) }
        } else {
            session?.pendingSteps += backward ? -1 : 1
        }
    }

    /// A key while the switcher is open. Returns whether it was the switcher's to take.
    fileprivate func steer(_ code: Int64) -> Bool {
        switch code {
        case 53: cancel()                      // Esc
        case 36, 76: released()                // Return and Enter pick now
        case 123: move { $0.step(-1) }         // ←
        case 124: move { $0.step(1) }          // →
        case 125: move { $0.row(1) }           // ↓
        case 126: move { $0.row(-1) }          // ↑
        default: return false
        }
        return true
    }

    private func move(_ change: (inout SwitcherSelection) -> Void) {
        guard session?.loaded == true else { return }
        change(&selection)
        model.selected = selection.index
    }

    /// The modifier came up: pick what is highlighted.
    fileprivate func released() {
        guard var session else { return }
        guard session.loaded else {
            session.released = true
            self.session = session
            return
        }
        commit()
    }

    /// A card was clicked.
    func pick(_ index: Int) {
        guard session?.loaded == true else { return }
        selection.select(index)
        commit()
    }

    private func commit() {
        let chosen = selection.count > 0 ? model.windows[selection.index] : nil
        end()
        guard let chosen else { return }
        picks += 1
        focus(chosen)
    }

    func cancel() {
        guard session != nil || switching else { return }
        end()
    }

    private func end() {
        session = nil
        switching = false
        watchdog?.invalidate()
        watchdog = nil
        hidePanel()
    }

    // MARK: Showing

    private func present(_ windows: [SwitcherWindow]) {
        guard var session, !session.loaded else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = Int((visible.width * 0.86 - 2 * SwitcherMetrics.padding + SwitcherMetrics.spacing)
                      / (SwitcherMetrics.cardWidth + SwitcherMetrics.spacing))
        let columns = SwitcherLayout.columns(count: windows.count, maxColumns: max(fit, 1))
        selection = SwitcherSelection(count: windows.count, columns: columns, backward: session.backward)
        // A press that came while the list was being read counts from the default pick on.
        selection.step(session.pendingSteps)
        session.loaded = true
        self.session = session
        for window in windows where model.icons[window.pid] == nil {
            model.icons[window.pid] = NSRunningApplication(processIdentifier: window.pid)?.icon
        }
        model.windows = windows
        model.columns = columns
        model.selected = selection.index
        if session.released {
            commit()
            return
        }
        showPanel(on: visible, columns: columns, count: windows.count)
        shown += 1
        openMs = Int(Date().timeIntervalSince(session.started) * 1000)
    }

    private func showPanel(on visible: CGRect, columns: Int, count: Int) {
        let pad = SwitcherMetrics.padding, gap = SwitcherMetrics.spacing
        let rows = max((count + columns - 1) / columns, 1)
        let size = count == 0
            ? CGSize(width: 320, height: 110)
            : CGSize(width: Double(columns) * SwitcherMetrics.cardWidth + Double(columns - 1) * gap + 2 * pad,
                     height: min(Double(rows) * SwitcherMetrics.cardHeight + Double(rows - 1) * gap + 2 * pad, visible.height * 0.8))
        let panel = self.panel ?? makePanel()
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // If the tap ever misses the modifier coming up (it can be paused under heavy load), the
        // panel would wait forever. The keyboard's own state settles it.
        watchdog?.invalidate()
        let modifier = CGEventFlags(rawValue: shortcut.modifier)
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !CGEventSource.flagsState(.combinedSessionState).contains(modifier) { WindowSwitcher.shared.released() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow follows the glass's rounded shape and lifts it off dark windows behind.
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = FirstClickHostingView(rootView: SwitcherPanelView(model: model))
        self.panel = panel
        return panel
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        // A quick fade, so the window that comes forward is not hidden behind a panel that
        // lingers; the panel is ordered out the moment the fade ends unless a new session began.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if !switching { WindowSwitcher.shared.panel?.orderOut(nil) }
            }
        }
    }

    // MARK: Reading the windows

    private func fetch(_ done: @escaping @MainActor ([SwitcherWindow]) -> Void) {
        waiters.append(done)
        guard !fetching else { return }
        fetching = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = shortcut.frontAppOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .filter { front == nil || $0.processIdentifier == front }
            .map { SwitcherApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", hidden: $0.isHidden) }
        // Atelier's own windows answer Accessibility on this very thread, so they are read here
        // through AppKit instead of being asked for from the background.
        let own = front == nil || front == ownPID ? ownWindows() : []
        let everywhere = allSpaces
        DispatchQueue.global(qos: .userInteractive).async {
            let list = Self.collect(apps: apps, own: own, allSpaces: everywhere)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WindowSwitcher.shared.fetched(list) }
            }
        }
    }

    private func fetched(_ list: [SwitcherWindow]) {
        fetching = false
        snapshot = (Date(), list)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter(list) }
    }

    private func ownWindows() -> [SwitcherWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let name = NSRunningApplication.current.localizedName ?? "Atelier"
        return NSApp.windows.compactMap { window in
            guard !(window is NSPanel), window.styleMask.contains(.titled), window.level == .normal,
                  window.isVisible || window.isMiniaturized else { return nil }
            return SwitcherWindow(id: "own-\(window.windowNumber)", pid: pid, windowID: CGWindowID(window.windowNumber),
                                  title: window.title.isEmpty ? name : window.title, appName: name, size: window.frame.size,
                                  minimized: window.isMiniaturized, ownNumber: window.windowNumber)
        }
    }

    /// Reads every app's windows at once, then puts them in switcher order. Runs off the main
    /// thread; each app gets a short Accessibility timeout so a hung one cannot hold the panel.
    nonisolated private static func collect(apps: [SwitcherApp], own: [SwitcherWindow], allSpaces: Bool) -> [SwitcherWindow] {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]]) ?? []
        let frontToBack = onScreen.compactMap { info -> UInt32? in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let number = info[kCGWindowNumber as String] as? Int else { return nil }
            return UInt32(number)
        }
        let z = SwitcherOrder.zIndex(of: frontToBack)

        let collector = SwitcherCollector()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            collector.add(windows(of: apps[index]))
        }
        var list = collector.all + own
        for index in list.indices where !list[index].minimized && !list[index].hidden {
            if let id = list[index].windowID, z[id] == nil { list[index].elsewhere = true }
        }
        if allSpaces {
            list += elsewhereWindows(apps: apps, known: Set(list.compactMap(\.windowID)), resolved: list.isEmpty || list.contains { $0.windowID != nil })
        } else {
            list.removeAll(where: \.elsewhere)
        }
        return SwitcherOrder.ordered(list, zIndex: { $0.windowID.flatMap { z[$0] } }, minimized: \.minimized)
    }

    /// One app's standard windows, front to back as the app reports them.
    nonisolated private static func windows(of app: SwitcherApp) -> [SwitcherWindow] {
        let element = DockAX.application(app.pid, timeout: 0.15)
        guard let list = DockAX.attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.compactMap { window in
            let subrole = DockAX.attribute(window, kAXSubroleAttribute) as? String
            guard subrole == nil || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { return nil }
            let minimized = (DockAX.attribute(window, kAXMinimizedAttribute) as? Bool) ?? false
            var size = CGSize.zero
            if let raw = DockAX.attribute(window, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
                AXValueGetValue(raw as! AXValue, .cgSize, &size)
            }
            // Below this a window is a palette or a strip, not something one switches to.
            guard minimized || (size.width >= 100 && size.height >= 60) else { return nil }
            let title = DockAX.attribute(window, kAXTitleAttribute) as? String ?? ""
            let ref = AXRef(element: window)
            let id = DockAX.windowID(ref)
            return SwitcherWindow(id: "\(app.pid)-\(id.map(String.init) ?? String(CFHash(window)))", ref: ref, pid: app.pid,
                                  windowID: id, title: title.isEmpty ? app.name : title, appName: app.name, size: size,
                                  minimized: minimized, hidden: app.hidden)
        }
    }

    /// Windows the window server holds off screen that Accessibility did not report: for most
    /// apps, the ones on other Spaces. Only their owner and size are public; a title would need
    /// screen recording, which Atelier does not ask for. Skipped when windows could not be
    /// matched to window-server numbers, as every window would then look unknown.
    nonisolated private static func elsewhereWindows(apps: [SwitcherApp], known: Set<CGWindowID>, resolved: Bool) -> [SwitcherWindow] {
        guard resolved else { return [] }
        let byPID = Dictionary(apps.filter { !$0.hidden }.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return all.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let number = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init), !known.contains(number),
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), let app = byPID[pid],
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 120, bounds.height >= 80 else { return nil }
            return SwitcherWindow(id: "cg-\(number)", pid: pid, windowID: number, title: app.name, appName: app.name,
                                  size: bounds.size, elsewhere: true)
        }
    }

    // MARK: Bringing a window forward

    private func focus(_ window: SwitcherWindow) {
        if let number = window.ownNumber {
            guard let own = NSApp.windows.first(where: { $0.windowNumber == number }) else { return }
            if own.isMiniaturized { own.deminiaturize(nil) }
            NSApp.activate()
            own.makeKeyAndOrderFront(nil)
            return
        }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        let ref = window.ref, pid = window.pid
        DispatchQueue.global(qos: .userInteractive).async {
            // Unminimises, makes it the app's main window and raises it above its siblings.
            if let ref { DockAX.raise(ref) }
            // macOS may decline an activation asked for by an app in the background; marking
            // the app frontmost through Accessibility is the dependable way.
            AXUIElementSetAttributeValue(DockAX.application(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
            }
        }
    }
}

/// Clicks on a card count the first time, even though the panel never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - The panel

struct SwitcherPanelView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        Group {
            if model.windows.isEmpty {
                Text("No Windows to Switch To")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(SwitcherMetrics.cardWidth), spacing: SwitcherMetrics.spacing),
                                                 count: model.columns),
                                  spacing: SwitcherMetrics.spacing) {
                            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                                SwitcherTile(title: window.title, app: window.appName, icon: model.icons[window.pid],
                                             shape: window.size, note: window.note, selected: index == model.selected)
                                    .id(index)
                                    .onTapGesture { WindowSwitcher.shared.pick(index) }
                                    .accessibilityLabel("\(window.title), \(window.appName)")
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .padding(SwitcherMetrics.padding)
                    }
                    .onChange(of: model.selected) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .atelierGlass(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 28))
        .environment(\.colorScheme, .dark)
    }
}

/// One card: the window's shape drawn small with the app's icon on it, then title and app.
struct SwitcherTile: View {
    let title: String
    let app: String
    let icon: NSImage?
    let shape: CGSize
    let note: String?
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                let fitted = SwitcherLayout.schematic(for: shape, in: CGSize(width: 112, height: 66))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(note == nil ? 0.1 : 0.04))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.35)).frame(width: 4, height: 4) }
                        }
                        .padding(5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: note == nil ? [] : [3, 2.5]))
                    }
                    .frame(width: fitted.width, height: fitted.height)
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .opacity(note == nil ? 1 : 0.75)
            }
            .frame(width: 120, height: 74)
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Text(note.map { "\(app) · \($0)" } ?? app)
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(width: SwitcherMetrics.cardWidth, height: SwitcherMetrics.cardHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
        }
        .contentShape(.rect(cornerRadius: 16))
    }
}

// MARK: - Card

struct WindowSwitcherCard: View {
    @ObservedObject private var switcher = WindowSwitcher.shared

    private var keyName: String { switcher.shortcut == .commandGrave ? "`" : "Tab" }
    private var modifierName: String {
        switch switcher.shortcut {
        case .optionTab: "Option"
        case .controlTab: "Control"
        case .commandGrave: "Command"
        }
    }

    private var shortcutNote: String {
        switch switcher.shortcut {
        case .optionTab: "Tab and ⇧Tab or the arrow keys move along, Esc cancels, and a click picks a window."
        case .controlTab: "Browsers and many editors use ⌃Tab to move between tabs. While this is on, the switcher has it instead."
        case .commandGrave: "Shows only the front app's windows, in place of macOS's own window cycling."
        }
    }

    private var spacesNote: String {
        switcher.allSpaces
            ? "Windows on other Spaces show their app and shape but no title, as reading it would need screen recording, which Atelier never asks for. Choosing one switches to that app."
            : "Most apps share only the windows on the Space you're in."
    }

    var body: some View {
        HeroCard("Window Switcher",
                 pitch: "Every window, not just every app. Hold \(modifierName), tap \(keyName), let go.",
                 isOn: $switcher.enabled, hue: DS.Spectrum.windows,
                 readout: switcher.shortcut.label, readoutCaption: "Shortcut",
                 preview: .overlay("engine.switcher", "Window Switcher", isOn: switcher.enabled) { size in
                     WindowSwitcherPreview(size: size)
                 }) {
            LivePlate { size, since in WindowSwitcherPlate(size: size, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                NeedsAccessRow(reason: "To see the shortcut and read window titles.")
                VStack(alignment: .leading, spacing: 6) {
                    Segments(selection: $switcher.shortcut,
                             options: SwitcherShortcut.allCases.map { ($0, $0.label) })
                    Text(shortcutNote).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !switcher.shortcut.frontAppOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Segments(selection: $switcher.allSpaces, options: [(false, "This Space"), (true, "All Spaces")])
                        Text(spacesNote).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The hero plate: the switcher's panel in miniature, drawn flat (no glass inside a card), with
/// the highlight resting on the second window. On hover it hops along as Tab would walk it.
struct WindowSwitcherPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since, rest: 0, fps: 10) { time in
            panel(selected: (Int(time / 0.6) + 1) % WindowSwitcherPreview.samples.count)
        }
    }

    private func panel(selected: Int) -> some View {
        let samples = WindowSwitcherPreview.samples
        let tile = min((size.width - 120) / Double(samples.count), 64.0)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(samples.indices, id: \.self) { index in
                    let chosen = index == selected
                    Group {
                        if let icon = WindowSwitcherPreview.icons[index] {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: tile * 0.62, height: tile * 0.62)
                    .opacity(samples[index].note == nil ? 1 : 0.6)
                    .frame(width: tile, height: tile)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(.white.opacity(chosen ? 0.16 : 0))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(.white.opacity(chosen ? 0.34 : 0), lineWidth: 0.75)
                            }
                    }
                }
            }
            Text("\(samples[selected].app) · \(samples[selected].title)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        .background {
            // Concentric with the tiles: 11 + 10 padding.
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17).opacity(0.92), Color(white: 0.1).opacity(0.92)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The panel at stage scale: five real app icons, the highlight hopping along as if Tab were
/// being pressed. Ticks a few times a second only.
struct WindowSwitcherPreview: View {
    let size: CGSize

    fileprivate struct Sample {
        let bundle: String
        let app: String
        let title: String
        let shape: CGSize
        var note: String?
    }

    fileprivate static let samples = [
        Sample(bundle: "com.apple.Safari", app: "Safari", title: "Start Page", shape: CGSize(width: 16, height: 10)),
        Sample(bundle: "com.apple.finder", app: "Finder", title: "Downloads", shape: CGSize(width: 4, height: 3)),
        Sample(bundle: "com.apple.Notes", app: "Notes", title: "Groceries", shape: CGSize(width: 3, height: 4)),
        Sample(bundle: "com.apple.mail", app: "Mail", title: "Inbox", shape: CGSize(width: 16, height: 10)),
        Sample(bundle: "com.apple.Music", app: "Music", title: "Library", shape: CGSize(width: 3, height: 2), note: "Minimized"),
    ]

    @MainActor fileprivate static let icons: [NSImage?] = samples.map { sample in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: sample.bundle)
            .map { NSWorkspace.shared.icon(forFile: $0.resolvingSymlinksInPath().path) }
    }

    var body: some View {
        let gap = SwitcherMetrics.spacing, pad = SwitcherMetrics.padding
        let width = 5 * SwitcherMetrics.cardWidth + 4 * gap + 2 * pad
        TimelineView(.periodic(from: .now, by: 0.7)) { context in
            // 1, 2, 3, 4, 0 … as Tab would walk it, starting on the second window.
            let selected = (Int(context.date.timeIntervalSinceReferenceDate / 0.7) % 5 + 1) % 5
            HStack(spacing: gap) {
                ForEach(Self.samples.indices, id: \.self) { index in
                    let sample = Self.samples[index]
                    SwitcherTile(title: sample.title, app: sample.app, icon: Self.icons[index], shape: sample.shape,
                                 note: sample.note, selected: index == selected)
                }
            }
            .padding(pad)
            .animation(DS.Motion.touch, value: selected)
            .atelierGlass(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 28))
            .environment(\.colorScheme, .dark)
            .frame(width: width)
            .scaleEffect(size.width / 1500)
            .frame(width: size.width, height: size.height)
        }
    }
}
