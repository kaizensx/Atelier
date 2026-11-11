import CoreGraphics
import Foundation

/// The eight places on a screen's rim that Atelier's Hot Corners can watch: four corners
/// and the middle of each edge.
public enum HotSpot: String, CaseIterable, Codable, Sendable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var id: String { rawValue }

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .top: "Top Edge"
        case .topRight: "Top Right"
        case .right: "Right Edge"
        case .bottomRight: "Bottom Right"
        case .bottom: "Bottom Edge"
        case .bottomLeft: "Bottom Left"
        case .left: "Left Edge"
        }
    }

    /// Position on a unit screen, y growing downward (0 is the top).
    public var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        }
    }

    /// The four corners Apple's own hot corners use, by their `wvous-*` key.
    public var appleKey: String? {
        switch self {
        case .topLeft: "tl"
        case .topRight: "tr"
        case .bottomLeft: "bl"
        case .bottomRight: "br"
        default: nil
        }
    }
}

/// Modifier keys a hot spot can require, stored as plain bits so they survive any keyboard API.
public struct HotModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = HotModifiers(rawValue: 1)
    public static let option = HotModifiers(rawValue: 2)
    public static let shift = HotModifiers(rawValue: 4)
    public static let command = HotModifiers(rawValue: 8)

    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// Hit testing in AppKit's global space: y grows upward, as `NSEvent.mouseLocation` reports.
public enum HotZones {
    /// Square reach of a corner, in points.
    public static let cornerReach = 6.0
    /// How close to an edge counts as touching it. The pointer stops one point short of maxX.
    public static let thickness = 2.0
    /// The share of an edge, around its middle, that counts as the edge spot.
    public static let edgeShare = 0.2

    /// The spot under `point` on `screen`, or nil. A spot on an edge another screen continues
    /// past is never returned, since the pointer slides through it instead of stopping there.
    public static func spot(at point: CGPoint, screen: CGRect, screens: [CGRect],
                            corner: Double = cornerReach, edgeShare: Double = edgeShare) -> HotSpot? {
        guard screen.insetBy(dx: -thickness, dy: -thickness).contains(point) else { return nil }
        let nearLeft = point.x <= screen.minX + thickness
        let nearRight = point.x >= screen.maxX - thickness - 1
        let nearBottom = point.y <= screen.minY + thickness
        let nearTop = point.y >= screen.maxY - thickness - 1
        let inLeftBand = point.x <= screen.minX + corner
        let inRightBand = point.x >= screen.maxX - corner - 1
        let inTopBand = point.y >= screen.maxY - corner - 1
        let inBottomBand = point.y <= screen.minY + corner

        let others = screens.filter { $0 != screen }
        func outer(_ dx: Double, _ dy: Double) -> Bool {
            let probe = CGPoint(x: point.x + dx, y: point.y + dy)
            return !others.contains { $0.contains(probe) }
        }
        let step = thickness + 3

        func stop(_ spot: HotSpot, _ dx: Double, _ dy: Double) -> HotSpot? {
            outer(dx, 0) && outer(0, dy) && outer(dx, dy) ? spot : nil
        }
        if (nearLeft && inTopBand) || (nearTop && inLeftBand) { return stop(.topLeft, -step, step) }
        if (nearRight && inTopBand) || (nearTop && inRightBand) { return stop(.topRight, step, step) }
        if (nearLeft && inBottomBand) || (nearBottom && inLeftBand) { return stop(.bottomLeft, -step, -step) }
        if (nearRight && inBottomBand) || (nearBottom && inRightBand) { return stop(.bottomRight, step, -step) }

        let halfX = screen.width * edgeShare / 2, halfY = screen.height * edgeShare / 2
        let middleX = abs(point.x - screen.midX) <= halfX, middleY = abs(point.y - screen.midY) <= halfY
        if nearTop && middleX { return outer(0, step) ? .top : nil }
        if nearBottom && middleX { return outer(0, -step) ? .bottom : nil }
        if nearLeft && middleY { return outer(-step, 0) ? .left : nil }
        if nearRight && middleY { return outer(step, 0) ? .right : nil }
        return nil
    }

    /// Whether a spot on `screen` can ever be reached as a resting place.
    public static func reachable(_ spot: HotSpot, screen: CGRect, screens: [CGRect]) -> Bool {
        let unit = spot.unit
        // Sample one point inside the spot and ask the same question as the pointer would.
        let x = screen.minX + unit.x * (screen.width - 1)
        let y = screen.maxY - 1 - unit.y * (screen.height - 1)
        return self.spot(at: CGPoint(x: x, y: y), screen: screen, screens: screens) == spot
    }
}

/// Decides when a spot fires: once per visit, after a dwell, never inside the cooldown.
/// Leaving the spot re-arms it. The caller owns any timer and the gates (modifiers, full
/// screen, dragging); this only keeps time.
public struct HotTrigger: Sendable, Equatable {
    public private(set) var current: HotSpot?
    public private(set) var enteredAt = 0.0
    public private(set) var fired = false
    public private(set) var lastFire = -Double.infinity

    public init() {}

    public enum Step: Equatable, Sendable {
        case none
        /// The spot was left (or changed to nothing). Cancel any pending dwell.
        case cancel
        /// A new spot was entered. Ask `ready` after `delay` seconds.
        case schedule(HotSpot, delay: Double)
    }

    public mutating func update(spot: HotSpot?, now: Double, dwell: Double) -> Step {
        guard spot != current else { return .none }
        current = spot
        enteredAt = now
        fired = false
        guard let spot else { return .cancel }
        return .schedule(spot, delay: max(dwell, 0))
    }

    /// The spot to fire now, if the pointer is still there, has waited long enough, has not
    /// fired on this visit, and the cooldown has passed.
    public func ready(now: Double, dwell: Double, cooldown: Double) -> HotSpot? {
        guard let current, !fired, now - enteredAt >= dwell - 0.005, now - lastFire >= cooldown else { return nil }
        return current
    }

    public mutating func markFired(now: Double) {
        fired = true
        lastFire = now
    }
}
