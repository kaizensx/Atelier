import AppKit
import ApplicationServices
import CoreGraphics
import DockCore

// MARK: - Display Memory
//
// macOS piles windows onto whatever display is left whenever a monitor is plugged or unplugged,
// the Mac wakes, or a resolution changes, and it never puts them back. Display Memory remembers
// the arrangement for each display configuration (which displays, where, at which size: see
// DockCore's DisplayConfiguration) and, when a configuration returns, glides every window back
// to where it was on that setup.
//
// How it stays cheap and right:
// - Watching: every 2 s it hashes the window server's list (ids and bounds, no Accessibility).
//   Only a change pays for an Accessibility snapshot, and a snapshot is only kept once 1.5 s
//   pass with no reconfiguration (SnapshotJournal): macOS starts moving windows the moment it
//   tells us the displays are changing, so the last snapshot before that may already be wrong.
// - Settling: CGDisplayRegisterReconfigurationCallback reports the change *before* it happens.
//   Snapshots stop, and DisplaySettleGate waits until nothing has changed for 1.2 s and the same
//   configuration has been seen for 1 s (or 15 s pass), so a burst of events is one restore.
// - Restoring: remembered windows are matched to live ones by window id, title, similar title,
//   then app order; full-screen and minimised windows are skipped; a window whose display is
//   missing is rehomed onto the primary display and clamped on screen (WindowGeometry.rehome).
//   Two short verification passes follow, for apps that re-place their windows late.
//
// Nothing system-wide changes: it moves windows through WindowEngine with the public
// Accessibility API, and off it removes its callback, observers and timer. The memory itself is
// data under `displayMemory.*`.

@MainActor
final class DisplayMemory: ObservableObject {
    static let shared = DisplayMemory()

    enum Keys {
        static let enabled = "displayMemory.enabled"
        /// JSON [DisplaySetup], most recently updated first.
        static let setups = "displayMemory.setups"
    }

    enum Phase: String { case off, watching, settling }

    /// Most setups anyone plugs into; the oldest is forgotten past this.
    static let limit = 16

    @Published private(set) var enabled: Bool
    @Published private(set) var setups: [DisplaySetup] = []
    @Published private(set) var currentKey: String?
    @Published private(set) var phase: Phase = .off
    /// One line for the card: what happened last.
    @Published private(set) var status: String?

    private let store = UserDefaults.standard
    private var gate = DisplaySettleGate()
    private var journal = SnapshotJournal<[RememberedWindow]>()
    private var timer: Timer?
    private var timerRate = 0.0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var callbackInstalled = false
    private var lastSignature: UInt64?
    /// No snapshots before this: a restore and its verification passes are still running.
    private var holdUntil = 0.0
    private var verifyPasses: [Double] = []
    private var verifySetup: String?

    private var events = 0
    private var snapshots = 0
    private var restores = 0
    private var lastReport: [String] = []

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private init() {
        enabled = store.bool(forKey: Keys.enabled)
        if let data = store.data(forKey: Keys.setups),
           let saved = try? JSONDecoder().decode([DisplaySetup].self, from: data) {
            setups = saved
        }
    }

    // MARK: Lifecycle

    func resume() {
        currentKey = Self.currentConfiguration().key
        if enabled { start() }
    }

    func restoreOnQuit() { stop() }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        store.set(on, forKey: Keys.enabled)
        if on { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        if !callbackInstalled {
            callbackInstalled = CGDisplayRegisterReconfigurationCallback(displayMemoryReconfigured, nil) == .success
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.willSleepNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let label = note.name.rawValue
                MainActor.assumeIsolated { DisplayMemory.shared.displaysChanging(source: label) }
            }))
        }
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayMemory.shared.displaysChanging(source: "screenParameters") }
        }))
        phase = .watching
        lastSignature = nil
        currentKey = Self.currentConfiguration().key
        retime(2)
    }

    private func stop() {
        if callbackInstalled {
            CGDisplayRemoveReconfigurationCallback(displayMemoryReconfigured, nil)
            callbackInstalled = false
        }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        timerRate = 0
        journal.invalidate()
        gate = DisplaySettleGate()
        verifyPasses.removeAll()
        phase = .off
    }

    private func retime(_ interval: Double) {
        guard enabled, interval != timerRate else { return }
        timerRate = interval
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { DisplayMemory.shared.tick() }
        }
        next.tolerance = interval * 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    // MARK: Events

    /// A display is about to change, has changed, or the Mac slept or woke.
    func displaysChanging(source: String) {
        guard enabled else { return }
        events += 1
        journal.invalidate()
        verifyPasses.removeAll()
        gate.noteChange(now: now)
        phase = .settling
        retime(0.25)
    }

    private func tick() {
        let t = now
        let config = Self.currentConfiguration()
        let key = config.isEmpty ? nil : config.key
        if gate.settling {
            if let settled = gate.observe(key: key, now: t) { self.settled(config, key: settled) }
            return
        }
        currentKey = key
        if let pass = verifyPasses.first, t >= pass {
            verifyPasses.removeFirst()
            if let id = verifySetup, let setup = setups.first(where: { $0.id == id }), id == key {
                restore(setup, onto: config, verification: true)
            }
        }
        if verifyPasses.isEmpty, phase == .watching { retime(2) }
        guard t >= holdUntil, let key, AXIsProcessTrusted() else { return }
        if let due = journal.due(now: t, currentKey: key) { commit(due.payload, config: config) }
        let signature = Self.listSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        let fresh = snapshot(config)
        if let known = setups.first(where: { $0.id == key }), !DisplayMemoryLogic.differs(known.windows, fresh) { return }
        journal.propose(key: key, payload: fresh, now: t)
    }

    private func settled(_ config: DisplayConfiguration, key: String) {
        phase = .watching
        currentKey = key
        lastSignature = nil
        if let setup = setups.first(where: { $0.id == key }), AXIsProcessTrusted() {
            restore(setup, onto: config, verification: false)
            verifySetup = key
            verifyPasses = [now + 1.5, now + 4]
            holdUntil = now + 5.5
            retime(0.25)
        } else {
            holdUntil = now
            if !setups.contains(where: { $0.id == key }) { status = "New setup: \(config.summary). Arrange your windows; they are remembered." }
            retime(2)
        }
    }

    // MARK: Snapshots

    private func snapshot(_ config: DisplayConfiguration) -> [RememberedWindow] {
        let listed = AXDesk.listedWindows()
        return AXDesk.allWindows().enumerated().compactMap { order, window -> RememberedWindow? in
            guard let frame = window.frame, let app = window.app.bundleIdentifier, window.isMovable else { return nil }
            let pid = window.app.processIdentifier
            return RememberedWindow(app: app, appName: window.app.localizedName ?? app, title: window.title,
                                    windowID: WindowGeometry.windowID(pid: pid, frame: frame, in: listed), pid: pid,
                                    frame: frame, display: config.identity(for: frame), order: order)
        }
    }

    private func commit(_ fresh: [RememberedWindow], config: DisplayConfiguration) {
        let previous = setups.first { $0.id == config.key }
        let windows = DisplayMemoryLogic.merge(previous: previous?.windows ?? [], fresh: fresh, alive: Self.aliveWindowIDs())
        var setup = previous ?? DisplaySetup(configuration: config, windows: [], updated: Date())
        setup.configuration = config
        setup.windows = windows
        setup.updated = Date()
        setups.removeAll { $0.id == config.key }
        setups.insert(setup, at: 0)
        if setups.count > Self.limit { setups.removeLast(setups.count - Self.limit) }
        snapshots += 1
        persist()
    }

    /// Takes and keeps a snapshot at once, for the test hook.
    func snapshotNow() {
        let config = Self.currentConfiguration()
        guard !config.isEmpty, AXIsProcessTrusted() else { return }
        commit(snapshot(config), config: config)
        lastSignature = Self.listSignature()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(setups) { store.set(data, forKey: Keys.setups) }
    }

    func forget(_ id: String) {
        setups.removeAll { $0.id == id }
        persist()
    }

    // MARK: Restoring

    /// Puts a setup's windows back on the displays there are now. `id` may be any remembered
    /// setup: on another configuration windows follow their display, or are rehomed.
    func restoreNow(_ id: String) {
        guard let setup = setups.first(where: { $0.id == id }) else { return }
        restore(setup, onto: Self.currentConfiguration(), verification: false)
        holdUntil = now + 2
    }

    private func restore(_ setup: DisplaySetup, onto config: DisplayConfiguration, verification: Bool) {
        guard AXIsProcessTrusted() else {
            status = "Display Memory needs Accessibility access to move windows."
            return
        }
        let listed = AXDesk.listedWindows()
        let live = AXDesk.allWindows().filter(\.isMovable)
        let keys = live.map { window -> LiveWindow in
            let frame = window.frame ?? .zero
            let pid = window.app.processIdentifier
            return LiveWindow(app: window.app.bundleIdentifier ?? "", title: window.title,
                              windowID: WindowGeometry.windowID(pid: pid, frame: frame, in: listed), pid: pid, frame: frame)
        }
        // Rehomed into the room the Atelier Dock leaves, not under its bar.
        let displays = config.displays.map {
            WindowGeometry.Display(frame: $0.frame, visible: ScreenArea.usableAX(frame: $0.frame, fallback: $0.visible))
        }
        let pairs = DisplayMemoryLogic.match(saved: setup.windows, live: keys)
        var moves: [(window: AXWindow, frame: CGRect)] = []
        var report = ["\(verification ? "verify" : "restore") \(setup.id) onto \(config.key) (\(config.summary)) at \(Date())"]
        for pair in pairs {
            let saved = setup.windows[pair.saved]
            let (target, placement) = DisplayMemoryLogic.target(for: saved, saved: setup.configuration, current: config)
            let safe = WindowGeometry.rehome(target, displays: displays)
            let current = keys[pair.live].frame
            let move = DisplayMemoryLogic.needsMove(current, to: safe)
            if move { moves.append((live[pair.live], safe)) }
            report.append("  \(move ? "move" : "keep") \(saved.app) \"\(saved.title)\" by \(pair.reason.rawValue) \(placement.rawValue) "
                          + "\(Self.text(current)) -> \(Self.text(safe))")
        }
        let placed = Set(pairs.map(\.saved))
        for (index, saved) in setup.windows.enumerated() where !placed.contains(index) {
            report.append("  missing \(saved.app) \"\(saved.title)\"")
        }
        WindowEngine.shared.place(moves, animated: !verification)
        lastReport = report
        writeReport()
        guard !verification else { return }
        restores += 1
        if let index = setups.firstIndex(where: { $0.id == setup.id }) {
            setups[index].restored = Date()
            setups[index].restores += 1
            persist()
        }
        let count = moves.count
        status = count == 0 ? "Every window was already in place on \(config.summary)."
            : "Put \(count == 1 ? "1 window" : "\(count) windows") back on \(config.summary)."
    }

    // MARK: Reading the system

    static func currentConfiguration() -> DisplayConfiguration {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return DisplayConfiguration([]) }
        let height = Double(primary.frame.height)
        return DisplayConfiguration(screens.compactMap { screen -> DisplayFacts? in
            guard let id = LightEngine.displayID(of: screen) else { return nil }
            return DisplayFacts(uuid: DisplayModeKit.uuid(id), vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                serial: CGDisplaySerialNumber(id), name: screen.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0,
                                frame: WindowGeometry.flipped(screen.frame, primaryHeight: height),
                                visible: WindowGeometry.flipped(screen.visibleFrame, primaryHeight: height),
                                scale: Double(screen.backingScaleFactor), rotation: CGDisplayRotation(id))
        })
    }

    /// Normal windows on screen, ids and bounds only: no Accessibility, no titles.
    private static func listSignature() -> UInt64 {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = AXDesk.listedWindows().filter { $0.layer == 0 && $0.pid != own }
        return DisplayMemoryLogic.listSignature(list.map { ($0.id, $0.bounds) })
    }

    /// Every normal window that exists, on any Space.
    private static func aliveWindowIDs() -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? Int : nil
        })
    }

    private static func text(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
    }

    // MARK: Diagnostics and tests

    var diagnostics: String {
        "displayMemory=\(enabled ? "on" : "off") displayMemoryPhase=\(phase.rawValue) displayMemorySetups=\(setups.count) "
            + "displayMemoryCurrent=\(currentKey ?? "-") displayMemoryKnown=\(setups.contains { $0.id == currentKey }) "
            + "displayMemoryEvents=\(events) displayMemorySnapshots=\(snapshots) displayMemoryRestores=\(restores) "
            + "displayMemoryCallback=\(callbackInstalled)"
    }

    private static var reportPath: String { NSTemporaryDirectory() + "atelier-displaymemory.txt" }

    private func writeReport() {
        let config = Self.currentConfiguration()
        var lines = [diagnostics, "current \(config.key) \(DisplayConfiguration.canonical(config.displays, identities: config.identities))"]
        for setup in setups {
            lines.append("setup \(setup.id) \(setup.configuration.summary) windows=\(setup.windows.count) restores=\(setup.restores) updated=\(setup.updated)")
            for window in setup.windows {
                lines.append("  \(window.order) \(window.app) id=\(window.windowID.map(String.init) ?? "-") \"\(window.title)\" \(Self.text(window.frame)) on \(window.display ?? "-")")
            }
        }
        lines.append("last:")
        lines += lastReport
        try? lines.joined(separator: "\n").write(toFile: Self.reportPath, atomically: true, encoding: .utf8)
    }

    /// `atelier://displaymemory?on=1|0`, `?snapshot=1` (take and keep one now), `?restore=<key>|current`,
    /// `?simulate=reconfig` (as if the displays changed: settle, then restore), `?forget=<key>|all`,
    /// `?report=1` (everything to $TMPDIR/atelier-displaymemory.txt; also written after each restore).
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let on = value("on") { setEnabled(on == "1") }
        if value("snapshot") != nil { snapshotNow() }
        if let id = value("forget") {
            if id == "all" { setups.removeAll(); persist() } else { forget(id) }
        }
        if let id = value("restore") { restoreNow(id == "current" ? (currentKey ?? Self.currentConfiguration().key) : id) }
        if value("simulate") == "reconfig" { displaysChanging(source: "simulate") }
        if value("report") != nil { writeReport() }
    }
}

/// CoreGraphics calls this on the main thread, once with the begin flag before the change and
/// once per display after it.
private func displayMemoryReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                       _ context: UnsafeMutableRawPointer?) {
    let label = flags.contains(.beginConfigurationFlag) ? "begin" : "end"
    DispatchQueue.main.async {
        MainActor.assumeIsolated { DisplayMemory.shared.displaysChanging(source: "cg-\(label)") }
    }
}
