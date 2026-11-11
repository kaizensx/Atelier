import CoreGraphics
import Foundation
import Testing
@testable import DockCore

@Test func pointerRestsOnlyAfterTheDelay() {
    var rest = PointerRest(delay: 0.3)
    let started = rest.move(to: CGPoint(x: 100, y: 100), at: 10)
    #expect(started)
    #expect(!rest.isRested(at: 10.1))
    #expect(rest.isRested(at: 10.3))
    #expect(rest.due == 10.3)
}

@Test func smallDriftKeepsTheRestBigMovesRestartIt() {
    var rest = PointerRest(delay: 0.3, tolerance: 4)
    rest.move(to: CGPoint(x: 100, y: 100), at: 10)
    // A hand on the mouse wobbles by a point or two; the wait goes on.
    let restarted = rest.move(to: CGPoint(x: 102, y: 101), at: 10.2)
    #expect(!restarted)
    #expect(rest.isRested(at: 10.3))
    // Crossing on to somewhere else starts the wait again.
    let before = rest.generation
    let movedOn = rest.move(to: CGPoint(x: 140, y: 100), at: 10.25)
    #expect(movedOn)
    #expect(rest.generation == before + 1)
    #expect(!rest.isRested(at: 10.3))
    #expect(rest.isRested(at: 10.55))
}

@Test func aRestIsUsedOnce() {
    var rest = PointerRest(delay: 0.1)
    rest.move(to: .zero, at: 0)
    #expect(rest.isRested(at: 0.2))
    rest.spend()
    #expect(!rest.isRested(at: 5))
    rest.move(to: CGPoint(x: 50, y: 0), at: 6)
    #expect(rest.isRested(at: 6.1))
}

@Test func windowFoundUpTheChainUnlessSomethingFloatsOnIt() {
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXStaticText", "AXGroup", "AXScrollArea", "AXWindow", "AXApplication"]) == 3)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXWindow"]) == 0)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXButton", "AXSheet", "AXWindow"]) == nil)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXMenuItem", "AXMenu", "AXWindow"]) == nil)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXMenuBarItem", "AXMenuBar", "AXApplication"]) == nil)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXDockItem", "AXList", "AXApplication"]) == nil)
    #expect(FocusFollowsRules.windowIndex(inChain: ["AXGroup"]) == nil)
}

@Test func onlyOrdinaryWindowsRise() {
    #expect(FocusFollowsRules.isRaisable(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, fullScreen: false))
    #expect(!FocusFollowsRules.isRaisable(role: "AXWindow", subrole: "AXDialog", minimized: false, fullScreen: false))
    #expect(!FocusFollowsRules.isRaisable(role: "AXWindow", subrole: "AXFloatingWindow", minimized: false, fullScreen: false))
    #expect(!FocusFollowsRules.isRaisable(role: "AXWindow", subrole: "AXStandardWindow", minimized: true, fullScreen: false))
    #expect(!FocusFollowsRules.isRaisable(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, fullScreen: true))
    #expect(!FocusFollowsRules.isRaisable(role: "AXSheet", subrole: nil, minimized: false, fullScreen: false))
}

@Test func buttonsAndControlPause() {
    #expect(FocusFollowsRules.isPaused(buttonsDown: 1, controlHeld: false, pauseWithControl: false))
    #expect(FocusFollowsRules.isPaused(buttonsDown: 0, controlHeld: true, pauseWithControl: true))
    #expect(!FocusFollowsRules.isPaused(buttonsDown: 0, controlHeld: true, pauseWithControl: false))
    #expect(!FocusFollowsRules.isPaused(buttonsDown: 0, controlHeld: false, pauseWithControl: true))
}

@Test func delayStaysInRange() {
    #expect(FocusFollowsRules.clampDelay(0) == 0.1)
    #expect(FocusFollowsRules.clampDelay(0.3) == 0.3)
    #expect(FocusFollowsRules.clampDelay(4) == 1.0)
}

@Test func whatLiesUnderThePointer() {
    typealias L = FocusFollowsRules.Listed
    let own: Int32 = 7
    let shade = L(number: 1, pid: own, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let front = L(number: 2, pid: 20, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
    let back = L(number: 3, pid: 30, layer: 0, alpha: 1, bounds: CGRect(x: 200, y: 200, width: 400, height: 400))
    let dock = L(number: 4, pid: 40, layer: 20, alpha: 1, bounds: CGRect(x: 0, y: 740, width: 1000, height: 60))
    let settings = L(number: 5, pid: own, layer: 0, alpha: 1, bounds: CGRect(x: 700, y: 0, width: 300, height: 300))
    let list = [dock, shade, settings, front, back]
    let pass: Set<Int> = [1]

    // Atelier's shade is looked through; the window beneath it counts.
    #expect(FocusFollowsRules.under(CGPoint(x: 500, y: 500), in: list, ownPID: own, passThrough: pass) == .window(back))
    #expect(FocusFollowsRules.under(CGPoint(x: 100, y: 100), in: list, ownPID: own, passThrough: pass) == .window(front))
    #expect(FocusFollowsRules.under(CGPoint(x: 500, y: 770), in: list, ownPID: own, passThrough: pass) == .system)
    #expect(FocusFollowsRules.under(CGPoint(x: 800, y: 100), in: list, ownPID: own, passThrough: pass) == .own)
    #expect(FocusFollowsRules.under(CGPoint(x: 900, y: 500), in: list, ownPID: own, passThrough: pass) == .desktop)
    // Without knowing the shade is click-through, it would hide everything.
    #expect(FocusFollowsRules.under(CGPoint(x: 500, y: 500), in: list, ownPID: own, passThrough: []) == .own)
}

@Test func anOpenMenuHoldsEverything() {
    typealias L = FocusFollowsRules.Listed
    let window = L(number: 1, pid: 2, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
    let menu = L(number: 2, pid: 2, layer: 101, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
    #expect(!FocusFollowsRules.menuOpen(in: [window]))
    #expect(FocusFollowsRules.menuOpen(in: [menu, window]))
}

/// Another app's full-screen click-through overlay sits above every window. The window
/// server's own hit test sees through it, and that answer decides.
@Test func anotherAppsOverlayDoesNotHideTheWindowBelow() {
    let overlay = FocusFollowsRules.Listed(number: 900, pid: 904, layer: 2_147_483_628, alpha: 1,
                                           bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let calculator = FocusFollowsRules.Listed(number: 21209, pid: 500, layer: 0, alpha: 1,
                                              bounds: CGRect(x: 200, y: 200, width: 300, height: 500))
    let list = [overlay, calculator]
    let point = CGPoint(x: 223, y: 342)
    #expect(FocusFollowsRules.under(point, in: list, ownPID: 1, passThrough: []) == .system)
    #expect(FocusFollowsRules.under(point, in: list, ownPID: 1, passThrough: [], hit: 21209) == .window(calculator))
}
