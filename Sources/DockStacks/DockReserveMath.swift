import CoreGraphics
import Foundation

// Reserve Dock Space as values and geometry only: no AppKit, no Accessibility, so the rule
// that decides how a window is fitted can be tested on its own.

// MARK: - Prefs

struct DockReservePrefs: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case reserve, overlap
        var id: String { rawValue }
        var title: String { self == .reserve ? "Reserve Dock Space" : "Overlap the Dock" }
    }
    var mode = Mode.reserve
    /// Reserve even while the dock auto-hides.
    var whileHidden = false
    /// Points kept free between a window and the bar.
    var margin = 4.0
    /// Bundle identifiers of apps whose windows are never fitted.
    var exceptions: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case mode, whileHidden, margin, exceptions }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .reserve
        whileHidden = (try? c.decodeIfPresent(Bool.self, forKey: .whileHidden)) ?? false
        margin = min(max((try? c.decodeIfPresent(Double.self, forKey: .margin)) ?? 4, 0), 24)
        exceptions = (try? c.decodeIfPresent([String].self, forKey: .exceptions)) ?? []
    }
}

// MARK: - Geometry

/// The screen the dock is on, in Accessibility coordinates: origin at the top left of the
/// main display, y growing down.
struct DockReserveScreen: Equatable, Sendable {
    var full: CGRect
    var visible: CGRect
    var edge: OwnDockEdge
    /// From the screen edge to the far side of the bar, plus the margin.
    var thickness: Double
}

/// Pure, so it is tested without windows.
enum DockReserveMath {
    /// How far from the visible edge still counts as placed against it (zoom, tiling).
    static let flushTolerance = 6.0
    static let smallest = 60.0

    /// The frame `window` should have, or nil to leave it. `resized` says the window's size
    /// changed during the drag that just ended, so it is shrunk rather than moved.
    static func fit(_ window: CGRect, on screen: DockReserveScreen, resized: Bool = false) -> CGRect? {
        let edge = screen.edge
        let w = canon(window, edge), full = canon(screen.full, edge), visible = canon(screen.visible, edge)
        let bandTop = full.maxY - screen.thickness
        let bottom = min(visible.maxY, bandTop)
        // Clear of the band, or wholly in it: nothing to fit.
        guard w.maxY > bandTop + 0.5, w.minY < bandTop else { return nil }
        guard full.contains(CGPoint(x: w.midX, y: w.midY)) else { return nil }
        // A window as big as the screen is full screen in all but name.
        if w.width >= full.width - 1, w.height >= full.height - 1 { return nil }
        // Pushed past the screen edge on purpose: parked, not maximised.
        if w.maxY > full.maxY + flushTolerance { return nil }
        let top = visible.minY
        let room = bottom - top
        guard room >= smallest else { return nil }
        let flush = abs(w.maxY - visible.maxY) <= flushTolerance
        let tall = w.height > room + 0.5
        var r = w
        if flush || tall || resized {
            r.origin.y = max(w.minY, top)
            r.size.height = bottom - r.minY
        } else {
            r.origin.y = bottom - w.height
            if r.minY < top {
                r.origin.y = top
                r.size.height = room
            }
        }
        guard r.height >= smallest else { return nil }
        guard abs(r.minY - w.minY) > 0.5 || abs(r.height - w.height) > 0.5 else { return nil }
        return uncanon(r, edge)
    }

    /// Turns any edge into the bottom one, so the rule is written once.
    static func canon(_ r: CGRect, _ edge: OwnDockEdge) -> CGRect {
        switch edge {
        case .bottom: r
        case .top: CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height)
        case .left: CGRect(x: r.minY, y: -r.maxX, width: r.height, height: r.width)
        case .right: CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
        }
    }

    static func uncanon(_ c: CGRect, _ edge: OwnDockEdge) -> CGRect {
        switch edge {
        case .bottom: c
        case .top: CGRect(x: c.minX, y: -c.maxY, width: c.width, height: c.height)
        case .left: CGRect(x: -c.maxY, y: c.minX, width: c.height, height: c.width)
        case .right: CGRect(x: c.minY, y: c.minX, width: c.height, height: c.width)
        }
    }

    /// AppKit's bottom-left screen rect in Accessibility's top-left coordinates.
    static func ax(_ rect: CGRect, mainHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

