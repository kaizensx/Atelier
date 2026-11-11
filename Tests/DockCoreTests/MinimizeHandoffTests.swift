import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let side = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

@Test func handoffFollowMacOSReadsTheOwnersEffectNotAteliersScale() {
    // Replaced: the Dock holds Atelier's Scale, the owner's Genie is in the backup.
    #expect(MinimizeHandoff.followedEffect(current: "scale", replaced: true, saved: "genie") == "genie")
    // The key was absent before: macOS's default, which resolves to Genie.
    #expect(MinimizeHandoff.followedEffect(current: "scale", replaced: true, saved: nil) == nil)
    #expect(MinimizeEffect.system.resolved(systemEffect: MinimizeHandoff.followedEffect(current: "scale", replaced: true, saved: nil)) == .genie)
    // The owner picked something else in Desktop & Dock while replaced: that is theirs.
    #expect(MinimizeHandoff.followedEffect(current: "suck", replaced: true, saved: "genie") == "suck")
    // Not replaced: the Dock's own value, whatever it is.
    #expect(MinimizeHandoff.followedEffect(current: "scale", replaced: false, saved: "genie") == "scale")
}

@Test func handoffParkKeepsTheWindowsSizeAndPushesItPastTheEdge() {
    let size = CGSize(width: 640, height: 480)
    let slot = CGRect(x: 2500, y: 1000, width: 48, height: 48)
    let bottom = MinimizeHandoff.parkRect(window: size, target: slot, screen: side, edge: .bottom)
    #expect(bottom.size == size)
    #expect(bottom.minY == side.maxY)
    #expect(bottom.midX == slot.midX)
    #expect(side.minX <= bottom.minX && bottom.maxX <= side.maxX)
    // Near a screen's end it stays on that screen, never on the next one.
    let corner = MinimizeHandoff.parkRect(window: size, target: CGRect(x: 1700, y: 1060, width: 48, height: 48), screen: main, edge: .bottom)
    #expect(corner.maxX == main.maxX)

    let left = MinimizeHandoff.parkRect(window: size, target: CGRect(x: 4, y: 500, width: 48, height: 48), screen: main, edge: .left)
    #expect(left.maxX == main.minX && left.midY == 524 && left.size == size)
    let right = MinimizeHandoff.parkRect(window: size, target: CGRect(x: 3600, y: 2, width: 48, height: 48), screen: side, edge: .right)
    #expect(right.minX == side.maxX)
    // Clamped to the screen rather than above its top.
    #expect(right.minY == side.minY)
    // A window larger than the screen still gets a rect, from the screen's start.
    let huge = MinimizeHandoff.parkRect(window: CGSize(width: 4000, height: 300), target: slot, screen: side, edge: .bottom)
    #expect(huge.minX == side.minX)
}

@Test func handoffVeilIsOnlyAStripAlongTheHiddenDocksEdge() {
    let bottom = MinimizeHandoff.veilStrip(screen: main, edge: .bottom)
    #expect(bottom == CGRect(x: 0, y: 0, width: 1728, height: MinimizeHandoff.veilDepth))
    // Far less than the band the Genie needed (170 pt and up).
    #expect(bottom.height < 100)
    #expect(MinimizeHandoff.veilStrip(screen: main, edge: .left) == CGRect(x: 0, y: 0, width: 72, height: 1117))
    #expect(MinimizeHandoff.veilStrip(screen: main, edge: .right) == CGRect(x: 1728 - 72, y: 0, width: 72, height: 1117))
    // A second screen below-left of the main one gets its own strip.
    let lower = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
    let strip = MinimizeHandoff.veilStrip(screen: lower, edge: .bottom)
    #expect(strip.minX == lower.minX && strip.minY == lower.minY && strip.width == lower.width)
    // Never deeper than the screen.
    #expect(MinimizeHandoff.veilStrip(screen: CGRect(x: 0, y: 0, width: 50, height: 40), edge: .bottom).height == 40)
}

@Test func handoffVeilPictureKeepsAteliersOwnWindowsUnderIt() {
    let veil = 19
    // Atelier's wallpaper (desktop level), dimming and borders (normal level) are under the
    // Veil: left out of its picture they would vanish from the strip and blink back.
    #expect(!MinimizeHandoff.leftOutOfVeil(own: true, layer: -2147483623, veilLevel: veil, isMinimising: false))
    #expect(!MinimizeHandoff.leftOutOfVeil(own: true, layer: 0, veilLevel: veil, isMinimising: false))
    // The Atelier Dock and the effect are above it and stay live: not in the picture.
    #expect(MinimizeHandoff.leftOutOfVeil(own: true, layer: 20, veilLevel: veil, isMinimising: false))
    #expect(MinimizeHandoff.leftOutOfVeil(own: true, layer: 1001, veilLevel: veil, isMinimising: false))
    // Other apps' windows are always in it, whatever their level, but the one going away.
    #expect(!MinimizeHandoff.leftOutOfVeil(own: false, layer: 25, veilLevel: veil, isMinimising: false))
    #expect(MinimizeHandoff.leftOutOfVeil(own: false, layer: 0, veilLevel: veil, isMinimising: true))
    // Atelier's border around the window going away follows it to the edge: it goes too.
    let window = CGRect(x: 500, y: 220, width: 640, height: 480)
    #expect(MinimizeHandoff.leftOutOfVeil(own: true, layer: 0, veilLevel: veil, isMinimising: false,
                                          frame: window.insetBy(dx: -6, dy: -6), minimising: window))
    // A full-screen wallpaper or another window's dimming stays.
    #expect(!MinimizeHandoff.leftOutOfVeil(own: true, layer: 0, veilLevel: veil, isMinimising: false,
                                           frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), minimising: window))
    #expect(!MinimizeHandoff.leftOutOfVeil(own: true, layer: 0, veilLevel: veil, isMinimising: false,
                                           frame: CGRect(x: 60, y: 566, width: 760, height: 470), minimising: window))
    // Another app's window hugging it is not Atelier's to leave out.
    #expect(!MinimizeHandoff.leftOutOfVeil(own: false, layer: 0, veilLevel: veil, isMinimising: false,
                                           frame: window, minimising: window))
    #expect(!MinimizeHandoff.hugs(.null, window))
}

@Test func handoffAimFollowsTheTileAndKeepsTheLastOne() {
    let last = CGRect(x: 1400, y: 10, width: 54, height: 54)
    let live = CGRect(x: 1373, y: 10, width: 54, height: 54)
    #expect(MinimizeHandoff.aim(live: live, last: last) == live)
    #expect(MinimizeHandoff.aim(live: nil, last: last) == last)
    // A tile just laid out, not drawn yet, has no size: the last aim holds.
    #expect(MinimizeHandoff.aim(live: CGRect(x: 5, y: 5, width: 0, height: 0), last: last) == last)
    #expect(MinimizeHandoff.tileID(pid: 412, key: 77) == "min:412:77")
}

@Test func handoffVeilOutlastsTheSystemAnimationOnly() {
    #expect(MinimizeHandoff.veilHold(since: 0) == MinimizeHandoff.systemAnimation)
    // The effect (0.5 s) outlasts the system's Scale: the Veil goes one frame after it.
    #expect(MinimizeHandoff.veilHold(since: 0.5) < 0.02)
    // Slow motion (Shift) makes the effect 8 times longer, never the Veil.
    let slow = MinimizeTiming.duration(.genie, restoring: false, slow: true)
    #expect(slow > 3 && MinimizeHandoff.veilHold(since: slow) < 0.02)
    #expect(MinimizeHandoff.veilFade * 60 >= 2 && MinimizeHandoff.veilFade * 60 <= 4)
    #expect(MinimizeHandoff.hiddenDockEffect == "scale")
}

@Test func handoffRestoreBringsTheWindowBackJustInTime() {
    // A normal restore is short: the window comes back at once.
    let normal = MinimizeTiming.duration(.genie, restoring: true, slow: false)
    #expect(MinimizeHandoff.restoreCall(duration: normal) < 0.1)
    // In slow motion it stays minimised until the last 0.4 s, so the Veil is not up for 4 s.
    let slow = MinimizeTiming.duration(.genie, restoring: true, slow: true)
    let call = MinimizeHandoff.restoreCall(duration: slow)
    #expect(slow - call >= MinimizeHandoff.systemAnimation)
    #expect(slow - call < 0.5)
    #expect(MinimizeHandoff.restoreCall(duration: 0) == 0)
}
