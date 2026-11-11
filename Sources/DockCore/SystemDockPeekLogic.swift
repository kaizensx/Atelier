import CoreGraphics
import Foundation

// MARK: - Dock Peek for the macOS Dock: the pure part
//
// Everything Dock Peek decides without touching AppKit or Accessibility: where the card goes
// beside a Dock icon, when hovering has lasted long enough to show it and when leaving has
// lasted long enough to hide it, which trackpad or wheel movement over an icon counts as a
// gesture, and the two-step confirm before a pinch quits an app.
//
// Coordinates are the global, top-left-origin ones Accessibility reports (AXPosition, AXSize,
// AXFrame) and CGEvent locations use: y grows downward from the top of the primary display.

/// Which edge the macOS Dock sits on, from `com.apple.dock orientation`.
public enum SystemDockOrientation: String, CaseIterable, Sendable {
    case bottom, left, right

    /// The preference value; anything missing or unknown is the default, the bottom.
    public init(preference: String?) {
        self = preference.flatMap(SystemDockOrientation.init(rawValue:)) ?? .bottom
    }

    public var horizontal: Bool { self == .bottom }
}

// MARK: - Placement

/// Where the card sits, and where along its dock-side edge the notch points at the icon.
public struct SystemDockCardPlacement: Equatable, Sendable {
    public var frame: CGRect
    /// Along the card's dock-side edge, in card points from its leading (left or top) corner.
    public var notch: Double

    public init(frame: CGRect, notch: Double) {
        self.frame = frame
        self.notch = notch
    }
}

public enum SystemDockPeekPlacement {
    /// The card beside `icon`, on the side away from the Dock, centred on the icon and kept
    /// inside `bounds` (the screen less the menu bar). Only clamping at a screen edge moves the
    /// card off centre; the notch keeps pointing at the icon then, never closer to a corner
    /// than `corner`.
    public static func place(card: CGSize, icon: CGRect, bounds: CGRect, orientation: SystemDockOrientation,
                             gap: Double = 10, margin: Double = 8, corner: Double = 27) -> SystemDockCardPlacement {
        let width = Double(card.width), height = Double(card.height)
        var x: Double, y: Double
        switch orientation {
        case .bottom:
            x = clamp(icon.midX - width / 2, bounds.minX + margin, bounds.maxX - margin - width)
            y = max(icon.minY - gap - height, bounds.minY + margin)
        case .left:
            x = min(icon.maxX + gap, bounds.maxX - margin - width)
            y = clamp(icon.midY - height / 2, bounds.minY + margin, bounds.maxY - margin - height)
        case .right:
            x = max(icon.minX - gap - width, bounds.minX + margin)
            y = clamp(icon.midY - height / 2, bounds.minY + margin, bounds.maxY - margin - height)
        }
        x = x.rounded()
        y = y.rounded()
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let notch = orientation.horizontal
            ? clamp(icon.midX - x, corner, width - corner)
            : clamp(icon.midY - y, corner, height - corner)
        return SystemDockCardPlacement(frame: frame, notch: notch)
    }

    /// The edge the Dock is on, guessed from where the icon sits on its screen, for when the
    /// preference cannot be read.
    public static func orientation(icon: CGRect, screen: CGRect) -> SystemDockOrientation {
        let bottom = screen.maxY - icon.maxY, left = icon.minX - screen.minX, right = screen.maxX - icon.maxX
        if left < bottom, left <= right { return .left }
        if right < bottom, right < left { return .right }
        return .bottom
    }

    /// Converts a top-left-origin global rect to AppKit's bottom-left-origin one, given the
    /// primary display's height.
    public static func flipped(_ rect: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        high < low ? (low + high) / 2 : min(max(value, low), high)
    }
}

// MARK: - Hit testing

public enum SystemDockHit {
    /// The icon under `point`, from the icon frames as the Dock reported them. `slop` widens
    /// each frame a little, since magnification moves them between two reads.
    public static func index(at point: CGPoint, in frames: [CGRect], slop: Double = 2) -> Int? {
        frames.firstIndex { $0.width > 0 && $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }
}

// MARK: - Hover

/// When the card shows and hides. Fed the icon the Dock reports as hovered (its selected child),
/// whether the pointer is in the card, and the clock. Never reads the clock itself.
///
/// - A fresh hover waits `delay` before the card shows, so sweeping across the Dock shows nothing.
/// - Once a card shows, moving to another icon switches at once: the hover has been earned.
/// - Leaving the icon keeps the card `grace` seconds, time to reach the card; inside the card it
///   stays as long as the pointer does. The Dock also clears its selection for an instant between
///   two neighbouring icons, which the grace absorbs.
/// - `dismiss()` (a click on the icon, an action in the card) hides it until another icon is hovered.
public struct SystemDockHoverMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case waiting(icon: String, since: Double)
        case showing(icon: String)
        case leaving(icon: String, since: Double)
        case suppressed(icon: String)
    }

    public var delay: Double
    public var grace: Double
    public private(set) var phase = Phase.idle
    public private(set) var inCard = false
    /// The icon under the pointer right now, as last reported.
    public private(set) var hovered: String?

    public init(delay: Double = 0.3, grace: Double = 0.32) {
        self.delay = delay
        self.grace = grace
    }

    /// The icon whose card is on screen.
    public var shown: String? {
        switch phase {
        case .showing(let icon), .leaving(let icon, _): icon
        default: nil
        }
    }

    /// When `tick` next has something to do.
    public var deadline: Double? {
        switch phase {
        case .waiting(_, let since): since + delay
        case .leaving(_, let since): inCard ? nil : since + grace
        default: nil
        }
    }

    public mutating func hover(_ icon: String?, at now: Double) {
        hovered = icon
        switch phase {
        case .idle:
            if let icon { phase = .waiting(icon: icon, since: now) }
        case .waiting(let current, _):
            if let icon { if icon != current { phase = .waiting(icon: icon, since: now) } } else { phase = .idle }
        case .showing(let current):
            if let icon { if icon != current { phase = .showing(icon: icon) } }
            else if !inCard { phase = .leaving(icon: current, since: now) }
        case .leaving:
            if let icon { phase = .showing(icon: icon) }
        case .suppressed(let current):
            if let icon { if icon != current { phase = .waiting(icon: icon, since: now) } } else { phase = .idle }
        }
        tick(at: now)
    }

    public mutating func card(inside: Bool, at now: Double) {
        inCard = inside
        switch phase {
        case .leaving(let icon, _) where inside:
            phase = .showing(icon: icon)
        case .showing(let icon) where !inside && hovered == nil:
            phase = .leaving(icon: icon, since: now)
        default:
            break
        }
    }

    public mutating func tick(at now: Double) {
        switch phase {
        case .waiting(let icon, let since) where now - since >= delay:
            phase = .showing(icon: icon)
        case .leaving(_, let since) where !inCard && now - since >= grace:
            phase = .idle
        default:
            break
        }
    }

    /// Hides the card until the pointer moves to another icon (or off the Dock and back).
    public mutating func dismiss() {
        inCard = false
        phase = hovered.map { .suppressed(icon: $0) } ?? .idle
    }
}

// MARK: - Gestures

/// What a gesture over a Dock icon does to that icon's app. Raw values are stable: settings and
/// `atelier://dockpeek?simulate=` use them.
public enum SystemDockGesture: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Two-finger swipe down: minimise the app's front window.
    case minimize
    /// Two-finger swipe up: bring back its minimised window.
    case restore
    /// Pinch in: quit the app, after a confirm.
    case quit
    /// Mouse wheel up: hide the app.
    case hide
    /// Mouse wheel down: show the app again.
    case show

    public var id: String { rawValue }
}

/// A scroll event's phase, from either `scrollPhase` (the fingers) or `momentumPhase`.
public enum SystemDockScrollPhase: Sendable {
    /// A wheel click, or a continuous device that reports no phase.
    case none
    case began, changed, ended
    /// The glide after the fingers lift. Never a gesture: it would fire on the next icon too.
    case momentum
}

/// Turns raw scroll and magnify events over one icon into at most one gesture each.
///
/// `upward` is the movement in the device's own sense, positive when fingers (or the wheel)
/// move away from the person, whatever Natural Scrolling says; the live side undoes the
/// inversion with `isDirectionInvertedFromDevice`. `sideways` is the other axis, used only to
/// keep a sideways swipe from counting.
public struct SystemDockGestureClassifier: Equatable, Sendable {
    /// Points of finger travel before a swipe counts.
    public var swipeDistance = 28.0
    /// The vertical travel must be this many times the sideways travel.
    public var axisDominance = 1.5
    /// Total magnification (negative is pinching in) before a pinch counts.
    public var pinchThreshold = 0.25
    /// A continuous scroll with no phase that pauses this long starts a fresh gesture.
    public var idleReset = 0.35
    /// Wheel clicks closer than this are one turn of the wheel.
    public var wheelCooldown = 0.35

    private var up = 0.0, side = 0.0
    private var fired = false
    private var last = -Double.infinity
    private var pinch = 0.0
    private var pinchFired = false
    private var lastWheel = -Double.infinity

    public init() {}

    public mutating func scroll(upward: Double, sideways: Double, continuous: Bool,
                                phase: SystemDockScrollPhase, at now: Double) -> SystemDockGesture? {
        guard continuous else {
            guard upward != 0, abs(upward) >= abs(sideways), now - lastWheel >= wheelCooldown else { return nil }
            lastWheel = now
            return upward > 0 ? .hide : .show
        }
        switch phase {
        case .momentum:
            return nil
        case .ended:
            reset()
            return nil
        case .began:
            reset()
        case .changed, .none:
            if now - last > idleReset { reset() }
        }
        last = now
        up += upward
        side += sideways
        guard !fired, abs(up) >= swipeDistance, abs(up) >= abs(side) * axisDominance else { return nil }
        fired = true
        return up > 0 ? .restore : .minimize
    }

    public mutating func magnify(_ delta: Double, phase: SystemDockScrollPhase, at now: Double) -> SystemDockGesture? {
        switch phase {
        case .began:
            pinch = 0
            pinchFired = false
        case .ended, .momentum:
            pinch = 0
            pinchFired = false
            return nil
        case .changed, .none:
            break
        }
        pinch += delta
        guard !pinchFired, pinch <= -pinchThreshold else { return nil }
        pinchFired = true
        return .quit
    }

    /// The pointer left the icon: whatever was building up there is dropped.
    public mutating func reset() {
        up = 0
        side = 0
        fired = false
        last = -Double.infinity
    }
}

/// Pinch-in quits only when asked twice: the first pinch arms the confirm (the card says
/// "Pinch again to quit"), a second pinch on the same app within `window` seconds quits.
public struct SystemDockQuitConfirm: Equatable, Sendable {
    public var window: Double
    public private(set) var armed: (app: String, at: Double)?

    public init(window: Double = 2.5) { self.window = window }

    public static func == (a: Self, b: Self) -> Bool {
        a.window == b.window && a.armed?.app == b.armed?.app && a.armed?.at == b.armed?.at
    }

    /// True when this pinch should quit `app` now.
    public mutating func pinch(_ app: String, at now: Double) -> Bool {
        if isArmed(app, at: now) {
            armed = nil
            return true
        }
        armed = (app, now)
        return false
    }

    public func isArmed(_ app: String, at now: Double) -> Bool {
        guard let armed else { return false }
        return armed.app == app && now - armed.at <= window
    }

    public mutating func cancel() { armed = nil }
}
