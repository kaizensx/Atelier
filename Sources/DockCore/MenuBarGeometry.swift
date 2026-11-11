import CoreGraphics

/// Where the real menu bar is on one display, from the values NSScreen reports. AppKit screen
/// coordinates: origin bottom left, y up.
///
/// The bar's height is `frame.maxY - visibleFrame.maxY`: the visible frame ends exactly at the
/// bar's lower edge. Neither `safeAreaInsets.top` (the notch, 1 point short on a MacBook Pro)
/// nor `NSStatusBar.system.thickness` (a legacy 22) is the bar's height.
public struct MenuBarGeometry: Equatable, Sendable {
    /// The strip the menu bar occupies.
    public var bar: CGRect
    /// The camera housing, inside `bar`, or nil on a display without one.
    public var notch: CGRect?
    /// False while the bar is hidden (Automatically Hide the Menu Bar): then nothing reserves the strip.
    public var shown: Bool

    public init(frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?, fallback: CGFloat = 24) {
        let gap = frame.maxY - visibleFrame.maxY
        shown = gap > 0.5
        let height = shown ? gap : max(safeTop, fallback)
        bar = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if let left = leftArea, let right = rightArea, right.minX - left.maxX > 1 {
            let depth = max(left.height, safeTop)
            notch = CGRect(x: left.maxX, y: frame.maxY - depth, width: right.minX - left.maxX, height: depth)
        } else {
            notch = nil
        }
    }

    /// The bar's own frame with room below it for a shadow. The shadow area overlaps nothing that
    /// can be clicked: the skin ignores the mouse.
    public func panelFrame(shadow: CGFloat) -> CGRect {
        CGRect(x: bar.minX, y: bar.minY - shadow, width: bar.width, height: bar.height + shadow)
    }

    /// The notch in the skin's own coordinates: origin top left, as SwiftUI draws.
    public func notchInBar() -> CGRect? {
        guard let notch else { return nil }
        return CGRect(x: notch.minX - bar.minX, y: bar.maxY - notch.maxY, width: notch.width, height: notch.height)
    }

    /// A floating bar: inset from the screen edges, with ends rounded into a capsule.
    public static func floating(_ size: CGSize, inset: CGFloat = 6) -> CGRect {
        let vertical = min(3, max(size.height * 0.08, 1))
        return CGRect(x: inset, y: vertical, width: max(size.width - inset * 2, 0), height: max(size.height - vertical * 2, 0))
    }
}

/// How well a skin painted behind the menu bar can show on a given release.
///
/// macOS 26 draws the menu bar with no background of its own, so a window one level below it
/// shows through untouched. macOS 14 and 15 draw a translucent backdrop over whatever sits
/// behind the bar, so the skin shows through softened; with Reduce Transparency that backdrop
/// is opaque and covers the skin entirely.
public enum MenuBarSkinSupport: Equatable, Sendable {
    case full
    /// It shows, with a limit worth saying.
    case softened(String)
    /// Nothing of it can be seen.
    case covered(String)

    public var note: String? {
        switch self {
        case .full: nil
        case let .softened(text), let .covered(text): text
        }
    }

    public static func evaluate(major: Int, reduceTransparency: Bool, anyNotch: Bool, notchSkin: Bool) -> MenuBarSkinSupport {
        if major < 26 {
            if reduceTransparency {
                return .covered("Reduce Transparency makes macOS \(major)'s menu bar opaque, which covers the skin")
            }
            return .softened("macOS \(major) lays its own translucent bar over the skin, so colours look softer")
        }
        if notchSkin && !anyNotch { return .softened("No display here has a notch; this skin is a plain black bar") }
        return .full
    }
}
