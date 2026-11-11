import CoreGraphics
import Foundation

// MARK: - Title Bar Gestures, the pure part
//
// Swish-style window gestures: two fingers on the trackpad while the pointer rests on a window's
// title bar. Swipe left or right tiles the window to that half (again: on to the next display),
// up maximises (again: native full screen), down restores or centres (again: minimises), a pinch
// in closes and a pinch out goes full screen; the four diagonals take the quarters.
//
// Everything here is free of AppKit, Accessibility and MultitouchSupport, so every threshold and
// every frame can be tested: the recogniser reads the same `TouchFrame`s the trackpad sensor
// delivers (see TrackpadGestureLogic.swift for the coordinate conventions: x 0 left → 1 right,
// y 0 near edge → 1 far edge), and the planner turns a gesture into a target frame in
// Accessibility coordinates (origin top left of the primary display, y growing downward).

/// One of the title-bar gestures. Raw values are stable: they are stored in settings and used by
/// `atelier://titlebar?simulate=`.
public enum TitleBarGesture: String, CaseIterable, Codable, Sendable, Identifiable {
    case left, right, up, down, topLeft, topRight, bottomLeft, bottomRight, pinchIn, pinchOut

    public var id: String { rawValue }

    public var isPinch: Bool { self == .pinchIn || self == .pinchOut }
    public var isDiagonal: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }

    /// The fingers' direction of travel on the trackpad, y up (towards the far edge). Zero for pinches.
    public var vector: (dx: Double, dy: Double) {
        let d = 0.7071067811865476
        switch self {
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .up: return (0, 1)
        case .down: return (0, -1)
        case .topLeft: return (-d, d)
        case .topRight: return (d, d)
        case .bottomLeft: return (-d, -d)
        case .bottomRight: return (d, -d)
        case .pinchIn, .pinchOut: return (0, 0)
        }
    }
}

/// What a gesture can do to the window under the pointer.
public enum TitleBarAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, restore
    /// The display to the left or right, taking the half that faces back (the swipe continues).
    case displayLeft, displayRight
    /// The next display in order, keeping the window's place and proportion on it.
    case nextDisplay
    case minimize, fullScreen, close

    public var id: String { rawValue }

    /// The tile this action takes, for the actions that are a tile on the current display.
    public var tile: TitleBarTile? {
        switch self {
        case .leftHalf: .leftHalf
        case .rightHalf: .rightHalf
        case .topHalf: .topHalf
        case .bottomHalf: .bottomHalf
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        case .maximize: .maximize
        default: nil
        }
    }
}

/// The cells a window can take on one display.
public enum TitleBarTile: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight, maximize

    /// (first column, columns, first row, rows): every tile is one cell of a 1–2 × 1–2 grid.
    var cell: (Int, Int, Int, Int) {
        switch self {
        case .leftHalf: (0, 2, 0, 1)
        case .rightHalf: (1, 2, 0, 1)
        case .topHalf: (0, 1, 0, 2)
        case .bottomHalf: (0, 1, 1, 2)
        case .topLeft: (0, 2, 0, 2)
        case .topRight: (1, 2, 0, 2)
        case .bottomLeft: (0, 2, 1, 2)
        case .bottomRight: (1, 2, 1, 2)
        case .maximize: (0, 1, 0, 1)
        }
    }
}

/// What one gesture does: the first time, and again when the window already sits where the first
/// time put it (the repeated-swipe cycle).
public struct TitleBarBinding: Codable, Equatable, Sendable {
    public var first: TitleBarAction
    public var again: TitleBarAction

    public init(_ first: TitleBarAction, again: TitleBarAction = .none) {
        self.first = first
        self.again = again
    }

    /// Swish's defaults.
    public static func standard(_ gesture: TitleBarGesture) -> TitleBarBinding {
        switch gesture {
        case .left: TitleBarBinding(.leftHalf, again: .displayLeft)
        case .right: TitleBarBinding(.rightHalf, again: .displayRight)
        case .up: TitleBarBinding(.maximize, again: .fullScreen)
        case .down: TitleBarBinding(.restore, again: .minimize)
        case .topLeft: TitleBarBinding(.topLeft)
        case .topRight: TitleBarBinding(.topRight)
        case .bottomLeft: TitleBarBinding(.bottomLeft)
        case .bottomRight: TitleBarBinding(.bottomRight)
        case .pinchIn: TitleBarBinding(.close)
        case .pinchOut: TitleBarBinding(.fullScreen)
        }
    }
}

// MARK: - Recogniser

/// Every threshold in one place. Distances are in "pad heights": x is scaled by the trackpad's
/// aspect so a millimetre counts the same both ways (1.0 ≈ 96 mm on the M5 MacBook's trackpad).
public struct TitleBarTuning: Sendable, Equatable {
    /// Width ÷ depth of the sensor (156 × 96 mm on the M5 built-in trackpad).
    public var aspect = 156.0 / 96.0
    /// The fingers' midpoint must travel this far for a swipe to commit (≈ 14 mm).
    public var swipeTravel = 0.15
    /// From this much travel or spread on, the gesture counts as recognised: the preview shows
    /// and the scroll events of this touch are kept from the window.
    public var claimTravel = 0.045
    /// The distance between the fingers must change this much for a pinch to commit (≈ 12 mm).
    public var pinchTravel = 0.12
    /// A pinch only when the spread changes this many times more than the midpoint moves, and a
    /// swipe only when the midpoint moves this many times more than the spread changes.
    public var dominance = 1.3
    /// Both fingers of a swipe move the same way: the cosine between their paths must reach this.
    public var parallel = 0.6
    /// The four diagonals, each this many degrees either side of 45°. Off, everything is cardinal.
    public var diagonals = true
    public var diagonalHalfAngle = 16.0
    /// A flick commits early: this fraction of the travel, at least `flickSpeed` pad heights a second.
    public var flickFraction = 0.55
    public var flickSpeed = 1.4
    /// The two-finger count must hold this long before the gesture anchors (hysteresis).
    public var countHold = 0.02
    /// Contacts longer than this are a palm and are ignored, as in the tap recogniser.
    public var palmMajorAxis = 11.0
    /// Fingers landing this close to the left or right edge are Notification Center's swipe or a
    /// hand resting, not a title-bar gesture.
    public var edgeGuard = 0.05
    /// A touch that has not been recognised this long after anchoring is someone resting.
    public var maxIdle = 1.2
    /// After one finger lifts, the other has this long to follow before the gesture settles anyway.
    public var liftGrace = 0.2
    /// Larger is more eager: thresholds are divided by it. 0.5…2.
    public var sensitivity = 1.0 {
        didSet { sensitivity = min(max(sensitivity, 0.3), 3) }
    }

    public init() {}
    public static let standard = TitleBarTuning()

    public var effectiveSwipe: Double { swipeTravel / sensitivity }
    public var effectivePinch: Double { pinchTravel / sensitivity }
    public var effectiveClaim: Double { claimTravel / sensitivity }
}

/// What the recogniser says after each frame.
public struct TitleBarReading: Equatable, Sendable {
    /// A touch of interest is in progress (fingers down, not spoiled).
    public var active = false
    /// True on the one frame two fingers anchored: the moment to look at what is under the pointer.
    public var anchored = false
    /// What the fingers are doing now; nil until they have moved enough to say.
    public var candidate: TitleBarGesture?
    /// 0…1 towards the commit threshold of `candidate`.
    public var progress = 0.0
    /// Once recognised, stays true for the rest of the touch: its scroll events are not the
    /// window's.
    public var claimed = false
    /// Set on the frame the gesture completed (the fingers lifted past the threshold).
    public var committed: TitleBarGesture?
    /// Set on the frame a claimed touch ended without committing, or was spoiled.
    public var cancelled = false
    /// The midpoint's travel and the spread change, in pad heights, for the card's live view.
    public var travel = (dx: 0.0, dy: 0.0)
    public var spread = 0.0

    public init() {}

    public static func == (a: TitleBarReading, b: TitleBarReading) -> Bool {
        a.active == b.active && a.anchored == b.anchored && a.candidate == b.candidate && a.progress == b.progress
            && a.claimed == b.claimed && a.committed == b.committed && a.cancelled == b.cancelled
            && a.travel.dx == b.travel.dx && a.travel.dy == b.travel.dy && a.spread == b.spread
    }
}

/// Feed it frames in order. Two fingers anchor, their midpoint and spread are followed, and the
/// gesture commits when they lift past the threshold. A third finger, a palm, a landing at the
/// side edges or `spoil()` (the pointer is not on a title bar) gives the touch back to macOS.
public struct TitleBarRecognizer: Sendable {
    public var tuning: TitleBarTuning

    private struct Anchor: Sendable {
        var ids: (Int, Int)
        var a: (Double, Double)
        var b: (Double, Double)
        var time: Double
    }

    private struct Session: Sendable {
        var start: Double
        var candidateCount = 0
        var candidateSince: Double
        var anchor: Anchor?
        var spoiled = false
        var claimed = false
        var liftedAt: Double?
        /// The last two-finger measurement, used when the fingers lift.
        var last: Measure?
        var done = false
    }

    private struct Measure: Sendable {
        var candidate: TitleBarGesture?
        var progress: Double
        var travel: Double
        var dx: Double, dy: Double
        var spread: Double
        var time: Double
    }

    private var session: Session?
    private var palms: Set<Int> = []

    public init(tuning: TitleBarTuning = .standard) { self.tuning = tuning }

    public var active: Bool { session != nil }

    /// The pointer is not on a title bar (or the feature does not want this touch): ignore it
    /// until every finger has lifted.
    public mutating func spoil() { session?.spoiled = true }

    public mutating func reset() {
        session = nil
        palms = []
    }

    public mutating func feed(_ frame: TouchFrame) -> TitleBarReading {
        let present = Set(frame.touches.map(\.id))
        palms.formIntersection(present)
        for touch in frame.touches where touch.isDown && touch.majorAxis > tuning.palmMajorAxis { palms.insert(touch.id) }
        let down = frame.touches.filter { $0.isDown && !palms.contains($0.id) }
        let t = frame.time
        var reading = TitleBarReading()

        if session == nil {
            guard !down.isEmpty else { return reading }
            session = Session(start: t, candidateSince: t)
        }
        guard var s = session else { return reading }

        // Every finger gone: the touch is over. Commit if it got far enough.
        if down.isEmpty {
            if !s.spoiled && !s.done, let last = s.last {
                if let gesture = commits(last, anchorTime: s.anchor?.time ?? s.start) {
                    reading.committed = gesture
                } else if s.claimed {
                    reading.cancelled = true
                }
            } else if s.spoiled && s.claimed && !s.done {
                reading.cancelled = true
            }
            reading.claimed = s.claimed
            session = nil
            return reading
        }

        // A third finger is Mission Control, App Exposé or a three-finger drag: macOS's.
        if down.count >= 3 && !s.spoiled {
            s.spoiled = true
            if s.claimed { reading.cancelled = true }
        }

        if s.spoiled || s.done {
            reading.claimed = s.claimed
            session = s
            return reading
        }

        // Hysteresis on the finger count before anchoring.
        if down.count != s.candidateCount {
            s.candidateCount = down.count
            s.candidateSince = t
        }

        if s.anchor == nil {
            if down.count == 2 && t - s.candidateSince >= tuning.countHold {
                let p = down.sorted { $0.id < $1.id }
                let edge = tuning.edgeGuard
                if p.contains(where: { $0.x <= edge || $0.x >= 1 - edge }) {
                    s.spoiled = true
                } else {
                    s.anchor = Anchor(ids: (p[0].id, p[1].id), a: (p[0].x, p[0].y), b: (p[1].x, p[1].y), time: t)
                    reading.anchored = true
                }
            }
            reading.active = !s.spoiled
            session = s
            return reading
        }
        let anchor = s.anchor!

        if down.count == 2 {
            let ids = Set(down.map(\.id))
            guard ids == [anchor.ids.0, anchor.ids.1] else {
                // Not the fingers that anchored (one lifted and another landed): not one gesture.
                s.spoiled = true
                if s.claimed { reading.cancelled = true }
                reading.claimed = s.claimed
                session = s
                return reading
            }
            s.liftedAt = nil
            let a = down.first { $0.id == anchor.ids.0 }!, b = down.first { $0.id == anchor.ids.1 }!
            let m = measure(anchor: anchor, a: (a.x, a.y), b: (b.x, b.y), time: t)
            s.last = m
            if m.candidate != nil { s.claimed = true }
            if !s.claimed && m.candidate == nil && t - anchor.time > tuning.maxIdle {
                // Resting two fingers on the title bar is not a gesture.
                s.spoiled = true
            }
            reading.candidate = m.candidate
            reading.progress = m.progress
            reading.travel = (m.dx, m.dy)
            reading.spread = m.spread
        } else {
            // One finger left: the hand is lifting. Keep the last two-finger measurement.
            if s.liftedAt == nil { s.liftedAt = t }
            if let lifted = s.liftedAt, t - lifted > tuning.liftGrace {
                // The other finger stays down: settle now, then ignore it (it moves the pointer).
                if let last = s.last, let gesture = commits(last, anchorTime: anchor.time) {
                    reading.committed = gesture
                } else if s.claimed {
                    reading.cancelled = true
                }
                s.done = true
            } else if let last = s.last {
                reading.candidate = last.candidate
                reading.progress = last.progress
                reading.travel = (last.dx, last.dy)
                reading.spread = last.spread
            }
        }
        reading.active = !s.spoiled && !s.done
        reading.claimed = s.claimed
        session = s
        return reading
    }

    /// Midpoint travel and spread change since anchoring, classified.
    private func measure(anchor: Anchor, a: (Double, Double), b: (Double, Double), time: Double) -> Measure {
        let k = tuning.aspect
        let va = ((a.0 - anchor.a.0) * k, a.1 - anchor.a.1)
        let vb = ((b.0 - anchor.b.0) * k, b.1 - anchor.b.1)
        let dx = (va.0 + vb.0) / 2, dy = (va.1 + vb.1) / 2
        let travel = hypot(dx, dy)
        let d0 = hypot((anchor.a.0 - anchor.b.0) * k, anchor.a.1 - anchor.b.1)
        let d1 = hypot((a.0 - b.0) * k, a.1 - b.1)
        let spread = d1 - d0
        var candidate: TitleBarGesture?
        var progress = 0.0
        let claim = tuning.effectiveClaim
        if abs(spread) >= claim && abs(spread) >= tuning.dominance * travel {
            candidate = spread < 0 ? .pinchIn : .pinchOut
            progress = min(abs(spread) / tuning.effectivePinch, 1)
        } else if travel >= claim && travel >= tuning.dominance * abs(spread) && Self.parallel(va, vb, tuning.parallel) {
            candidate = Self.direction(dx: dx, dy: dy, tuning: tuning)
            progress = min(travel / tuning.effectiveSwipe, 1)
        }
        return Measure(candidate: candidate, progress: progress, travel: travel, dx: dx, dy: dy, spread: spread, time: time)
    }

    /// The fingers move together: either one barely moved, or their paths agree.
    static func parallel(_ va: (Double, Double), _ vb: (Double, Double), _ threshold: Double) -> Bool {
        let la = hypot(va.0, va.1), lb = hypot(vb.0, vb.1)
        if la < 0.01 || lb < 0.01 { return true }
        return (va.0 * vb.0 + va.1 * vb.1) / (la * lb) >= threshold
    }

    /// Eight sectors: cardinals wide, diagonals `diagonalHalfAngle` either side of 45°.
    public static func direction(dx: Double, dy: Double, tuning: TitleBarTuning = .standard) -> TitleBarGesture {
        let angle = atan2(dy, dx) * 180 / .pi  // -180…180, 0 right, 90 up
        if tuning.diagonals {
            let diagonals: [(Double, TitleBarGesture)] = [(45, .topRight), (135, .topLeft), (-135, .bottomLeft), (-45, .bottomRight)]
            for (centre, gesture) in diagonals where abs(angle - centre) <= tuning.diagonalHalfAngle { return gesture }
        }
        switch angle {
        case -45..<45: return .right
        case 45..<135: return .up
        case -135 ..< -45: return .down
        default: return .left
        }
    }

    /// Whether the last measurement is enough: past the threshold, or a fast flick most of the way.
    private func commits(_ m: Measure, anchorTime: Double) -> TitleBarGesture? {
        guard let candidate = m.candidate else { return nil }
        if m.progress >= 1 { return candidate }
        let duration = max(m.time - anchorTime, 0.001)
        let distance = candidate.isPinch ? abs(m.spread) : m.travel
        if m.progress >= tuning.flickFraction && distance / duration >= tuning.flickSpeed { return candidate }
        return nil
    }
}

// MARK: - Geometry

/// One display: its whole frame and the part windows may use (menu bar, Dock, Stage Manager's
/// strip taken off), both in Accessibility coordinates.
public struct TitleBarDisplay: Equatable, Sendable {
    public var frame: CGRect
    public var visible: CGRect

    public init(frame: CGRect, visible: CGRect) {
        self.frame = frame
        self.visible = visible
    }
}

public enum TitleBarGeometry {
    /// Apple's tiled-window spacing (WindowManager's `tiledWindowSpacing`).
    public static let appleGap = 8.0
    /// Room Stage Manager's strip of recent apps takes at the left edge when it is showing.
    public static let stageStrip = 96.0

    /// Whole-point edges of a run of equal tracks, with `gap` around and between them. The same
    /// arithmetic as the Window Engine's layouts, so a title-bar half and a hot-key half match.
    static func span(from first: Int, count: Int, of total: Int, start: Double, length: Double, gap: Double) -> (Double, Double) {
        let track = (length - gap * Double(total + 1)) / Double(total)
        let low = start + gap + Double(first) * (track + gap)
        let high = start + gap + Double(first + count) * (track + gap) - gap
        return (low.rounded(), high.rounded())
    }

    public static func frame(_ tile: TitleBarTile, in visible: CGRect, gap: Double) -> CGRect {
        let (column, columns, row, rows) = tile.cell
        let (left, right) = span(from: column, count: 1, of: columns, start: visible.minX, length: visible.width, gap: gap)
        let (top, bottom) = span(from: row, count: 1, of: rows, start: visible.minY, length: visible.height, gap: gap)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The window at its size (shrunk to fit), centred in the visible frame.
    public static func centered(_ size: CGSize, in visible: CGRect, gap: Double) -> CGRect {
        let room = visible.insetBy(dx: gap, dy: gap)
        let width = min(size.width, room.width), height = min(size.height, room.height)
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height)
    }

    /// A frame moved and shrunk until it lies inside `visible`.
    public static func clamped(_ frame: CGRect, into visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The visible frame with Stage Manager's strip taken off the left, when the strip shows.
    public static func usable(_ visible: CGRect, stageManager: Bool, stripHidden: Bool) -> CGRect {
        guard stageManager && !stripHidden, visible.width > stageStrip * 3 else { return visible }
        return CGRect(x: visible.minX + stageStrip, y: visible.minY, width: visible.width - stageStrip, height: visible.height)
    }

    /// The display holding most of `frame`; the nearest one when it is off every display.
    public static func displayIndex(of frame: CGRect, in displays: [TitleBarDisplay]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let area = { (r: CGRect) -> Double in r.isNull ? 0 : r.width * r.height }
        let best = displays.indices.max { area(displays[$0].frame.intersection(frame)) < area(displays[$1].frame.intersection(frame)) }!
        if area(displays[best].frame.intersection(frame)) > 0 { return best }
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        func distance(_ r: CGRect) -> Double {
            hypot(max(r.minX - mid.x, 0, mid.x - r.maxX), max(r.minY - mid.y, 0, mid.y - r.maxY))
        }
        return displays.indices.min { distance(displays[$0].frame) < distance(displays[$1].frame) }
    }

    public enum Side: Sendable { case left, right }

    /// The display next to `index` on that side: the closest one whose centre lies that way,
    /// preferring displays that overlap it vertically.
    public static func neighbour(of index: Int, _ side: Side, in displays: [TitleBarDisplay]) -> Int? {
        guard displays.indices.contains(index) else { return nil }
        let here = displays[index].frame
        let candidates = displays.indices.filter { i in
            i != index && (side == .left ? displays[i].frame.midX < here.midX : displays[i].frame.midX > here.midX)
        }
        func overlaps(_ r: CGRect) -> Bool { r.minY < here.maxY && r.maxY > here.minY }
        func gap(_ r: CGRect) -> Double { side == .left ? here.minX - r.maxX : r.minX - here.maxX }
        return candidates.min { a, b in
            let ra = displays[a].frame, rb = displays[b].frame
            if overlaps(ra) != overlaps(rb) { return overlaps(ra) }
            if abs(gap(ra) - gap(rb)) > 0.5 { return gap(ra) < gap(rb) }
            return abs(ra.midY - here.midY) < abs(rb.midY - here.midY)
        }
    }

    /// The same place and proportion on another visible frame.
    public static func proportional(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return clamped(frame, into: target) }
        let sx = target.width / source.width, sy = target.height / source.height
        let mapped = CGRect(x: target.minX + (frame.minX - source.minX) * sx, y: target.minY + (frame.minY - source.minY) * sy,
                            width: frame.width * sx, height: frame.height * sy)
        return clamped(CGRect(x: mapped.minX.rounded(), y: mapped.minY.rounded(), width: mapped.width.rounded(), height: mapped.height.rounded()),
                       into: target)
    }

    /// Two frames are the same place when every edge is within `tolerance` points. Apps round
    /// sizes (Terminal to its character grid), so exact equality is never asked for.
    public static func matches(_ a: CGRect, _ b: CGRect, tolerance: Double = 6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Whether `point` lies in the title-bar band of a window: from its top edge down `band`
    /// points, or down to the bottom of its toolbar when that is lower (and asked for).
    public static func inTitleBar(_ point: CGPoint, window: CGRect, band: Double, toolbarBottom: Double? = nil) -> Bool {
        guard point.x >= window.minX, point.x <= window.maxX, point.y >= window.minY else { return false }
        let bottom = max(window.minY + band, toolbarBottom ?? -Double.infinity)
        return point.y <= min(bottom, window.maxY)
    }

    /// The preview while the fingers move: from the window towards the target, eased, so the
    /// slab grows out of the window and reaches the target as the gesture reaches its threshold.
    public static func preview(from current: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let p = min(max(progress, 0), 1)
        let e = 1 - pow(1 - p, 3)  // ease out cubic
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * e }
        return CGRect(x: lerp(current.minX, target.minX), y: lerp(current.minY, target.minY),
                      width: lerp(current.width, target.width), height: lerp(current.height, target.height))
    }
}

// MARK: - Planning

/// What to do to the window.
public enum TitleBarPlan: Equatable, Sendable {
    case nothing(String)
    case frame(CGRect, display: Int)
    case fullScreen(Bool)
    case minimize
    case close

    /// The rectangle the preview shows for this plan, in Accessibility coordinates.
    public func previewTarget(window: CGRect, displays: [TitleBarDisplay]) -> CGRect? {
        switch self {
        case .nothing: return nil
        case .frame(let rect, _): return rect
        case .fullScreen:
            guard let i = TitleBarGeometry.displayIndex(of: window, in: displays) else { return nil }
            return displays[i].frame
        case .minimize:
            // Towards the Dock: a small slab at the bottom centre of the display.
            guard let i = TitleBarGeometry.displayIndex(of: window, in: displays) else { return nil }
            let v = displays[i].visible
            let w = max(window.width * 0.18, 60), h = max(window.height * 0.18, 40)
            return CGRect(x: (v.midX - w / 2).rounded(), y: (v.maxY - h - 4).rounded(), width: w.rounded(), height: h.rounded())
        case .close:
            // The window shrinking where it is.
            return window.insetBy(dx: window.width * 0.12, dy: window.height * 0.12)
        }
    }
}

/// The last gesture Atelier committed on a window, for the repeated-swipe cycle.
public struct TitleBarCommit: Equatable, Sendable {
    public var window: Int
    public var gesture: TitleBarGesture
    /// The frame the window really took (apps may round the one asked for).
    public var landed: CGRect

    public init(window: Int, gesture: TitleBarGesture, landed: CGRect) {
        self.window = window
        self.gesture = gesture
        self.landed = landed
    }
}

/// Everything the planner needs to know about the window and the screens.
public struct TitleBarContext: Equatable, Sendable {
    public var window: Int
    public var frame: CGRect
    public var displays: [TitleBarDisplay]
    public var gap: Double
    /// The frame before Atelier first tiled it, for Restore.
    public var saved: CGRect?
    public var isFullScreen: Bool
    public var last: TitleBarCommit?

    public init(window: Int = 0, frame: CGRect, displays: [TitleBarDisplay], gap: Double = TitleBarGeometry.appleGap,
                saved: CGRect? = nil, isFullScreen: Bool = false, last: TitleBarCommit? = nil) {
        self.window = window
        self.frame = frame
        self.displays = displays
        self.gap = gap
        self.saved = saved
        self.isFullScreen = isFullScreen
        self.last = last
    }
}

public enum TitleBarPlanner {
    /// The plan for a gesture, and whether it is the repeat ("again") step of its cycle.
    public static func plan(_ gesture: TitleBarGesture, binding: TitleBarBinding, context: TitleBarContext) -> (plan: TitleBarPlan, again: Bool) {
        if context.isFullScreen {
            // A full-screen window only leaves full screen (or closes): it cannot be tiled.
            let wantsFull = binding.first == .fullScreen || binding.again == .fullScreen
            if gesture == .down || wantsFull { return (.fullScreen(false), false) }
            if binding.first == .close { return (.close, false) }
            return (.nothing("The window is full screen"), false)
        }
        let first = action(binding.first, context: context)
        if binding.again != .none && isRepeat(gesture, firstPlan: first, context: context) {
            return (action(binding.again, context: context), true)
        }
        return (first, false)
    }

    /// The window already sits where the first step puts it, or where Atelier last put it with
    /// this same gesture: the next swipe is the cycle's second step.
    static func isRepeat(_ gesture: TitleBarGesture, firstPlan: TitleBarPlan, context: TitleBarContext) -> Bool {
        if case .frame(let target, _) = firstPlan, TitleBarGeometry.matches(context.frame, target) { return true }
        if let last = context.last, last.window == context.window, last.gesture == gesture,
           TitleBarGeometry.matches(context.frame, last.landed) { return true }
        return false
    }

    public static func action(_ action: TitleBarAction, context: TitleBarContext) -> TitleBarPlan {
        let displays = context.displays
        guard let index = TitleBarGeometry.displayIndex(of: context.frame, in: displays) else { return .nothing("No display") }
        let visible = displays[index].visible
        if let tile = action.tile {
            return .frame(TitleBarGeometry.frame(tile, in: visible, gap: context.gap), display: index)
        }
        switch action {
        case .none: return .nothing("No action set")
        case .center:
            return .frame(TitleBarGeometry.centered(context.frame.size, in: visible, gap: context.gap), display: index)
        case .restore:
            // Back to the frame it had before Atelier first tiled it. Already there, this plan
            // matches the window, so the cycle's next step (minimise by default) follows.
            if let saved = context.saved {
                let home = TitleBarGeometry.displayIndex(of: saved, in: displays) ?? index
                return .frame(TitleBarGeometry.clamped(saved, into: displays[home].visible), display: home)
            }
            return .frame(TitleBarGeometry.centered(restoredSize(context, visible: visible), in: visible, gap: context.gap), display: index)
        case .displayLeft, .displayRight:
            let side: TitleBarGeometry.Side = action == .displayLeft ? .left : .right
            guard let next = TitleBarGeometry.neighbour(of: index, side, in: displays) else {
                return .nothing(side == .left ? "No display to the left" : "No display to the right")
            }
            // The swipe carries on: from the left half of one display to the right half of the next.
            let tile: TitleBarTile = side == .left ? .rightHalf : .leftHalf
            return .frame(TitleBarGeometry.frame(tile, in: displays[next].visible, gap: context.gap), display: next)
        case .nextDisplay:
            guard displays.count > 1 else { return .nothing("Only one display") }
            let next = (index + 1) % displays.count
            return .frame(TitleBarGeometry.proportional(context.frame, from: visible, to: displays[next].visible), display: next)
        case .minimize: return .minimize
        case .fullScreen: return .fullScreen(true)
        case .close: return .close
        default: return .nothing("No action set")
        }
    }

    /// Centring a window that fills its display would change nothing; such a window comes back
    /// at two thirds of the display, the way a double-click on a zoomed title bar shrinks it.
    static func restoredSize(_ context: TitleBarContext, visible: CGRect) -> CGSize {
        let size = context.frame.size
        let filling = size.width >= visible.width - 2 * context.gap - 2 && size.height >= visible.height - 2 * context.gap - 2
        return filling ? CGSize(width: (visible.width * 2 / 3).rounded(), height: (visible.height * 2 / 3).rounded()) : size
    }
}

// MARK: - Synthetic two-finger touches

/// Two-finger frames shaped like the sensor's, for tests and the card's illustrations.
public enum SyntheticTitleBar {
    public static let step = 0.008

    /// Two fingers side by side at `center`, `spacing` apart, moving by `delta` (sensor units)
    /// and spreading by `spread` (added to their distance) over `duration`, then lifting.
    public static func gesture(center: (Double, Double) = (0.5, 0.5), spacing: Double = 0.12,
                               delta: (Double, Double) = (0, 0), spread: Double = 0, duration: Double = 0.3,
                               hold: Double = 0.04, at start: Double = 0, liftTogether: Bool = true) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        var t = start
        func pair(_ f: Double) -> [TouchSample] {
            let half = (spacing + spread * f) / 2
            let cx = center.0 + delta.0 * f, cy = center.1 + delta.1 * f
            return [TouchSample(id: 1, x: cx - half, y: cy), TouchSample(id: 2, x: cx + half, y: cy)]
        }
        while t <= start + hold + 1e-9 {
            frames.append(TouchFrame(time: t, touches: pair(0)))
            t += step
        }
        let moveStart = t
        while t <= moveStart + duration + 1e-9 {
            let f = duration > 0 ? (t - moveStart) / duration : 1
            frames.append(TouchFrame(time: t, touches: pair(f)))
            t += step
        }
        if !liftTogether {
            frames.append(TouchFrame(time: t, touches: [pair(1)[0]]))
            t += step
        }
        frames.append(TouchFrame(time: t, touches: []))
        return frames
    }

    /// Runs frames through a fresh recogniser and returns what committed.
    public static func recognize(_ frames: [TouchFrame], tuning: TitleBarTuning = .standard) -> [TitleBarGesture] {
        var recognizer = TitleBarRecognizer(tuning: tuning)
        return frames.compactMap { recognizer.feed($0).committed }
    }

    /// All readings, for tests that look inside the gesture.
    public static func readings(_ frames: [TouchFrame], tuning: TitleBarTuning = .standard) -> [TitleBarReading] {
        var recognizer = TitleBarRecognizer(tuning: tuning)
        return frames.map { recognizer.feed($0) }
    }
}
