import Foundation

// MARK: - Sensor maths
//
// The arithmetic behind Thermals & Power, kept apart from IOKit so it can be tested: the SMC's
// four-character keys, how its raw bytes turn into numbers, which readings are believable, and
// the rolling history the sparklines draw. Nothing here touches hardware.

/// SMC keys and data types are four ASCII characters packed big-endian into a UInt32: "TB0T"
/// is 0x54_42_30_54. The type "flt " has a trailing space, which is part of the code.
public enum FourCC {
    public static func code(_ text: String) -> UInt32 {
        var bytes = Array(text.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func text(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Turns the SMC's raw bytes into a number. Apple silicon reports almost everything as "flt ",
/// a little-endian float; the integer and fixed-point types are big-endian, as on Intel Macs.
/// Returns nil for types that are not numbers ("hex_", "{fds" and other structs).
public enum SMCDecode {
    public static func value(type: String, bytes: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            return bytes.prefix(n).reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag": return be(1).map { Double($0) }
        case "ui16": return be(2).map { Double($0) }
        case "ui32": return be(4).map { Double($0) }
        case "si8 ": return be(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16": return be(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        // Signed 7.8 fixed point: the old Intel temperature format.
        case "sp78": return be(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        // Unsigned 14.2 fixed point: the old Intel fan format.
        case "fpe2": return be(2).map { Double($0) / 4 }
        default: return fixedPoint(type: type, bytes: bytes)
        }
    }

    /// Intel Macs use a whole family of 16-bit fixed-point types named by their bit split:
    /// "spXY" is signed with X integer and Y fraction bits (X + Y = 15, plus the sign), "fpXY"
    /// unsigned with X + Y = 16, both digits in hex. "sp96" (power), "spb4", "sp5a", "fp2e" and
    /// the rest all decode the same way, so they are worked out rather than listed.
    static func fixedPoint(type: String, bytes: [UInt8]) -> Double? {
        let t = Array(type.utf8)
        guard t.count == 4, bytes.count >= 2,
              let whole = Int(String(UnicodeScalar(t[2])), radix: 16),
              let fraction = Int(String(UnicodeScalar(t[3])), radix: 16) else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let scale = Double(1 << fraction)
        if t[0] == UInt8(ascii: "s"), t[1] == UInt8(ascii: "p"), whole + fraction == 15 {
            return Double(Int16(bitPattern: raw)) / scale
        }
        if t[0] == UInt8(ascii: "f"), t[1] == UInt8(ascii: "p"), whole + fraction == 16 {
            return Double(raw) / scale
        }
        return nil
    }
}

// MARK: - Which keys this chip has

/// The chip generation, which decides the SMC's temperature key names. Apple renames them with
/// almost every generation (M3 moved the CPU cores to Te/Tf and put the GPU under Tf too), so a
/// family is looked up per chip, from the tables exelban/stats maintains
/// (Modules/Sensors/values.swift), and only falls back to a prefix guess for a chip newer than
/// the tables.
public enum SensorChip: Equatable, Sendable {
    case intel
    /// An Apple silicon generation: 1 for M1 (Pro, Max, Ultra), 2 for M2, and so on.
    case appleSilicon(generation: Int)
    /// Apple silicon whose name this code does not recognise (an A-series or a later naming).
    case appleSiliconUnknown

    /// From `machdep.cpu.brand_string`: "Intel(R) Core(TM) i7-…" or "Apple M3 Pro". An Intel
    /// build running under Rosetta still sees the Apple name there (checked on macOS 27.3).
    public static func from(brand: String, appleSilicon: Bool) -> SensorChip {
        let name = brand.lowercased()
        if name.contains("intel") && !appleSilicon { return .intel }
        guard appleSilicon || name.hasPrefix("apple") else { return .intel }
        // "apple m5 pro" → 5. The digits right after the "m" are the generation.
        if let range = name.range(of: "apple m") {
            let digits = name[range.upperBound...].prefix { $0.isNumber }
            if let generation = Int(digits), generation > 0 { return .appleSilicon(generation: generation) }
        }
        return .appleSiliconUnknown
    }
}

/// The SMC keys each family is read from, chosen from every key the Mac reports.
public enum SensorKeyPlan {
    /// The CPU core keys per Apple silicon generation, from Stats.
    static let appleCPU: [Int: [String]] = [
        1: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        2: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        3: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        4: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        5: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
            "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
        6: ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05",
            "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
    ]

    /// The GPU cluster keys per generation, from Stats.
    static let appleGPU: [Int: [String]] = [
        1: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
        2: ["Tg0f", "Tg0j"],
        3: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
        4: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
        5: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
        6: ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"],
    ]

    /// Intel's diode, proximity and package sensors. On Intel "Tp0P" is the power board, not a
    /// core, which is why Intel never takes the Apple silicon prefix guess.
    static let intelCPU = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCAD", "TCAC", "TCBC", "TCXC"]
    static let intelGPU = ["TCGC", "TG0D", "TGDD", "TG0H", "TG0P"]
    static let batteries = ["TB0T", "TB1T", "TB2T"]
    static let skins = ["Ts0P", "Ts1P"]
    static let power = ["PSTR", "PDTR", "PPBR"]

    /// The keys to read for each family, in the order the Mac lists them. A chip's table is
    /// used where its keys exist; an Apple silicon chip whose table finds nothing (a newer or
    /// unlisted variant) falls back to the prefixes every Apple silicon SMC has used so far.
    public static func plan(keys: [String], chip: SensorChip) -> [SensorKind: [String]] {
        let present = Set(keys)
        func pick(_ table: [String]) -> [String] {
            let wanted = Set(table)
            return keys.filter { wanted.contains($0) }
        }
        var plan: [SensorKind: [String]] = [:]
        switch chip {
        case .intel:
            let cores = keys.filter { k in
                let b = Array(k.utf8)
                // TC1C…TC9C: one per core on most Intel Macs.
                return b.count == 4 && k.hasPrefix("TC") && b[3] == UInt8(ascii: "C") && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b[2])
            }
            plan[.cpu] = pick(intelCPU) + cores.filter { !intelCPU.contains($0) }
            plan[.gpu] = pick(intelGPU)
        case .appleSilicon(let generation):
            let cpu = pick(appleCPU[generation] ?? [])
            let gpu = pick(appleGPU[generation] ?? [])
            plan[.cpu] = cpu.isEmpty ? keys.filter { SensorKind.of($0) == .cpu } : cpu
            plan[.gpu] = gpu.isEmpty ? keys.filter { SensorKind.of($0) == .gpu } : gpu
        case .appleSiliconUnknown:
            plan[.cpu] = keys.filter { SensorKind.of($0) == .cpu || $0.hasPrefix("Te") }
            plan[.gpu] = keys.filter { SensorKind.of($0) == .gpu }
        }
        plan[.battery] = batteries.filter(present.contains)
        plan[.skin] = skins.filter(present.contains)
        plan[.power] = power.filter(present.contains)
        plan[.fan] = keys.filter { SensorKind.of($0) == .fan && ($0.hasSuffix("Ac") || $0.hasSuffix("Tg") || $0.hasSuffix("Mn") || $0.hasSuffix("Mx")) }
        return plan.filter { !$0.value.isEmpty }
    }
}

/// What a Mac's sensors can show, from what discovery found. A MacBook Air has no fans, a Mac
/// mini or Studio no battery, and some Intel Macs no system power key; each reading that is
/// missing is left out instead of showing a dash forever.
public struct SensorCapabilities: Equatable, Sendable {
    public var temperature: Bool
    public var gpu: Bool
    public var fans: Bool
    public var power: Bool
    public var battery: Bool
    public var charger: Bool

    public init(temperature: Bool = false, gpu: Bool = false, fans: Bool = false, power: Bool = false,
                battery: Bool = false, charger: Bool = false) {
        self.temperature = temperature
        self.gpu = gpu
        self.fans = fans
        self.power = power
        self.battery = battery
        self.charger = charger
    }

    /// Before discovery has run: assume everything, so nothing flickers away and back.
    public static let unknown = SensorCapabilities(temperature: true, gpu: true, fans: true, power: true, battery: true, charger: true)

    public var any: Bool { temperature || gpu || fans || power }
}

/// Which family a key belongs to. Apple publishes none of these; the prefixes are the ones
/// measured on Apple silicon (Tp CPU cores, Tg GPU clusters) and used by every sensor app.
public enum SensorKind: String, Sendable, CaseIterable {
    case cpu, gpu, battery, skin, fan, power, other

    public static func of(_ key: String) -> SensorKind {
        let k = Array(key.utf8)
        guard k.count == 4 else { return .other }
        if key.hasPrefix("Tp") { return .cpu }
        if key.hasPrefix("Tg") { return .gpu }
        if key == "TB0T" { return .battery }
        if key == "Ts0P" { return .skin }
        if k[0] == UInt8(ascii: "F"), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(k[1]) { return .fan }
        if key == "PSTR" || key == "PDTR" || key == "PPBR" { return .power }
        return .other
    }
}

/// Which readings to believe. Unused sensor slots report -9199, 0 or NaN; a fan that has
/// stopped reports 0 rpm, which is true and kept.
public enum SensorFilter {
    public static func temperature(_ value: Double) -> Double? {
        value.isFinite && value > 1 && value < 130 ? value : nil
    }

    public static func fan(_ value: Double) -> Double? {
        value.isFinite && value >= 0 && value < 20_000 ? value : nil
    }

    public static func watts(_ value: Double) -> Double? {
        value.isFinite && value >= 0 && value < 1_000 ? value : nil
    }
}

/// The mean and the hottest of a family of sensors.
public struct SensorSummary: Equatable, Sendable {
    public let mean: Double
    public let max: Double
    public let count: Int

    public init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        mean = values.reduce(0, +) / Double(values.count)
        max = values.max()!
        count = values.count
    }
}

/// Exponential smoothing that behaves the same at 1 and 4 samples a second: the weight of a
/// new sample depends on how long it has been since the last one, not on how many came in.
public struct Smoother: Equatable, Sendable {
    public var value: Double?
    /// Seconds for a step change to be about two thirds of the way through.
    public let tau: Double

    public init(tau: Double) { self.tau = tau }

    @discardableResult
    public mutating func add(_ sample: Double, dt: Double) -> Double {
        guard let old = value, dt > 0, tau > 0 else {
            value = sample
            return sample
        }
        let alpha = 1 - exp(-dt / tau)
        let new = old + (sample - old) * alpha
        value = new
        return new
    }
}

/// A fixed-size ring of timed samples: appending never reallocates, the oldest falls off.
public struct SampleRing: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let time: Double
        public let value: Double
        public init(time: Double, value: Double) { self.time = time; self.value = value }
    }

    public let capacity: Int
    private var storage: [Sample] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = Swift.max(capacity, 1)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ value: Double, at time: Double) {
        let sample = Sample(time: time, value: value)
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[head] = sample
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest first.
    public var samples: [Sample] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    public var latest: Sample? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
    }

    /// The samples no older than `span` seconds before `now`, oldest first.
    public func window(_ span: Double, now: Double) -> [Sample] {
        samples.filter { $0.time >= now - span && $0.time <= now }
    }

    /// The lowest and highest value in the window, or nil if it is empty.
    public func range(_ span: Double, now: Double) -> ClosedRange<Double>? {
        let values = window(span, now: now).map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }
}

/// Where a reading sits between cool and hot, 0 to 1, for colour. Temperatures run from a
/// resting Mac (35 °C) to throttling (100 °C); watts and fan speeds use their own bounds.
public enum HeatScale {
    public static func temperature(_ celsius: Double) -> Double { clamp((celsius - 35) / 65) }
    public static func watts(_ watts: Double, ceiling: Double = 120) -> Double { clamp(watts / ceiling) }
    public static func fan(_ rpm: Double, min: Double, max: Double) -> Double {
        max > min ? clamp((rpm - min) / (max - min)) : 0
    }

    public static func clamp(_ x: Double) -> Double { x.isFinite ? Swift.min(Swift.max(x, 0), 1) : 0 }
}

/// The y of each point of a sparkline, 0 at the bottom and 1 at the top, with a little room
/// above and below so a flat line sits in the middle rather than on an edge.
public enum SparkScale {
    public static func normalise(_ values: [Double], floor: Double? = nil, minimumSpan: Double = 1) -> [Double] {
        guard let low0 = values.min(), let high0 = values.max() else { return [] }
        let low = Swift.min(floor ?? low0, low0)
        var span = high0 - low
        var base = low
        if span < minimumSpan {
            base -= (minimumSpan - span) / 2
            span = minimumSpan
        }
        return values.map { 0.08 + 0.84 * ($0 - base) / span }
    }
}
