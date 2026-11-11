import AppKit
import DockCore
import IOKit
import IOKit.hid
import SwiftUI

// MARK: - Sensors
//
// Temperatures, fan speeds and power draw, which macOS measures all the time and never shows.
// Three sources, all read only and none needing root or a permission:
//
// - The SMC, the chip that runs the fans. Its keys are listed at start-up by index, and the
//   CPU and GPU families are then chosen from them with a table per chip (SensorKeyPlan):
//   Intel's TC0P/TG0P, M1/M2's Tp/Tg, M3's Te/Tf, M5's own Tp/Tg set. TB0T is the battery,
//   Ts0P the palm rest, F<n>Ac a fan's speed (none on a MacBook Air), PSTR the whole system's
//   power. Intel reports sp78/fpe2 fixed point, Apple silicon floats; SMCDecode reads both.
//   Only the read, key-info and key-by-index commands are ever sent; never a write.
// - The HID event system's thermal services, "PMU tdie", the SoC's own die sensors. They are
//   a cross-check, and the CPU reading if a Mac's SMC has no Tp keys.
// - The lid angle sensor, HID 0x05AC:0x8104, on MacBooks that have one.
//
// Everything runs on one background queue, 1 sample a second while anything shows a reading
// and 4 while a popover or the stage draws live sparklines. With nothing showing, the timer is
// gone and nothing is read.

/// One fan, as the SMC reports it.
struct FanReading: Equatable, Sendable {
    var rpm: Double
    var target: Double?
    var min: Double
    var max: Double
}

/// One reading of every sensor, taken together.
struct SensorSnapshot: Equatable, Sendable {
    var time: Double
    var cpu: SensorSummary?
    var gpu: SensorSummary?
    var battery: Double?
    var skin: Double?
    var fans: [FanReading] = []
    /// PSTR: what the whole Mac draws, in watts.
    var systemWatts: Double?
    /// PDTR: what comes in from the charger. Zero on battery.
    var chargerWatts: Double?
    /// The hottest PMU die sensor, from the HID thermal services.
    var die: Double?
    /// Degrees the lid is open, if the Mac has the sensor.
    var lid: Double?

    /// The CPU's temperature: the SMC's core sensors, or the die sensors if there are none.
    var cpuTemperature: Double? { cpu?.mean ?? die }
    /// Fan speed as one number: the average of the fans.
    var fanRPM: Double? { fans.isEmpty ? nil : fans.map(\.rpm).reduce(0, +) / Double(fans.count) }
}

// MARK: SMC

/// The AppleSMC user client, read only. Lives on Sensors' queue.
private final class SMCConnection {
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    struct KeyInfo { let size: UInt32; let type: String }

    private enum Command: UInt8 {
        // 6 is write. It is deliberately not here.
        case read = 5, keyAtIndex = 8, keyInfo = 9
    }

    /// One call with the 80-byte SMCParamStruct, laid out by hand rather than trusting a Swift
    /// struct to match C: key at 0, keyInfo.dataSize at 28, dataType at 32, result at 40,
    /// command at 42, data32 at 44, the value's bytes from 48.
    private func call(_ command: Command, key: UInt32 = 0, index: UInt32 = 0, size: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        func put(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { for i in 0..<4 { input[offset + i] = $0[i] } }
        }
        put(key, at: 0)
        put(size, at: 28)
        put(index, at: 44)
        input[42] = command.rawValue
        var outSize = 80
        guard IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outSize) == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    var keyCount: Int {
        guard let info = info("#KEY"), let value = read("#KEY", info) else { return 0 }
        return Int(value)
    }

    func key(at index: Int) -> String? {
        call(.keyAtIndex, index: UInt32(index)).map { FourCC.text(Self.word($0, 0)) }
    }

    func info(_ key: String) -> KeyInfo? {
        call(.keyInfo, key: FourCC.code(key)).map { KeyInfo(size: Self.word($0, 28), type: FourCC.text(Self.word($0, 32))) }
    }

    func read(_ key: String, _ info: KeyInfo) -> Double? {
        guard let out = call(.read, key: FourCC.code(key), size: info.size) else { return nil }
        return SMCDecode.value(type: info.type, bytes: Array(out[48..<80]))
    }
}

// MARK: HID thermal services

/// The HID event system's temperature services, through IOKit's unexported client calls.
private final class HIDThermal {
    private typealias Create = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloat = @convention(c) (OpaquePointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat
    private let client: OpaquePointer
    private let services: CFArray
    /// Indices of the "PMU tdie" services within `services`.
    private let dies: [Int]

    init?() {
        let kit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        guard let create = dlsym(kit, "IOHIDEventSystemClientCreate"), let match = dlsym(kit, "IOHIDEventSystemClientSetMatching"),
              let copy = dlsym(kit, "IOHIDEventSystemClientCopyServices"), let property = dlsym(kit, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(kit, "IOHIDServiceClientCopyEvent"), let float = dlsym(kit, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault) else { return nil }
        _ = unsafeBitCast(match, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = unsafeBitCast(copy, to: CopyServices.self)(client)?.takeRetainedValue() else { return nil }
        let copyProperty = unsafeBitCast(property, to: CopyProperty.self)
        dies = (0..<CFArrayGetCount(services)).filter { i in
            let service = OpaquePointer(CFArrayGetValueAtIndex(services, i)!)
            return (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String)?.hasPrefix("PMU tdie") == true
        }
        guard !dies.isEmpty else { return nil }
        self.client = client
        self.services = services
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        getFloat = unsafeBitCast(float, to: GetFloat.self)
    }

    deinit { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(client)).release() }

    var count: Int { dies.count }

    /// The hottest die. Unused slots read -9199 and are dropped.
    func hottest() -> Double? {
        let values = dies.compactMap { i -> Double? in
            let service = OpaquePointer(CFArrayGetValueAtIndex(services, i)!)
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0) else { return nil }
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
            return SensorFilter.temperature(getFloat(event, Int32(Self.temperatureEvent << 16)))
        }
        return values.max()
    }
}

// MARK: Lid angle

/// The hinge sensor MacBooks have had since 2019, on the HID Sensor page as usage 0x8A.
/// Feature report 1 holds the angle in degrees, low byte first.
private final class LidSensor {
    private let device: IOHIDDevice
    private var open = false

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                                kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else { return nil }
        self.device = device
        guard angle() != nil else { return nil }
    }

    deinit { if open { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) } }

    func angle() -> Double? {
        if !open {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
            open = true
        }
        var report = [UInt8](repeating: 0, count: 16)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 else { return nil }
        let degrees = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        return degrees <= 360 ? degrees : nil
    }
}

// MARK: Reader

/// Everything that touches hardware. Created and used only on Sensors' queue, which is why it
/// can be handed across as unchecked Sendable.
private final class SensorReader: @unchecked Sendable {
    private var smc: SMCConnection?
    private var hid: HIDThermal?
    private var lid: LidSensor?
    private var keys: [SensorKind: [(String, SMCConnection.KeyInfo)]] = [:]
    private var fanKeys: [(actual: (String, SMCConnection.KeyInfo), target: (String, SMCConnection.KeyInfo)?, min: Double, max: Double)] = []
    private var watts: [String: SMCConnection.KeyInfo] = [:]
    private(set) var discovered = false
    private(set) var keyCount = 0
    private(set) var dieCount = 0
    private(set) var hasLid = false
    /// Costs measured on an M5 Pro: one SMC read about 0.17 ms, so the 42 GPU keys are ~7 ms;
    /// the 42 HID die sensors ~30 ms together. Both are reused for a while rather than read
    /// on every 4 Hz tick.
    private var lastGPU: (time: Double, value: SensorSummary?)?
    private var lastDie: (time: Double, value: Double?)?
    private static let gpuEvery = 0.5
    private static let dieEvery = 10.0

    /// The chip generation, which decides the temperature key names.
    private static let chip: SensorChip = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return SensorChip.from(brand: String(cString: name), appleSilicon: MacPlatform.appleSilicon)
    }()

    /// What the panels can show, once discovery has run.
    private(set) var capabilities = SensorCapabilities.unknown

    /// Walks every SMC key once, by index, picks this chip's families from them and keeps the
    /// ones that read as believable numbers. About 3600 keys on an M5 Pro, a few tens of ms.
    func discover() {
        guard !discovered else { return }
        discovered = true
        smc = SMCConnection()
        hid = HIDThermal()
        lid = LidSensor()
        dieCount = hid?.count ?? 0
        hasLid = lid != nil
        defer {
            capabilities = SensorCapabilities(temperature: !(keys[.cpu]?.isEmpty ?? true) || dieCount > 0,
                                              gpu: !(keys[.gpu]?.isEmpty ?? true), fans: !fanKeys.isEmpty,
                                              power: watts["PSTR"] != nil, battery: !(keys[.battery]?.isEmpty ?? true),
                                              charger: watts["PDTR"] != nil && !(keys[.battery]?.isEmpty ?? true))
        }
        guard let smc else { return }
        var fanInfo: [String: (SMCConnection.KeyInfo, Double)] = [:]
        let names = (0..<smc.keyCount).compactMap { smc.key(at: $0) }
        let plan = SensorKeyPlan.plan(keys: names, chip: Self.chip)
        for (kind, planned) in plan {
            for key in planned {
                guard let info = smc.info(key), let value = smc.read(key, info) else { continue }
                switch kind {
                case .cpu, .gpu, .battery, .skin:
                    // A slot with nothing behind it reads 0 or -9199 for good; skip it for good.
                    guard SensorFilter.temperature(value) != nil else { continue }
                    keys[kind, default: []].append((key, info))
                case .fan:
                    guard SensorFilter.fan(value) != nil else { continue }
                    fanInfo[key] = (info, value)
                case .power:
                    guard SensorFilter.watts(value) != nil else { continue }
                    watts[key] = info
                case .other:
                    continue
                }
            }
        }
        for n in 0..<10 {
            guard let actual = fanInfo["F\(n)Ac"] else { continue }
            fanKeys.append((("F\(n)Ac", actual.0), fanInfo["F\(n)Tg"].map { ("F\(n)Tg", $0.0) },
                            fanInfo["F\(n)Mn"]?.1 ?? 0, fanInfo["F\(n)Mx"]?.1 ?? 0))
        }
        keyCount = keys.values.map(\.count).reduce(0, +) + fanKeys.count + watts.count
    }

    func sample(at time: Double) -> SensorSnapshot {
        discover()
        var snapshot = SensorSnapshot(time: time)
        guard let smc else {
            snapshot.die = hid?.hottest()
            snapshot.lid = lid?.angle()
            return snapshot
        }
        // The die sensors stand in for the CPU when the SMC has no core keys, and are read on
        // every tick then; otherwise they are only a cross-check.
        if keys[.cpu]?.isEmpty ?? true {
            snapshot.die = hid?.hottest()
        } else if let lastDie, time - lastDie.time < Self.dieEvery {
            snapshot.die = lastDie.value
        } else {
            snapshot.die = hid?.hottest()
            lastDie = (time, snapshot.die)
        }
        func family(_ kind: SensorKind) -> [Double] {
            (keys[kind] ?? []).compactMap { smc.read($0.0, $0.1).flatMap(SensorFilter.temperature) }
        }
        snapshot.cpu = SensorSummary(family(.cpu))
        if let lastGPU, time - lastGPU.time < Self.gpuEvery {
            snapshot.gpu = lastGPU.value
        } else {
            snapshot.gpu = SensorSummary(family(.gpu))
            lastGPU = (time, snapshot.gpu)
        }
        snapshot.battery = family(.battery).first
        snapshot.skin = family(.skin).first
        snapshot.fans = fanKeys.compactMap { fan in
            guard let rpm = smc.read(fan.actual.0, fan.actual.1).flatMap(SensorFilter.fan) else { return nil }
            let target = fan.target.flatMap { smc.read($0.0, $0.1) }.flatMap(SensorFilter.fan)
            return FanReading(rpm: rpm, target: target, min: fan.min, max: fan.max)
        }
        snapshot.systemWatts = watts["PSTR"].flatMap { smc.read("PSTR", $0) }.flatMap(SensorFilter.watts)
        snapshot.chargerWatts = watts["PDTR"].flatMap { smc.read("PDTR", $0) }.flatMap(SensorFilter.watts)
        snapshot.lid = lid?.angle()
        return snapshot
    }
}

// MARK: Sensors

@MainActor
final class Sensors: ObservableObject {
    static let shared = Sensors()

    /// How far back the sparklines reach.
    static let span = 120.0
    static let slowInterval = 1.0
    static let fastInterval = 0.25

    @Published private(set) var latest: SensorSnapshot?
    /// Smoothed for the menu bar and rings, so a single noisy core does not flicker the digits.
    @Published private(set) var cpu: Double?
    @Published private(set) var gpu: Double?
    @Published private(set) var watts: Double?
    @Published private(set) var fans: Double?
    /// Whether discovery has run and found anything worth showing.
    @Published private(set) var available = true
    /// Which readings this Mac has: no fans on a MacBook Air, no battery on a desktop.
    @Published private(set) var capabilities = SensorCapabilities.unknown

    private(set) var cpuHistory = SampleRing(capacity: 600)
    private(set) var gpuHistory = SampleRing(capacity: 600)
    private(set) var wattsHistory = SampleRing(capacity: 600)
    private(set) var fanHistory = SampleRing(capacity: 600)

    private var cpuSmooth = Smoother(tau: 1.5), gpuSmooth = Smoother(tau: 1.5)
    private var wattsSmooth = Smoother(tau: 1), fanSmooth = Smoother(tau: 1)

    private let queue = DispatchQueue(label: "atelier.sensors", qos: .utility)
    private let reader = SensorReader()
    private var timer: DispatchSourceTimer?
    private var users = 0
    private var fastUsers = 0
    private var interval = 0.0
    private(set) var samples = 0
    private var keyCount = 0
    private var dieCount = 0
    private(set) var hasLid = false

    private init() {}

    /// Seconds since a fixed point, for history timestamps; the same clock TimelineView dates map onto.
    nonisolated static func clock(_ date: Date = Date()) -> Double { date.timeIntervalSinceReferenceDate }

    // MARK: Demand

    /// Something on screen shows a reading. `fast` asks for 4 samples a second, for live sparklines.
    func acquire(fast: Bool = false) {
        users += 1
        if fast { fastUsers += 1 }
        reschedule()
    }

    func release(fast: Bool = false) {
        guard users > 0 else { return }
        users -= 1
        if fast { fastUsers = max(fastUsers - 1, 0) }
        reschedule()
    }

    private func reschedule() {
        let wanted = users == 0 ? 0 : fastUsers > 0 ? Self.fastInterval : Self.slowInterval
        guard wanted != interval else { return }
        interval = wanted
        guard wanted > 0 else {
            timer?.cancel()
            timer = nil
            return
        }
        // A long pause leaves a gap the sparkline would draw straight across; start it over.
        if let last = latest?.time, Self.clock() - last > 10 { clearHistory() }
        let timer = self.timer ?? {
            let made = DispatchSource.makeTimerSource(queue: queue)
            made.setEventHandler(handler: Self.tick(reader))
            made.resume()
            self.timer = made
            return made
        }()
        timer.schedule(deadline: .now(), repeating: wanted, leeway: .milliseconds(Int(wanted * 100)))
    }

    /// The timer's work, made outside the main actor: a closure written inside a main-actor
    /// method would inherit that isolation and trap when the queue runs it.
    private nonisolated static func tick(_ reader: SensorReader) -> @Sendable () -> Void {
        {
            let snapshot = reader.sample(at: Sensors.clock())
            let counts = (reader.keyCount, reader.dieCount, reader.hasLid)
            let capabilities = reader.capabilities
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Sensors.shared.receive(snapshot, counts: counts, capabilities: capabilities) }
            }
        }
    }

    private func clearHistory() {
        for ring in [\Sensors.cpuHistory, \.gpuHistory, \.wattsHistory, \.fanHistory] as [ReferenceWritableKeyPath<Sensors, SampleRing>] {
            self[keyPath: ring].removeAll()
        }
        cpuSmooth.value = nil; gpuSmooth.value = nil; wattsSmooth.value = nil; fanSmooth.value = nil
    }

    private func receive(_ snapshot: SensorSnapshot, counts: (keys: Int, dies: Int, lid: Bool), capabilities: SensorCapabilities) {
        if self.capabilities != capabilities { self.capabilities = capabilities }
        let dt = latest.map { snapshot.time - $0.time } ?? 0
        samples += 1
        keyCount = counts.keys
        dieCount = counts.dies
        hasLid = counts.lid
        let t = snapshot.time
        if let v = snapshot.cpuTemperature { cpu = cpuSmooth.add(v, dt: dt); cpuHistory.append(v, at: t) }
        if let v = snapshot.gpu?.mean { gpu = gpuSmooth.add(v, dt: dt); gpuHistory.append(v, at: t) }
        if let v = snapshot.systemWatts { watts = wattsSmooth.add(v, dt: dt); wattsHistory.append(v, at: t) }
        if let v = snapshot.fanRPM { fans = fanSmooth.add(v, dt: dt); fanHistory.append(v, at: t) }
        let found = counts.keys > 0 || counts.dies > 0
        if available != found { available = found }
        latest = snapshot
    }

    // MARK: Reporting

    /// Takes one reading now, on the sensors' queue, whether or not anything is showing.
    /// For atelier://diag, which may be asked while the sensors are idle.
    func readNow() {
        let reader = self.reader
        let snapshot = queue.sync { reader.sample(at: Sensors.clock()) }
        receive(snapshot, counts: (reader.keyCount, reader.dieCount, reader.hasLid), capabilities: reader.capabilities)
    }

    /// For atelier://diag. Values are the raw latest reading, to compare with sensortest.
    /// A reading older than five seconds is refreshed first.
    var diagnostics: String {
        if (latest.map { Sensors.clock() - $0.time } ?? .infinity) > 5 { readNow() }
        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        let s = latest
        return "sensCPU=\(f(s?.cpuTemperature)) sensGPU=\(f(s?.gpu?.mean)) sensFan0=\(f(s?.fans.first?.rpm, 0)) " +
            "sensWatts=\(f(s?.systemWatts)) sensKeys=\(keyCount) sensDies=\(dieCount) sensDie=\(f(s?.die)) " +
            "sensLid=\(hasLid ? f(s?.lid, 0) : "absent") sensFans=\(capabilities.fans ? "yes" : "none") sensBattery=\(capabilities.battery) " +
            "sensRate=\(interval == 0 ? "off" : String(format: "%.0fHz", 1 / interval)) sensSamples=\(samples)"
    }
}

/// Keeps the sensors sampling while this view is on screen; `fast` for live sparklines.
struct SensorDemand: ViewModifier {
    var fast = false
    var on = true
    @State private var held: Bool?

    func body(content: Content) -> some View {
        content
            .onAppear { hold(on) }
            .onDisappear { hold(false) }
            .onChange(of: on) { _, new in hold(new) }
            .onChange(of: fast) { _, _ in
                guard held == true else { return }
                Sensors.shared.release(fast: !fast)
                Sensors.shared.acquire(fast: fast)
            }
    }

    private func hold(_ wanted: Bool) {
        guard wanted != (held ?? false) else { return }
        held = wanted
        wanted ? Sensors.shared.acquire(fast: fast) : Sensors.shared.release(fast: fast)
    }
}

extension View {
    func sensing(fast: Bool = false, on: Bool = true) -> some View { modifier(SensorDemand(fast: fast, on: on)) }
}
