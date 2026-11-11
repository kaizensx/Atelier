import CoreGraphics
import Foundation
import Testing
@testable import DockCore

// MARK: - Placement

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
/// The screen less a 37-point menu bar.
private let bounds = CGRect(x: 0, y: 37, width: 1512, height: 945)
private let card = CGSize(width: 360, height: 190)

@Test func orientationFromPreference() {
    #expect(SystemDockOrientation(preference: "left") == .left)
    #expect(SystemDockOrientation(preference: "right") == .right)
    #expect(SystemDockOrientation(preference: "bottom") == .bottom)
    #expect(SystemDockOrientation(preference: nil) == .bottom)
    #expect(SystemDockOrientation(preference: "top") == .bottom)
}

@Test func bottomDockCardSitsAboveAndCentred() {
    let icon = CGRect(x: 700, y: 920, width: 56, height: 56)
    let placed = SystemDockPeekPlacement.place(card: card, icon: icon, bounds: bounds, orientation: .bottom, gap: 10)
    #expect(placed.frame.maxY == icon.minY - 10)
    #expect(placed.frame.midX == icon.midX)
    #expect(placed.frame.size == card)
    #expect(placed.notch == Double(card.width) / 2)
}

@Test func bottomDockCardClampsAtScreenEdgesNotchFollowsIcon() {
    let left = CGRect(x: 4, y: 920, width: 56, height: 56)
    let placed = SystemDockPeekPlacement.place(card: card, icon: left, bounds: bounds, orientation: .bottom, margin: 8, corner: 27)
    #expect(placed.frame.minX == 8)
    // The icon's centre is at 32, 24 points into the card: the notch stops at the corner.
    #expect(placed.notch == 27)
    let right = CGRect(x: 1440, y: 920, width: 56, height: 56)
    let other = SystemDockPeekPlacement.place(card: card, icon: right, bounds: bounds, orientation: .bottom, margin: 8)
    #expect(other.frame.maxX == bounds.maxX - 8)
    #expect(other.notch == Double(right.midX - other.frame.minX))
}

@Test func sideDocksPlaceCardBesideTheIcon() {
    let leftIcon = CGRect(x: 0, y: 400, width: 56, height: 56)
    let left = SystemDockPeekPlacement.place(card: card, icon: leftIcon, bounds: bounds, orientation: .left, gap: 10)
    #expect(left.frame.minX == leftIcon.maxX + 10)
    #expect(left.frame.midY == leftIcon.midY)
    #expect(left.notch == Double(card.height) / 2)

    let rightIcon = CGRect(x: 1456, y: 400, width: 56, height: 56)
    let right = SystemDockPeekPlacement.place(card: card, icon: rightIcon, bounds: bounds, orientation: .right, gap: 10)
    #expect(right.frame.maxX == rightIcon.minX - 10)
    #expect(right.frame.midY == rightIcon.midY)
}

@Test func sideDockCardStaysBelowTheMenuBar() {
    let top = CGRect(x: 0, y: 40, width: 56, height: 56)
    let placed = SystemDockPeekPlacement.place(card: card, icon: top, bounds: bounds, orientation: .left, margin: 8)
    #expect(placed.frame.minY == bounds.minY + 8)
    #expect(placed.notch >= 27)
    let bottom = CGRect(x: 0, y: 930, width: 56, height: 50)
    let low = SystemDockPeekPlacement.place(card: card, icon: bottom, bounds: bounds, orientation: .left, margin: 8)
    #expect(low.frame.maxY == bounds.maxY - 8)
    #expect(low.notch <= card.height - 27)
}

@Test func cardTooBigForScreenStaysCentredOnIt() {
    let huge = CGSize(width: 2000, height: 190)
    let icon = CGRect(x: 700, y: 920, width: 56, height: 56)
    let placed = SystemDockPeekPlacement.place(card: huge, icon: icon, bounds: bounds, orientation: .bottom, margin: 8)
    #expect(placed.frame.midX == bounds.midX)
}

@Test func secondaryScreenToTheLeftUsesItsOwnBounds() {
    let second = CGRect(x: -1920, y: -98, width: 1920, height: 1080)
    let icon = CGRect(x: -1900, y: 920, width: 56, height: 56)
    let placed = SystemDockPeekPlacement.place(card: card, icon: icon, bounds: second, orientation: .bottom, margin: 8)
    #expect(placed.frame.minX == second.minX + 8)
}

@Test func guessesOrientationFromIconPosition() {
    #expect(SystemDockPeekPlacement.orientation(icon: CGRect(x: 700, y: 920, width: 56, height: 56), screen: screen) == .bottom)
    #expect(SystemDockPeekPlacement.orientation(icon: CGRect(x: 0, y: 400, width: 56, height: 56), screen: screen) == .left)
    #expect(SystemDockPeekPlacement.orientation(icon: CGRect(x: 1456, y: 400, width: 56, height: 56), screen: screen) == .right)
}

@Test func flipsToAppKitCoordinates() {
    let rect = CGRect(x: 10, y: 100, width: 50, height: 20)
    #expect(SystemDockPeekPlacement.flipped(rect, primaryHeight: 982) == CGRect(x: 10, y: 862, width: 50, height: 20))
}

@Test func hitTestFindsIconWithSlop() {
    let frames = [CGRect(x: 0, y: 0, width: 50, height: 50), .zero, CGRect(x: 60, y: 0, width: 50, height: 50)]
    #expect(SystemDockHit.index(at: CGPoint(x: 25, y: 25), in: frames) == 0)
    #expect(SystemDockHit.index(at: CGPoint(x: 111, y: 25), in: frames, slop: 2) == 2)
    #expect(SystemDockHit.index(at: CGPoint(x: 55, y: 25), in: frames, slop: 2) == nil)
    #expect(SystemDockHit.index(at: .zero, in: [.zero]) == nil)
}

// MARK: - Hover

@Test func hoverWaitsForTheDelay() {
    var machine = SystemDockHoverMachine(delay: 0.3, grace: 0.3)
    machine.hover("safari", at: 0)
    #expect(machine.shown == nil)
    #expect(machine.deadline == 0.3)
    machine.tick(at: 0.2)
    #expect(machine.shown == nil)
    machine.tick(at: 0.31)
    #expect(machine.shown == "safari")
}

@Test func sweepingAcrossTheDockShowsNothing() {
    var machine = SystemDockHoverMachine(delay: 0.3, grace: 0.3)
    machine.hover("a", at: 0)
    machine.hover("b", at: 0.1)
    machine.hover("c", at: 0.2)
    machine.tick(at: 0.35)
    #expect(machine.shown == nil)
    machine.hover(nil, at: 0.4)
    machine.tick(at: 1)
    #expect(machine.phase == .idle)
}

@Test func onceShownNeighboursSwitchAtOnce() {
    var machine = SystemDockHoverMachine(delay: 0.3, grace: 0.3)
    machine.hover("a", at: 0)
    machine.tick(at: 0.3)
    machine.hover("b", at: 0.5)
    #expect(machine.shown == "b")
    // The Dock clears its selection for an instant between neighbours: no flicker.
    machine.hover(nil, at: 0.6)
    #expect(machine.shown == "b")
    machine.hover("c", at: 0.65)
    #expect(machine.shown == "c")
}

@Test func leavingKeepsCardForGraceThenHides() {
    var machine = SystemDockHoverMachine(delay: 0, grace: 0.3)
    machine.hover("a", at: 0)
    #expect(machine.shown == "a")
    machine.hover(nil, at: 1)
    #expect(machine.shown == "a")
    #expect(machine.deadline == 1.3)
    machine.tick(at: 1.2)
    #expect(machine.shown == "a")
    machine.tick(at: 1.31)
    #expect(machine.shown == nil)
}

@Test func reachingTheCardKeepsItOpen() {
    var machine = SystemDockHoverMachine(delay: 0, grace: 0.3)
    machine.hover("a", at: 0)
    machine.hover(nil, at: 1)
    machine.card(inside: true, at: 1.15)
    machine.tick(at: 5)
    #expect(machine.shown == "a")
    #expect(machine.deadline == nil)
    machine.card(inside: false, at: 6)
    #expect(machine.shown == "a")
    machine.tick(at: 6.31)
    #expect(machine.shown == nil)
}

@Test func leavingTheCardBackOntoTheIconKeepsIt() {
    var machine = SystemDockHoverMachine(delay: 0, grace: 0.3)
    machine.hover("a", at: 0)
    machine.hover(nil, at: 1)
    machine.card(inside: true, at: 1.1)
    machine.hover("a", at: 2)
    machine.card(inside: false, at: 2)
    machine.tick(at: 9)
    #expect(machine.shown == "a")
}

@Test func dismissSuppressesUntilAnotherIcon() {
    var machine = SystemDockHoverMachine(delay: 0.2, grace: 0.3)
    machine.hover("a", at: 0)
    machine.tick(at: 0.2)
    machine.dismiss()
    #expect(machine.shown == nil)
    #expect(machine.phase == .suppressed(icon: "a"))
    machine.hover("a", at: 1)
    machine.tick(at: 5)
    #expect(machine.shown == nil)
    machine.hover("b", at: 6)
    machine.tick(at: 6.2)
    #expect(machine.shown == "b")
    // Off the Dock and back onto the same icon works again too.
    machine.dismiss()
    machine.hover(nil, at: 7)
    machine.hover("b", at: 8)
    machine.tick(at: 8.3)
    #expect(machine.shown == "b")
}

// MARK: - Gestures

@Test func swipeDownMinimisesOncePerGesture() {
    var g = SystemDockGestureClassifier()
    #expect(g.scroll(upward: -10, sideways: 0, continuous: true, phase: .began, at: 0) == nil)
    #expect(g.scroll(upward: -10, sideways: 1, continuous: true, phase: .changed, at: 0.01) == nil)
    #expect(g.scroll(upward: -10, sideways: 0, continuous: true, phase: .changed, at: 0.02) == .minimize)
    #expect(g.scroll(upward: -40, sideways: 0, continuous: true, phase: .changed, at: 0.03) == nil)
    #expect(g.scroll(upward: 0, sideways: 0, continuous: true, phase: .ended, at: 0.04) == nil)
    #expect(g.scroll(upward: -30, sideways: 0, continuous: true, phase: .momentum, at: 0.05) == nil)
}

@Test func swipeUpRestores() {
    var g = SystemDockGestureClassifier()
    _ = g.scroll(upward: 15, sideways: 0, continuous: true, phase: .began, at: 0)
    #expect(g.scroll(upward: 15, sideways: 0, continuous: true, phase: .changed, at: 0.01) == .restore)
}

@Test func sidewaysOrShortSwipesDoNothing() {
    var g = SystemDockGestureClassifier()
    _ = g.scroll(upward: 10, sideways: 30, continuous: true, phase: .began, at: 0)
    #expect(g.scroll(upward: 20, sideways: 30, continuous: true, phase: .changed, at: 0.01) == nil)
    var short = SystemDockGestureClassifier()
    _ = short.scroll(upward: 10, sideways: 0, continuous: true, phase: .began, at: 0)
    #expect(short.scroll(upward: 10, sideways: 0, continuous: true, phase: .changed, at: 0.01) == nil)
    #expect(short.scroll(upward: 0, sideways: 0, continuous: true, phase: .ended, at: 0.02) == nil)
    // The next gesture starts from zero.
    #expect(short.scroll(upward: 10, sideways: 0, continuous: true, phase: .began, at: 1) == nil)
}

@Test func phaselessContinuousScrollResetsAfterAPause() {
    var g = SystemDockGestureClassifier()
    #expect(g.scroll(upward: -20, sideways: 0, continuous: true, phase: .none, at: 0) == nil)
    // A pause longer than idleReset starts again.
    #expect(g.scroll(upward: -20, sideways: 0, continuous: true, phase: .none, at: 1) == nil)
    #expect(g.scroll(upward: -20, sideways: 0, continuous: true, phase: .none, at: 1.1) == .minimize)
}

@Test func wheelHidesAndShowsWithCooldown() {
    var g = SystemDockGestureClassifier()
    #expect(g.scroll(upward: 1, sideways: 0, continuous: false, phase: .none, at: 0) == .hide)
    #expect(g.scroll(upward: 1, sideways: 0, continuous: false, phase: .none, at: 0.1) == nil)
    #expect(g.scroll(upward: -1, sideways: 0, continuous: false, phase: .none, at: 0.5) == .show)
    #expect(g.scroll(upward: 0, sideways: 1, continuous: false, phase: .none, at: 2) == nil)
}

@Test func pinchInQuitsOncePerPinch() {
    var g = SystemDockGestureClassifier()
    #expect(g.magnify(-0.1, phase: .began, at: 0) == nil)
    #expect(g.magnify(-0.1, phase: .changed, at: 0.01) == nil)
    #expect(g.magnify(-0.1, phase: .changed, at: 0.02) == .quit)
    #expect(g.magnify(-0.3, phase: .changed, at: 0.03) == nil)
    #expect(g.magnify(0, phase: .ended, at: 0.04) == nil)
    // Pinching out never quits.
    #expect(g.magnify(0.5, phase: .began, at: 1) == nil)
    #expect(g.magnify(0.5, phase: .changed, at: 1.01) == nil)
}

@Test func quitNeedsTwoPinchesOnTheSameAppInTime() {
    var confirm = SystemDockQuitConfirm(window: 2)
    #expect(confirm.pinch("safari", at: 0) == false)
    #expect(confirm.isArmed("safari", at: 1))
    #expect(confirm.pinch("safari", at: 1.5) == true)
    #expect(!confirm.isArmed("safari", at: 1.6))
    // Too late: the second pinch arms again instead.
    #expect(confirm.pinch("mail", at: 10) == false)
    #expect(confirm.pinch("mail", at: 13) == false)
    #expect(confirm.pinch("mail", at: 14) == true)
    // Another app re-arms for that app.
    #expect(confirm.pinch("a", at: 20) == false)
    #expect(confirm.pinch("b", at: 20.5) == false)
    #expect(confirm.pinch("b", at: 21) == true)
    confirm.cancel()
    #expect(confirm.armed == nil)
}
