import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
/// A second screen to the right of the main one, top-aligned.
private let side = CGRect(x: 1728, y: 37, width: 1920, height: 1080)

@Test func cornersOfALoneScreen() {
    let screens = [main]
    #expect(HotZones.spot(at: CGPoint(x: 0, y: 1117), screen: main, screens: screens) == .topLeft)
    #expect(HotZones.spot(at: CGPoint(x: 1727, y: 1116), screen: main, screens: screens) == .topRight)
    #expect(HotZones.spot(at: CGPoint(x: 0, y: 0), screen: main, screens: screens) == .bottomLeft)
    #expect(HotZones.spot(at: CGPoint(x: 1727, y: 0), screen: main, screens: screens) == .bottomRight)
}

@Test func edgeMiddlesAndNothingElse() {
    let screens = [main]
    #expect(HotZones.spot(at: CGPoint(x: 864, y: 1117), screen: main, screens: screens) == .top)
    #expect(HotZones.spot(at: CGPoint(x: 864, y: 0), screen: main, screens: screens) == .bottom)
    #expect(HotZones.spot(at: CGPoint(x: 0, y: 558), screen: main, screens: screens) == .left)
    #expect(HotZones.spot(at: CGPoint(x: 1727, y: 558), screen: main, screens: screens) == .right)
    // On the top edge, but far from its middle and from the corners.
    #expect(HotZones.spot(at: CGPoint(x: 300, y: 1117), screen: main, screens: screens) == nil)
    // Nowhere near an edge.
    #expect(HotZones.spot(at: CGPoint(x: 800, y: 500), screen: main, screens: screens) == nil)
}

@Test func sharedEdgesNeverFire() {
    let screens = [main, side]
    // The right edge of the main screen continues into the side screen.
    #expect(HotZones.spot(at: CGPoint(x: 1727, y: 558), screen: main, screens: screens) == nil)
    #expect(!HotZones.reachable(.right, screen: main, screens: screens))
    #expect(!HotZones.reachable(.left, screen: side, screens: screens))
    // The main screen's top right corner: the pointer can slide right into the side screen.
    #expect(!HotZones.reachable(.topRight, screen: main, screens: screens))
    // Its bottom right corner sits below the side screen, so it is still a stop.
    #expect(HotZones.reachable(.bottomRight, screen: main, screens: screens))
    // The side screen's outer right edge is a real stop.
    #expect(HotZones.reachable(.right, screen: side, screens: screens))
    #expect(HotZones.reachable(.topLeft, screen: main, screens: screens))
}

@Test func everySpotOfALoneScreenIsReachable() {
    for spot in HotSpot.allCases {
        #expect(HotZones.reachable(spot, screen: main, screens: [main]), "\(spot)")
    }
}

@Test func triggerFiresOncePerVisitAfterDwell() {
    var trigger = HotTrigger()
    #expect(trigger.update(spot: .topLeft, now: 10, dwell: 0.3) == .schedule(.topLeft, delay: 0.3))
    #expect(trigger.ready(now: 10.1, dwell: 0.3, cooldown: 1) == nil)
    #expect(trigger.ready(now: 10.3, dwell: 0.3, cooldown: 1) == .topLeft)
    trigger.markFired(now: 10.3)
    // Still there: never again on this visit.
    #expect(trigger.update(spot: .topLeft, now: 12, dwell: 0.3) == .none)
    #expect(trigger.ready(now: 12, dwell: 0.3, cooldown: 1) == nil)
}

@Test func cooldownHoldsAQuickReturn() {
    var trigger = HotTrigger()
    _ = trigger.update(spot: .bottom, now: 0, dwell: 0)
    #expect(trigger.ready(now: 0, dwell: 0, cooldown: 1.5) == .bottom)
    trigger.markFired(now: 0)
    #expect(trigger.update(spot: nil, now: 0.2, dwell: 0) == .cancel)
    _ = trigger.update(spot: .bottom, now: 0.5, dwell: 0)
    #expect(trigger.ready(now: 0.5, dwell: 0, cooldown: 1.5) == nil)
    _ = trigger.update(spot: nil, now: 1.0, dwell: 0)
    _ = trigger.update(spot: .bottom, now: 2.0, dwell: 0)
    #expect(trigger.ready(now: 2.0, dwell: 0, cooldown: 1.5) == .bottom)
}

@Test func leavingBeforeTheDwellCancels() {
    var trigger = HotTrigger()
    _ = trigger.update(spot: .right, now: 0, dwell: 0.5)
    #expect(trigger.update(spot: nil, now: 0.2, dwell: 0.5) == .cancel)
    #expect(trigger.ready(now: 0.6, dwell: 0.5, cooldown: 0) == nil)
}

@Test func modifierSymbolsReadInAppleOrder() {
    #expect(HotModifiers([.command, .control, .shift]).symbols == "⌃⇧⌘")
    #expect(HotModifiers([]).symbols == "")
}

@Test func onlyCornersHaveAppleKeys() {
    #expect(HotSpot.allCases.compactMap(\.appleKey) == ["tl", "tr", "br", "bl"])
    #expect(HotSpot.allCases.filter(\.isCorner).count == 4)
}
