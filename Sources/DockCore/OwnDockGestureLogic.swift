import CoreGraphics
import Foundation

// MARK: - Gestures & Peek for the Atelier Dock: the pure part
//
// The Atelier Dock already has Live Peek and Scroll for Windows. This adds what the macOS Dock
// version (`SystemDockPeekLogic`) has: swipe and pinch on an app's tile, and close and minimise
// buttons on the window pictures. The gesture itself is still recognised by
// `SystemDockGestureClassifier`; this file only decides which scroll events are a swipe and
// which are Scroll for Windows, what each gesture does here, and where the buttons sit.

/// What a gesture on an Atelier Dock tile does to its app. Raw values are stable: settings and
/// `atelier://dockgestures` use them.
public enum OwnDockGestureAction: String, CaseIterable, Codable, Sendable, Identifiable {
    /// App Exposé for that app: all its windows, spread out.
    case expose
    /// Bring back its newest minimised window.
    case restore
    /// Minimise its front window.
    case minimize
    /// Hide the whole app.
    case hide
    /// Quit it, after a second pinch.
    case quit
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .expose: "App Exposé"
        case .restore: "Restore window"
        case .minimize: "Minimise window"
        case .hide: "Hide app"
        case .quit: "Quit"
        case .none: "Nothing"
        }
    }
}

/// The three gestures, under the names the test hook uses.
public enum OwnDockGestureKind: String, CaseIterable, Sendable {
    case swipeUp, swipeDown, pinch

    /// The classifier's answer, renamed: up is its `.restore`, down its `.minimize`.
    public init?(_ gesture: SystemDockGesture) {
        switch gesture {
        case .restore: self = .swipeUp
        case .minimize: self = .swipeDown
        case .quit: self = .pinch
        case .hide, .show: return nil
        }
    }
}

/// Which action each gesture is set to.
public struct OwnDockGestureSettings: Equatable, Sendable {
    public var up: OwnDockGestureAction
    public var down: OwnDockGestureAction
    /// Pinch to quit. Off unless asked for; even on, it needs a second pinch.
    public var pinch: Bool

    public init(up: OwnDockGestureAction = .expose, down: OwnDockGestureAction = .minimize, pinch: Bool = false) {
        self.up = up
        self.down = down
        self.pinch = pinch
    }

    /// The choices offered for each swipe.
    public static let upChoices: [OwnDockGestureAction] = [.expose, .restore, .none]
    public static let downChoices: [OwnDockGestureAction] = [.minimize, .hide, .none]

    public func action(_ kind: OwnDockGestureKind) -> OwnDockGestureAction {
        switch kind {
        case .swipeUp: up
        case .swipeDown: down
        case .pinch: pinch ? .quit : .none
        }
    }

    /// Any vertical swipe acts: only then are vertical scrolls taken from Scroll for Windows.
    public var swipes: Bool { up != .none || down != .none }
}

// MARK: - Swipe or scroll

/// Splits two-finger scrolling on a tile between the swipe gestures and Scroll for Windows.
///
/// A trackpad scroll is locked to one axis once the fingers have moved `lock` points: mostly
/// vertical is a swipe (up or down), mostly sideways stays Scroll for Windows. Until the lock,
/// events are held back from both, so a sideways scroll never fires a swipe and a swipe never
/// steps through windows. A mouse wheel (no fine deltas) always stays Scroll for Windows, and so
/// does everything when no swipe is set.
public struct OwnDockSwipeRouter: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        /// The swipe gesture takes it (feed the classifier, swallow the event).
        case swipe
        /// Not decided yet: swallow it, feed no one.
        case hold
        /// Scroll for Windows takes it, as before.
        case scroll
    }

    enum Axis: Equatable, Sendable { case vertical, sideways }

    /// Points of travel before the axis is decided.
    public var lock = 6.0
    /// Vertical must be this many times the sideways travel to be a swipe.
    public var dominance = 1.2
    /// A phaseless continuous scroll that pauses this long starts over.
    public var idleReset = 0.35

    private var axis: Axis?
    private var up = 0.0, side = 0.0
    private var last = -Double.infinity

    public init() {}

    public mutating func route(dx: Double, dy: Double, continuous: Bool, phase: SystemDockScrollPhase,
                               swipes: Bool, at now: Double) -> Route {
        guard swipes, continuous else { return .scroll }
        switch phase {
        case .momentum:
            // The glide after a swipe belongs to it; after a sideways scroll it is Scroll for
            // Windows' (which ignores momentum anyway).
            return axis == .vertical ? .swipe : .scroll
        case .began:
            reset()
        case .ended:
            let was = axis
            reset()
            return was == .sideways ? .scroll : .swipe
        case .changed, .none:
            if now - last > idleReset { reset() }
        }
        last = now
        if let axis { return axis == .vertical ? .swipe : .scroll }
        up += abs(dy)
        side += abs(dx)
        guard max(up, side) >= lock else { return .hold }
        axis = up >= side * dominance ? .vertical : .sideways
        return axis == .vertical ? .swipe : .scroll
    }

    public mutating func reset() {
        axis = nil
        up = 0
        side = 0
        last = -Double.infinity
    }

    /// The current sequence is a swipe.
    public var locked: Bool { axis == .vertical }
}

// MARK: - Buttons on the window pictures

/// The close and minimise buttons on the picture under the pointer, in the same coordinates as
/// the picture's cell (`DockPeekLayout.cellFrame`): top trailing corner, close outermost.
public enum OwnDockPeekButtons {
    public static let size = 20.0
    public static let inset = 6.0
    public static let gap = 5.0

    public enum Button: String, Equatable, Sendable { case close, minimize }

    /// Close always; minimise only for a window that is not minimised already.
    public static func rects(cell: CGRect, minimized: Bool) -> [(Button, CGRect)] {
        let close = CGRect(x: cell.maxX - inset - size, y: cell.minY + inset, width: size, height: size)
        guard !minimized else { return [(.close, close)] }
        let minimize = close.offsetBy(dx: -(size + gap), dy: 0)
        return [(.minimize, minimize), (.close, close)]
    }

    /// The button under `point`, with a few points of slop: they are small.
    public static func hit(_ point: CGPoint, cell: CGRect, minimized: Bool, slop: Double = 3) -> Button? {
        rects(cell: cell, minimized: minimized).first { $0.1.insetBy(dx: -slop, dy: -slop).contains(point) }?.0
    }
}
