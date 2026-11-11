import Foundation
import Testing
@testable import DockCore

private typealias S = SyntheticTouches
private let three = [(0.40, 0.45), (0.50, 0.50), (0.60, 0.45)]
private let four = [(0.30, 0.45), (0.42, 0.52), (0.54, 0.52), (0.66, 0.45)]

@Test func threeAndFourFingerTaps() {
    #expect(S.recognize(S.tap(three)) == [.threeTap])
    #expect(S.recognize(S.tap(four)) == [.fourTap])
    // One finger and plain two-finger taps are macOS's own click and secondary click.
    #expect(S.recognize(S.tap([(0.5, 0.5)])).isEmpty)
    #expect(S.recognize(S.tap([(0.45, 0.5), (0.55, 0.5)])).isEmpty)
    // Five fingers is not one of ours.
    #expect(S.recognize(S.tap(four + [(0.2, 0.3)])).isEmpty)
}

@Test func tapVersusDragAndHold() {
    // A little wobble is still a tap...
    #expect(S.recognize(S.tap(three, jitter: 0.02)) == [.threeTap])
    // ...moving further is a three-finger drag or swipe, which stays with macOS.
    #expect(S.recognize(S.tap(three, jitter: 0.08)).isEmpty)
    // Resting too long is not a tap either.
    #expect(S.recognize(S.tap(three, hold: 0.45)).isEmpty)
    #expect(S.recognize(S.tap(three, hold: 0.28)) == [.threeTap])
}

@Test func fingersMustLandTogether() {
    #expect(S.recognize(S.tap(three, hold: 0.06, stagger: 0.03)) == [.threeTap])
    // A hand resting, then more fingers much later: not one tap.
    #expect(S.recognize(S.tap(three, hold: 0.05, stagger: 0.09)).isEmpty)
}

@Test func fingerCountHysteresis() {
    // Three fingers tapping, with a fourth brushing the glass for a single frame.
    var frames = S.tap(three, hold: 0.1)
    frames[5].touches.append(TouchSample(id: 9, x: 0.75, y: 0.4))
    var recognizer = GestureRecognizer()
    var fired: [TrackpadGesture] = []
    for frame in frames { fired += recognizer.feed(frame) }
    // The brush never held long enough to count: still a three-finger tap, never a four.
    #expect(fired == [.threeTap])
    // A fourth finger that really joins (held) is a different touch: not a three-finger tap.
    var joined = S.tap(three, hold: 0.1)
    for i in 3..<9 { joined[i].touches.append(TouchSample(id: 9, x: 0.75, y: 0.4)) }
    #expect(S.recognize(joined) != [.threeTap])

    // A count that wobbles for one frame in the middle (a finger reading as lifted) holds.
    var wobble = S.tap(four, hold: 0.12)
    wobble[6].touches.removeLast()
    #expect(S.recognize(wobble) == [.fourTap])

    // The live count follows only once a count has held.
    var live = GestureRecognizer()
    _ = live.feed(TouchFrame(time: 0, touches: [TouchSample(id: 1, x: 0.5, y: 0.5)]))
    #expect(live.fingers == 0)
    _ = live.feed(TouchFrame(time: 0.024, touches: [TouchSample(id: 1, x: 0.5, y: 0.5)]))
    #expect(live.fingers == 1)
    _ = live.feed(TouchFrame(time: 0.032, touches: [TouchSample(id: 1, x: 0.5, y: 0.5), TouchSample(id: 2, x: 0.6, y: 0.5)]))
    #expect(live.fingers == 1)
    _ = live.feed(TouchFrame(time: 0.06, touches: [TouchSample(id: 1, x: 0.5, y: 0.5), TouchSample(id: 2, x: 0.6, y: 0.5)]))
    #expect(live.fingers == 2)
}

@Test func twoFingerCornerTaps() {
    #expect(S.recognize(S.tap([(0.08, 0.92), (0.16, 0.88)])) == [.topLeftTap])
    #expect(S.recognize(S.tap([(0.86, 0.9), (0.94, 0.86)])) == [.topRightTap])
    // Bottom corners and the middle are left to secondary click.
    #expect(S.recognize(S.tap([(0.08, 0.1), (0.16, 0.12)])).isEmpty)
    #expect(S.recognize(S.tap([(0.45, 0.9), (0.55, 0.9)])).isEmpty)
    // A two-finger scroll that starts in a corner is a scroll.
    #expect(S.recognize(S.tap([(0.08, 0.92), (0.16, 0.88)], jitter: 0.1)).isEmpty)
}

@Test func oneFingerEdgeSwipes() {
    #expect(S.recognize(S.swipe(from: (0.02, 0.5), to: (0.35, 0.52))) == [.swipeFromLeft])
    #expect(S.recognize(S.swipe(from: (0.98, 0.5), to: (0.66, 0.48))) == [.swipeFromRight])
    // Starting away from the edge is moving the pointer.
    #expect(S.recognize(S.swipe(from: (0.2, 0.5), to: (0.6, 0.5))).isEmpty)
    // Too short.
    #expect(S.recognize(S.swipe(from: (0.02, 0.5), to: (0.12, 0.5))).isEmpty)
    // Outwards, or mostly up and down, is not a swipe in.
    #expect(S.recognize(S.swipe(from: (0.03, 0.5), to: (0.0, 0.5))).isEmpty)
    #expect(S.recognize(S.swipe(from: (0.03, 0.2), to: (0.2, 0.8))).isEmpty)
    // Too slow: a pointer move that happened to start at the edge.
    #expect(S.recognize(S.swipe(from: (0.02, 0.5), to: (0.4, 0.5), duration: 1.2)).isEmpty)
}

@Test func edgeSwipeFiresMidTouchOnce() {
    var recognizer = GestureRecognizer()
    var firedAt: [Int] = []
    let frames = S.swipe(from: (0.02, 0.5), to: (0.5, 0.5), duration: 0.3)
    for (i, frame) in frames.enumerated() where !recognizer.feed(frame).isEmpty { firedAt.append(i) }
    #expect(firedAt.count == 1)
    // It fires as soon as it has gone far enough, well before the finger lifts.
    #expect(firedAt[0] < frames.count / 2)
    // A second finger joining makes it a two-finger gesture, not an edge swipe.
    var two = S.swipe(from: (0.02, 0.5), to: (0.4, 0.5), duration: 0.3)
    for i in two.indices.dropLast() { two[i].touches.append(TouchSample(id: 7, x: 0.5, y: 0.3)) }
    #expect(S.recognize(two).isEmpty)
}

@Test func palmRejection() {
    // A palm resting at the bottom while three fingers tap: still a three-finger tap.
    var frames = S.tap(three)
    for i in frames.indices.dropLast() {
        frames[i].touches.append(TouchSample(id: 20, x: 0.8, y: 0.08, majorAxis: 16))
    }
    #expect(S.recognize(frames) == [.threeTap])
    // A palm alone does nothing, and does not count as a finger.
    #expect(S.recognize(S.tap([(0.3, 0.1), (0.7, 0.1)], majorAxis: 15)).isEmpty)
    var recognizer = GestureRecognizer()
    _ = recognizer.feed(TouchFrame(time: 0, touches: [TouchSample(id: 1, x: 0.5, y: 0.1, majorAxis: 18)]))
    #expect(!recognizer.active)
    // Two palms and two fingers in the corner: a corner tap, not a four-finger tap.
    var corner = S.tap([(0.08, 0.92), (0.16, 0.88)])
    for i in corner.indices.dropLast() {
        corner[i].touches += [TouchSample(id: 30, x: 0.2, y: 0.1, majorAxis: 14), TouchSample(id: 31, x: 0.8, y: 0.1, majorAxis: 14)]
    }
    #expect(S.recognize(corner) == [.topLeftTap])
}

@Test func hoveringFingersDoNotCount() {
    // Fingers hovering or leaving (states 1, 2, 5, 6) are not on the glass.
    var frames = S.tap(three)
    for i in frames.indices.dropLast() {
        frames[i].touches.append(TouchSample(id: 40, x: 0.9, y: 0.5, state: TouchPhase.hoverInRange.rawValue))
    }
    #expect(S.recognize(frames) == [.threeTap])
    let lingering = TouchFrame(time: 0, touches: [TouchSample(id: 1, x: 0.5, y: 0.5, state: TouchPhase.lingerInRange.rawValue)])
    var recognizer = GestureRecognizer()
    #expect(recognizer.feed(lingering).isEmpty)
    #expect(!recognizer.active)
}

@Test func threeFingerForcePress() {
    #expect(S.recognize(S.press(three, peak: 1.3)) == [.threeForce])
    // Light pressure, held a while, is nothing.
    #expect(S.recognize(S.press(three, peak: 0.5)).isEmpty)
    // A firm press does not also count as a tap, even when it is quick.
    #expect(S.recognize(S.press(three, duration: 0.2, peak: 1.6)) == [.threeForce])
    // Two fingers pressing hard is not ours.
    #expect(S.recognize(S.press([(0.4, 0.5), (0.6, 0.5)], peak: 1.5)).isEmpty)
    // The threshold is tunable.
    var soft = GestureTuning()
    soft.forceThreshold = 0.45
    #expect(S.recognize(S.press(three, peak: 0.5), tuning: soft) == [.threeForce])
}

@Test func gesturesBackToBack() {
    // Two taps in a row are two gestures; the recognizer resets between them.
    let frames = S.tap(three) + S.tap(four, at: 0.4) + S.swipe(from: (0.98, 0.5), to: (0.6, 0.5), at: 0.9)
    #expect(S.recognize(frames) == [.threeTap, .fourTap, .swipeFromRight])
}

@Test func gestureMetadata() {
    #expect(TrackpadGesture(rawValue: "threeTap") == .threeTap)
    #expect(TrackpadGesture.allCases.count == 7)
    #expect(TrackpadGesture.topRightTap.fingers == 2)
    #expect(TrackpadGesture.swipeFromLeft.fingers == 1)
}

@Test func firmPressNeedsForceTouch() {
    let press = SyntheticTouches.press([(0.3, 0.5), (0.5, 0.5), (0.7, 0.5)], peak: 1.3)
    #expect(SyntheticTouches.recognize(press).contains(.threeForce))
    var noForce = GestureTuning.standard
    noForce.forceEnabled = false
    #expect(!SyntheticTouches.recognize(press, tuning: noForce).contains(.threeForce))
    // Taps do not read pressure, so they still work without Force Touch.
    let tap = SyntheticTouches.tap([(0.3, 0.5), (0.5, 0.5), (0.7, 0.5)])
    #expect(SyntheticTouches.recognize(tap, tuning: noForce) == [.threeTap])
    #expect(TrackpadGesture.allCases.filter(\.needsForceTouch) == [.threeForce])
}

@Test func multitouchDevicesExcludeMice() {
    // The M5's built-in trackpad, as measured: family 111, 156 × 96 mm.
    #expect(MultitouchDeviceKind.classify(family: 111, builtIn: true, surface: (15600, 9600)) == .trackpad)
    // A Magic Trackpad with unknown family is still a trackpad (wider than deep).
    #expect(MultitouchDeviceKind.classify(family: nil, builtIn: false, surface: (16000, 11500)) == .trackpad)
    #expect(MultitouchDeviceKind.classify(family: nil, builtIn: false, surface: nil) == .trackpad)
    // Magic Mouse by family, and by shape when the family is unknown.
    #expect(MultitouchDeviceKind.classify(family: 112, builtIn: false, surface: nil) == .mouse)
    #expect(MultitouchDeviceKind.classify(family: 113, builtIn: false, surface: (5700, 9700)) == .mouse)
    #expect(MultitouchDeviceKind.classify(family: 999, builtIn: false, surface: (5700, 9700)) == .mouse)
}

@Test func inputSupportVerdicts() {
    #expect(InputSupport.gestures(frameworkLoaded: false, trackpads: 1, forceTrackpads: 1) != .available)
    if case .unavailable = InputSupport.gestures(frameworkLoaded: true, trackpads: 0, forceTrackpads: 0) {} else { Issue.record("no trackpad must be unavailable") }
    if case .limited = InputSupport.gestures(frameworkLoaded: true, trackpads: 1, forceTrackpads: 0) {} else { Issue.record("no Force Touch must be limited") }
    #expect(InputSupport.gestures(frameworkLoaded: true, trackpads: 2, forceTrackpads: 1) == .available)
    #expect(InputSupport.haptics(actuators: 1, forceTrackpads: 1) == .available)
    if case .limited = InputSupport.haptics(actuators: 0, forceTrackpads: 1) {} else { Issue.record("fallback must be limited") }
    if case .unavailable = InputSupport.haptics(actuators: 0, forceTrackpads: 0) {} else { Issue.record("no Force Touch must be unavailable") }
}
