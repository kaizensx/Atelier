import CoreGraphics
import Foundation

/// A zone on a unit screen: x and y from the top left, all values 0...1.
public struct ZoneRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
}

/// A snap layout the owner drew.
public struct CustomLayout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var zones: [ZoneRect]

    public init(id: UUID = UUID(), name: String, zones: [ZoneRect]) {
        self.id = id
        self.name = name
        self.zones = zones
    }

    public static let presets: [CustomLayout] = [
        CustomLayout(name: "Ultrawide Thirds", zones: [
            ZoneRect(x: 0, y: 0, width: 0.25, height: 1),
            ZoneRect(x: 0.25, y: 0, width: 0.5, height: 1),
            ZoneRect(x: 0.75, y: 0, width: 0.25, height: 1),
        ]),
        CustomLayout(name: "Focus and Side", zones: [
            ZoneRect(x: 0, y: 0, width: 0.7, height: 1),
            ZoneRect(x: 0.7, y: 0, width: 0.3, height: 0.5),
            ZoneRect(x: 0.7, y: 0.5, width: 0.3, height: 0.5),
        ]),
        CustomLayout(name: "Six Grid", zones: (0..<6).map { index in
            ZoneRect(x: Double(index % 3) / 3, y: Double(index / 3) / 2, width: 1.0 / 3, height: 0.5)
        }),
    ]
}

/// Where a per-app rule puts a window.
public enum RulePlacement: Codable, Hashable, Sendable {
    /// A built-in layout, by its raw value.
    case layout(String)
    /// A zone of a custom layout.
    case zone(layout: UUID, index: Int)
    /// Centred at a share of the visible frame.
    case percent(Double)
}

/// "Always open this app here."
public struct AppRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var placement: RulePlacement
    /// Index into the screens list, nil for whichever screen the window opens on.
    public var display: Int?
    public var enabled: Bool

    public init(id: UUID = UUID(), bundleID: String, appName: String, placement: RulePlacement,
                display: Int? = nil, enabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.placement = placement
        self.display = display
        self.enabled = enabled
    }
}

/// Pure geometry for the Tools chapter. Rectangles use Accessibility coordinates (y down),
/// like `WindowGeometry` in the app.
public enum ToolsGeometry {
    /// The window frame for a zone. Outer edges keep a full gap from the screen, inner edges
    /// split it with the neighbour, so two zones that touch leave exactly one gap between them.
    public static func frame(of zone: ZoneRect, in visible: CGRect, gap: Double) -> CGRect {
        let left = visible.minX + zone.x * visible.width
        let right = visible.minX + (zone.x + zone.width) * visible.width
        let top = visible.minY + zone.y * visible.height
        let bottom = visible.minY + (zone.y + zone.height) * visible.height
        func inset(_ touchesEdge: Bool) -> Double { touchesEdge ? gap : gap / 2 }
        let l = left + inset(zone.x <= 0.0005)
        let r = right - inset(zone.x + zone.width >= 0.9995)
        let t = top + inset(zone.y <= 0.0005)
        let b = bottom - inset(zone.y + zone.height >= 0.9995)
        return CGRect(x: l.rounded(), y: t.rounded(), width: max(r - l, 1).rounded(), height: max(b - t, 1).rounded())
    }

    /// A zone between two unit points, snapped outward to a grid. Nil when it would be empty.
    public static func zone(from a: CGPoint, to b: CGPoint, columns: Int, rows: Int) -> ZoneRect? {
        guard columns > 0, rows > 0 else { return nil }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        let cols = Double(columns), rws = Double(rows)
        let x0 = (clamp(min(a.x, b.x)) * cols).rounded(.down) / cols
        let x1 = (clamp(max(a.x, b.x)) * cols).rounded(.up) / cols
        let y0 = (clamp(min(a.y, b.y)) * rws).rounded(.down) / rws
        let y1 = (clamp(max(a.y, b.y)) * rws).rounded(.up) / rws
        let width = max(x1 - x0, 1 / cols), height = max(y1 - y0, 1 / rws)
        let x = min(x0, 1 - width), y = min(y0, 1 - height)
        return ZoneRect(x: x, y: y, width: width, height: height)
    }

    /// The smallest zone holding a unit point, so a small zone drawn over a big one wins.
    public static func zoneIndex(containing point: CGPoint, in zones: [ZoneRect]) -> Int? {
        zones.indices.filter { zones[$0].contains(point) }.min { zones[$0].area < zones[$1].area }
    }

    /// A window centred in `visible` at `percent` of its width and height.
    public static func percentFrame(_ percent: Double, in visible: CGRect) -> CGRect {
        let share = min(max(percent, 0.2), 1)
        let width = (visible.width * share).rounded(), height = (visible.height * share).rounded()
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    /// The next item in a cycle, starting at 0 when there is no current one.
    public static func nextIndex(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0 else { return 0 }
        return (current + 1) % count
    }

    /// The first enabled rule for an app.
    public static func rule(for bundleID: String, in rules: [AppRule]) -> AppRule? {
        rules.first { $0.enabled && $0.bundleID == bundleID }
    }

    /// A stored display index, kept when that display still exists.
    public static func displayIndex(preferred: Int?, count: Int, fallback: Int) -> Int {
        if let preferred, preferred >= 0, preferred < count { return preferred }
        return min(max(fallback, 0), max(count - 1, 0))
    }
}
