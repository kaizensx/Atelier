import CoreGraphics
import Foundation

/// The part of a screen a placed window may use. While the Atelier Dock stands in for the macOS
/// Dock, `NSScreen.visibleFrame` keeps only a few points for the hidden system Dock, so every
/// snap, layout and rehome would put windows under the bar. This takes the dock's band off the
/// edge it sits on, on top of what the visible frame already leaves out (the menu bar, and the
/// macOS Dock when it shows).
///
/// All rectangles here are AppKit screen coordinates: origin at the bottom left, y growing up.
public enum UsableArea {
    public enum Edge: String, Sendable, CaseIterable { case bottom, top, left, right }

    /// The room the dock keeps on one edge, measured from the screen's own edge.
    public struct Band: Equatable, Sendable {
        public var edge: Edge
        public var thickness: Double
        public init(edge: Edge, thickness: Double) {
            self.edge = edge
            self.thickness = thickness
        }
    }

    /// Below this, a band is ignored rather than leave a window no room at all.
    public static let smallest = 200.0

    /// How far the dock's band reaches in from the screen edge: whatever already sits between
    /// that edge and the bar (the menu bar at the top, the macOS Dock when Atelier's sits beside
    /// it), then the gap under the bar, the bar, and the margin kept free above it. The same rule
    /// as Reserve Dock Space, so a window placed here is never fitted again by it.
    public static func thickness(edge: Edge, full: CGRect, visible: CGRect, replacing: Bool,
                                 gap: Double, bar: Double, margin: Double) -> Double {
        let inset: Double = switch edge {
        case .top: Double(full.maxY - visible.maxY)
        case .bottom: replacing ? 0 : Double(visible.minY - full.minY)
        case .left: replacing ? 0 : Double(visible.minX - full.minX)
        case .right: replacing ? 0 : Double(full.maxX - visible.maxX)
        }
        return max(inset, 0) + max(gap, 0) + max(bar, 0) + max(margin, 0)
    }

    /// The visible frame less the dock's band. Without a band, or with one that would leave less
    /// than `smallest` points, the visible frame as it is.
    public static func rect(full: CGRect, visible: CGRect, band: Band?) -> CGRect {
        guard let band, band.thickness > 0, band.thickness.isFinite else { return visible }
        var r = visible
        let t = CGFloat(band.thickness)
        switch band.edge {
        case .bottom:
            let floor = max(visible.minY, full.minY + t)
            r = CGRect(x: visible.minX, y: floor, width: visible.width, height: visible.maxY - floor)
        case .top:
            let ceiling = min(visible.maxY, full.maxY - t)
            r = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: ceiling - visible.minY)
        case .left:
            let side = max(visible.minX, full.minX + t)
            r = CGRect(x: side, y: visible.minY, width: visible.maxX - side, height: visible.height)
        case .right:
            let side = min(visible.maxX, full.maxX - t)
            r = CGRect(x: visible.minX, y: visible.minY, width: side - visible.minX, height: visible.height)
        }
        guard r.width >= smallest, r.height >= smallest else { return visible }
        return r
    }
}
