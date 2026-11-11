import CoreGraphics
import Foundation

// MARK: - Focus Follows Mouse, the parts that need no screen
//
// Deciding when the pointer has come to rest, and whether what lies under it is a window that
// may be brought forward, are plain rules. They live here so they can be tested without
// Accessibility, a window server or a mouse.

/// Watches the pointer and says when it has rested in one place for long enough.
///
/// The pointer counts as resting while it stays within `tolerance` points of where it last
/// stopped; a hand on a mouse is never perfectly still, and a few points of drift must not
/// restart the wait. Any larger move sets a new anchor and the wait begins again, so a pointer
/// that is only crossing a window on its way elsewhere never rests long enough to raise it.
public struct PointerRest: Sendable, Equatable {
    public var delay: TimeInterval
    public var tolerance: CGFloat
    /// Where the pointer last stopped, and when it got there.
    public private(set) var anchor: CGPoint?
    public private(set) var since: TimeInterval = 0
    /// Bumped each time the anchor moves, so work begun for an older rest can tell it is stale.
    public private(set) var generation = 0
    /// Set once a rest has been acted on, so one rest raises at most one window.
    public private(set) var spent = false

    public init(delay: TimeInterval, tolerance: CGFloat = 4) {
        self.delay = delay
        self.tolerance = tolerance
    }

    /// Records a pointer position. Returns true when it started a new rest, which is the
    /// caller's cue to wait `delay` seconds and then ask `isRested`.
    @discardableResult
    public mutating func move(to point: CGPoint, at time: TimeInterval) -> Bool {
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= tolerance { return false }
        anchor = point
        since = time
        generation += 1
        spent = false
        return true
    }

    /// Whether the pointer has been still for the whole delay, and that rest has not been used.
    public func isRested(at time: TimeInterval) -> Bool {
        anchor != nil && !spent && time - since >= delay - 0.005
    }

    /// When the current rest will be long enough, for scheduling a single timer.
    public var due: TimeInterval { since + delay }

    public mutating func spend() { spent = true }
}

public enum FocusFollowsRules {
    /// Roles that mean the pointer is over something that floats on a window rather than the
    /// window itself: a menu, a sheet, a popover. Raising from there would yank the window out
    /// from under a choice the person is making.
    public static let blockingRoles: Set<String> = [
        "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXSheet", "AXPopover", "AXDrawer",
        "AXSystemDialog", "AXDockItem",
    ]

    /// Given the roles from the element under the pointer up through its parents (the element
    /// first), the index of the window that owns it, or nil when there is none or something in
    /// between rules it out.
    public static func windowIndex(inChain roles: [String]) -> Int? {
        for (index, role) in roles.enumerated() {
            if role == "AXWindow" { return index }
            if blockingRoles.contains(role) || role == "AXApplication" { return nil }
        }
        return nil
    }

    /// Whether a window may be raised: an ordinary document window, on screen and not taking
    /// a whole space of its own. Dialogs, floating panels and the desktop all have other subroles.
    public static func isRaisable(role: String?, subrole: String?, minimized: Bool, fullScreen: Bool) -> Bool {
        role == "AXWindow" && subrole == "AXStandardWindow" && !minimized && !fullScreen
    }

    /// Whether the person is doing something the pointer's resting must not interrupt: holding
    /// a mouse button (dragging, selecting) or the pause key.
    public static func isPaused(buttonsDown: Int, controlHeld: Bool, pauseWithControl: Bool) -> Bool {
        buttonsDown != 0 || (pauseWithControl && controlHeld)
    }

    /// Clamps a delay to what the setting allows.
    public static func clampDelay(_ value: Double) -> Double { min(max(value, 0.1), 1.0) }

    /// One window as the window server lists it, front to back.
    public struct Listed: Sendable, Equatable {
        public let number: Int
        public let pid: Int32
        public let layer: Int
        public let alpha: Double
        /// Screen points, top-left origin.
        public let bounds: CGRect

        public init(number: Int, pid: Int32, layer: Int, alpha: Double, bounds: CGRect) {
            self.number = number
            self.pid = pid
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }
    }

    /// What the pointer sees through the window list.
    public enum Under: Equatable, Sendable {
        /// An ordinary window of another app, which may be raised.
        case window(Listed)
        /// Nothing but the desktop.
        case desktop
        /// Something above the ordinary windows: the menu bar, the Dock, an open menu,
        /// Mission Control, Notification Center.
        case system
        /// One of Atelier's own windows that takes clicks.
        case own
    }

    /// The topmost window under a point, skipping Atelier's click-through panels (which the
    /// pointer passes through) and windows faded to nothing.
    ///
    /// `hit` is the window the window server itself would hand a click at that point, or 0
    /// when unknown. It sees through every click-through overlay, other apps' included (a
    /// full-screen effect layer from another app would otherwise hide every window below it),
    /// so when it is known it decides.
    public static func under(_ point: CGPoint, in list: [Listed], ownPID: Int32, passThrough: Set<Int>, hit: Int = 0) -> Under {
        if hit != 0, let window = list.first(where: { $0.number == hit }) {
            if window.pid == ownPID { return passThrough.contains(window.number) ? .desktop : .own }
            return window.layer == 0 ? .window(window) : .system
        }
        for window in list where window.bounds.contains(point) && window.alpha > 0.01 {
            if window.pid == ownPID {
                if passThrough.contains(window.number) { continue }
                return .own
            }
            return window.layer == 0 ? .window(window) : .system
        }
        return .desktop
    }

    /// Whether a menu is open anywhere: pop-up menus sit on their own window layer. While one
    /// is open, raising anything would close it.
    public static func menuOpen(in list: [Listed]) -> Bool {
        list.contains { $0.layer == 101 && $0.alpha > 0.01 }
    }
}
