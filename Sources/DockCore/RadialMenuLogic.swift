import Foundation

// MARK: - Radial Window Menu: pure picking
//
// Hold a trigger and a ring appears around the pointer. Where the pointer goes relative to the
// ring's centre picks a layout: the centre maximises, the inner ring holds halves and quarters
// (eight 45° sectors), the outer ring holds thirds. Everything here is free of AppKit so the
// geometry and the timing can be tested. Offsets use screen coordinates (y grows downward);
// angles are degrees counter-clockwise from east, so "up" is 90°.

/// What a radial pick does. Raw values match `WindowGeometry.Layout` in the app target.
public enum RadialPick: String, CaseIterable, Sendable {
    case maximize
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case center
}

public enum RadialBand: Int, Sendable, Equatable {
    case center, inner, outer
}

/// Eight compass sectors, counter-clockwise from east, 45° each, centred on their angle.
public enum RadialSector: Int, CaseIterable, Sendable {
    case east, northEast, north, northWest, west, southWest, south, southEast

    public var angle: Double { Double(rawValue) * 45 }

    public static func containing(angle: Double) -> RadialSector {
        let index = Int(((RadialGeometry.normalized(angle) + 22.5) / 45).rounded(.down)) % 8
        return RadialSector(rawValue: index) ?? .east
    }
}

public struct RadialSelection: Equatable, Sendable {
    public var band: RadialBand
    /// Nil in the centre.
    public var sector: RadialSector?
    public var pick: RadialPick

    public init(band: RadialBand, sector: RadialSector?, thirds: Bool = true) {
        self.band = band
        self.sector = band == .center ? nil : sector
        pick = RadialMap.pick(band: band, sector: self.sector, thirds: thirds)
    }

    public static let centre = RadialSelection(band: .center, sector: nil)
}

/// Which layout lives where. The outer ring's three southern sectors share one pick, Center,
/// so the ring draws them as a single 135° arc.
public enum RadialMap {
    public static let inner: [RadialPick] = [.rightHalf, .topRight, .topHalf, .topLeft, .leftHalf, .bottomLeft, .bottomHalf, .bottomRight]
    public static let outer: [RadialPick] = [.rightThird, .rightTwoThirds, .centerThird, .leftTwoThirds, .leftThird, .center, .center, .center]

    public static func pick(band: RadialBand, sector: RadialSector?, thirds: Bool = true) -> RadialPick {
        guard let sector, band != .center else { return .maximize }
        return (band == .outer && thirds ? outer : inner)[sector.rawValue]
    }

    /// One drawn arc: runs of neighbouring sectors with the same pick.
    public struct Segment: Equatable, Sendable {
        public var pick: RadialPick
        public var first: RadialSector
        public var count: Int
        /// Centre angle and width in degrees.
        public var angle: Double { RadialGeometry.normalized(first.angle + Double(count - 1) * 22.5) }
        public var span: Double { Double(count) * 45 }
        public func contains(_ sector: RadialSector) -> Bool {
            (sector.rawValue - first.rawValue + 8) % 8 < count
        }
    }

    public static func segments(_ band: RadialBand) -> [Segment] {
        guard band != .center else { return [] }
        let picks = band == .outer ? outer : inner
        // Start at a boundary so a run never wraps past index 0 unseen.
        let start = (0..<8).first { picks[$0] != picks[($0 + 7) % 8] } ?? 0
        var segments: [Segment] = []
        for offset in 0..<8 {
            let index = (start + offset) % 8
            if let last = segments.last, last.pick == picks[index] {
                segments[segments.count - 1].count += 1
            } else {
                segments.append(Segment(pick: picks[index], first: RadialSector(rawValue: index)!, count: 1))
            }
        }
        return segments
    }

    public static func segment(for selection: RadialSelection) -> Segment? {
        guard let sector = selection.sector else { return nil }
        return segments(selection.band).first { $0.contains(sector) }
    }
}

public enum RadialGeometry {
    public static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// Screen offset (y down) to a compass angle (counter-clockwise from east, up is 90°).
    public static func angle(dx: Double, dy: Double) -> Double { normalized(atan2(-dy, dx) * 180 / .pi) }

    /// Smallest signed difference a → b, in -180...180.
    public static func delta(from a: Double, to b: Double) -> Double {
        var difference = normalized(b - a)
        if difference > 180 { difference -= 360 }
        return difference
    }

    /// The screen offset for an angle and a distance, for `simulate`.
    public static func offset(angle: Double, distance: Double) -> (dx: Double, dy: Double) {
        let radians = angle * .pi / 180
        return (cos(radians) * distance, -sin(radians) * distance)
    }

    /// Where the ring sits: centred on the pointer, pulled in so it stays wholly on screen.
    public static func clampedCentre(x: Double, y: Double, radius: Double,
                                     minX: Double, minY: Double, maxX: Double, maxY: Double) -> (x: Double, y: Double) {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return (clamp(x, minX + radius, maxX - radius), clamp(y, minY + radius, maxY - radius))
    }
}

public struct RadialTuning: Equatable, Sendable {
    /// Inside this distance the pick is Maximize.
    public var deadZone = 30.0
    /// Beyond this distance the outer ring (thirds) takes over.
    public var outerRadius = 104.0
    /// Degrees past a sector's edge before the pick moves on.
    public var angleHysteresis = 7.0
    /// Points past a ring's edge before the band changes.
    public var radiusHysteresis = 8.0
    public var thirds = true

    public init() {}
}

/// Pointer offset → selection, with a dead zone and hysteresis on both angle and radius so a
/// hand resting on a boundary does not flicker between two layouts.
public struct RadialPicker: Sendable {
    public var tuning: RadialTuning
    public private(set) var selection = RadialSelection.centre

    public init(tuning: RadialTuning = RadialTuning()) { self.tuning = tuning }

    /// Returns true when the pick changed (the moment for a haptic tick).
    @discardableResult
    public mutating func update(dx: Double, dy: Double) -> Bool {
        let next = Self.select(dx: dx, dy: dy, previous: selection, tuning: tuning)
        let changed = next.pick != selection.pick
        selection = next
        return changed
    }

    /// Sets the selection directly, for arrow keys.
    @discardableResult
    public mutating func force(_ next: RadialSelection) -> Bool {
        let changed = next.pick != selection.pick
        selection = next
        return changed
    }

    public mutating func reset() { selection = .centre }

    public static func select(dx: Double, dy: Double, previous: RadialSelection, tuning: RadialTuning) -> RadialSelection {
        let distance = (dx * dx + dy * dy).squareRoot()
        let h = tuning.radiusHysteresis
        let dead = previous.band == .center ? tuning.deadZone + h / 2 : tuning.deadZone - h / 2
        if distance < max(dead, 0) { return .centre }
        var band = RadialBand.inner
        if tuning.thirds {
            let edge = previous.band == .outer ? tuning.outerRadius - h : tuning.outerRadius + h / 2
            if distance >= edge { band = .outer }
        }
        let angle = RadialGeometry.angle(dx: dx, dy: dy)
        var sector = RadialSector.containing(angle: angle)
        if let held = previous.sector, held != sector,
           abs(RadialGeometry.delta(from: held.angle, to: angle)) <= 22.5 + tuning.angleHysteresis {
            sector = held
        }
        return RadialSelection(band: band, sector: sector, thirds: tuning.thirds)
    }
}

// MARK: - Arrow keys

public enum RadialArrow: String, Sendable, CaseIterable {
    case up, down, left, right

    public init?(keycode: Int64) {
        switch keycode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        default: return nil
        }
    }
}

/// Arrows pick a direction; two held together pick a corner; pressing the same direction again
/// steps out to the thirds ring and back. Releasing keys never changes the pick, so both keys of
/// a corner can be let go in any order.
public struct RadialKeys: Sendable {
    public private(set) var held: Set<RadialArrow> = []

    public init() {}

    public mutating func press(_ arrow: RadialArrow, current: RadialSelection, thirds: Bool) -> RadialSelection {
        held.insert(arrow)
        let x = (held.contains(.right) ? 1 : 0) - (held.contains(.left) ? 1 : 0)
        let y = (held.contains(.up) ? 1 : 0) - (held.contains(.down) ? 1 : 0)
        guard x != 0 || y != 0 else { return .centre }
        let sector = RadialSector.containing(angle: atan2(Double(y), Double(x)) * 180 / .pi)
        var band = RadialBand.inner
        if thirds, current.sector == sector, current.band == .inner { band = .outer }
        return RadialSelection(band: band, sector: sector, thirds: thirds)
    }

    public mutating func release(_ arrow: RadialArrow) { held.remove(arrow) }
    public mutating func reset() { held = [] }
}

// MARK: - Trigger

/// What opens the ring. Each modifier trigger must be held alone for a moment, so chords such as
/// ⌃⌥← (Hot Keys) still work: a key pressed during that moment means a chord, not the ring.
public enum RadialTrigger: String, CaseIterable, Sendable {
    case hyper, controlOption, rightOption, rightCommand, function

    public var title: String {
        switch self {
        case .hyper: "Hyper"
        case .controlOption: "⌃⌥"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .function: "fn"
        }
    }

    /// CGEventFlags bits (and the device-dependent side bits from IOLLEvent.h).
    public enum Mask {
        public static let shift: UInt64 = 0x20000
        public static let control: UInt64 = 0x40000
        public static let option: UInt64 = 0x80000
        public static let command: UInt64 = 0x100000
        public static let function: UInt64 = 0x800000
        public static let rightOption: UInt64 = 0x40
        public static let rightCommand: UInt64 = 0x10
        public static let all: UInt64 = shift | control | option | command | function
    }

    /// How long the trigger must be held, alone, before the ring opens. Hyper waits out Hyper
    /// Key's own tap limit (0.3 s), so a quick Caps Lock is still Escape and never opens the ring.
    public var delay: Double {
        switch self {
        case .hyper: 0.3
        default: 0.2
        }
    }

    /// Whether the modifier state holds this trigger and nothing else. Hyper is not a flag
    /// state; it comes from the Hyper Key tap.
    public func exactly(_ flags: UInt64) -> Bool {
        let held = flags & Mask.all
        switch self {
        case .hyper: return false
        case .controlOption: return held == Mask.control | Mask.option
        case .rightOption: return held == Mask.option && flags & Mask.rightOption != 0
        case .rightCommand: return held == Mask.command && flags & Mask.rightCommand != 0
        case .function: return held == Mask.function
        }
    }

    /// Whether the trigger is still held, extra modifiers allowed (a release of any part is a release).
    public func holds(_ flags: UInt64) -> Bool {
        switch self {
        case .hyper: return false
        case .controlOption: return flags & Mask.control != 0 && flags & Mask.option != 0
        case .rightOption: return flags & Mask.option != 0 && flags & Mask.rightOption != 0
        case .rightCommand: return flags & Mask.command != 0 && flags & Mask.rightCommand != 0
        case .function: return flags & Mask.function != 0
        }
    }
}

/// When the ring opens, applies and cancels.
public struct RadialGate: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case arming(since: Double)
        case open
    }

    public enum Action: Equatable, Sendable {
        case none
        case open
        case commit
        case cancel
        /// The trigger went up before the ring opened: a middle click is sent on as a click.
        case click
    }

    public private(set) var phase = Phase.idle

    public init() {}

    public var isOpen: Bool { phase == .open }
    public var isArming: Bool { if case .arming = phase { true } else { false } }

    public mutating func triggerDown(now: Double) -> Action {
        if phase == .idle { phase = .arming(since: now) }
        return .none
    }

    public mutating func tick(now: Double, delay: Double) -> Action {
        guard case let .arming(since) = phase, now - since >= delay - 0.0005 else { return .none }
        phase = .open
        return .open
    }

    /// Another key or button while arming means a chord: stand down. While open it is ours.
    public mutating func otherInput() -> Action {
        if isArming { phase = .idle }
        return .none
    }

    public mutating func triggerUp() -> Action {
        switch phase {
        case .idle: return .none
        case .arming: phase = .idle; return .click
        case .open: phase = .idle; return .commit
        }
    }

    public mutating func escape() -> Action {
        guard phase == .open else { return .none }
        phase = .idle
        return .cancel
    }

    public mutating func reset() { phase = .idle }
}
