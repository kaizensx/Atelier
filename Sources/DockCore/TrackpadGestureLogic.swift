import Foundation

// MARK: - Trackpad gesture recognizer
//
// Pure logic, no AppKit and no MultitouchSupport: it takes the finger frames the trackpad
// sensor reports (about 125 a second on an M-series MacBook) and says which of Atelier's
// gestures just happened. Keeping it free of the private framework means every threshold can
// be tested with recorded or synthetic frames, and the live side only has to copy numbers.
//
// Coordinates are the sensor's normalised ones: x 0 at the left edge, 1 at the right; y 0 at
// the edge nearest you, 1 at the far (top) edge. Pressure is the sensor's zTotal (a light
// resting finger reads about 0.3, a firm one higher); majorAxis is the contact's long axis in
// the sensor's units (a fingertip is about 7, a palm or the side of a hand well over 11).

/// One of the gestures Atelier adds. Raw values are stable: they are stored in settings and
/// used by `atelier://gesture?simulate=`.
public enum TrackpadGesture: String, CaseIterable, Codable, Sendable, Identifiable {
    case threeTap, fourTap, topLeftTap, topRightTap, swipeFromLeft, swipeFromRight, threeForce

    public var id: String { rawValue }

    /// How many fingers it takes; the stage preview and the card draw this many dots.
    public var fingers: Int {
        switch self {
        case .threeTap, .threeForce: 3
        case .fourTap: 4
        case .topLeftTap, .topRightTap: 2
        case .swipeFromLeft, .swipeFromRight: 1
        }
    }
}

/// The sensor's path states. Only 3 (make touch) and 4 (touching) are a finger pressing the
/// glass; the others are a finger hovering, arriving or leaving, and counting them would make
/// every tap look a frame or two longer and every lift look like an extra finger.
public enum TouchPhase: Int, Sendable {
    case notTracking = 0, startInRange, hoverInRange, makeTouch, touching, breakTouch, lingerInRange, outOfRange
}

public struct TouchSample: Sendable, Equatable {
    /// The sensor's path index: stays the same for one finger from landing to lifting.
    public var id: Int
    public var x: Double
    public var y: Double
    public var state: Int
    public var pressure: Double
    public var majorAxis: Double

    public init(id: Int, x: Double, y: Double, state: Int = TouchPhase.touching.rawValue,
                pressure: Double = 0.35, majorAxis: Double = 7) {
        self.id = id
        self.x = x
        self.y = y
        self.state = state
        self.pressure = pressure
        self.majorAxis = majorAxis
    }

    public var isDown: Bool { state == TouchPhase.makeTouch.rawValue || state == TouchPhase.touching.rawValue }
}

public struct TouchFrame: Sendable, Equatable {
    /// Seconds, any monotonic clock (the sensor's own timestamp in the app).
    public var time: Double
    public var touches: [TouchSample]

    public init(time: Double, touches: [TouchSample]) {
        self.time = time
        self.touches = touches
    }
}

/// Every threshold in one place, so tests and the card's sliders can move them.
public struct GestureTuning: Sendable, Equatable {
    /// A tap is over in this long from the first finger landing to the last one lifting.
    /// macOS's own tap-to-click allows about a quarter second; a little more suits several fingers.
    public var tapMaxDuration = 0.32
    /// No finger may wander further than this (normalised) during a tap; further is a drag or
    /// a swipe, which belong to macOS (scrolling, Mission Control, Spaces).
    public var tapMaxTravel = 0.035
    /// All fingers of a tap must land within this window. Fingers arriving later are someone
    /// resting a hand and then tapping, not one tap.
    public var landWindow = 0.12
    /// A finger count must hold this long before it counts. A fourth finger brushing the glass
    /// for one frame does not turn a three-finger tap into a four-finger one (hysteresis).
    public var countHold = 0.02
    /// Contacts with a long axis over this are a palm or the side of a hand and are ignored.
    public var palmMajorAxis = 11.0
    /// Two-finger corner taps: the fingers' midpoint must sit within this of both edges.
    public var cornerSize = 0.24
    /// Edge swipes start this close to the left or right edge...
    public var edgeZone = 0.07
    /// ...travel at least this far inwards...
    public var edgeTravel = 0.16
    /// ...within this long of landing, mostly sideways. A swipe is a flick; a slow slide from
    /// the edge is someone moving the pointer and must stay just that.
    public var edgeMaxDuration = 0.4
    /// Mean pressure of three fingers that counts as a firm press.
    public var forceThreshold = 0.9
    /// A firm press may roll the fingers a little, not slide them.
    public var forceMaxTravel = 0.06
    /// Whether the trackpad now being touched measures force. Without Force Touch (Magic
    /// Trackpad 1, MacBooks before 2015) zTotal is contact size, not pressure, and three
    /// resting fingers could pass the threshold, so the firm press is off there.
    public var forceEnabled = true

    public init() {}
    public static let standard = GestureTuning()
}

/// Feed it frames in order; it answers with the gestures each frame completed.
public struct GestureRecognizer: Sendable {
    public var tuning: GestureTuning

    private struct Track: Sendable {
        var startX: Double, startY: Double, startTime: Double
        var x: Double, y: Double
        var lastTime: Double
        var travel = 0.0
    }

    private struct Session: Sendable {
        var start: Double
        var tracks: [Int: Track] = [:]
        var candidate = 0
        var candidateSince: Double
        var stable = 0
        var peak = 0
        /// Set once a gesture fired mid-touch (an edge swipe or a firm press), so lifting the
        /// fingers does not also count as a tap.
        var consumed = false
    }

    private var session: Session?
    /// Contacts judged a palm stay a palm until they lift, even if they shrink for a frame.
    private var palms: Set<Int> = []

    public init(tuning: GestureTuning = .standard) { self.tuning = tuning }

    /// Fingers on the glass right now, after hysteresis and palm rejection; 0 between gestures.
    public var fingers: Int { session?.stable ?? 0 }
    /// Whether a touch is in progress.
    public var active: Bool { session != nil }

    public mutating func feed(_ frame: TouchFrame) -> [TrackpadGesture] {
        let present = Set(frame.touches.map(\.id))
        palms.formIntersection(present)
        for touch in frame.touches where touch.isDown && touch.majorAxis > tuning.palmMajorAxis { palms.insert(touch.id) }
        let down = frame.touches.filter { $0.isDown && !palms.contains($0.id) }

        if session == nil {
            guard !down.isEmpty else { return [] }
            session = Session(start: frame.time, candidateSince: frame.time)
        }
        guard var s = session else { return [] }
        let t = frame.time

        // Hysteresis first, on the count that held until now: a count only becomes real once it
        // has lasted `countHold`. Done before the new count is looked at, so the last count of
        // a tap still gets its say on the frame where every finger lifts.
        if t - s.candidateSince >= tuning.countHold {
            s.stable = s.candidate
            s.peak = max(s.peak, s.stable)
        }
        if down.count != s.candidate {
            s.candidate = down.count
            s.candidateSince = t
        }

        for touch in down {
            if var track = s.tracks[touch.id] {
                track.x = touch.x
                track.y = touch.y
                track.lastTime = t
                track.travel = max(track.travel, hypot(touch.x - track.startX, touch.y - track.startY))
                s.tracks[touch.id] = track
            } else {
                s.tracks[touch.id] = Track(startX: touch.x, startY: touch.y, startTime: t, x: touch.x, y: touch.y, lastTime: t)
            }
        }

        var fired: [TrackpadGesture] = []
        if !s.consumed, let gesture = midTouch(s, down: down, time: t) {
            fired.append(gesture)
            s.consumed = true
        }

        if down.isEmpty {
            if !s.consumed, let tap = tap(s, end: t) { fired.append(tap) }
            session = nil
        } else {
            session = s
        }
        return fired
    }

    /// Gestures that fire while fingers are still down: the edge swipe the moment it has gone
    /// far enough (waiting for the lift would feel late), and the firm press at its threshold.
    private func midTouch(_ s: Session, down: [TouchSample], time: Double) -> TrackpadGesture? {
        // One finger, and only ever one this touch: a second finger makes it a scroll.
        if down.count == 1, s.tracks.count == 1, let track = s.tracks.values.first, time - s.start <= tuning.edgeMaxDuration {
            let dx = track.x - track.startX, dy = track.y - track.startY
            let sideways = abs(dx) >= 2 * abs(dy)
            if sideways && track.startX <= tuning.edgeZone && dx >= tuning.edgeTravel { return .swipeFromLeft }
            if sideways && track.startX >= 1 - tuning.edgeZone && -dx >= tuning.edgeTravel { return .swipeFromRight }
        }
        if tuning.forceEnabled, down.count == 3, s.stable == 3 {
            let mean = down.map(\.pressure).reduce(0, +) / 3
            let still = s.tracks.values.allSatisfy { $0.travel <= tuning.forceMaxTravel }
            if mean >= tuning.forceThreshold && still { return .threeForce }
        }
        return nil
    }

    /// Every finger has lifted: was it a tap, and of which kind?
    private func tap(_ s: Session, end: Double) -> TrackpadGesture? {
        guard end - s.start <= tuning.tapMaxDuration else { return nil }
        // A contact that came and went within `countHold` (a knuckle or a fourth finger brushing
        // the glass) is not one of the tap's fingers: drop it rather than spoil the tap.
        let tracks = s.tracks.values.filter { $0.lastTime - $0.startTime >= tuning.countHold }
        // Exactly the fingers that counted, all of them barely moving, all landing together.
        guard s.peak >= 2, tracks.count == s.peak else { return nil }
        guard tracks.allSatisfy({ $0.travel <= tuning.tapMaxTravel }) else { return nil }
        let landings = tracks.map(\.startTime)
        guard (landings.max() ?? 0) - (landings.min() ?? 0) <= tuning.landWindow else { return nil }
        switch s.peak {
        case 3: return .threeTap
        case 4: return .fourTap
        case 2:
            let x = tracks.map(\.startX).reduce(0, +) / 2
            let y = tracks.map(\.startY).reduce(0, +) / 2
            guard y >= 1 - tuning.cornerSize else { return nil }
            if x <= tuning.cornerSize { return .topLeftTap }
            if x >= 1 - tuning.cornerSize { return .topRightTap }
            return nil
        default: return nil
        }
    }
}

extension TrackpadGesture {
    /// Gestures that read pressure, so need a Force Touch trackpad.
    public var needsForceTouch: Bool { self == .threeForce }
}

// MARK: - Which multitouch devices are trackpads

/// MultitouchSupport lists every multitouch surface: the built-in trackpad, Magic Trackpads, and
/// also Magic Mice, whose top is a touch surface too. A one-finger edge flick or a three-finger
/// tap on a mouse is ordinary handling, so mice are left out of gestures.
public enum MultitouchDeviceKind: Equatable, Sendable {
    case trackpad, mouse

    /// Family IDs Magic Mouse reports (first and second generation), as used by trackpad
    /// utilities; not documented by Apple, so the surface shape is checked as well.
    public static let mouseFamilies: Set<Int> = [112, 113]

    /// - Parameters:
    ///   - family: MTDeviceGetFamilyID, nil if unreadable.
    ///   - surface: MTDeviceGetSensorSurfaceDimensions (hundredths of a millimetre), nil if unreadable.
    public static func classify(family: Int?, builtIn: Bool, surface: (width: Int, height: Int)?) -> MultitouchDeviceKind {
        if builtIn { return .trackpad }
        if let family, mouseFamilies.contains(family) { return .mouse }
        // Every Mac trackpad is wider than it is deep; a Magic Mouse's surface is longer than wide.
        if let surface, surface.width > 0, surface.height > 0, Double(surface.width) < Double(surface.height) * 0.9 { return .mouse }
        return .trackpad
    }
}

// MARK: - What this Mac can do

/// Availability without AppKit, so the rules can be tested. DockStacks maps it onto
/// FeatureAvailability for the cards.
public enum InputSupport: Equatable, Sendable {
    case available
    case limited(String)
    case unavailable(String)

    /// Trackpad Gestures, from what the sensor survey found.
    /// - Parameters:
    ///   - frameworkLoaded: MultitouchSupport and its finger-stream functions were found.
    ///   - trackpads: trackpads listed now (mice excluded).
    ///   - forceTrackpads: how many of them report Force Touch.
    public static func gestures(frameworkLoaded: Bool, trackpads: Int, forceTrackpads: Int) -> InputSupport {
        guard frameworkLoaded else { return .unavailable("This macOS doesn’t let apps read the trackpad sensor") }
        guard trackpads > 0 else { return .unavailable("Needs a trackpad: none is connected") }
        if forceTrackpads == 0 { return .limited("No Force Touch here, so the firm press is off") }
        return .available
    }

    /// Haptics: the actuator, the in-front-only fallback, or nothing at all.
    /// - Parameters:
    ///   - actuators: trackpad actuators that opened.
    ///   - forceTrackpads: trackpads that report Force Touch (NSHapticFeedbackManager plays on those).
    public static func haptics(actuators: Int, forceTrackpads: Int) -> InputSupport {
        if actuators > 0 { return .available }
        if forceTrackpads > 0 { return .limited("Plays only while Atelier is in front on this Mac") }
        return .unavailable("Needs a Force Touch trackpad")
    }
}

// MARK: - Synthetic touches

/// Frame sequences shaped like the sensor's, for tests, the gesture test tool and the stage
/// preview's animation. 8 ms apart, as the M5 trackpad delivers them.
public enum SyntheticTouches {
    public static let step = 0.008

    /// Fingers landing together at `points`, held still for `hold` seconds, then lifting.
    /// `jitter` moves each finger that far over the hold; `stagger` delays each next finger.
    public static func tap(_ points: [(Double, Double)], at start: Double = 0, hold: Double = 0.1,
                           jitter: Double = 0, stagger: Double = 0, pressure: Double = 0.35,
                           majorAxis: Double = 7, idBase: Int = 1) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        let span = hold + stagger * Double(points.count - 1)
        var t = start
        while t <= start + span + 1e-9 {
            var touches: [TouchSample] = []
            for (i, p) in points.enumerated() {
                let landed = start + stagger * Double(i)
                guard t >= landed - 1e-9 else { continue }
                let f = span > 0 ? (t - start) / span : 0
                touches.append(TouchSample(id: idBase + i, x: p.0 + jitter * f, y: p.1, pressure: pressure, majorAxis: majorAxis))
            }
            frames.append(TouchFrame(time: t, touches: touches))
            t += step
        }
        frames.append(lift(at: t))
        return frames
    }

    /// One finger sliding from `from` to `to` over `duration`, then lifting.
    public static func swipe(from: (Double, Double), to: (Double, Double), at start: Double = 0,
                             duration: Double = 0.25, id: Int = 1) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        var t = start
        while t <= start + duration + 1e-9 {
            let f = duration > 0 ? (t - start) / duration : 1
            frames.append(TouchFrame(time: t, touches: [TouchSample(id: id, x: from.0 + (to.0 - from.0) * f,
                                                                    y: from.1 + (to.1 - from.1) * f)]))
            t += step
        }
        frames.append(lift(at: t))
        return frames
    }

    /// Fingers resting, pressure ramping from light to `peak` over `duration`, then lifting.
    public static func press(_ points: [(Double, Double)], at start: Double = 0, duration: Double = 0.5,
                             peak: Double = 1.2) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        var t = start
        while t <= start + duration + 1e-9 {
            let f = (t - start) / duration
            let z = 0.35 + (peak - 0.35) * f
            frames.append(TouchFrame(time: t, touches: points.enumerated().map {
                TouchSample(id: $0.offset + 1, x: $0.element.0, y: $0.element.1, pressure: z)
            }))
            t += step
        }
        frames.append(lift(at: t))
        return frames
    }

    /// The frame after the fingers leave: the sensor reports them leaving, then nothing.
    public static func lift(at time: Double) -> TouchFrame { TouchFrame(time: time, touches: []) }

    /// Runs frames through a fresh recognizer and collects what fired.
    public static func recognize(_ frames: [TouchFrame], tuning: GestureTuning = .standard) -> [TrackpadGesture] {
        var recognizer = GestureRecognizer(tuning: tuning)
        return frames.flatMap { recognizer.feed($0) }
    }
}
