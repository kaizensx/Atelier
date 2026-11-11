import CoreGraphics
import Foundation

/// The arithmetic behind Edge Stash, kept apart from Accessibility so it can be tested. Every
/// rectangle is in global Accessibility coordinates: origin at the top left of the primary
/// display, y growing downward.
///
/// Measured on macOS 27.3 with TextEdit: the window server accepts any origin that leaves at
/// least one point of the window on a display, and integer origins only (1727.5 lands on 1727).
/// An origin that would take the window fully off every display is pulled back so that 40
/// points show (-586 for a 586-wide window lands on -546). So a stash keeps `sliver` points
/// on screen, never zero.
public enum EdgeStashLogic {
    public enum Edge: String, CaseIterable, Codable, Sendable {
        case left, right
    }

    /// Points of the window left on the display while stashed. One is the floor macOS keeps;
    /// two survives a rounding step in either direction.
    public static let sliver = 2.0
    /// What macOS leaves showing when asked to take a window fully off screen.
    public static let systemKeep = 40.0
    /// The tab drawn over the sliver.
    public static let tabSize = CGSize(width: 22, height: 58)
    public static let tabGap = 6.0
    /// Distance from the display edge a peeked window keeps.
    public static let peekInset = 10.0
    /// How close to an outer edge the pointer must be at release to count as a hit.
    public static let edgeZone = 4.0
    /// Horizontal speed, in points per second, that counts as a fling.
    public static let flingSpeed = 2200.0

    public struct Display: Equatable, Sendable {
        public var frame: CGRect
        public var visible: CGRect
        public init(frame: CGRect, visible: CGRect) {
            self.frame = frame
            self.visible = visible
        }
    }

    // MARK: Edges

    /// The display a frame mostly sits on, else the nearest one.
    public static func displayIndex(for frame: CGRect, in displays: [Display]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let area = { (rect: CGRect) -> Double in rect.isNull ? 0 : Double(rect.width * rect.height) }
        let best = displays.indices.max { area(displays[$0].frame.intersection(frame)) < area(displays[$1].frame.intersection(frame)) }
        if let best, area(displays[best].frame.intersection(frame)) > 0 { return best }
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        func distance(_ r: CGRect) -> Double {
            hypot(max(r.minX - mid.x, 0, mid.x - r.maxX), max(r.minY - mid.y, 0, mid.y - r.maxY))
        }
        return displays.indices.min { distance(displays[$0].frame) < distance(displays[$1].frame) }
    }

    /// True when nothing lies beyond this display's edge across the vertical span: a window
    /// pushed out there leaves every display, instead of landing on a neighbour.
    public static func isOuterEdge(_ edge: Edge, of index: Int, span: ClosedRange<Double>, in displays: [Display]) -> Bool {
        guard displays.indices.contains(index) else { return false }
        let frame = displays[index].frame
        let x = edge == .left ? frame.minX : frame.maxX
        for (other, display) in displays.enumerated() where other != index {
            let touches = edge == .left ? display.frame.maxX >= x - 1 && display.frame.minX < x
                                        : display.frame.minX <= x + 1 && display.frame.maxX > x
            let overlaps = display.frame.minY < span.upperBound && display.frame.maxY > span.lowerBound
            if touches && overlaps { return false }
        }
        return true
    }

    // MARK: Frames

    /// Where a window rests while stashed: all but `sliver` points beyond the edge, at its
    /// own height, kept within the visible frame vertically so its tab can be reached.
    public static func stashedFrame(for window: CGRect, edge: Edge, display: Display, sliver: Double = sliver) -> CGRect {
        let keep = max(1, sliver)
        let x = edge == .left ? display.frame.minX - window.width + keep : display.frame.maxX - keep
        return CGRect(x: x.rounded(.down), y: clampedY(window, in: display.visible), width: window.width, height: window.height)
    }

    /// Where a stashed window slides to when it peeks: against its edge, inset a little,
    /// fully inside the visible frame when it fits.
    public static func peekFrame(for window: CGRect, edge: Edge, display: Display, inset: Double = peekInset) -> CGRect {
        let visible = display.visible
        let x = edge == .left ? visible.minX + inset : visible.maxX - inset - window.width
        let clampedX = max(visible.minX, min(x, visible.maxX - window.width))
        return CGRect(x: window.width > visible.width ? visible.minX : clampedX.rounded(),
                      y: clampedY(window, in: visible), width: window.width, height: window.height)
    }

    private static func clampedY(_ window: CGRect, in visible: CGRect) -> Double {
        if window.height >= visible.height { return visible.minY }
        return min(max(window.minY, visible.minY), visible.maxY - window.height).rounded()
    }

    /// What macOS does to an origin that would leave no point of the window on screen.
    public static func systemClamp(x: Double, width: Double, display: CGRect) -> Double {
        if x + width <= display.minX { return display.minX - width + systemKeep }
        if x >= display.maxX { return display.maxX - systemKeep }
        return x.rounded(.down)
    }

    /// The frame a window goes back to. The original when its display is still there,
    /// otherwise moved onto the display it overlaps most, shrunk to fit if it must.
    public static func restoreFrame(_ original: CGRect, displays: [Display]) -> CGRect {
        guard !displays.isEmpty else { return original }
        let on = displays.contains { d in
            let i = d.visible.intersection(original)
            return !i.isNull && i.width >= min(80, original.width) && i.height >= min(40, original.height)
        }
        if on { return original }
        let area = { (rect: CGRect) -> Double in rect.isNull ? 0 : Double(rect.width * rect.height) }
        let best = displays.max { area($0.visible.intersection(original)) < area($1.visible.intersection(original)) } ?? displays[0]
        let visible = best.visible
        let width = min(original.width, visible.width), height = min(original.height, visible.height)
        return CGRect(x: min(max(original.minX, visible.minX), visible.maxX - width),
                      y: min(max(original.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    /// True when a frame read back is the one asked for, give or take rounding.
    public static func matches(_ actual: CGRect, _ target: CGRect, tolerance: Double = 1) -> Bool {
        abs(actual.minX - target.minX) <= tolerance && abs(actual.minY - target.minY) <= tolerance
            && abs(actual.width - target.width) <= tolerance && abs(actual.height - target.height) <= tolerance
    }

    /// True when a window is near enough to where its stash left it to still be that stash.
    /// An app that reopens its windows where it saved them puts a stashed one back here.
    public static func looksStashed(_ frame: CGRect, stashed: CGRect, tolerance: Double = 48) -> Bool {
        abs(frame.minX - stashed.minX) <= tolerance && abs(frame.minY - stashed.minY) <= tolerance
            && abs(frame.width - stashed.width) <= 2 && abs(frame.height - stashed.height) <= 2
    }

    // MARK: Tabs

    /// Centres for the tabs on one edge, in the order given: each as close as it can be to
    /// where it wants to be, never overlapping, all inside `range`. Ties keep their order.
    public static func tabCenters(desired: [Double], range: ClosedRange<Double>,
                                  height: Double = tabSize.height, gap: Double = tabGap) -> [Double] {
        guard !desired.isEmpty else { return [] }
        let pitch = height + gap
        let low = range.lowerBound + height / 2, high = max(low, range.upperBound - height / 2)
        let order = desired.indices.sorted { desired[$0] < desired[$1] || (desired[$0] == desired[$1] && $0 < $1) }
        var placed = order.map { min(max(desired[$0], low), high) }
        // Push down from the top, then up from the bottom; whatever remains is evenly packed.
        for i in placed.indices.dropFirst() { placed[i] = max(placed[i], placed[i - 1] + pitch) }
        if let last = placed.last, last > high {
            placed[placed.count - 1] = high
            for i in placed.indices.dropLast().reversed() { placed[i] = min(placed[i], placed[i + 1] - pitch) }
            if placed[0] < low {
                // More tabs than fit at full pitch: share the edge evenly.
                let step = placed.count > 1 ? (high - low) / Double(placed.count - 1) : 0
                for i in placed.indices { placed[i] = low + step * Double(i) }
            }
        }
        var result = Array(repeating: 0.0, count: desired.count)
        for (slot, index) in order.enumerated() { result[index] = placed[slot] }
        return result
    }

    /// The tab's rectangle: half over the display edge, centred on `center`.
    public static func tabFrame(edge: Edge, center: Double, display: Display, size: CGSize = tabSize) -> CGRect {
        let x = edge == .left ? display.frame.minX : display.frame.maxX - size.width
        return CGRect(x: x, y: (center - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    // MARK: Hover

    /// The strip that wakes a stash: its tab, and the sliver along the window's height, both
    /// widened a little inward so a pointer resting at the edge counts.
    public static func hotZones(tab: CGRect, stashed: CGRect, edge: Edge, display: Display, reach: Double = 3) -> [CGRect] {
        let x = edge == .left ? display.frame.minX : display.frame.maxX - reach
        return [tab, CGRect(x: x, y: stashed.minY, width: reach, height: stashed.height)]
    }

    public static func isHot(_ point: CGPoint, zones: [CGRect]) -> Bool { zones.contains { $0.contains(point) } }

    /// While peeked, the pointer may wander this far outside the window before it slides away.
    public static func keepZone(peek: CGRect, tab: CGRect, margin: Double = 24) -> CGRect {
        peek.insetBy(dx: -margin, dy: -margin).union(tab)
    }

    // MARK: Drag

    public struct Sample: Equatable, Sendable {
        public var time: Double
        public var point: CGPoint
        public init(time: Double, point: CGPoint) {
            self.time = time
            self.point = point
        }
    }

    /// Horizontal speed over the last `window` seconds of samples, in points per second.
    public static func velocityX(_ samples: [Sample], window: Double = 0.08) -> Double {
        guard let last = samples.last else { return 0 }
        guard let first = samples.last(where: { last.time - $0.time >= window }) ?? samples.first,
              last.time - first.time > 0.004 else { return 0 }
        return Double(last.point.x - first.point.x) / (last.time - first.time)
    }

    /// At release of a window drag with the modifier held: which edge to stash on, if any.
    /// The pointer against an outer edge always counts; a fast fling towards one counts
    /// when `fling` is on and the pointer is in the outer third of the display.
    public static func releaseEdge(cursor: CGPoint, velocityX: Double, display: Display, fling: Bool,
                                   leftOuter: Bool, rightOuter: Bool) -> Edge? {
        let frame = display.frame
        if leftOuter && cursor.x <= frame.minX + edgeZone { return .left }
        if rightOuter && cursor.x >= frame.maxX - edgeZone - 1 { return .right }
        guard fling else { return nil }
        let third = frame.width / 3
        if leftOuter && velocityX <= -flingSpeed && cursor.x <= frame.minX + third { return .left }
        if rightOuter && velocityX >= flingSpeed && cursor.x >= frame.maxX - third { return .right }
        return nil
    }

    /// While peeked, a window the person moved far from its peek spot has been taken out of
    /// the stash by hand.
    public static func movedByHand(_ actual: CGRect, peek: CGRect, threshold: Double = 30) -> Bool {
        hypot(actual.minX - peek.minX, actual.minY - peek.minY) > threshold
    }
}

/// One stashed window, saved to disk so a crash or a quit never leaves it off screen.
public struct EdgeStashRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var edge: EdgeStashLogic.Edge
    /// Where the window was before it was stashed. The one frame that must never be lost.
    public var original: CGRect
    /// Where it was left, read back from the window after the move.
    public var stashed: CGRect
    public var windowNumber: Int?
    public var date: Date
    /// Set when its app quit with the window stashed: on the app's next launch the window
    /// that comes back at `stashed` is moved to `original`.
    public var orphaned: Bool

    public init(id: UUID = UUID(), pid: Int32, bundleID: String?, appName: String, title: String,
                edge: EdgeStashLogic.Edge, original: CGRect, stashed: CGRect, windowNumber: Int?,
                date: Date = Date(), orphaned: Bool = false) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.edge = edge
        self.original = original
        self.stashed = stashed
        self.windowNumber = windowNumber
        self.date = date
        self.orphaned = orphaned
    }

    /// Orphans older than this are dropped: the app has long since been reopened or removed.
    public static let orphanLifetime = 7 * 24 * 3600.0

    public static func encode(_ records: [EdgeStashRecord]) -> Data? { try? JSONEncoder().encode(records) }
    public static func decode(_ data: Data?) -> [EdgeStashRecord] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([EdgeStashRecord].self, from: data)) ?? []
    }
}
