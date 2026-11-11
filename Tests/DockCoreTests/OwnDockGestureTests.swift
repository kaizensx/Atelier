import CoreGraphics
import Foundation
import Testing
@testable import DockCore

// MARK: - Settings and mapping

@Test func ownDockGestureDefaults() {
    let settings = OwnDockGestureSettings()
    #expect(settings.action(.swipeUp) == .expose)
    #expect(settings.action(.swipeDown) == .minimize)
    // Pinch to quit is off unless asked for.
    #expect(settings.action(.pinch) == .none)
    #expect(settings.swipes)
}

@Test func ownDockGesturePinchAndNone() {
    var settings = OwnDockGestureSettings(up: .none, down: .none, pinch: true)
    #expect(settings.action(.pinch) == .quit)
    #expect(!settings.swipes)
    settings.down = .hide
    #expect(settings.swipes)
    #expect(settings.action(.swipeDown) == .hide)
}

@Test func ownDockGestureKindFromClassifier() {
    #expect(OwnDockGestureKind(.restore) == .swipeUp)
    #expect(OwnDockGestureKind(.minimize) == .swipeDown)
    #expect(OwnDockGestureKind(.quit) == .pinch)
    #expect(OwnDockGestureKind(.hide) == nil)
    #expect(OwnDockGestureKind(.show) == nil)
}

@Test func ownDockGestureRawValuesAreStable() {
    #expect(OwnDockGestureAction.allCases.map(\.rawValue) == ["expose", "restore", "minimize", "hide", "quit", "none"])
    #expect(OwnDockGestureKind.allCases.map(\.rawValue) == ["swipeUp", "swipeDown", "pinch"])
}

// MARK: - Router

@Test func routerWheelAlwaysScrolls() {
    var router = OwnDockSwipeRouter()
    #expect(router.route(dx: 0, dy: 10, continuous: false, phase: .none, swipes: true, at: 0) == .scroll)
}

@Test func routerNoSwipesSetAlwaysScrolls() {
    var router = OwnDockSwipeRouter()
    #expect(router.route(dx: 0, dy: 40, continuous: true, phase: .began, swipes: false, at: 0) == .scroll)
}

@Test func routerVerticalLocksToSwipe() {
    var router = OwnDockSwipeRouter()
    #expect(router.route(dx: 0, dy: 2, continuous: true, phase: .began, swipes: true, at: 0) == .hold)
    #expect(router.route(dx: 1, dy: 3, continuous: true, phase: .changed, swipes: true, at: 0.01) == .hold)
    #expect(router.route(dx: 0, dy: 3, continuous: true, phase: .changed, swipes: true, at: 0.02) == .swipe)
    #expect(router.locked)
    // Once locked, even sideways movement stays with the swipe.
    #expect(router.route(dx: 30, dy: 0, continuous: true, phase: .changed, swipes: true, at: 0.03) == .swipe)
    #expect(router.route(dx: 0, dy: 0, continuous: true, phase: .ended, swipes: true, at: 0.04) == .swipe)
    #expect(!router.locked)
}

@Test func routerSidewaysLocksToScroll() {
    var router = OwnDockSwipeRouter()
    #expect(router.route(dx: 4, dy: 1, continuous: true, phase: .began, swipes: true, at: 0) == .hold)
    #expect(router.route(dx: 4, dy: 1, continuous: true, phase: .changed, swipes: true, at: 0.01) == .scroll)
    #expect(router.route(dx: 0, dy: 20, continuous: true, phase: .changed, swipes: true, at: 0.02) == .scroll)
    #expect(router.route(dx: 0, dy: 0, continuous: true, phase: .ended, swipes: true, at: 0.03) == .scroll)
}

@Test func routerDiagonalIsNotASwipe() {
    var router = OwnDockSwipeRouter()
    // Equal travel on both axes fails the 1.2 dominance.
    #expect(router.route(dx: 5, dy: 5, continuous: true, phase: .began, swipes: true, at: 0) == .hold)
    #expect(router.route(dx: 5, dy: 5, continuous: true, phase: .changed, swipes: true, at: 0.01) == .scroll)
}

@Test func routerMomentumFollowsTheLock() {
    var router = OwnDockSwipeRouter()
    _ = router.route(dx: 0, dy: 10, continuous: true, phase: .began, swipes: true, at: 0)
    #expect(router.route(dx: 0, dy: 10, continuous: true, phase: .momentum, swipes: true, at: 0.01) == .swipe)
    var other = OwnDockSwipeRouter()
    #expect(other.route(dx: 0, dy: 10, continuous: true, phase: .momentum, swipes: true, at: 0) == .scroll)
}

@Test func routerPhaselessIdleStartsOver() {
    var router = OwnDockSwipeRouter()
    #expect(router.route(dx: 10, dy: 0, continuous: true, phase: .none, swipes: true, at: 0) == .scroll)
    #expect(router.route(dx: 0, dy: 3, continuous: true, phase: .none, swipes: true, at: 0.1) == .scroll)
    // A pause longer than idleReset: a new gesture, decided afresh.
    #expect(router.route(dx: 0, dy: 3, continuous: true, phase: .none, swipes: true, at: 1) == .hold)
    #expect(router.route(dx: 0, dy: 4, continuous: true, phase: .none, swipes: true, at: 1.05) == .swipe)
}

@Test func routerAndClassifierFireOneSwipeUp() {
    var router = OwnDockSwipeRouter()
    var classifier = SystemDockGestureClassifier()
    var fired: [SystemDockGesture] = []
    let steps: [(Double, SystemDockScrollPhase)] = [(2, .began)] + Array(repeating: (6, .changed), count: 10) + [(0, .ended)]
    for (index, step) in steps.enumerated() {
        let now = Double(index) * 0.01
        guard router.route(dx: 0, dy: step.0, continuous: true, phase: step.1, swipes: true, at: now) == .swipe else { continue }
        if let gesture = classifier.scroll(upward: step.0, sideways: 0, continuous: true, phase: step.1, at: now) { fired.append(gesture) }
    }
    #expect(fired == [.restore])
    #expect(OwnDockGestureKind(fired[0]) == .swipeUp)
}

// MARK: - Buttons

@Test func peekButtonsSitTopTrailing() {
    let cell = CGRect(x: 100, y: 50, width: 164, height: 122)
    let rects = OwnDockPeekButtons.rects(cell: cell, minimized: false)
    #expect(rects.map(\.0) == [.minimize, .close])
    let close = rects[1].1, minimize = rects[0].1
    #expect(Double(close.maxX) == Double(cell.maxX) - OwnDockPeekButtons.inset)
    #expect(Double(close.minY) == Double(cell.minY) + OwnDockPeekButtons.inset)
    #expect(Double(close.width) == OwnDockPeekButtons.size)
    #expect(Double(minimize.maxX) == Double(close.minX) - OwnDockPeekButtons.gap)
}

@Test func peekButtonsMinimisedHasOnlyClose() {
    let cell = CGRect(x: 0, y: 0, width: 164, height: 122)
    #expect(OwnDockPeekButtons.rects(cell: cell, minimized: true).map(\.0) == [.close])
    #expect(OwnDockPeekButtons.hit(CGPoint(x: 164 - 6 - 25 - 10, y: 16), cell: cell, minimized: true) == nil)
}

@Test func peekButtonsHitTesting() {
    let cell = CGRect(x: 0, y: 0, width: 164, height: 122)
    #expect(OwnDockPeekButtons.hit(CGPoint(x: 148, y: 16), cell: cell, minimized: false) == .close)
    #expect(OwnDockPeekButtons.hit(CGPoint(x: 123, y: 16), cell: cell, minimized: false) == .minimize)
    // The middle of the picture is the picture, not a button.
    #expect(OwnDockPeekButtons.hit(CGPoint(x: 82, y: 60), cell: cell, minimized: false) == nil)
    // A little slop past the edge still counts.
    #expect(OwnDockPeekButtons.hit(CGPoint(x: 160, y: 4), cell: cell, minimized: false) == .close)
}
