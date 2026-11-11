import Foundation

// MARK: - External Monitor Control (DDC/CI), the pure half
//
// DDC/CI is how a Mac talks to a monitor's own controls over the video cable: I²C on the
// display's DDC channel, chip address 0x37, the host writing from sub-address 0x51. A request
// is a length byte (0x80 | payload length), an opcode, the payload and an XOR checksum. What
// is here has no IOKit in it: packets, the reply parser, the value maps, the retry plan the
// transport follows, the glide and the coalescer that keep a slow bus from falling behind,
// display ↔ IOAVService matching (MonitorControl's Arm64DDC scoring), and the safety rules.
//
// Sources the numbers come from: VESA MCCS 2.2a (VCP codes, input values, mute values),
// MonitorControl's Arm64DDC.swift and IntelDDC.swift, and m1ddc's i2c.m (delays, retries,
// checksum seeds).

/// The VCP codes Atelier reads or writes. Nothing outside this list is ever written.
public enum VCPCode: UInt8, Sendable, CaseIterable {
    case brightness = 0x10
    case contrast = 0x12
    case input = 0x60
    case volume = 0x62
    case mute = 0x8D

    public var title: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .input: "Input"
        case .volume: "Volume"
        case .mute: "Mute"
        }
    }

    /// The short name the test hook and diagnostics use.
    public var key: String {
        switch self {
        case .brightness: "brightness"
        case .contrast: "contrast"
        case .input: "input"
        case .volume: "volume"
        case .mute: "mute"
        }
    }

    /// "0x10", "16", "brightness": what the hook accepts.
    public init?(token: String) {
        let t = token.lowercased().trimmingCharacters(in: .whitespaces)
        if let match = VCPCode.allCases.first(where: { $0.key == t }) { self = match; return }
        let number: UInt8? = t.hasPrefix("0x") ? UInt8(t.dropFirst(2), radix: 16) : UInt8(t)
        guard let number, let code = VCPCode(rawValue: number) else { return nil }
        self = code
    }
}

/// What may be sent. Writes go only to the five codes above; factory resets (0x04 all,
/// 0x05 luminance and contrast, 0x06 geometry, 0x08 colour, 0x0A TV) and power (0xD6) can
/// never be built, whatever a caller passes.
public enum DDCSafety {
    public static let forbidden: Set<UInt8> = [0x04, 0x05, 0x06, 0x08, 0x0A, 0xD6]

    public static func mayWrite(_ code: UInt8) -> Bool {
        !forbidden.contains(code) && VCPCode(rawValue: code) != nil
    }

    /// The last gate before the bus: an allowed code, and at least one external display found.
    public static func mayWrite(_ code: UInt8, externalDisplays: Int) -> Bool {
        externalDisplays > 0 && mayWrite(code)
    }
}

/// Packets on the wire.
public enum DDCPacket {
    /// The monitor's DDC/CI chip, 7-bit (0x6E on the wire when writing, 0x6F when reading).
    public static let chipAddress: UInt8 = 0x37
    /// The host's sub-address, the first byte after the chip address.
    public static let dataAddress: UInt8 = 0x51
    public static let destination: UInt8 = 0x6E
    /// A reply's checksum is seeded with the virtual host address 0x50.
    public static let replySeed: UInt8 = 0x50
    /// A Get VCP Feature reply: source, length, opcode, result, code, type, max(2), current(2), checksum.
    public static let replyLength = 11

    /// Which XOR seed a request's checksum starts from. The standard one covers the
    /// destination and the sub-address (m1ddc, MonitorControl's writes, IntelDDC). Some
    /// monitors only answer a read seeded with the destination alone, which is what
    /// MonitorControl sends for reads; the retry plan alternates the two.
    public enum Seed: Sendable, Equatable {
        case standard, destinationOnly
        public var value: UInt8 { self == .standard ? destination ^ dataAddress : destination }
    }

    public static func checksum(seed: UInt8, _ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Get VCP Feature: 0x82 0x01 code checksum. Sent to sub-address 0x51.
    public static func getRequest(_ code: UInt8, seed: Seed = .standard) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code]
        packet.append(checksum(seed: seed.value, packet))
        return packet
    }

    /// Set VCP Feature: 0x84 0x03 code high low checksum. Nil for any code that may not be written.
    public static func setRequest(_ code: UInt8, value: UInt16) -> [UInt8]? {
        guard DDCSafety.mayWrite(code) else { return nil }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(checksum(seed: Seed.standard.value, packet))
        return packet
    }

    /// The same request as the Intel I²C interface takes it: the sub-address first, and the
    /// checksum seeded with the destination only, which comes to the same byte.
    public static func framed(_ packet: [UInt8]) -> [UInt8] { [dataAddress] + packet }

    public enum Reply: Equatable, Sendable {
        case value(current: UInt16, maximum: UInt16)
        /// The monitor answered and said it does not have this control.
        case unsupported
        case invalid(String)
    }

    public static func parseReply(_ bytes: [UInt8], code: UInt8) -> Reply {
        guard bytes.count >= replyLength else { return .invalid("short reply") }
        let reply = Array(bytes.prefix(replyLength))
        if reply.allSatisfy({ $0 == 0 }) || reply.allSatisfy({ $0 == 0xFF }) { return .invalid("no answer") }
        guard checksum(seed: replySeed, reply.prefix(replyLength - 1)) == reply[replyLength - 1] else {
            return .invalid("bad checksum")
        }
        guard reply[0] == destination else { return .invalid("wrong source") }
        guard reply[2] == 0x02 else { return .invalid("wrong opcode") }
        guard reply[4] == code else { return .invalid("wrong code") }
        if reply[3] != 0 { return .unsupported }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return .value(current: current, maximum: maximum)
    }

    /// A well-formed reply, for tests and for the fake transport.
    public static func makeReply(code: UInt8, current: UInt16, maximum: UInt16, result: UInt8 = 0) -> [UInt8] {
        var reply: [UInt8] = [destination, 0x88, 0x02, result, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        reply.append(checksum(seed: replySeed, reply))
        return reply
    }
}

/// How the transport walks a request: m1ddc and MonitorControl's numbers. Each write is sent
/// twice (some monitors drop the first after a quiet bus), a read waits 50 ms for the monitor
/// to prepare its answer, and a failed exchange is tried again after 20 ms, four more times.
public struct DDCRetryPolicy: Sendable, Equatable {
    public var writeDelay: UInt32      // µs before each write
    public var writeCycles: Int
    public var readDelay: UInt32       // µs between the request and reading the answer
    public var attempts: Int
    public var retryDelay: UInt32      // µs after a failed attempt

    public init(writeDelay: UInt32 = 10_000, writeCycles: Int = 2, readDelay: UInt32 = 50_000,
                attempts: Int = 5, retryDelay: UInt32 = 20_000) {
        self.writeDelay = writeDelay
        self.writeCycles = max(writeCycles, 1)
        self.readDelay = readDelay
        self.attempts = max(attempts, 1)
        self.retryDelay = retryDelay
    }

    public static let standard = DDCRetryPolicy()
    /// For a monitor that has failed before: longer waits, as m1ddc advises for slow scalers.
    public static let patient = DDCRetryPolicy(writeDelay: 50_000, writeCycles: 2, readDelay: 100_000, attempts: 4, retryDelay: 50_000)
    /// The first probe of a display nobody knows yet answers: few tries, so a silent display
    /// costs well under a second.
    public static let probe = DDCRetryPolicy(writeDelay: 10_000, writeCycles: 1, readDelay: 50_000, attempts: 2, retryDelay: 20_000)

    /// The seed for one attempt of a read: standard first, then the other one, alternating.
    public func seed(attempt: Int) -> DDCPacket.Seed { attempt % 2 == 0 ? .standard : .destinationOnly }

    public enum Step: Equatable, Sendable {
        case wait(UInt32)
        case write(DDCPacket.Seed)
        case read
        /// The end of an attempt: stop here when it went through, else go on.
        case check
    }

    /// Every step of one exchange, in order. A write-only exchange has no read and no seed swap.
    public func plan(read: Bool) -> [Step] {
        var steps: [Step] = []
        for attempt in 0..<attempts {
            let seed: DDCPacket.Seed = read ? self.seed(attempt: attempt) : .standard
            for _ in 0..<writeCycles {
                steps.append(.wait(writeDelay))
                steps.append(.write(seed))
            }
            if read {
                steps.append(.wait(readDelay))
                steps.append(.read)
            }
            steps.append(.check)
            if attempt < attempts - 1 { steps.append(.wait(retryDelay)) }
        }
        return steps
    }

    /// The longest an exchange can take, in seconds, for the bus scheduler.
    public func worstCase(read: Bool) -> Double {
        plan(read: read).reduce(0.0) { total, step in
            if case .wait(let us) = step { return total + Double(us) / 1_000_000 }
            return total
        }
    }
}

/// Fractions on a slider and the raw numbers a monitor takes.
public enum DDCScale {
    /// A monitor that reports a maximum of 0 is treated as the usual 0–100.
    public static func effectiveMaximum(_ maximum: UInt16) -> UInt16 { maximum == 0 ? 100 : maximum }

    public static func raw(_ fraction: Double, maximum: UInt16) -> UInt16 {
        let top = Double(effectiveMaximum(maximum))
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return UInt16((f * top).rounded())
    }

    public static func fraction(_ raw: UInt16, maximum: UInt16) -> Double {
        min(Double(raw) / Double(effectiveMaximum(maximum)), 1)
    }

    /// The gamma scale that stands in for brightness on a monitor without DDC. It never goes
    /// below 15 %, so a slider at zero leaves a dim but readable screen, never black.
    public static let softwareFloor = 0.15

    public static func softwareScale(_ fraction: Double) -> Double {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 1
        return softwareFloor + (1 - softwareFloor) * f
    }

    /// MCCS mute: 1 is muted, 2 is sound on.
    public static func muteValue(_ muted: Bool) -> UInt16 { muted ? 1 : 2 }
    public static func isMuted(_ raw: UInt16) -> Bool { raw & 0xFF == 1 }
}

/// Inputs as MCCS numbers them. Many monitors put junk in the high byte, so only the low byte counts.
public enum DDCInput {
    public static let names: [UInt16: String] = [
        0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2",
        0x05: "Composite 1", 0x06: "Composite 2", 0x07: "S-Video 1", 0x08: "S-Video 2",
        0x0C: "Component 1", 0x0D: "Component 2", 0x0E: "Component 3",
        0x0F: "DisplayPort 1", 0x10: "DisplayPort 2", 0x11: "HDMI 1", 0x12: "HDMI 2",
        0x13: "HDMI 3", 0x1B: "USB-C", 0x19: "USB-C 2",
    ]
    /// What the card offers: the ports a monitor of the last ten years has.
    public static let common: [UInt16] = [0x0F, 0x10, 0x11, 0x12, 0x1B, 0x03, 0x01]

    public static func name(_ raw: UInt16) -> String {
        names[raw & 0xFF] ?? String(format: "Input 0x%02X", raw & 0xFF)
    }

    public static func normalized(_ raw: UInt16) -> UInt16 { raw & 0xFF }
}

/// A brightness glide over DDC. The bus takes about 50 ms per write, so the glide is a few
/// eased steps (20 a second at most), and steps that land on the same raw value are dropped.
public enum DDCGlide {
    public static func steps(from start: Double, to end: Double, maximum: UInt16,
                             duration: Double = 0.3, rate: Double = 20) -> [UInt16] {
        let count = max(Int((duration * rate).rounded()), 1)
        var out: [UInt16] = []
        for i in 1...count {
            let t = Double(i) / Double(count)
            let eased = 1 - pow(1 - t, 3)
            let raw = DDCScale.raw(start + (end - start) * eased, maximum: maximum)
            if out.last != raw { out.append(raw) }
        }
        let last = DDCScale.raw(end, maximum: maximum)
        if out.last != last { out.append(last) }
        if out.first == DDCScale.raw(start, maximum: maximum), out.count > 1 { out.removeFirst() }
        return out
    }
}

/// The newest value wins: a slider dragged faster than the bus can write leaves only the
/// latest value waiting per code, and a value equal to the last one written is not sent again.
public struct DDCCoalescer: Sendable {
    private var pending: [UInt8: UInt16] = [:]
    private var order: [UInt8] = []
    private var written: [UInt8: UInt16] = [:]

    public init() {}

    public mutating func push(_ code: UInt8, _ value: UInt16) {
        if pending[code] == nil { order.append(code) }
        pending[code] = value
    }

    /// The next write to send, oldest code first; nil when nothing is waiting.
    public mutating func next() -> (code: UInt8, value: UInt16)? {
        while let code = order.first {
            order.removeFirst()
            guard let value = pending.removeValue(forKey: code) else { continue }
            if written[code] == value { continue }
            return (code, value)
        }
        return nil
    }

    /// After a write went out (or a read told us the real value).
    public mutating func record(_ code: UInt8, _ value: UInt16) { written[code] = value }
    /// Forget what was written, so the next push goes out even if equal (after a reconnect).
    public mutating func forget() { written = [:] }
    public var isEmpty: Bool { pending.isEmpty }
}

/// The IORegistry and CoreDisplay facts matching a display to its AV service, as plain values.
public struct DDCDisplayFacts: Sendable, Equatable {
    public var vendor: Int64, product: Int64, serial: Int64
    public var week: Int64, year: Int64
    public var horizontalMM: Int64, verticalMM: Int64
    public var location: String
    public var name: String

    public init(vendor: Int64 = 0, product: Int64 = 0, serial: Int64 = 0, week: Int64 = 0, year: Int64 = 0,
                horizontalMM: Int64 = 0, verticalMM: Int64 = 0, location: String = "", name: String = "") {
        self.vendor = vendor; self.product = product; self.serial = serial
        self.week = week; self.year = year
        self.horizontalMM = horizontalMM; self.verticalMM = verticalMM
        self.location = location; self.name = name
    }
}

public struct DDCServiceFacts: Sendable, Equatable {
    /// "EDID UUID" of the framebuffer: hex of EDID fields, in a fixed layout.
    public var edidUUID: String
    /// The framebuffer's IOService path, which CoreDisplay reports as IODisplayLocation.
    public var path: String
    public var productName: String
    public var serial: Int64
    public var manufacturer: String
    /// DCPAVServiceProxy's "Location": "External" or "Embedded".
    public var location: String
    /// Order in the registry walk, unique per service.
    public var index: Int

    public init(edidUUID: String = "", path: String = "", productName: String = "", serial: Int64 = 0,
                manufacturer: String = "", location: String = "", index: Int = 0) {
        self.edidUUID = edidUUID; self.path = path; self.productName = productName; self.serial = serial
        self.manufacturer = manufacturer; self.location = location; self.index = index
    }

    public var external: Bool { location == "External" }
}

public enum DDCMatch {
    public static let maxScore = 20

    /// MonitorControl's score: one point per EDID UUID field that agrees (vendor, product,
    /// manufacture date, image size), ten for the same IORegistry path, one each for name and serial.
    public static func score(_ display: DDCDisplayFacts, _ service: DDCServiceFacts) -> Int {
        var score = 0
        let uuid = service.edidUUID.uppercased()
        func clamp(_ v: Int64, _ top: Int64) -> Int64 { max(0, min(v, top)) }
        let product = UInt16(clamp(display.product, 0xFFFF))
        let keys: [(String, Int)] = [
            (String(format: "%04X", UInt16(clamp(display.vendor, 0xFFFF))), 0),
            (String(format: "%02X%02X", UInt8(product & 0xFF), UInt8(product >> 8)), 4),
            (String(format: "%02X%02X", UInt8(clamp(display.week, 255)), UInt8(clamp(display.year - 1990, 255))), 19),
            (String(format: "%02X%02X", UInt8(clamp(display.horizontalMM / 10, 255)), UInt8(clamp(display.verticalMM / 10, 255))), 30),
        ]
        for (key, at) in keys where key != "0000" && uuid.count >= at + 4 {
            let start = uuid.index(uuid.startIndex, offsetBy: at)
            if uuid[start..<uuid.index(start, offsetBy: 4)] == key { score += 1 }
        }
        if !service.path.isEmpty, service.path == display.location { score += 10 }
        if !service.productName.isEmpty, service.productName.lowercased() == display.name.lowercased() { score += 1 }
        if service.serial != 0, service.serial == display.serial { score += 1 }
        return score
    }

    /// Best pairs first, each display and each service used once; a score of 0 is no match.
    public static func assign(displays: [(id: UInt32, facts: DDCDisplayFacts)],
                              services: [DDCServiceFacts]) -> [UInt32: Int] {
        var candidates: [(score: Int, id: UInt32, service: Int)] = []
        for display in displays {
            for service in services {
                let s = score(display.facts, service)
                if s > 0 { candidates.append((s, display.id, service.index)) }
            }
        }
        candidates.sort { ($0.score, -Int($0.id), -$0.service) > ($1.score, -Int($1.id), -$1.service) }
        var out: [UInt32: Int] = [:]
        var taken = Set<Int>()
        for c in candidates where out[c.id] == nil && !taken.contains(c.service) {
            out[c.id] = c.service
            taken.insert(c.service)
        }
        return out
    }
}

/// Which displays Atelier may talk to, and how.
public enum DDCEligibility: Equatable, Sendable {
    case ddc
    /// Apple's own displays take brightness from DisplayServices; DDC is left alone there.
    case native
    case skip(String)

    public static func verdict(builtIn: Bool, virtual: Bool, mirrorHidden: Bool = false, appleNative: Bool,
                               serviceLocation: String?, dummy: Bool = false) -> DDCEligibility {
        if builtIn { return .skip("built-in panel") }
        if virtual { return .skip("virtual display") }
        if dummy { return .skip("dummy plug") }
        if mirrorHidden { return .skip("mirrored") }
        if appleNative { return .native }
        if let serviceLocation, serviceLocation != "External" { return .skip("not external") }
        return .ddc
    }

    /// Dummy HDMI plugs that answer like a monitor and do nothing (MonitorControl's list).
    public static func isDummy(manufacturer: String, product: String) -> Bool {
        manufacturer == "AOC" && product == "28E850"
    }
}

/// Per-monitor memory: one key per monitor, stable across ports and reboots.
public enum DDCMemory {
    public static func key(vendor: UInt32, model: UInt32, serial: UInt32, name: String) -> String {
        let clean = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return "ddc.monitor.\(String(vendor, radix: 16))-\(String(model, radix: 16))-\(serial == 0 ? clean : String(serial))"
    }
}

/// Whether a sound output is a monitor's speakers: HDMI and DisplayPort audio carry the
/// monitor's own name, more or less.
public enum DDCAudio {
    public static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func matches(device: String, display: String) -> Bool {
        let d = normalized(device), m = normalized(display)
        guard !d.isEmpty, !m.isEmpty else { return false }
        return d.contains(m) || m.contains(d)
    }
}

/// `atelier://ddc?…`, parsed.
public enum DDCCommand: Equatable, Sendable {
    case list
    case read(VCPCode, display: UInt32?)
    case set(VCPCode, value: UInt16, display: UInt32?)
    /// Through the engine: glide, memory and the software fallback, as the slider does.
    case level(VCPCode, fraction: Double, display: UInt32?)
    case refresh
    case invalid(String)

    public static func parse(_ items: [(name: String, value: String?)]) -> DDCCommand {
        func value(_ name: String) -> String? { items.first { $0.name == name }.map { $0.value ?? "" } }
        let display: UInt32? = value("display").flatMap { UInt32($0) }
        if value("display") != nil, display == nil, value("display") != "" { return .invalid("display must be a display ID") }
        if let token = value("set") {
            guard let code = VCPCode(token: token) else { return .invalid("set: \(token) is not a code Atelier writes") }
            guard let raw = value("value"), let number = UInt16(raw) else { return .invalid("set needs value=<0…65535>") }
            return .set(code, value: number, display: display)
        }
        if let token = value("read") {
            guard let code = VCPCode(token: token) else { return .invalid("read: unknown code \(token)") }
            return .read(code, display: display)
        }
        for code in [VCPCode.brightness, .contrast, .volume] {
            if let raw = value(code.key) {
                guard let f = Double(raw), f.isFinite, (0...1).contains(f) else { return .invalid("\(code.key) needs 0…1") }
                return .level(code, fraction: f, display: display)
            }
        }
        if value("refresh") != nil { return .refresh }
        return .list
    }
}
