import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private func row(_ bases: [Double]) -> [(path: String, base: Double)] {
    bases.enumerated().map { ("/Applications/App\($0.offset).app", $0.element) }
}

@Test func bounceOneTileLiftedAtTheBottom() {
    var bases = row(Array(repeating: 1117, count: 10))
    bases[4].base = 1090
    #expect(OwnDockBounce.bouncing(bases, orientation: "bottom") == ["/Applications/App4.app"])
}

@Test func bounceIgnoresTilesBelowTheLine() {
    // Bigger than the rest, the wrong way: never a bounce.
    var bases = row(Array(repeating: 1117, count: 10))
    bases[2].base = 1130
    #expect(OwnDockBounce.bouncing(bases, orientation: "bottom").isEmpty)
}

@Test func bounceSlidingDockIsNotABounce() {
    // Auto-hide slides the Dock in: each tile was read at a different point of the slide.
    let bases = row((0..<12).map { 1180 - Double($0) * 6 })
    #expect(OwnDockBounce.bouncing(bases, orientation: "bottom").isEmpty)
}

@Test func bounceSidesLiftAwayFromTheirEdge() {
    var left = row(Array(repeating: 0, count: 8))
    left[1].base = 20
    left[3].base = -20
    #expect(OwnDockBounce.bouncing(left, orientation: "left") == ["/Applications/App1.app"])
    var right = row(Array(repeating: 1728, count: 8))
    right[5].base = 1700
    right[6].base = 1750
    #expect(OwnDockBounce.bouncing(right, orientation: "right") == ["/Applications/App5.app"])
}

@Test func bounceTwoAtOnceStillCount() {
    var bases = row(Array(repeating: 1117, count: 6))
    bases[0].base = 1100
    bases[5].base = 1095
    #expect(OwnDockBounce.bouncing(bases, orientation: "bottom").count == 2)
    #expect(OwnDockBounce.bouncing(row([1117, 1100]), orientation: "bottom").isEmpty)
}

@Test func attentionOnlyForTheBouncingApp() {
    let now = Date()
    let next = OwnDockBounce.attention(previous: [:], bouncing: ["/A.app"], front: "/B.app",
                                       launched: [:], opening: [], now: now)
    #expect(next == ["/A.app": now])
}

@Test func attentionSkipsLaunchesAndFront() {
    let now = Date()
    let launched = OwnDockBounce.attention(previous: [:], bouncing: ["/A.app", "/C.app", "/F.app"], front: "/F.app",
                                           launched: ["/A.app": now.addingTimeInterval(-2)], opening: ["/C.app"], now: now)
    #expect(launched.isEmpty)
    // Past the launch grace, a bounce is a request again.
    let later = OwnDockBounce.attention(previous: [:], bouncing: ["/A.app"], front: nil,
                                        launched: ["/A.app": now.addingTimeInterval(-9)], opening: [], now: now)
    #expect(later.keys.sorted() == ["/A.app"])
}

@Test func attentionEndsWhenActivatedOrStale() {
    let now = Date()
    let previous = ["/A.app": now.addingTimeInterval(-1), "/B.app": now.addingTimeInterval(-13)]
    let next = OwnDockBounce.attention(previous: previous, bouncing: [], front: "/A.app", launched: [:], opening: [], now: now)
    #expect(next.isEmpty)
    let kept = OwnDockBounce.attention(previous: previous, bouncing: [], front: nil, launched: [:], opening: [], now: now)
    #expect(Array(kept.keys) == ["/A.app"])
}

@Test func sameAppMatchesResolvedPaths() {
    let resolve: (String) -> String = { $0 == "/Applications/Safari.app" ? "/System/Cryptexes/App/System/Applications/Safari.app" : $0 }
    let keys = ["/Applications/Safari.app", "/Applications/Notes.app"]
    #expect(OwnDockBounce.sameApp(keys, as: "/System/Cryptexes/App/System/Applications/Safari.app", resolve: resolve) == ["/Applications/Safari.app"])
    #expect(OwnDockBounce.sameApp(keys, as: "/Applications/Notes.app", resolve: resolve) == ["/Applications/Notes.app"])
    #expect(OwnDockBounce.sameApp(keys, as: "/Applications/Mail.app", resolve: resolve).isEmpty)
}

@Test func minimizeShrinkEndsOnTheSlot() {
    let from = CGRect(x: 100, y: 100, width: 800, height: 600)
    let to = OwnDockMinimizeShrink.aim(slot: CGRect(x: 500, y: 1050, width: 64, height: 64))
    #expect(to == CGRect(x: 492, y: 1052, width: 80, height: 60))
    let frames = OwnDockMinimizeShrink.frames(from: from, to: to, steps: 7)
    #expect(frames.count == 7)
    #expect(frames.last == to)
    // Eased in: the first step moves less than an even share.
    #expect(frames[0].width > from.width - (from.width - to.width) / 7)
    // Always shrinking toward the slot.
    for pair in zip(frames, frames.dropFirst()) { #expect(pair.1.width <= pair.0.width) }
}

@Test func attentionIsReadOnlyBeforeMacOS27() {
    // macOS 27's Dock draws every tile in one window: a bounce moves no tile frame.
    #expect(OwnDockBounce.attentionReadable(osMajor: 15))
    #expect(OwnDockBounce.attentionReadable(osMajor: 26))
    #expect(!OwnDockBounce.attentionReadable(osMajor: 27))
    #expect(!OwnDockBounce.attentionReadable(osMajor: 28))
}
