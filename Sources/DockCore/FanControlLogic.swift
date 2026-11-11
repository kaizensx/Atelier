import Foundation

// MARK: - Fan Control logic
//
// Everything Fan Control decides, kept apart from IOKit so it can be tested: the curves
// (temperature to fan level), the governor that follows a curve with hysteresis and a slew
// limit, the safety rules the root helper obeys, how a value is encoded for an SMC write,
// which mode key this Mac's SMC has, the files the app and the helper share, and the
// LaunchDaemon that runs the helper. Nothing here touches hardware.
//
// What the SMC does with fans on Apple silicon (agoodkind/macos-smc-fan, docs/research.md,
// checked against this Mac's keys with `AtelierFans --probe`):
//   F<n>Ac  flt   actual rpm          F<n>Tg  flt   target rpm (honoured in manual mode)
//   F<n>Mn  flt   minimum rpm         F<n>Mx  flt   maximum rpm
//   F<n>Md  ui8   mode, 0 auto, 1 manual, 3 system (thermalmonitord in charge). M5 spells it
//                 F<n>md, lower-case m; M1-M4 F<n>Md. Probed at run time, never assumed.
//   Ftst    ui8   "force test": on M3/M4 thermalmonitord refuses a mode write (SMC result 0x82)
//                 until Ftst=1, after which the write succeeds within 3-6 s. M5 has no Ftst and
//                 takes the mode write directly. Firmware clears Ftst on sleep.
// Writes need root (kIOReturnNotPrivileged otherwise), which is why there is a helper at all.

// MARK: Curves

/// A fan level is a fraction of the fan's own range: 0 is its minimum rpm, 1 its maximum. One
/// curve then fits every fan of every Mac.
public struct FanCurve: Equatable, Sendable, Codable {
    public struct Point: Equatable, Sendable, Codable {
        public var celsius: Double
        public var level: Double
        public init(_ celsius: Double, _ level: Double) {
            self.celsius = celsius
            self.level = level
        }
    }

    public static let temperatureRange = 30.0...105.0

    /// Sorted by temperature, levels between 0 and 1, never two at the same temperature.
    public private(set) var points: [Point]
    /// Below the first point the fans are handed back to macOS, which can stop them entirely;
    /// holding a fan at its minimum would be louder than the system at idle.
    public var systemBelowStart: Bool

    public init(_ points: [Point], systemBelowStart: Bool = true) {
        let clean = points
            .filter { $0.celsius.isFinite && $0.level.isFinite }
            .map { Point(min(max($0.celsius, 0), 120), min(max($0.level, 0), 1)) }
            .enumerated()
            // Stable: of two points at one temperature, the first given wins.
            .sorted { ($0.element.celsius, $0.offset) < ($1.element.celsius, $1.offset) }
            .map(\.element)
        var unique: [Point] = []
        for point in clean where unique.last?.celsius != point.celsius { unique.append(point) }
        self.points = unique.isEmpty ? [Point(0, 1)] : unique
        self.systemBelowStart = systemBelowStart
    }

    /// The level at a temperature, straight lines between points and flat past the last one.
    /// nil below the first point when the curve leaves the fans to the system there.
    public func level(at celsius: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if celsius < first.celsius { return systemBelowStart ? nil : first.level }
        if celsius >= last.celsius { return last.level }
        for (a, b) in zip(points, points.dropFirst()) where celsius >= a.celsius && celsius < b.celsius {
            let t = (celsius - a.celsius) / (b.celsius - a.celsius)
            return a.level + (b.level - a.level) * t
        }
        return last.level
    }

    /// "55:0,68:0.3,80:0.7,90:1", with a leading "~" when the curve never hands back to the system.
    public var text: String {
        let body = points.map { "\(Self.number($0.celsius)):\(Self.number($0.level))" }.joined(separator: ",")
        return systemBelowStart ? body : "~" + body
    }

    public static func parse(_ text: String) -> FanCurve? {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        let always = body.hasPrefix("~")
        if always { body = body.dropFirst() }
        let points = body.split(separator: ",").compactMap { pair -> Point? in
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let c = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let l = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return Point(c, l)
        }
        guard !points.isEmpty, points.count == body.split(separator: ",").count else { return nil }
        return FanCurve(points, systemBelowStart: !always)
    }

    /// Moves one point, kept between its neighbours so the curve stays a function of temperature
    /// and never falls as it gets hotter.
    public mutating func move(_ index: Int, celsius: Double, level: Double) {
        guard points.indices.contains(index) else { return }
        let low = index > 0 ? points[index - 1].celsius + 1 : Self.temperatureRange.lowerBound
        let high = index < points.count - 1 ? points[index + 1].celsius - 1 : Self.temperatureRange.upperBound
        let floor = index > 0 ? points[index - 1].level : 0
        let ceiling = index < points.count - 1 ? points[index + 1].level : 1
        points[index] = Point(min(max(celsius, low), max(low, high)), min(max(level, floor), ceiling))
    }

    private static func number(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

public enum FanPreset: String, CaseIterable, Sendable, Codable {
    /// macOS runs the fans: Fan Control is off.
    case system
    case silent, balanced, max, custom

    public var title: String {
        switch self {
        case .system: "Automatic"
        case .silent: "Silent"
        case .balanced: "Balanced"
        case .max: "Max"
        case .custom: "Custom"
        }
    }

    /// The preset's curve; nil for system and custom (custom has the owner's own).
    public var curve: FanCurve? {
        switch self {
        case .system, .custom: nil
        // Quieter than macOS under load: nothing until 70 °C, a gentle ramp, full speed at 97.
        case .silent: FanCurve([.init(70, 0), .init(80, 0.25), .init(90, 0.6), .init(97, 1)])
        // Earlier and firmer than macOS: cooler chips, fans you hear once the work is real.
        case .balanced: FanCurve([.init(55, 0), .init(68, 0.3), .init(80, 0.7), .init(90, 1)])
        case .max: FanCurve([.init(0, 1)], systemBelowStart: false)
        }
    }
}

/// What the governor wants from the fans.
public enum FanDemand: Equatable, Sendable {
    /// Hand the fans back to macOS.
    case system
    /// A level between 0 and 1 of each fan's range.
    case level(Double)
    /// Full speed because the hard limit was crossed.
    case overheat

    public var level: Double? {
        switch self {
        case .system: nil
        case .level(let l): l
        case .overheat: 1
        }
    }

    public var text: String {
        switch self {
        case .system: "system"
        case .level(let l): String(format: "%.3f", l)
        case .overheat: "overheat"
        }
    }
}

/// Turns levels into rpm. Never below the fan's minimum, never above its maximum.
public enum FanTarget {
    public static func rpm(level: Double, min: Double, max: Double) -> Double {
        guard max > min else { return min }
        let l = level.isFinite ? Swift.min(Swift.max(level, 0), 1) : 1
        return clamp(min + (max - min) * l, min: min, max: max)
    }

    /// The helper's last word on any rpm it is asked for. A broken number means full speed.
    public static func clamp(_ rpm: Double, min: Double, max: Double) -> Double {
        guard rpm.isFinite else { return Swift.max(max, min) }
        return Swift.min(Swift.max(rpm, min), Swift.max(max, min))
    }
}

// MARK: Governor

/// Follows a curve without hunting: the temperature it reads rises at once but falls only once
/// it is `hysteresis` degrees below, and the level moves at most `riseRate` / `fallRate` per
/// second (fast up, slow down, the way a fan should sound). At or over `hardLimit` it is full
/// speed at once, latched until the temperature is `limitClear` degrees under the limit.
public struct FanGovernor: Equatable, Sendable {
    public var hysteresis = 3.0
    public var riseRate = 0.5
    public var fallRate = 0.08
    public var hardLimit = 95.0
    public var limitClear = 8.0

    public private(set) var effective: Double?
    public private(set) var level: Double?
    public private(set) var overheated = false

    public init(hardLimit: Double = 95) { self.hardLimit = FanSafety.clampLimit(hardLimit) }

    public mutating func reset() {
        effective = nil
        level = nil
        overheated = false
    }

    public mutating func step(temperature: Double?, curve: FanCurve, dt: Double) -> FanDemand {
        // No reading, no control: the system knows its temperatures, a blind curve does not.
        guard let t = temperature, t.isFinite else {
            reset()
            return .system
        }
        if t >= hardLimit { overheated = true }
        if overheated, t < hardLimit - limitClear { overheated = false }
        let held = effective ?? t
        effective = min(max(held, t), t + hysteresis)
        if overheated {
            level = 1
            return .overheat
        }
        guard let target = curve.level(at: effective!) else {
            level = nil
            return .system
        }
        let current = level ?? 0
        let step = max(min(dt, 5), 0) * (target > current ? riseRate : fallRate)
        let next = current + min(max(target - current, -step), step)
        level = next
        return .level(next)
    }
}

/// Runs a governor over made-up temperatures, for checking a curve before it touches a fan.
public enum FanDryRun {
    public struct Row: Equatable, Sendable {
        public let time: Double
        public let celsius: Double
        public let demand: FanDemand
        public let rpm: [Double?]
    }

    public static func run(curve: FanCurve, temperatures: [Double], dt: Double = 1, hardLimit: Double = 95,
                           fans: [(min: Double, max: Double)]) -> [Row] {
        var governor = FanGovernor(hardLimit: hardLimit)
        return temperatures.enumerated().map { i, t in
            let demand = governor.step(temperature: t, curve: curve, dt: dt)
            let rpm = fans.map { fan in demand.level.map { FanTarget.rpm(level: $0, min: fan.min, max: fan.max) } }
            return Row(time: Double(i) * dt, celsius: t, demand: demand, rpm: rpm)
        }
    }

    /// "40,50,60" or "ramp" (35 → 100 → 35 °C, a degree a second, then held at the peak).
    public static func temperatures(_ text: String) -> [Double] {
        if text == "ramp" {
            let up = stride(from: 35.0, through: 100, by: 1).map { $0 }
            return up + Array(repeating: 100, count: 5) + up.reversed()
        }
        return text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: SMC

public enum SMCFanMode: UInt8, Sendable {
    case auto = 0, manual = 1, forced = 2, system = 3
}

public enum FanKeys {
    public static let unlock = "Ftst"
    public static let count = "FNum"
    public static func actual(_ fan: Int) -> String { "F\(fan)Ac" }
    public static func target(_ fan: Int) -> String { "F\(fan)Tg" }
    public static func minimum(_ fan: Int) -> String { "F\(fan)Mn" }
    public static func maximum(_ fan: Int) -> String { "F\(fan)Mx" }

    /// This SMC's mode key for a fan: F0Md up to M4, F0md on M5. nil if it has neither.
    public static func mode(_ fan: Int, in keys: Set<String>) -> String? {
        ["F\(fan)Md", "F\(fan)md"].first { keys.contains($0) }
    }

    /// Fan indices that have an actual-speed key, in order.
    public static func fans(in keys: Set<String>) -> [Int] {
        (0..<10).filter { keys.contains(actual($0)) }
    }
}

/// The bytes an SMC write carries, the inverse of SMCDecode: Apple silicon floats are little
/// endian, the integer and fixed-point types big endian. nil for any type it does not know or a
/// size that does not match the key's, so a wrong guess can never reach the chip.
public enum SMCEncode {
    public static func bytes(type: String, value: Double, size: Int) -> [UInt8]? {
        guard value.isFinite else { return nil }
        func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64(n - 1 - $0))) } }
        func unsigned(_ max: Double) -> UInt64 { UInt64(min(max, Swift.max(0, value.rounded()))) }
        let out: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            out = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt32($0))) }
        case "ui8 ", "flag": out = [UInt8(unsigned(255))]
        case "ui16": out = be(unsigned(65535), 2)
        case "ui32": out = be(unsigned(4_294_967_295), 4)
        case "fpe2": out = be(UInt64(min(16383.75, Swift.max(0, value)) * 4), 2)
        default: return nil
        }
        return out.count == size ? out : nil
    }
}

// MARK: Helper protocol

/// What the app asks of the helper, rewritten every couple of seconds as the heartbeat.
public struct FanCommand: Codable, Equatable, Sendable {
    public struct Fan: Codable, Equatable, Sendable {
        public var index: Int
        /// nil hands this fan to the system.
        public var rpm: Double?
        public init(index: Int, rpm: Double?) {
            self.index = index
            self.rpm = rpm
        }
    }

    public static let version = 1
    public var version = FanCommand.version
    /// Seconds since 1970 when the app wrote it.
    public var sent: Double
    public var seq: Int
    public var fans: [Fan]
    public var hardLimit: Double
    /// Why the app wants this, for the status line ("balanced", "quit", "sleep").
    public var reason: String

    public init(sent: Double, seq: Int, fans: [Fan], hardLimit: Double, reason: String) {
        self.sent = sent
        self.seq = seq
        self.fans = fans
        self.hardLimit = hardLimit
        self.reason = reason
    }

    public static func system(sent: Double, seq: Int, reason: String) -> FanCommand {
        FanCommand(sent: sent, seq: seq, fans: [], hardLimit: 95, reason: reason)
    }
}

/// What the helper reports back, every half second while it runs.
public struct FanHelperStatus: Codable, Equatable, Sendable {
    public struct Fan: Codable, Equatable, Sendable {
        public var index: Int
        public var mode: Int?
        public var target: Double?
        public var actual: Double?
        public var min: Double
        public var max: Double
        public init(index: Int, mode: Int?, target: Double?, actual: Double?, min: Double, max: Double) {
            self.index = index
            self.mode = mode
            self.target = target
            self.actual = actual
            self.min = min
            self.max = max
        }
    }

    public var version = 1
    public var pid: Int32
    public var time: Double
    /// "system", "manual" or "overheat".
    public var state: String
    public var reason: String
    public var fans: [Fan]
    public var modeKey: String?
    public var hasUnlock: Bool
    public var unlockUsed: Bool
    public var hottest: Double?
    public var reclaims: Int
    public var error: String?

    public init(pid: Int32, time: Double, state: String, reason: String, fans: [Fan], modeKey: String?,
                hasUnlock: Bool, unlockUsed: Bool, hottest: Double?, reclaims: Int, error: String?) {
        self.pid = pid
        self.time = time
        self.state = state
        self.reason = reason
        self.fans = fans
        self.modeKey = modeKey
        self.hasUnlock = hasUnlock
        self.unlockUsed = unlockUsed
        self.hottest = hottest
        self.reclaims = reclaims
        self.error = error
    }
}

/// What the helper does on each tick.
public enum FanHelperDecision: Equatable, Sendable {
    case system(String)
    case manual([Int: Double])
    case overheat
}

/// The helper's rules, the only ones that matter if the app misbehaves. In order: asleep or
/// waking, no command, a stale or future heartbeat, a command from before the last wake, an
/// unknown version, a blind helper (no temperature) are all "back to the system". A command
/// with every fan on the system is the system too. Over the hard limit is full speed, latched
/// until `limitClear` degrees below it.
public enum FanSafety {
    public static let heartbeat = 10.0
    public static let limitRange = 80.0...105.0
    public static let limitClear = 8.0

    public static func clampLimit(_ limit: Double) -> Double {
        limit.isFinite ? min(max(limit, limitRange.lowerBound), limitRange.upperBound) : 95
    }

    public static func decide(command: FanCommand?, now: Double, hottest: Double?, asleep: Bool,
                              wokeAt: Double?, overheated: inout Bool) -> FanHelperDecision {
        if asleep { overheated = false; return .system("sleep") }
        guard let command else { overheated = false; return .system("no command") }
        guard command.version == FanCommand.version else { overheated = false; return .system("version") }
        guard abs(now - command.sent) <= heartbeat else { overheated = false; return .system("heartbeat") }
        if let wokeAt, command.sent < wokeAt { overheated = false; return .system("wake") }
        let manual = command.fans.reduce(into: [Int: Double]()) { $0[$1.index] = $1.rpm }
        guard !manual.isEmpty else { overheated = false; return .system(command.reason) }
        guard let hottest, hottest.isFinite else { overheated = false; return .system("no temperature") }
        let limit = clampLimit(command.hardLimit)
        if hottest >= limit { overheated = true }
        if overheated, hottest < limit - limitClear { overheated = false }
        return overheated ? .overheat : .manual(manual)
    }
}

// MARK: Install

/// The helper's place on disk and the LaunchDaemon that runs it as root.
public enum FanHelperInstall {
    public static let label = "net.dasantos.atelier.fans"
    public static let helperPath = "/Library/PrivilegedHelperTools/net.dasantos.atelier.fans"
    public static let plistPath = "/Library/LaunchDaemons/net.dasantos.atelier.fans.plist"
    /// Root-owned: the helper's status and log.
    public static let directory = "/Library/Application Support/Atelier/Fans"
    /// Owned by the person who installed it, mode 700: the app's command. The helper reads it
    /// only if it is a plain file owned by that person, never through a link.
    public static let inbox = directory + "/Inbox"
    public static var statusPath: String { directory + "/status.json" }
    public static var commandPath: String { inbox + "/command.json" }

    public static func plist(owner: UInt32) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>\(helperPath)</string><string>--daemon</string><string>--owner</string><string>\(owner)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Interactive</string>
          <key>StandardErrorPath</key><string>\(directory)/helper.log</string>
        </dict></plist>

        """
    }

    /// One administrator prompt: copy the helper, write the daemon, make the two folders, start it.
    public static func installScript(helperSource: String, plistSource: String, owner: UInt32) -> String {
        let q = shellQuote
        return [
            "/bin/launchctl bootout system/\(label) 2>/dev/null",
            "/bin/mkdir -p /Library/PrivilegedHelperTools \(q(inbox))",
            "/usr/sbin/chown root:wheel \(q("/Library/Application Support/Atelier")) \(q(directory))",
            "/bin/chmod 755 \(q(directory))",
            "/usr/sbin/chown \(owner) \(q(inbox))",
            "/bin/chmod 700 \(q(inbox))",
            "/bin/cp -f \(q(helperSource)) \(q(helperPath))",
            "/usr/sbin/chown root:wheel \(q(helperPath))",
            "/bin/chmod 755 \(q(helperPath))",
            "/bin/cp -f \(q(plistSource)) \(q(plistPath))",
            "/usr/sbin/chown root:wheel \(q(plistPath))",
            "/bin/chmod 644 \(q(plistPath))",
            "/bin/launchctl bootstrap system \(q(plistPath))",
        ].joined(separator: "; ")
    }

    /// Stopping the daemon sends it SIGTERM, on which it hands every fan back to the system
    /// before it exits; then everything it put on disk goes.
    public static var removeScript: String {
        let q = shellQuote
        return [
            "/bin/launchctl bootout system/\(label) 2>/dev/null",
            "/bin/sleep 1",
            "/bin/rm -f \(q(plistPath)) \(q(helperPath))",
            "/bin/rm -rf \(q(directory))",
            "/bin/rmdir \(q("/Library/Application Support/Atelier")) 2>/dev/null",
            "true",
        ].joined(separator: "; ")
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
