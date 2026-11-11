import CoreGraphics
import Foundation

/// The arithmetic behind Move & Resize Anywhere, kept apart from Accessibility so it can be
/// tested. Every rectangle is in global screen coordinates with the origin at the top left of
/// the primary display and y growing downward, the space both Accessibility and CGEvent use.
public enum GrabGeometry {
    /// The modifier keys that turn a click into a grab.
    public enum Chord: String, CaseIterable, Sendable {
        case controlCommand
        case optionCommand
        case controlOption

        /// The symbols as macOS writes them in menus, in its own order: ⌃ ⌥ ⇧ ⌘.
        public var symbols: String {
            switch self {
            case .controlCommand: "⌃⌘"
            case .optionCommand: "⌥⌘"
            case .controlOption: "⌃⌥"
            }
        }

        public var flags: CGEventFlags {
            switch self {
            case .controlCommand: [.maskControl, .maskCommand]
            case .optionCommand: [.maskAlternate, .maskCommand]
            case .controlOption: [.maskControl, .maskAlternate]
            }
        }

        /// True when exactly this chord is held. Shift or a third modifier means the person
        /// is reaching for some other shortcut, so the click is left to the app.
        public func isHeld(in flags: CGEventFlags) -> Bool {
            let watched: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            return flags.intersection(watched) == self.flags
        }
    }

    /// The corner a resize pulls: the one nearest the point where the window was grabbed.
    public struct Corner: Equatable, Sendable {
        public var right: Bool
        public var bottom: Bool

        public init(right: Bool, bottom: Bool) {
            self.right = right
            self.bottom = bottom
        }
    }

    /// The corner of the quadrant that holds `point`. The exact middle counts as bottom
    /// right, the corner people reach for most.
    public static func corner(for point: CGPoint, in frame: CGRect) -> Corner {
        Corner(right: point.x >= frame.midX, bottom: point.y >= frame.midY)
    }

    /// Where the window goes when the pointer has travelled `delta` since the grab.
    public static func moved(_ start: CGRect, by delta: CGVector) -> CGRect {
        start.offsetBy(dx: delta.dx, dy: delta.dy)
    }

    /// The frame after pulling `corner` by `delta`. The opposite corner stays put, and the
    /// size never drops below `minimum`, so a pull past the far edge stops at the smallest
    /// window rather than turning it inside out.
    public static func resized(_ start: CGRect, corner: Corner, by delta: CGVector, minimum: CGSize) -> CGRect {
        let width = max(minimum.width, start.width + (corner.right ? delta.dx : -delta.dx))
        let height = max(minimum.height, start.height + (corner.bottom ? delta.dy : -delta.dy))
        let size = CGSize(width: width, height: height)
        return CGRect(origin: anchoredOrigin(start, corner: corner, size: size), size: size)
    }

    /// The origin that keeps the corner opposite `corner` where it was in `start` for a
    /// window of `size`. Used again once the app has answered with the size it really took,
    /// because an app with a larger minimum than ours would otherwise drift sideways.
    public static func anchoredOrigin(_ start: CGRect, corner: Corner, size: CGSize) -> CGPoint {
        CGPoint(x: corner.right ? start.minX : start.maxX - size.width,
                y: corner.bottom ? start.minY : start.maxY - size.height)
    }

    /// Raises a learnt minimum when the app refused a smaller size. A dimension only grows,
    /// and only when the app gave back more than was asked for.
    public static func learnMinimum(_ minimum: CGSize, asked: CGSize, got: CGSize) -> CGSize {
        CGSize(width: got.width > asked.width + 0.5 ? max(minimum.width, got.width) : minimum.width,
               height: got.height > asked.height + 0.5 ? max(minimum.height, got.height) : minimum.height)
    }
}
