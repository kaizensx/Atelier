import AppKit
import DockCore
import SwiftUI

// MARK: - Fan Control
//
// Sets the fans by a curve (temperature to speed) or at full speed, which macOS never lets
// anyone do. The app decides; a tiny root helper (AtelierFans, a LaunchDaemon the owner installs
// from the card with one administrator password and removes the same way) does the SMC writes.
//
// Once a second while a preset is on, the app reads the hotter of the CPU and GPU averages from
// Sensors, runs FanGovernor over the curve (3 °C hysteresis, fast up and slow down, full speed
// over the hard limit) and writes the resulting rpm per fan to the helper's inbox. That file is
// also the heartbeat: the helper hands every fan back to macOS when it is 10 s old, so a crash,
// a hang or a force quit can never leave the fans pinned. Quitting, turning it off, sleep and
// removing the helper all write "system" first; the helper does the same on its own for sleep,
// for being stopped, for any temperature it cannot read, and it never goes below a fan's SMC
// minimum. Off by default; settings under `fans.*`.

@MainActor
final class FanControl: ObservableObject {
    static let shared = FanControl()

    enum Keys {
        static let preset = "fans.preset"
        static let last = "fans.lastPreset"
        static let curve = "fans.curve"
        static let limit = "fans.hardLimit"
    }

    enum HelperState: Equatable {
        case absent
        /// On disk but not answering: starting, stopped or broken.
        case installed
        case running

        var text: String {
            switch self {
            case .absent: "not installed"
            case .installed: "installed, not answering"
            case .running: "running"
            }
        }
    }

    @Published private(set) var preset: FanPreset
    @Published var customCurve: FanCurve { didSet { store.set(customCurve.text, forKey: Keys.curve) } }
    @Published var hardLimit: Double {
        didSet {
            store.set(hardLimit, forKey: Keys.limit)
            governor.hardLimit = FanSafety.clampLimit(hardLimit)
        }
    }
    @Published private(set) var helper = HelperState.absent
    @Published private(set) var status: FanHelperStatus?
    @Published private(set) var demand = FanDemand.system
    @Published private(set) var temperature: Double?
    @Published private(set) var lastError: String?
    @Published private(set) var working = false

    private let store = UserDefaults.standard
    private var governor: FanGovernor
    private var timer: Timer?
    private var holding = false
    private var lastTick: Double?
    private var seq = 0
    private(set) var commands = 0
    private var lastCommand: FanCommand?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let store = UserDefaults.standard
        preset = FanPreset(rawValue: store.string(forKey: Keys.preset) ?? "") ?? .system
        customCurve = store.string(forKey: Keys.curve).flatMap(FanCurve.parse) ?? FanPreset.balanced.curve!
        let limit = store.object(forKey: Keys.limit) as? Double ?? 95
        hardLimit = FanSafety.clampLimit(limit)
        governor = FanGovernor(hardLimit: limit)
    }

    var enabled: Bool { preset != .system }

    /// The curve in force: the preset's, or the owner's own for Custom.
    var curve: FanCurve? { preset == .custom ? customCurve : preset.curve }

    /// The last preset that was on, for the card's switch.
    var lastPreset: FanPreset {
        FanPreset(rawValue: store.string(forKey: Keys.last) ?? "").flatMap { $0 == .system ? nil : $0 } ?? .balanced
    }

    // MARK: Lifecycle

    func resume() {
        refreshHelper()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FanControl.shared.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FanControl.shared.didWake() }
        })
        apply()
    }

    /// Quitting: every fan back to the system now, without waiting for the heartbeat to lapse.
    func restoreOnQuit() {
        stopTimer()
        sendSystem("quit")
    }

    func setPreset(_ new: FanPreset) {
        guard new != preset else { return }
        preset = new
        store.set(new.rawValue, forKey: Keys.preset)
        if new != .system { store.set(new.rawValue, forKey: Keys.last) }
        governor.reset()
        apply()
    }

    func setEnabled(_ on: Bool) { setPreset(on ? lastPreset : .system) }

    /// Edits the custom curve; dragging a preset's point turns it into Custom from there.
    func editCurve(_ change: (inout FanCurve) -> Void) {
        var base = curve ?? customCurve
        if !base.systemBelowStart, base.points.count < 2 { base = FanPreset.balanced.curve! }
        change(&base)
        customCurve = base
        if preset != .custom { setPreset(.custom) }
    }

    private func apply() {
        if enabled {
            if !holding { holding = true; Sensors.shared.acquire() }
            if timer == nil {
                lastTick = nil
                let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { FanControl.shared.tick() } }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            tick()
        } else {
            stopTimer()
            if holding { holding = false; Sensors.shared.release() }
            demand = .system
            sendSystem("off")
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func willSleep() {
        guard enabled else { return }
        stopTimer()
        sendSystem("sleep")
    }

    private func didWake() {
        governor.reset()
        apply()
    }

    // MARK: Control loop

    /// The hotter of the CPU and GPU, smoothed, as the helper's own reading is.
    private var hottest: Double? { [Sensors.shared.cpu, Sensors.shared.gpu].compactMap { $0 }.max() }

    private func tick() {
        refreshHelper()
        guard let curve else { return }
        let now = Sensors.clock()
        let dt = lastTick.map { now - $0 } ?? 1
        lastTick = now
        temperature = hottest
        demand = governor.step(temperature: temperature, curve: curve, dt: dt)
        send(demand, reason: preset.rawValue)
    }

    /// Each fan's range: from the helper when it answers (it read them as root), else Sensors.
    private var fanRanges: [(index: Int, min: Double, max: Double)] {
        if let fans = status?.fans, !fans.isEmpty { return fans.map { ($0.index, $0.min, $0.max) } }
        return (Sensors.shared.latest?.fans ?? []).enumerated().map { ($0.offset, $0.element.min, $0.element.max) }
    }

    private func send(_ demand: FanDemand, reason: String) {
        let fans = fanRanges.map { fan in
            FanCommand.Fan(index: fan.index, rpm: demand == .overheat ? fan.max
                           : demand.level.map { FanTarget.rpm(level: $0, min: fan.min, max: fan.max) })
        }
        seq += 1
        write(FanCommand(sent: Date().timeIntervalSince1970, seq: seq,
                         fans: fans.contains { $0.rpm != nil } ? fans : [], hardLimit: hardLimit, reason: reason))
    }

    private func sendSystem(_ reason: String) {
        seq += 1
        write(.system(sent: Date().timeIntervalSince1970, seq: seq, reason: reason))
    }

    /// Only once the helper's inbox exists, which only its installer makes.
    private func write(_ command: FanCommand) {
        lastCommand = command
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: FanHelperInstall.inbox, isDirectory: &isDirectory), isDirectory.boolValue,
              let data = try? JSONEncoder().encode(command) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: FanHelperInstall.commandPath), options: .atomic)
            commands += 1
        } catch {
            lastError = "Could not reach the helper: \(error.localizedDescription)"
        }
    }

    // MARK: Helper

    func refreshHelper() {
        let fm = FileManager.default
        let decoded = fm.contents(atPath: FanHelperInstall.statusPath).flatMap { try? JSONDecoder().decode(FanHelperStatus.self, from: $0) }
        if decoded != status { status = decoded }
        let state: HelperState
        if !fm.fileExists(atPath: FanHelperInstall.plistPath) || !fm.fileExists(atPath: FanHelperInstall.helperPath) {
            state = .absent
        } else if let decoded, abs(Date().timeIntervalSince1970 - decoded.time) < FanHelperInstall.statusFreshness {
            state = .running
        } else {
            state = .installed
        }
        if state != helper { helper = state }
    }

    /// The installed helper is older than the one in this build: an app update never replaces
    /// what is in /Library on its own, so the card offers "Update helper…".
    var helperOutdated: Bool {
        helper != .absent && bundledHelper != nil && FanHelperInstall.isOutdated(status) == true
    }

    /// The helper built beside the app's own executable (Contents/MacOS in the bundle).
    var bundledHelper: String? {
        let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AtelierFans").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// One administrator password: copies the helper, writes its LaunchDaemon, starts it. Also
    /// how an outdated helper is updated: the script boots the old one out first.
    func installHelper() {
        guard !working else { return }
        Task { await installHelperNow() }
    }

    func installHelperNow() async {
        guard let source = bundledHelper else { lastError = "The fan helper is missing from this build."; return }
        let plist = NSTemporaryDirectory() + "net.dasantos.atelier.fans.plist"
        do {
            try FanHelperInstall.plist(owner: getuid()).write(toFile: plist, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Could not prepare the helper: \(error.localizedDescription)"
            return
        }
        await runPrivileged(FanHelperInstall.installScript(helperSource: source, plistSource: plist, owner: getuid()),
                            describing: helper == .absent ? "install the fan helper" : "update the fan helper")
        try? FileManager.default.removeItem(atPath: plist)
        afterHelperChange()
    }

    /// Fans back to the system first, then the daemon stops (handing back again) and goes.
    func removeHelper() {
        guard !working else { return }
        Task { await removeHelperNow() }
    }

    /// For the card and for Remove Everything. Returns whether the helper is gone.
    @discardableResult
    func removeHelperNow() async -> Bool {
        let wasOn = preset
        setPreset(.system)
        sendSystem("remove")
        await runPrivileged(FanHelperInstall.removeScript, describing: "remove the fan helper")
        refreshHelper()
        if helper != .absent { setPreset(wasOn); return false }
        return true
    }

    /// Before the helper is removed by someone else's prompt (Remove Everything): every fan
    /// back to the system, and the switch off.
    func handBackForRemoval() {
        setPreset(.system)
        sendSystem("remove")
    }

    private func afterHelperChange() {
        refreshHelper()
        // The daemon takes a moment to write its first status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FanControl.shared.refreshHelper(); FanControl.shared.apply() }
    }

    /// The same path as DockBridge.runPrivileged: the system's administrator prompt, run by the
    /// owner's click and never on its own, off the main thread (the remove script sleeps a
    /// second while the daemon hands the fans back). `working` drives the card's progress.
    private func runPrivileged(_ script: String, describing what: String) async {
        working = true
        defer { working = false }
        if let failure = await AdminPrompt.run(script, reason: what) {
            lastError = "Could not \(what): \(failure)"
        } else {
            lastError = nil
        }
    }

    // MARK: Read-only probe

    /// Runs the helper binary with --probe as this user: reads only, never writes.
    func probe() -> String {
        guard let path = bundledHelper else { return "probe: helper binary missing" }
        return DockBridge.runReadOnly(path, ["--probe"]) ?? "probe: failed to run"
    }

    // MARK: Test hook

    /// atelier://fans?report | mode=silent|balanced|max|custom|system | on=0|1 | curve=55:0,68:0.3,80:0.7,90:1
    /// | limit=95 | dryrun=40,60,80|ramp [&dt=1] | probe | helper=install|remove|status. Always writes
    /// $TMPDIR/atelier-fans.txt last.
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let tmp = NSTemporaryDirectory()
        if let text = value("curve") {
            if let parsed = FanCurve.parse(text) { customCurve = parsed } else { lastError = "Bad curve: \(text)" }
        }
        if let limit = value("limit").flatMap(Double.init) { hardLimit = FanSafety.clampLimit(limit) }
        if let on = value("on") { setEnabled(on == "1") }
        if let mode = value("mode") {
            if let new = FanPreset(rawValue: mode == "auto" ? "system" : mode) { setPreset(new) } else { lastError = "No preset \(mode)" }
        }
        if let temps = value("dryrun") {
            let curve = value("curve").flatMap(FanCurve.parse) ?? self.curve ?? FanPreset.balanced.curve!
            let dt = value("dt").flatMap(Double.init) ?? 1
            var ranges = fanRanges.map { (min: $0.min, max: $0.max) }
            if ranges.isEmpty { ranges = [(1350, 5349), (1350, 5777)] }
            let rows = FanDryRun.run(curve: curve, temperatures: FanDryRun.temperatures(temps), dt: dt, hardLimit: hardLimit, fans: ranges)
            var lines = ["curve=\(curve.text) hardLimit=\(hardLimit) dt=\(dt) fans=\(ranges.map { "\(Int($0.min))-\(Int($0.max))" }.joined(separator: ","))",
                         "t\ttempC\tdemand\t" + ranges.indices.map { "fan\($0)rpm" }.joined(separator: "\t")]
            lines += rows.map { row in
                ([String(format: "%.0f", row.time), String(format: "%.1f", row.celsius), row.demand.text]
                    + row.rpm.map { $0.map { String(Int($0.rounded())) } ?? "system" }).joined(separator: "\t")
            }
            try? lines.joined(separator: "\n").write(toFile: tmp + "atelier-fans-dryrun.txt", atomically: true, encoding: .utf8)
        }
        if items.contains(where: { $0.name == "probe" }) {
            try? probe().write(toFile: tmp + "atelier-fans-probe.txt", atomically: true, encoding: .utf8)
        }
        switch value("helper") {
        case "install", "update": installHelper()
        case "remove": removeHelper()
        default: refreshHelper()
        }
        try? report.write(toFile: tmp + "atelier-fans.txt", atomically: true, encoding: .utf8)
    }

    var report: String {
        refreshHelper()
        let sensors = Sensors.shared
        if sensors.latest == nil || Sensors.clock() - (sensors.latest?.time ?? 0) > 5 { sensors.readNow() }
        func f(_ v: Double?, _ d: Int = 1) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "-" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ v: T?) -> String { v.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "-" }
        var lines = [
            "preset=\(preset.rawValue) enabled=\(enabled) curve=\(curve?.text ?? "-") custom=\(customCurve.text) hardLimit=\(f(hardLimit, 0))",
            "helper=\(helper) bundled=\(bundledHelper ?? "-") installedAt=\(FanHelperInstall.helperPath) "
                + "helperVersion=\(status?.helperVersion.map(String.init) ?? "-") wants=\(FanHelperInstall.helperVersion) outdated=\(helperOutdated)",
            "temperature=\(f(temperature)) hottestNow=\(f(hottest)) demand=\(demand.text) overheated=\(governor.overheated) commands=\(commands)",
            "lastCommand=\(json(lastCommand))",
            "status=\(json(status))",
            "error=\(lastError ?? "-")",
            "sensorFans=\(sensors.latest?.fans.count ?? 0)",
        ]
        for (i, fan) in (sensors.latest?.fans ?? []).enumerated() {
            lines.append("fan\(i) rpm=\(f(fan.rpm, 0)) target=\(f(fan.target, 0)) min=\(f(fan.min, 0)) max=\(f(fan.max, 0))")
        }
        return lines.joined(separator: "\n")
    }

    var diagnostics: String {
        "fanPreset=\(preset.rawValue) fanHelper=\(helper) fanDemand=\(demand.text) fanTemp=\(temperature.map { String(format: "%.1f", $0) } ?? "-") " +
            "fanState=\(status?.state ?? "-") fanCmds=\(commands)"
    }
}
