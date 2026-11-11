import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private typealias G = SyntheticTitleBar

// MARK: - Recogniser: swipes

@Test func cardinalSwipes() {
    #expect(G.recognize(G.gesture(delta: (0.15, 0))) == [.right])
    #expect(G.recognize(G.gesture(delta: (-0.15, 0))) == [.left])
    // y grows towards the far edge: fingers pushed away from you are a swipe up.
    #expect(G.recognize(G.gesture(delta: (0, 0.2))) == [.up])
    #expect(G.recognize(G.gesture(delta: (0, -0.2))) == [.down])
}

@Test func diagonalSwipes() {
    // 0.13 sideways is 0.21 pad heights, matching 0.21 up: 45°.
    #expect(G.recognize(G.gesture(delta: (0.13, 0.21))) == [.topRight])
    #expect(G.recognize(G.gesture(delta: (-0.13, 0.21))) == [.topLeft])
    #expect(G.recognize(G.gesture(delta: (-0.13, -0.21))) == [.bottomLeft])
    #expect(G.recognize(G.gesture(delta: (0.13, -0.21))) == [.bottomRight])
}

@Test func diagonalsCanBeTurnedOff() {
    var tuning = TitleBarTuning()
    tuning.diagonals = false
    let gesture = G.recognize(G.gesture(delta: (0.13, 0.22)), tuning: tuning)
    #expect(gesture == [.up] || gesture == [.right])
}

@Test func directionSectors() {
    let t = TitleBarTuning()
    #expect(TitleBarRecognizer.direction(dx: 1, dy: 0, tuning: t) == .right)
    #expect(TitleBarRecognizer.direction(dx: -1, dy: 0.1, tuning: t) == .left)
    #expect(TitleBarRecognizer.direction(dx: 0.05, dy: 1, tuning: t) == .up)
    #expect(TitleBarRecognizer.direction(dx: 0, dy: -1, tuning: t) == .down)
    #expect(TitleBarRecognizer.direction(dx: 1, dy: 1, tuning: t) == .topRight)
    // 25° lies outside the diagonal's 16° sector: right.
    #expect(TitleBarRecognizer.direction(dx: cos(25 * .pi / 180), dy: sin(25 * .pi / 180), tuning: t) == .right)
    // 65° falls to up.
    #expect(TitleBarRecognizer.direction(dx: cos(65 * .pi / 180), dy: sin(65 * .pi / 180), tuning: t) == .up)
    // 40° is inside the diagonal sector.
    #expect(TitleBarRecognizer.direction(dx: cos(40 * .pi / 180), dy: sin(40 * .pi / 180), tuning: t) == .topRight)
    #expect(TitleBarRecognizer.direction(dx: -1, dy: -1, tuning: t) == .bottomLeft)
    #expect(TitleBarRecognizer.direction(dx: 1, dy: -1, tuning: t) == .bottomRight)
}

@Test func tooShortIsNothing() {
    #expect(G.recognize(G.gesture(delta: (0.04, 0), duration: 0.4)).isEmpty)
    #expect(G.recognize(G.gesture(delta: (0, 0.08), duration: 0.5)).isEmpty)
    // Resting two fingers is no gesture at all.
    #expect(G.recognize(G.gesture(delta: (0, 0), duration: 0.4)).isEmpty)
}

@Test func flickCommitsEarly() {
    // Three quarters of the travel, fast: a flick.
    #expect(G.recognize(G.gesture(delta: (0.07, 0), duration: 0.05)) == [.right])
    // The same distance slowly is not enough.
    #expect(G.recognize(G.gesture(delta: (0.07, 0), duration: 0.6)).isEmpty)
}

@Test func sensitivityScalesThresholds() {
    let short = G.gesture(delta: (0.07, 0), duration: 0.6)
    var eager = TitleBarTuning()
    eager.sensitivity = 2
    #expect(G.recognize(short, tuning: eager) == [.right])
    var calm = TitleBarTuning()
    calm.sensitivity = 0.5
    #expect(G.recognize(G.gesture(delta: (0.15, 0), duration: 0.6), tuning: calm).isEmpty)
    #expect(G.recognize(G.gesture(delta: (0.3, 0), duration: 0.6), tuning: calm) == [.right])
    // Clamped to a sane range.
    var wild = TitleBarTuning()
    wild.sensitivity = 50
    #expect(wild.sensitivity == 3)
}

@Test func goingBackCancels() {
    // Out past the threshold, then back to where it started before lifting: changed mind.
    var frames = G.gesture(delta: (0.15, 0), duration: 0.2)
    let lift = frames.removeLast()
    var t = frames.last!.time
    for i in 1...25 {
        t += G.step
        let x = 0.5 + 0.15 * (1 - Double(i) / 25)
        frames.append(TouchFrame(time: t, touches: [TouchSample(id: 1, x: x - 0.06, y: 0.5), TouchSample(id: 2, x: x + 0.06, y: 0.5)]))
    }
    frames.append(TouchFrame(time: t + G.step, touches: lift.touches))
    let readings = G.readings(frames)
    #expect(readings.compactMap(\.committed).isEmpty)
    #expect(readings.last?.cancelled == true)
    #expect(readings.contains { $0.claimed })
}

@Test func changingDirectionMidwayFollowsTheFingers() {
    // Start right, then sweep up: the gesture is what the fingers say at the lift.
    var frames = G.gesture(delta: (0.05, 0), duration: 0.1)
    frames.removeLast()
    var t = frames.last!.time
    for i in 1...30 {
        t += G.step
        let y = 0.5 + 0.25 * Double(i) / 30
        frames.append(TouchFrame(time: t, touches: [TouchSample(id: 1, x: 0.49, y: y), TouchSample(id: 2, x: 0.61, y: y)]))
    }
    frames.append(TouchFrame(time: t + G.step, touches: []))
    #expect(G.recognize(frames) == [.up])
}

// MARK: - Recogniser: pinches

@Test func pinches() {
    #expect(G.recognize(G.gesture(spacing: 0.3, spread: -0.15)) == [.pinchIn])
    #expect(G.recognize(G.gesture(spacing: 0.12, spread: 0.15)) == [.pinchOut])
    // A small pinch is nothing.
    #expect(G.recognize(G.gesture(spacing: 0.3, spread: -0.03, duration: 0.5)).isEmpty)
}

@Test func pinchWhileDriftingIsStillAPinch() {
    #expect(G.recognize(G.gesture(spacing: 0.3, delta: (0.02, 0.01), spread: -0.18)) == [.pinchIn])
}

@Test func swipeWithSlightSpreadIsASwipe() {
    #expect(G.recognize(G.gesture(delta: (0.18, 0), spread: 0.02)) == [.right])
}

@Test func opposedFingersAreNotASwipe() {
    // Two fingers turning about their midpoint: a rotation, which is not ours.
    var frames: [TouchFrame] = []
    var t = 0.0
    let k = TitleBarTuning.standard.aspect
    for i in 0...40 {
        let angle = Double(i) / 40 * .pi / 3
        let r = 0.1
        let a = (0.5 + r * cos(angle) / k, 0.5 + r * sin(angle)), b = (0.5 - r * cos(angle) / k, 0.5 - r * sin(angle))
        frames.append(TouchFrame(time: t, touches: [TouchSample(id: 1, x: a.0, y: a.1), TouchSample(id: 2, x: b.0, y: b.1)]))
        t += G.step
    }
    frames.append(TouchFrame(time: t, touches: []))
    #expect(G.recognize(frames).isEmpty)
}

// MARK: - Recogniser: whose touch it is

@Test func threeFingersBelongToMacOS() {
    var frames = G.gesture(delta: (0.2, 0))
    for i in 3..<frames.count - 1 { frames[i].touches.append(TouchSample(id: 3, x: 0.3, y: 0.4)) }
    #expect(G.recognize(frames).isEmpty)
}

@Test func thirdFingerLateCancelsAClaimedGesture() {
    var frames = G.gesture(delta: (0.2, 0), duration: 0.3)
    let late = frames.count - 6
    for i in late..<frames.count - 1 { frames[i].touches.append(TouchSample(id: 3, x: 0.3, y: 0.4)) }
    let readings = G.readings(frames)
    #expect(readings.compactMap(\.committed).isEmpty)
    #expect(readings.contains { $0.cancelled })
}

@Test func oneFingerIsThePointer() {
    #expect(SyntheticTitleBar.recognize(SyntheticTouches.swipe(from: (0.3, 0.5), to: (0.7, 0.5))).isEmpty)
}

@Test func edgeLandingIsNotificationCenter() {
    // Two fingers landing at the right edge and swiping left: Notification Center's.
    #expect(G.recognize(G.gesture(center: (0.92, 0.5), spacing: 0.08, delta: (-0.3, 0))).isEmpty)
    #expect(G.recognize(G.gesture(center: (0.06, 0.5), spacing: 0.08, delta: (0.3, 0))).isEmpty)
}

@Test func palmIsIgnored() {
    var frames = G.gesture(delta: (0.15, 0))
    for i in 0..<frames.count - 1 {
        frames[i].touches.append(TouchSample(id: 7, x: 0.2, y: 0.1, majorAxis: 14))
    }
    #expect(G.recognize(frames) == [.right])
}

@Test func spoilIgnoresTheTouch() {
    let frames = G.gesture(delta: (0.2, 0))
    var recognizer = TitleBarRecognizer()
    var fired: [TitleBarGesture] = []
    for frame in frames {
        let reading = recognizer.feed(frame)
        if reading.anchored { recognizer.spoil() }
        if let gesture = reading.committed { fired.append(gesture) }
    }
    #expect(fired.isEmpty)
    #expect(!recognizer.active)
}

@Test func anchorsOnceAfterHysteresis() {
    let readings = G.readings(G.gesture(delta: (0.2, 0)))
    #expect(readings.filter(\.anchored).count == 1)
    // Not on the very first frame: the count has to hold first.
    #expect(readings.first?.anchored == false)
}

@Test func claimComesBeforeCommit() {
    let readings = G.readings(G.gesture(delta: (0.2, 0), duration: 0.3))
    let claim = readings.firstIndex { $0.claimed }
    let commit = readings.firstIndex { $0.committed != nil }
    #expect(claim != nil && commit != nil && claim! < commit!)
    // Progress climbs to 1 before the lift.
    #expect(readings.dropLast().last?.progress == 1)
    #expect(readings.dropLast().last?.candidate == .right)
}

@Test func staggeredLiftStillCommits() {
    #expect(G.recognize(G.gesture(delta: (0.2, 0), liftTogether: false)) == [.right])
}

@Test func oneFingerStayingDownSettlesAfterGrace() {
    var frames = G.gesture(delta: (0.2, 0))
    frames.removeLast()
    var t = frames.last!.time
    // One finger stays and wanders off: the gesture settles once, then the finger is the pointer's.
    for i in 0..<60 {
        t += G.step
        frames.append(TouchFrame(time: t, touches: [TouchSample(id: 1, x: 0.6 - Double(i) * 0.005, y: 0.5)]))
    }
    frames.append(TouchFrame(time: t + G.step, touches: []))
    #expect(G.recognize(frames) == [.right])
}

@Test func restingTooLongSpoils() {
    var frames = G.gesture(delta: (0, 0), duration: 1.5)
    frames.removeLast()
    var t = frames.last!.time
    for i in 1...30 {
        t += G.step
        let x = 0.5 + 0.2 * Double(i) / 30
        frames.append(TouchFrame(time: t, touches: [TouchSample(id: 1, x: x - 0.06, y: 0.5), TouchSample(id: 2, x: x + 0.06, y: 0.5)]))
    }
    frames.append(TouchFrame(time: t + G.step, touches: []))
    #expect(G.recognize(frames).isEmpty)
}

@Test func swappedFingerIsNotOneGesture() {
    var frames = G.gesture(delta: (0.2, 0))
    // Mid-gesture, finger 2 is replaced by finger 9.
    for i in 10..<frames.count - 1 {
        frames[i].touches = frames[i].touches.map { $0.id == 2 ? TouchSample(id: 9, x: $0.x, y: $0.y) : $0 }
    }
    #expect(G.recognize(frames).isEmpty)
}

@Test func consecutiveGesturesEachCount() {
    let one = G.gesture(delta: (0.2, 0))
    let two = G.gesture(delta: (0, -0.25), at: one.last!.time + 0.2)
    #expect(G.recognize(one + two) == [.right, .down])
}

// MARK: - Geometry

private let screen = TitleBarDisplay(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     visible: CGRect(x: 0, y: 33, width: 1512, height: 949))
private let rightScreen = TitleBarDisplay(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                                          visible: CGRect(x: 1512, y: -175, width: 2560, height: 1415))
private let leftScreen = TitleBarDisplay(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                         visible: CGRect(x: -1920, y: 25, width: 1920, height: 1055))

@Test func halvesAndQuartersWithGaps() {
    let v = screen.visible
    let left = TitleBarGeometry.frame(.leftHalf, in: v, gap: 8)
    let right = TitleBarGeometry.frame(.rightHalf, in: v, gap: 8)
    #expect(left == CGRect(x: 8, y: 41, width: 744, height: 933))
    #expect(right == CGRect(x: 760, y: 41, width: 744, height: 933))
    #expect(right.minX - left.maxX == 8)
    let tl = TitleBarGeometry.frame(.topLeft, in: v, gap: 8)
    let br = TitleBarGeometry.frame(.bottomRight, in: v, gap: 8)
    #expect(tl.minX == 8 && tl.minY == 41)
    #expect(br.maxX == 1504 && br.maxY == 974)
    #expect(TitleBarGeometry.frame(.maximize, in: v, gap: 8) == v.insetBy(dx: 8, dy: 8))
    #expect(TitleBarGeometry.frame(.maximize, in: v, gap: 0) == v)
    let top = TitleBarGeometry.frame(.topHalf, in: v, gap: 0), bottom = TitleBarGeometry.frame(.bottomHalf, in: v, gap: 0)
    #expect(top.maxY == bottom.minY && top.width == v.width)
}

@Test func quartersTileTheScreen() {
    let v = screen.visible
    let tiles: [TitleBarTile] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    let area = tiles.map { TitleBarGeometry.frame($0, in: v, gap: 0) }.reduce(0.0) { $0 + $1.width * $1.height }
    #expect(abs(area - v.width * v.height) < v.width + v.height)
}

@Test func centeredAndClamped() {
    let v = screen.visible
    let c = TitleBarGeometry.centered(CGSize(width: 800, height: 600), in: v, gap: 8)
    #expect(c == CGRect(x: 356, y: 208, width: 800, height: 600))
    // Too large: shrunk into the room inside the gap.
    let big = TitleBarGeometry.centered(CGSize(width: 4000, height: 3000), in: v, gap: 8)
    #expect(big.width == v.width - 16 && big.height == v.height - 16)
    let off = TitleBarGeometry.clamped(CGRect(x: 1400, y: -50, width: 500, height: 400), into: v)
    #expect(off == CGRect(x: 1012, y: 33, width: 500, height: 400))
}

@Test func stageManagerStrip() {
    let v = screen.visible
    #expect(TitleBarGeometry.usable(v, stageManager: false, stripHidden: false) == v)
    #expect(TitleBarGeometry.usable(v, stageManager: true, stripHidden: true) == v)
    let usable = TitleBarGeometry.usable(v, stageManager: true, stripHidden: false)
    #expect(usable.minX == TitleBarGeometry.stageStrip && usable.maxX == v.maxX)
    // A tiny display keeps its whole width.
    let small = CGRect(x: 0, y: 0, width: 200, height: 200)
    #expect(TitleBarGeometry.usable(small, stageManager: true, stripHidden: false) == small)
}

@Test func displayIndexAndNeighbours() {
    let all = [screen, rightScreen, leftScreen]
    #expect(TitleBarGeometry.displayIndex(of: CGRect(x: 100, y: 100, width: 300, height: 300), in: all) == 0)
    // Mostly on the right display.
    #expect(TitleBarGeometry.displayIndex(of: CGRect(x: 1400, y: 100, width: 600, height: 300), in: all) == 1)
    #expect(TitleBarGeometry.displayIndex(of: CGRect(x: -800, y: 100, width: 300, height: 300), in: all) == 2)
    // Off every display: the nearest.
    #expect(TitleBarGeometry.displayIndex(of: CGRect(x: 700, y: 1100, width: 100, height: 100), in: all) == 0)
    #expect(TitleBarGeometry.displayIndex(of: .zero, in: []) == nil)
    #expect(TitleBarGeometry.neighbour(of: 0, .right, in: all) == 1)
    #expect(TitleBarGeometry.neighbour(of: 0, .left, in: all) == 2)
    #expect(TitleBarGeometry.neighbour(of: 1, .left, in: all) == 0)
    #expect(TitleBarGeometry.neighbour(of: 1, .right, in: all) == nil)
    #expect(TitleBarGeometry.neighbour(of: 2, .left, in: all) == nil)
    #expect(TitleBarGeometry.neighbour(of: 9, .left, in: all) == nil)
}

@Test func neighbourPrefersOverlappingDisplays() {
    // One display far to the right but stacked below, one adjacent at the same height.
    let below = TitleBarDisplay(frame: CGRect(x: 1600, y: 1200, width: 1000, height: 800), visible: CGRect(x: 1600, y: 1200, width: 1000, height: 800))
    let beside = TitleBarDisplay(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1512, y: 25, width: 1920, height: 1055))
    #expect(TitleBarGeometry.neighbour(of: 0, .right, in: [screen, below, beside]) == 2)
}

@Test func proportionalMove() {
    let window = CGRect(x: 0, y: 33, width: 756, height: 474.5)
    let moved = TitleBarGeometry.proportional(window, from: screen.visible, to: rightScreen.visible)
    #expect(moved.minX == 1512 && moved.minY == -175)
    #expect(abs(moved.width - 1280) <= 1 && abs(moved.height - 707.5) <= 1)
}

@Test func frameMatching() {
    let a = CGRect(x: 8, y: 41, width: 744, height: 933)
    #expect(TitleBarGeometry.matches(a, a))
    #expect(TitleBarGeometry.matches(a, a.insetBy(dx: 2, dy: 2)))
    #expect(!TitleBarGeometry.matches(a, a.offsetBy(dx: 20, dy: 0)))
    #expect(TitleBarGeometry.matches(a, CGRect(x: 8, y: 41, width: 735, height: 925), tolerance: 10))
}

@Test func titleBarBand() {
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    #expect(TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 110), window: window, band: 40))
    #expect(TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 140), window: window, band: 40))
    #expect(!TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 141), window: window, band: 40))
    #expect(!TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 99), window: window, band: 40))
    #expect(!TitleBarGeometry.inTitleBar(CGPoint(x: 950, y: 110), window: window, band: 40))
    // A tall toolbar extends the band; a short one does not shrink it.
    #expect(TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 170), window: window, band: 40, toolbarBottom: 178))
    #expect(TitleBarGeometry.inTitleBar(CGPoint(x: 400, y: 135), window: window, band: 40, toolbarBottom: 120))
    // Never below the window.
    let short = CGRect(x: 0, y: 0, width: 300, height: 30)
    #expect(!TitleBarGeometry.inTitleBar(CGPoint(x: 10, y: 35), window: short, band: 40))
}

@Test func previewEasesTowardsTarget() {
    let from = CGRect(x: 300, y: 200, width: 600, height: 400)
    let to = CGRect(x: 8, y: 41, width: 744, height: 933)
    #expect(TitleBarGeometry.preview(from: from, to: to, progress: 0) == from)
    #expect(TitleBarGeometry.preview(from: from, to: to, progress: 1) == to)
    #expect(TitleBarGeometry.preview(from: from, to: to, progress: 3) == to)
    let half = TitleBarGeometry.preview(from: from, to: to, progress: 0.5)
    // Ease out: past halfway at half progress.
    #expect(half.minX < (from.minX + to.minX) / 2)
}

// MARK: - Planning and cycles

private func context(_ frame: CGRect, displays: [TitleBarDisplay] = [screen], saved: CGRect? = nil,
                     full: Bool = false, last: TitleBarCommit? = nil) -> TitleBarContext {
    TitleBarContext(window: 42, frame: frame, displays: displays, gap: 8, saved: saved, isFullScreen: full, last: last)
}

private let floating = CGRect(x: 300, y: 200, width: 700, height: 500)

@Test func defaultBindings() {
    #expect(TitleBarBinding.standard(.left) == TitleBarBinding(.leftHalf, again: .displayLeft))
    #expect(TitleBarBinding.standard(.up) == TitleBarBinding(.maximize, again: .fullScreen))
    #expect(TitleBarBinding.standard(.down) == TitleBarBinding(.restore, again: .minimize))
    #expect(TitleBarBinding.standard(.pinchIn).first == .close)
    #expect(TitleBarBinding.standard(.pinchOut).first == .fullScreen)
    #expect(TitleBarBinding.standard(.topRight).first == .topRight)
    for gesture in TitleBarGesture.allCases { #expect(TitleBarBinding.standard(gesture).first != .none) }
}

@Test func firstSwipeTiles() {
    let (plan, again) = TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(floating))
    #expect(plan == .frame(CGRect(x: 8, y: 41, width: 744, height: 933), display: 0))
    #expect(!again)
    let (up, _) = TitleBarPlanner.plan(.up, binding: .standard(.up), context: context(floating))
    #expect(up == .frame(screen.visible.insetBy(dx: 8, dy: 8), display: 0))
    let (quarter, _) = TitleBarPlanner.plan(.bottomRight, binding: .standard(.bottomRight), context: context(floating))
    if case .frame(let rect, _) = quarter { #expect(rect.maxX == 1504 && rect.maxY == 974) } else { Issue.record("not a frame") }
}

@Test func secondSwipeGoesToTheNextDisplay() {
    let all = [screen, rightScreen, leftScreen]
    let leftHalf = TitleBarGeometry.frame(.leftHalf, in: screen.visible, gap: 8)
    let (plan, again) = TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(leftHalf, displays: all))
    #expect(again)
    #expect(plan == .frame(TitleBarGeometry.frame(.rightHalf, in: leftScreen.visible, gap: 8), display: 2))
    let rightHalf = TitleBarGeometry.frame(.rightHalf, in: screen.visible, gap: 8)
    let (right, _) = TitleBarPlanner.plan(.right, binding: .standard(.right), context: context(rightHalf, displays: all))
    #expect(right == .frame(TitleBarGeometry.frame(.leftHalf, in: rightScreen.visible, gap: 8), display: 1))
}

@Test func secondSwipeWithNoDisplayThere() {
    let leftHalf = TitleBarGeometry.frame(.leftHalf, in: screen.visible, gap: 8)
    let (plan, again) = TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(leftHalf))
    #expect(again)
    #expect(plan == .nothing("No display to the left"))
}

@Test func repeatRecognisedFromLastCommitWhenAppRounded() {
    // Terminal took a size a few points off the half; Atelier remembers what it really landed at.
    let landed = CGRect(x: 8, y: 41, width: 731, height: 921)
    let last = TitleBarCommit(window: 42, gesture: .left, landed: landed)
    let (_, again) = TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(landed, last: last))
    #expect(again)
    // Another window, or another gesture, is a first time.
    let other = TitleBarCommit(window: 7, gesture: .left, landed: landed)
    #expect(!TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(landed, last: other)).again)
    let otherGesture = TitleBarCommit(window: 42, gesture: .up, landed: landed)
    #expect(!TitleBarPlanner.plan(.left, binding: .standard(.left), context: context(landed, last: otherGesture)).again)
}

@Test func upTwiceIsFullScreen() {
    let max = TitleBarGeometry.frame(.maximize, in: screen.visible, gap: 8)
    let (plan, again) = TitleBarPlanner.plan(.up, binding: .standard(.up), context: context(max))
    #expect(again && plan == .fullScreen(true))
}

@Test func downRestoresThenMinimises() {
    let max = TitleBarGeometry.frame(.maximize, in: screen.visible, gap: 8)
    let (restore, again) = TitleBarPlanner.plan(.down, binding: .standard(.down), context: context(max, saved: floating))
    #expect(restore == .frame(floating, display: 0) && !again)
    // At its saved frame already: the second swipe down minimises.
    let (second, repeated) = TitleBarPlanner.plan(.down, binding: .standard(.down), context: context(floating, saved: floating))
    #expect(second == .minimize && repeated)
}

@Test func downWithoutSavedFrameCentres() {
    let (plan, _) = TitleBarPlanner.plan(.down, binding: .standard(.down), context: context(floating))
    #expect(plan == .minimize || plan == .frame(TitleBarGeometry.centered(floating.size, in: screen.visible, gap: 8), display: 0))
    let off = CGRect(x: 20, y: 60, width: 700, height: 500)
    let (centre, again) = TitleBarPlanner.plan(.down, binding: .standard(.down), context: context(off))
    #expect(!again)
    #expect(centre == .frame(TitleBarGeometry.centered(off.size, in: screen.visible, gap: 8), display: 0))
    // Centred already: again is minimise.
    let centred = TitleBarGeometry.centered(off.size, in: screen.visible, gap: 8)
    #expect(TitleBarPlanner.plan(.down, binding: .standard(.down), context: context(centred)).plan == .minimize)
}

@Test func restoringAMaximisedWindowWithNoMemoryShrinksIt() {
    let max = TitleBarGeometry.frame(.maximize, in: screen.visible, gap: 8)
    let (plan, _) = TitleBarPlanner.plan(.down, binding: TitleBarBinding(.restore), context: context(max))
    guard case .frame(let rect, _) = plan else { Issue.record("not a frame"); return }
    #expect(rect.width < max.width && rect.height < max.height)
    #expect(abs(rect.midX - screen.visible.midX) <= 1)
}

@Test func restoreClampsASavedFrameFromAGoneDisplay() {
    let saved = CGRect(x: 2000, y: 100, width: 900, height: 700)  // was on a display no longer there
    let (plan, _) = TitleBarPlanner.plan(.down, binding: TitleBarBinding(.restore), context: context(floating, saved: saved))
    guard case .frame(let rect, _) = plan else { Issue.record("not a frame"); return }
    #expect(screen.visible.contains(rect))
}

@Test func pinchesPlan() {
    #expect(TitleBarPlanner.plan(.pinchIn, binding: .standard(.pinchIn), context: context(floating)).plan == .close)
    #expect(TitleBarPlanner.plan(.pinchOut, binding: .standard(.pinchOut), context: context(floating)).plan == .fullScreen(true))
}

@Test func fullScreenWindows() {
    let full = context(screen.frame, full: true)
    #expect(TitleBarPlanner.plan(.down, binding: .standard(.down), context: full).plan == .fullScreen(false))
    #expect(TitleBarPlanner.plan(.pinchOut, binding: .standard(.pinchOut), context: full).plan == .fullScreen(false))
    #expect(TitleBarPlanner.plan(.up, binding: .standard(.up), context: full).plan == .fullScreen(false))
    #expect(TitleBarPlanner.plan(.pinchIn, binding: .standard(.pinchIn), context: full).plan == .close)
    #expect(TitleBarPlanner.plan(.left, binding: .standard(.left), context: full).plan == .nothing("The window is full screen"))
}

@Test func noneAndNextDisplay() {
    #expect(TitleBarPlanner.plan(.left, binding: TitleBarBinding(.none), context: context(floating)).plan == .nothing("No action set"))
    #expect(TitleBarPlanner.action(.nextDisplay, context: context(floating)) == .nothing("Only one display"))
    let all = [screen, rightScreen]
    guard case .frame(let rect, let display) = TitleBarPlanner.action(.nextDisplay, context: context(floating, displays: all)) else {
        Issue.record("not a frame"); return
    }
    #expect(display == 1 && rightScreen.visible.contains(rect))
    // From the last display it wraps to the first.
    let there = CGRect(x: 2000, y: 0, width: 800, height: 600)
    if case .frame(_, let back) = TitleBarPlanner.action(.nextDisplay, context: context(there, displays: all)) { #expect(back == 0) }
}

@Test func noAgainKeepsDoingTheFirst() {
    let leftHalf = TitleBarGeometry.frame(.leftHalf, in: screen.visible, gap: 8)
    let (plan, again) = TitleBarPlanner.plan(.left, binding: TitleBarBinding(.leftHalf), context: context(leftHalf))
    #expect(!again && plan == .frame(leftHalf, display: 0))
}

@Test func previewTargets() {
    let all = [screen]
    #expect(TitleBarPlan.fullScreen(true).previewTarget(window: floating, displays: all) == screen.frame)
    let close = TitleBarPlan.close.previewTarget(window: floating, displays: all)!
    #expect(floating.contains(close) && close.width < floating.width)
    let min = TitleBarPlan.minimize.previewTarget(window: floating, displays: all)!
    #expect(min.maxY <= screen.visible.maxY && abs(min.midX - screen.visible.midX) <= 1)
    #expect(TitleBarPlan.nothing("x").previewTarget(window: floating, displays: all) == nil)
    let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
    #expect(TitleBarPlan.frame(rect, display: 0).previewTarget(window: floating, displays: all) == rect)
}

@Test func titleBarGestureMetadata() {
    #expect(TitleBarGesture.allCases.count == 10)
    #expect(TitleBarGesture.pinchIn.isPinch && !TitleBarGesture.left.isPinch)
    #expect(TitleBarGesture.topLeft.isDiagonal && !TitleBarGesture.up.isDiagonal)
    #expect(TitleBarGesture.up.vector.dy == 1 && TitleBarGesture.left.vector.dx == -1)
    #expect(TitleBarGesture(rawValue: "topLeft") == .topLeft)
    #expect(TitleBarAction.leftHalf.tile == .leftHalf && TitleBarAction.close.tile == nil)
    // Bindings survive a round trip through settings.
    let data = try! JSONEncoder().encode(TitleBarBinding.standard(.left))
    #expect(try! JSONDecoder().decode(TitleBarBinding.self, from: data) == .standard(.left))
}
