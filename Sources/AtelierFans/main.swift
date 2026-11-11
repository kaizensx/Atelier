import DockCore
import Foundation
import IOKit
import IOKit.pwr_mgt

// Atelier's fan helper: the one part of Fan Control that runs as root, because the SMC takes
// fan writes from root only. Installed only when the owner asks, as a LaunchDaemon, and removed
// from the same card. It does as little as it can:
//
//   * every half second while it drives a fan (every 2 s while the fans are the system's), reads the app's command (a small JSON file in a folder only the owner
//     can write) and the chip's temperatures, asks FanSafety what to do, and does it;
//   * hands every fan back to the system when the command is older than 10 s (the app stopped,
//     crashed or hung), when the app quits or turns Fan Control off, when the Mac goes to sleep
//     (and until the app speaks again after waking), when it cannot read a temperature, and when
//     it is stopped (launchctl bootout sends SIGTERM);
//   * runs the fans at full speed while the hottest reading is over the owner's hard limit;
//   * never sets a fan below its SMC minimum nor above its maximum, whatever it is asked.
//
// `AtelierFans --probe` reads the same keys and prints them, without root and without ever
// writing: the SMC connection it opens refuses writes before they are sent.

// MARK: SMC

final class SMC {
    struct Info: Equatable { let size: UInt32; let type: String }

    private var connection: io_connect_t = 0
    let writable: Bool
    private var infos: [String: Info] = [:]

    init?(writable: Bool) {
        self.writable = writable
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private enum Command: UInt8 { case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9 }

    /// The 80-byte SMCParamStruct by hand: key at 0, keyInfo.dataSize at 28, dataType at 32,
    /// result at 40, command at 42, data32 at 44, the value's bytes from 48.
    private func call(_ command: Command, key: UInt32 = 0, index: UInt32 = 0, info: Info? = nil,
                      bytes: [UInt8] = []) -> (kern: kern_return_t, result: UInt8, out: [UInt8]) {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        func put(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { for i in 0..<4 { input[offset + i] = $0[i] } }
        }
        put(key, at: 0)
        if let info {
            put(info.size, at: 28)
            put(FourCC.code(info.type), at: 32)
        }
        put(index, at: 44)
        input[42] = command.rawValue
        for (i, byte) in bytes.prefix(32).enumerated() { input[48 + i] = byte }
        var outSize = 80
        let kern = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outSize)
        return (kern, output[40], output)
    }

    private static func word(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    func info(_ key: String) -> Info? {
        if let known = infos[key] { return known }
        let r = call(.keyInfo, key: FourCC.code(key))
        guard r.kern == KERN_SUCCESS, r.result == 0 else { return nil }
        let info = Info(size: Self.word(r.out, 28), type: FourCC.text(Self.word(r.out, 32)))
        infos[key] = info
        return info
    }

    func read(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        let r = call(.read, key: FourCC.code(key), info: info)
        guard r.kern == KERN_SUCCESS, r.result == 0 else { return nil }
        return SMCDecode.value(type: info.type, bytes: Array(r.out[48..<80]))
    }

    var keyCount: Int { read("#KEY").map(Int.init) ?? 0 }

    func key(at index: Int) -> String? {
        let r = call(.keyAtIndex, index: UInt32(index))
        guard r.kern == KERN_SUCCESS, r.result == 0 else { return nil }
        return FourCC.text(Self.word(r.out, 0))
    }

    /// nil on success, else why not. A read-only connection never sends anything.
    func write(_ key: String, _ value: Double) -> String? {
        guard writable else { return "read only" }
        guard let info = info(key) else { return "\(key): no such key" }
        guard let bytes = SMCEncode.bytes(type: info.type, value: value, size: Int(info.size)) else {
            return "\(key): cannot encode \(info.type) size \(info.size)"
        }
        let r = call(.write, key: FourCC.code(key), info: info, bytes: bytes)
        if r.kern != KERN_SUCCESS { return "\(key): kern 0x\(String(UInt32(bitPattern: r.kern), radix: 16))" }
        if r.result != 0 { return "\(key): smc 0x\(String(r.result, radix: 16))" }
        return nil
    }
}

// MARK: Machine

/// What this Mac's SMC has for fans and temperatures, found once by walking every key.
struct Machine {
    struct Fan { let index: Int; let min: Double; let max: Double }
    var fans: [Fan] = []
    var modeKeys: [Int: String] = [:]
    var hasUnlock = false
    var cpuKeys: [String] = []
    var gpuKeys: [String] = []
    var keyCount = 0

    static var appleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var brand: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    init(_ smc: SMC) {
        keyCount = smc.keyCount
        let names = (0..<keyCount).compactMap { smc.key(at: $0) }
        let keys = Set(names)
        for index in FanKeys.fans(in: keys) {
            let mn = smc.read(FanKeys.minimum(index)) ?? 0
            let mx = smc.read(FanKeys.maximum(index)) ?? 0
            fans.append(Fan(index: index, min: mn, max: mx))
            if let mode = FanKeys.mode(index, in: keys) { modeKeys[index] = mode }
        }
        hasUnlock = keys.contains(FanKeys.unlock)
        let plan = SensorKeyPlan.plan(keys: names, chip: SensorChip.from(brand: Self.brand, appleSilicon: Self.appleSilicon))
        cpuKeys = (plan[.cpu] ?? []).filter { smc.read($0).flatMap(SensorFilter.temperature) != nil }
        gpuKeys = (plan[.gpu] ?? []).filter { smc.read($0).flatMap(SensorFilter.temperature) != nil }
    }

    /// The hotter of the CPU and GPU averages: the number the curve and the hard limit use.
    func hottest(_ smc: SMC) -> Double? {
        func mean(_ keys: [String]) -> Double? {
            SensorSummary(keys.compactMap { smc.read($0).flatMap(SensorFilter.temperature) })?.mean
        }
        return [mean(cpuKeys), mean(gpuKeys)].compactMap { $0 }.max()
    }
}

// MARK: Probe

func probe() -> Int32 {
    guard let smc = SMC(writable: false) else {
        print("smc=unavailable")
        return 1
    }
    let machine = Machine(smc)
    func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
    print("root=\(getuid() == 0) appleSilicon=\(Machine.appleSilicon) brand=\(Machine.brand)")
    print("keys=\(machine.keyCount) fans=\(machine.fans.count) unlock=\(machine.hasUnlock ? "Ftst present (\(f(smc.read(FanKeys.unlock))))" : "absent")")
    print("cpuKeys=\(machine.cpuKeys.count) gpuKeys=\(machine.gpuKeys.count) hottest=\(f(machine.hottest(smc)))")
    if let n = smc.read(FanKeys.count) { print("FNum=\(Int(n))") }
    for fan in machine.fans {
        let mode = machine.modeKeys[fan.index]
        let modeInfo = mode.flatMap(smc.info)
        let tgInfo = smc.info(FanKeys.target(fan.index))
        print("fan\(fan.index) actual=\(f(smc.read(FanKeys.actual(fan.index)))) target=\(f(smc.read(FanKeys.target(fan.index)))) " +
              "min=\(f(fan.min)) max=\(f(fan.max)) modeKey=\(mode ?? "-") mode=\(mode.flatMap(smc.read).map { String(Int($0)) } ?? "-") " +
              "modeType=\(modeInfo.map { "\($0.type.trimmingCharacters(in: .whitespaces))/\($0.size)" } ?? "-") " +
              "targetType=\(tgInfo.map { "\($0.type.trimmingCharacters(in: .whitespaces))/\($0.size)" } ?? "-") " +
              "encodable=\(tgInfo.flatMap { SMCEncode.bytes(type: $0.type, value: fan.min, size: Int($0.size)) } != nil && modeInfo.flatMap { SMCEncode.bytes(type: $0.type, value: 1, size: Int($0.size)) } != nil)")
    }
    return 0
}

// MARK: Daemon

@MainActor
final class Helper {
    let smc: SMC
    let machine: Machine
    let owner: uid_t
    let statusPath: String
    let commandPath: String
    private var lastDecision = ""
    /// A fan whose mode write failed is not tried again for 30 s: the unlock path can block 10 s.
    private var failedAt: [Int: Double] = [:]
    private var controlled: Set<Int> = []
    private var unlockUsed = false
    private var lastTarget: [Int: (rpm: Double, time: Double)] = [:]
    private var overheated = false
    private var asleep = false
    private var wokeAt: Double?
    private var reclaims = 0
    private var lastError: String?
    private var lastState = ""
    /// Whether a fan is under the helper's control, which sets how often it ticks.
    private(set) var driving = false

    init(smc: SMC, owner: uid_t, directory: String? = nil) {
        self.smc = smc
        self.machine = Machine(smc)
        self.owner = owner
        statusPath = directory.map { $0 + "/status.json" } ?? FanHelperInstall.statusPath
        commandPath = directory.map { $0 + "/Inbox/command.json" } ?? FanHelperInstall.commandPath
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    func log(_ text: String) {
        FileHandle.standardError.write(Data("\(Date()) \(text)\n".utf8))
    }

    /// A fan we drove before a crash or restart goes back to the system first.
    func start() {
        if let data = FileManager.default.contents(atPath: statusPath),
           let old = try? JSONDecoder().decode(FanHelperStatus.self, from: data), old.state != "system" {
            controlled = Set(machine.fans.map(\.index))
            unlockUsed = old.unlockUsed
            release("restart")
        }
        log("start fans=\(machine.fans.count) modeKeys=\(machine.modeKeys) unlock=\(machine.hasUnlock)")
        writeStatus(state: "system", reason: "start")
    }

    /// Only a plain file owned by the owner, opened without following a link.
    private func readCommand() -> FanCommand? {
        let fd = open(commandPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_size < 65536 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, Int(info.st_size)) }
        guard count == Int(info.st_size) else { return nil }
        return try? JSONDecoder().decode(FanCommand.self, from: data)
    }

    func tick() {
        let now = Self.now()
        lastError = nil
        let command = readCommand()
        // The temperature only matters while a fan is asked for (or held for overheat): idle,
        // the helper skips the sensor walk and only reads the command and the fans' status.
        let wantsFans = command?.fans.contains { $0.rpm != nil } ?? false
        let hottest = wantsFans || overheated || !controlled.isEmpty ? machine.hottest(smc) : nil
        let decision = FanSafety.decide(command: command, now: now, hottest: hottest, asleep: asleep,
                                        wokeAt: wokeAt, overheated: &overheated)
        let described = "\(decision)"
        if described != lastDecision {
            log("decide \(described) hottest=\(hottest.map { String(format: "%.1f", $0) } ?? "-")")
            lastDecision = described
        }
        switch decision {
        case .system(let reason):
            failedAt = [:]
            release(reason)
            driving = !controlled.isEmpty
            writeStatus(state: "system", reason: reason, hottest: hottest)
        case .manual(let rpm):
            drive(rpm, now: now)
            driving = true
            writeStatus(state: controlled.isEmpty ? "system" : "manual", reason: "command", hottest: hottest)
        case .overheat:
            drive(Dictionary(uniqueKeysWithValues: machine.fans.map { ($0.index, $0.max) }), now: now)
            driving = true
            writeStatus(state: "overheat", reason: "hard limit", hottest: hottest)
        }
    }

    private func drive(_ wanted: [Int: Double], now: Double) {
        for fan in machine.fans {
            guard let asked = wanted[fan.index] else {
                if controlled.contains(fan.index) { releaseFan(fan.index) }
                continue
            }
            if let failed = failedAt[fan.index], now - failed < 30 { lastError = lastError ?? "fan \(fan.index): waiting to retry"; continue }
            guard manual(fan.index) else { failedAt[fan.index] = now; continue }
            failedAt[fan.index] = nil
            controlled.insert(fan.index)
            let rpm = FanTarget.clamp(asked, min: fan.min, max: fan.max)
            // The SMC keeps a target; it is written again when it changes or every 5 s.
            if let last = lastTarget[fan.index], abs(last.rpm - rpm) < 10, now - last.time < 5 { continue }
            if let error = smc.write(FanKeys.target(fan.index), rpm) {
                // 0x87 is known to apply anyway; read back to know.
                if let back = smc.read(FanKeys.target(fan.index)), abs(back - rpm) < 1 { lastError = nil }
                else { lastError = error; continue }
            }
            lastTarget[fan.index] = (rpm, now)
        }
        if controlled.isEmpty, unlockUsed { endUnlock() }
    }

    /// Puts a fan in manual mode. On M3/M4 a refused mode write needs Ftst=1 first, then the
    /// mode write succeeds within a few seconds once thermalmonitord lets go.
    private func manual(_ fan: Int) -> Bool {
        guard let key = machine.modeKeys[fan] else { lastError = "fan \(fan): no mode key"; return false }
        if smc.read(key) == Double(SMCFanMode.manual.rawValue) { return true }
        if controlled.contains(fan) { reclaims += 1; lastTarget[fan] = nil }
        guard var error = smc.write(key, Double(SMCFanMode.manual.rawValue)) else { return true }
        if machine.hasUnlock {
            if !unlockUsed {
                if let failed = smc.write(FanKeys.unlock, 1) { lastError = failed; return false }
                unlockUsed = true
            }
            for _ in 0..<100 {
                usleep(100_000)
                guard let again = smc.write(key, Double(SMCFanMode.manual.rawValue)) else { return true }
                error = again
            }
        }
        lastError = "fan \(fan): \(error)"
        return false
    }

    private func releaseFan(_ fan: Int) {
        if let key = machine.modeKeys[fan], let error = smc.write(key, Double(SMCFanMode.auto.rawValue)) { lastError = error }
        controlled.remove(fan)
        lastTarget[fan] = nil
    }

    private func endUnlock() {
        if let error = smc.write(FanKeys.unlock, 0) { lastError = error }
        unlockUsed = false
    }

    /// Every fan back to the system. Cheap when there is nothing to undo.
    func release(_ reason: String) {
        guard !controlled.isEmpty || unlockUsed else { return }
        for fan in controlled.sorted() { releaseFan(fan) }
        if unlockUsed { endUnlock() }
        log("release \(reason)")
    }

    func willSleep() {
        asleep = true
        release("sleep")
        writeStatus(state: "system", reason: "sleep")
    }

    func didWake() {
        asleep = false
        // Firmware clears Ftst on sleep; the app must speak again after this moment.
        wokeAt = Self.now()
        unlockUsed = false
    }

    func stop() {
        release("stopped")
        writeStatus(state: "system", reason: "stopped")
    }

    private func writeStatus(state: String, reason: String, hottest: Double? = nil) {
        let fans = machine.fans.map { fan in
            FanHelperStatus.Fan(index: fan.index, mode: machine.modeKeys[fan.index].flatMap(smc.read).map { Int($0) },
                                target: smc.read(FanKeys.target(fan.index)), actual: smc.read(FanKeys.actual(fan.index)),
                                min: fan.min, max: fan.max)
        }
        let status = FanHelperStatus(pid: getpid(), time: Self.now(), state: state, reason: reason, fans: fans,
                                     modeKey: machine.modeKeys[0], hasUnlock: machine.hasUnlock, unlockUsed: unlockUsed,
                                     hottest: hottest, reclaims: reclaims, error: lastError,
                                     helperVersion: FanHelperInstall.helperVersion)
        if state + reason != lastState {
            log("state \(state) (\(reason))\(lastError.map { " error \($0)" } ?? "")")
            lastState = state + reason
        }
        guard let data = try? JSONEncoder().encode(status) else { return }
        // The folder is root's: an atomic write there cannot be redirected through a link.
        try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
    }
}

// MARK: Sleep

nonisolated(unsafe) var powerRoot: io_connect_t = 0

private func powerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t,
                           _ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    let notice = Int(bitPattern: argument)
    switch message {
    case 0xE000_0270: // kIOMessageCanSystemSleep
        IOAllowPowerChange(powerRoot, notice)
    case 0xE000_0280: // kIOMessageSystemWillSleep
        MainActor.assumeIsolated { Daemon.helper?.willSleep() }
        IOAllowPowerChange(powerRoot, notice)
    case 0xE000_0300: // kIOMessageSystemHasPoweredOn
        MainActor.assumeIsolated { Daemon.helper?.didWake() }
    default:
        break
    }
}

/// What the run loop keeps alive.
@MainActor enum Daemon {
    static var helper: Helper?
    static var signals: [DispatchSourceSignal] = []
    static var timer: DispatchSourceTimer?
    static var fast = false

    /// One tick, then the pace for the next: quick while a fan is driven, slow while idle.
    static func tick() {
        guard let helper else { return }
        helper.tick()
        guard helper.driving != fast, let timer else { return }
        fast = helper.driving
        let interval = FanHelperInstall.tickInterval(driving: fast)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(fast ? 50 : 250))
    }
}

// MARK: Main

let arguments = CommandLine.arguments
if arguments.contains("--probe") { exit(probe()) }
if arguments.contains("--version") { print(FanHelperInstall.helperVersion); exit(0) }

guard arguments.contains("--daemon"), let ownerIndex = arguments.firstIndex(of: "--owner"),
      ownerIndex + 1 < arguments.count, let owner = UInt32(arguments[ownerIndex + 1]) else {
    print("usage: AtelierFans --probe | --daemon --owner <uid> [--dry --dir <folder>]")
    exit(2)
}
// --dry: the whole loop as any user, with a read-only SMC (every write refused before it is
// sent) and its files in --dir, to test the command, heartbeat and safety rules live.
let dry = arguments.contains("--dry")
let directory = arguments.firstIndex(of: "--dir").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
guard dry || getuid() == 0, let smc = SMC(writable: !dry) else {
    FileHandle.standardError.write(Data("AtelierFans: needs root and the SMC\n".utf8))
    exit(1)
}
if dry && directory == nil {
    FileHandle.standardError.write(Data("AtelierFans: --dry needs --dir\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let helper = Helper(smc: smc, owner: owner, directory: directory)
    Daemon.helper = helper
    helper.start()

    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    powerRoot = IORegisterForSystemPower(nil, &port, powerCallback, &notifier)
    if let port { CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode) }

    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Daemon.helper?.stop()
                exit(0)
            }
        }
        source.resume()
        Daemon.signals.append(source)
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    // Idle pace at first; the first tick that drives a fan switches to the quick one.
    timer.schedule(deadline: .now() + 0.2, repeating: FanHelperInstall.tickInterval(driving: false), leeway: .milliseconds(250))
    timer.setEventHandler { MainActor.assumeIsolated { Daemon.tick() } }
    timer.resume()
    Daemon.timer = timer
}

CFRunLoopRun()
