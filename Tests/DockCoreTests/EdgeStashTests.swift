import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private typealias L = EdgeStashLogic
// This Mac: 1728x1117, menu bar 33.
private let mac = L.Display(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                            visible: CGRect(x: 0, y: 33, width: 1728, height: 1084))
// A second display to the right of it, lower.
private let side = L.Display(frame: CGRect(x: 1728, y: 200, width: 1920, height: 1080),
                             visible: CGRect(x: 1728, y: 200, width: 1920, height: 1080))
private let window = CGRect(x: 185, y: 83, width: 586, height: 488)

@Test func stashLeavesTheSliverOnScreen() {
    let left = L.stashedFrame(for: window, edge: .left, display: mac)
    #expect(left == CGRect(x: -584, y: 83, width: 586, height: 488))
    #expect(Double(left.maxX) == L.sliver)
    let right = L.stashedFrame(for: window, edge: .right, display: mac)
    #expect(right == CGRect(x: 1726, y: 83, width: 586, height: 488))
    // macOS would leave it there: at least one point is on the display.
    #expect(L.systemClamp(x: Double(left.minX), width: Double(left.width), display: mac.frame) == Double(left.minX))
    #expect(L.systemClamp(x: Double(right.minX), width: Double(right.width), display: mac.frame) == Double(right.minX))
}

@Test func sliverNeverDropsToZero() {
    let left = L.stashedFrame(for: window, edge: .left, display: mac, sliver: 0)
    #expect(Double(left.maxX) == 1.0)
}

@Test func systemClampMatchesWhatMacOSDid() {
    // Measured: -586 for a 586-wide window lands on -546, 1728 lands on 1688.
    #expect(L.systemClamp(x: -586, width: 586, display: mac.frame) == -546)
    #expect(L.systemClamp(x: -686, width: 586, display: mac.frame) == -546)
    #expect(L.systemClamp(x: 1728, width: 586, display: mac.frame) == 1688)
    #expect(L.systemClamp(x: 1727.5, width: 586, display: mac.frame) == 1727)
    #expect(L.systemClamp(x: -585, width: 586, display: mac.frame) == -585)
}

@Test func stashedWindowStaysReachableVertically() {
    let low = CGRect(x: 100, y: 900, width: 400, height: 500)
    #expect(L.stashedFrame(for: low, edge: .left, display: mac).minY == CGFloat(1117 - 500))
    let high = CGRect(x: 100, y: 0, width: 400, height: 300)
    #expect(L.stashedFrame(for: high, edge: .left, display: mac).minY == CGFloat(33))
    let tall = CGRect(x: 0, y: 10, width: 400, height: 1300)
    #expect(L.stashedFrame(for: tall, edge: .right, display: mac).minY == CGFloat(33))
}

@Test func peekSitsAgainstItsEdge() {
    let stashed = L.stashedFrame(for: window, edge: .left, display: mac)
    #expect(L.peekFrame(for: stashed, edge: .left, display: mac) == CGRect(x: 10, y: 83, width: 586, height: 488))
    let right = L.stashedFrame(for: window, edge: .right, display: mac)
    #expect(L.peekFrame(for: right, edge: .right, display: mac) == CGRect(x: 1728 - 10 - 586, y: 83, width: 586, height: 488))
    let wide = CGRect(x: 0, y: 40, width: 1800, height: 300)
    #expect(L.peekFrame(for: wide, edge: .right, display: mac).minX == CGFloat(0))
}

@Test func outerEdgesKnowTheirNeighbours() {
    let displays = [mac, side]
    let span = 100.0...500.0
    #expect(L.isOuterEdge(.left, of: 0, span: span, in: displays))
    // The side display starts at y 200, so it is beside this span.
    #expect(!L.isOuterEdge(.right, of: 0, span: span, in: displays))
    // A window high enough to miss the side display can go out to the right.
    #expect(L.isOuterEdge(.right, of: 0, span: 40.0...190.0, in: displays))
    #expect(!L.isOuterEdge(.left, of: 1, span: 300.0...600.0, in: displays))
    #expect(L.isOuterEdge(.right, of: 1, span: 300.0...600.0, in: displays))
    #expect(!L.isOuterEdge(.left, of: 5, span: span, in: displays))
}

@Test func displayIndexPrefersTheLargestOverlap() {
    let displays = [mac, side]
    #expect(L.displayIndex(for: window, in: displays) == 0)
    #expect(L.displayIndex(for: CGRect(x: 1700, y: 400, width: 600, height: 300), in: displays) == 1)
    // Fully off screen: the nearest.
    #expect(L.displayIndex(for: CGRect(x: -900, y: 100, width: 300, height: 300), in: displays) == 0)
    #expect(L.displayIndex(for: window, in: []) == nil)
}

@Test func restoreKeepsTheOriginalWhenItsDisplayIsThere() {
    #expect(L.restoreFrame(window, displays: [mac]) == window)
    // A frame that was half on the gone display still counts as on screen if enough shows.
    let edge = CGRect(x: 1500, y: 300, width: 600, height: 400)
    #expect(L.restoreFrame(edge, displays: [mac]) == edge)
}

@Test func restoreRehomesAFrameFromAGoneDisplay() {
    let gone = CGRect(x: 2000, y: 400, width: 800, height: 600)
    let back = L.restoreFrame(gone, displays: [mac])
    #expect(back == CGRect(x: 1728 - 800, y: 400, width: 800, height: 600))
    let huge = CGRect(x: 3000, y: 0, width: 2500, height: 1500)
    #expect(L.restoreFrame(huge, displays: [mac]) == mac.visible)
    #expect(L.restoreFrame(gone, displays: []) == gone)
}

@Test func matchesAllowsRounding() {
    #expect(L.matches(CGRect(x: 10.5, y: 20, width: 300, height: 200), CGRect(x: 10, y: 20, width: 300, height: 200)))
    #expect(!L.matches(CGRect(x: 13, y: 20, width: 300, height: 200), CGRect(x: 10, y: 20, width: 300, height: 200)))
    #expect(!L.matches(CGRect(x: 10, y: 20, width: 296, height: 200), CGRect(x: 10, y: 20, width: 300, height: 200)))
}

@Test func looksStashedFindsAReopenedWindow() {
    let stashed = L.stashedFrame(for: window, edge: .left, display: mac)
    #expect(L.looksStashed(stashed, stashed: stashed))
    // macOS pulled it back to 40 points showing when the app reopened it.
    #expect(L.looksStashed(stashed.offsetBy(dx: 38, dy: 0), stashed: stashed))
    #expect(!L.looksStashed(window, stashed: stashed))
    #expect(!L.looksStashed(CGRect(x: stashed.minX, y: stashed.minY, width: 500, height: 488), stashed: stashed))
}

@Test func tabsKeepTheirPlaceWhenThereIsRoom() {
    let centers = L.tabCenters(desired: [300, 700], range: 33...1117)
    #expect(centers == [300, 700])
}

@Test func tabsPushApartWithoutOverlap() {
    let pitch = Double(L.tabSize.height) + L.tabGap
    let centers = L.tabCenters(desired: [500, 500, 510], range: 33...1117)
    #expect(centers == [500, 500 + pitch, 500 + 2 * pitch])
    // Order is by position, not by input order.
    let mixed = L.tabCenters(desired: [600, 590], range: 33...1117)
    #expect(mixed[1] == 590 && mixed[0] == 590 + pitch)
}

@Test func tabsStayInsideTheEdge() {
    let half = Double(L.tabSize.height) / 2, pitch = Double(L.tabSize.height) + L.tabGap
    let low = L.tabCenters(desired: [1110, 1110], range: 33...1117)
    #expect(low == [1117 - half - pitch, 1117 - half])
    let high = L.tabCenters(desired: [0], range: 33...1117)
    #expect(high == [33 + half])
}

@Test func tooManyTabsShareTheEdgeEvenly() {
    let range = 0.0...200.0
    let centers = L.tabCenters(desired: Array(repeating: 100, count: 5), range: range)
    let half = Double(L.tabSize.height) / 2
    #expect(centers.first == half && centers.last == 200 - half)
    let steps = zip(centers.dropFirst(), centers).map { $0 - $1 }
    #expect(steps.allSatisfy { abs($0 - steps[0]) < 0.001 })
    #expect(L.tabCenters(desired: [], range: range).isEmpty)
}

@Test func tabFrameHugsTheEdge() {
    #expect(L.tabFrame(edge: .left, center: 300, display: mac) == CGRect(x: 0, y: 271, width: 22, height: 58))
    #expect(L.tabFrame(edge: .right, center: 300, display: mac) == CGRect(x: 1706, y: 271, width: 22, height: 58))
}

@Test func hotZoneCoversTabAndSliver() {
    let stashed = L.stashedFrame(for: window, edge: .left, display: mac)
    let tab = L.tabFrame(edge: .left, center: 700, display: mac)
    let zones = L.hotZones(tab: tab, stashed: stashed, edge: .left, display: mac)
    #expect(L.isHot(CGPoint(x: 0, y: 100), zones: zones))
    #expect(L.isHot(CGPoint(x: 10, y: 700), zones: zones))
    #expect(!L.isHot(CGPoint(x: 10, y: 100), zones: zones))
    #expect(!L.isHot(CGPoint(x: 0, y: 640), zones: zones))
    let peek = L.peekFrame(for: stashed, edge: .left, display: mac)
    let keep = L.keepZone(peek: peek, tab: tab)
    #expect(keep.contains(CGPoint(x: peek.maxX + 20, y: peek.midY)))
    #expect(!keep.contains(CGPoint(x: peek.maxX + 30, y: peek.midY)))
}

@Test func velocityReadsTheLastStretch() {
    let samples = (0..<10).map { L.Sample(time: Double($0) * 0.01, point: CGPoint(x: 1000 - Double($0) * 30, y: 400)) }
    #expect(abs(L.velocityX(samples) + 3000) < 0.001)
    #expect(L.velocityX([]) == 0)
    #expect(L.velocityX([samples[0]]) == 0)
}

@Test func releaseAtAnEdgeStashes() {
    #expect(L.releaseEdge(cursor: CGPoint(x: 1, y: 400), velocityX: 0, display: mac, fling: false, leftOuter: true, rightOuter: true) == .left)
    #expect(L.releaseEdge(cursor: CGPoint(x: 1727, y: 400), velocityX: 0, display: mac, fling: false, leftOuter: true, rightOuter: true) == .right)
    #expect(L.releaseEdge(cursor: CGPoint(x: 1727, y: 400), velocityX: 0, display: mac, fling: false, leftOuter: true, rightOuter: false) == nil)
    #expect(L.releaseEdge(cursor: CGPoint(x: 800, y: 400), velocityX: 0, display: mac, fling: true, leftOuter: true, rightOuter: true) == nil)
}

@Test func flingTowardsAnEdgeStashes() {
    #expect(L.releaseEdge(cursor: CGPoint(x: 300, y: 400), velocityX: -3000, display: mac, fling: true, leftOuter: true, rightOuter: true) == .left)
    #expect(L.releaseEdge(cursor: CGPoint(x: 300, y: 400), velocityX: -3000, display: mac, fling: false, leftOuter: true, rightOuter: true) == nil)
    // Too slow, or in the middle of the display.
    #expect(L.releaseEdge(cursor: CGPoint(x: 300, y: 400), velocityX: -1000, display: mac, fling: true, leftOuter: true, rightOuter: true) == nil)
    #expect(L.releaseEdge(cursor: CGPoint(x: 864, y: 400), velocityX: 4000, display: mac, fling: true, leftOuter: true, rightOuter: true) == nil)
    #expect(L.releaseEdge(cursor: CGPoint(x: 1400, y: 400), velocityX: 4000, display: mac, fling: true, leftOuter: true, rightOuter: true) == .right)
}

@Test func movedByHandNeedsARealMove() {
    let peek = CGRect(x: 10, y: 83, width: 586, height: 488)
    #expect(!L.movedByHand(peek.offsetBy(dx: 5, dy: 5), peek: peek))
    #expect(L.movedByHand(peek.offsetBy(dx: 200, dy: 0), peek: peek))
}

@Test func recordsSurviveARoundTrip() {
    let record = EdgeStashRecord(pid: 42, bundleID: "com.apple.TextEdit", appName: "TextEdit", title: "Untitled",
                                 edge: .left, original: window, stashed: L.stashedFrame(for: window, edge: .left, display: mac),
                                 windowNumber: 1234, date: Date(timeIntervalSince1970: 1000))
    let back = EdgeStashRecord.decode(EdgeStashRecord.encode([record]))
    #expect(back == [record])
    #expect(EdgeStashRecord.decode(nil).isEmpty)
    #expect(EdgeStashRecord.decode(Data("nonsense".utf8)).isEmpty)
}
