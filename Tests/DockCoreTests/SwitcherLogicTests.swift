import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private struct W { let name: String; let z: Int?; let min: Bool }

@Test func switcherOrdersByStackingThenOffscreenThenMinimised() {
    let items = [W(name: "mini", z: nil, min: true), W(name: "back", z: 7, min: false),
                 W(name: "elsewhere", z: nil, min: false), W(name: "front", z: 2, min: false),
                 W(name: "mini2", z: 1, min: true)]
    let ordered = SwitcherOrder.ordered(items, zIndex: \.z, minimized: \.min).map(\.name)
    #expect(ordered == ["front", "back", "elsewhere", "mini", "mini2"])
}

@Test func switcherOrderKeepsTiesStable() {
    let items = [W(name: "a", z: nil, min: false), W(name: "b", z: nil, min: false), W(name: "c", z: nil, min: false)]
    #expect(SwitcherOrder.ordered(items, zIndex: \.z, minimized: \.min).map(\.name) == ["a", "b", "c"])
}

@Test func switcherZIndexTakesFirstPlace() {
    let map = SwitcherOrder.zIndex(of: [40, 12, 40, 9])
    #expect(map[40] == 0 && map[12] == 1 && map[9] == 3)
}

@Test func firstPressSelectsSecondWindow() {
    #expect(SwitcherSelection(count: 5, columns: 5).index == 1)
    #expect(SwitcherSelection(count: 5, columns: 5, backward: true).index == 4)
    #expect(SwitcherSelection(count: 1, columns: 1).index == 0)
    #expect(SwitcherSelection(count: 0, columns: 1).index == 0)
}

@Test func selectionStepsWrapBothWays() {
    var selection = SwitcherSelection(count: 3, columns: 3)
    selection.step(1)
    #expect(selection.index == 2)
    selection.step(1)
    #expect(selection.index == 0)
    selection.step(-1)
    #expect(selection.index == 2)
    selection.step(-7)
    #expect(selection.index == 1)
}

@Test func selectionRowsKeepColumnAndWrap() {
    // Seven cards in rows of three: 0 1 2 / 3 4 5 / 6
    var selection = SwitcherSelection(count: 7, columns: 3)
    selection.row(1)
    #expect(selection.index == 4)
    selection.row(1)
    #expect(selection.index == 6)  // the short last row: its last card
    selection.row(1)
    #expect(selection.index == 0)
    selection.row(-1)
    #expect(selection.index == 6)
    selection.select(2)
    selection.row(-1)
    #expect(selection.index == 6)
    selection.select(99)
    #expect(selection.index == 6)
}

@Test func singleRowIgnoresUpAndDown() {
    var selection = SwitcherSelection(count: 4, columns: 4)
    selection.row(1)
    #expect(selection.index == 1)
}

@Test func switcherColumnsBalanceRows() {
    #expect(SwitcherLayout.columns(count: 4, maxColumns: 6) == 4)
    #expect(SwitcherLayout.columns(count: 7, maxColumns: 6) == 4)
    #expect(SwitcherLayout.columns(count: 12, maxColumns: 6) == 6)
    #expect(SwitcherLayout.columns(count: 0, maxColumns: 6) == 1)
}

@Test func schematicKeepsAspectInsideBox() {
    let wide = SwitcherLayout.schematic(for: CGSize(width: 1600, height: 800), in: CGSize(width: 40, height: 30))
    #expect(wide.width == 40 && wide.height == 20)
    let sliver = SwitcherLayout.schematic(for: CGSize(width: 10, height: 1000), in: CGSize(width: 40, height: 30))
    #expect(sliver.height == 30 && sliver.width == 8)
}

@Test func shortcutMatchesOnlyItsChord() {
    let alt = CGEventFlags.maskAlternate.rawValue, shift = CGEventFlags.maskShift.rawValue
    let cmd = CGEventFlags.maskCommand.rawValue
    #expect(SwitcherShortcut.optionTab.matches(keyCode: 48, flags: alt))
    #expect(SwitcherShortcut.optionTab.matches(keyCode: 48, flags: alt | shift))
    #expect(!SwitcherShortcut.optionTab.matches(keyCode: 48, flags: alt | cmd))
    #expect(!SwitcherShortcut.optionTab.matches(keyCode: 48, flags: cmd))
    #expect(!SwitcherShortcut.optionTab.matches(keyCode: 50, flags: alt))
    #expect(SwitcherShortcut.commandGrave.matches(keyCode: 50, flags: cmd))
    #expect(SwitcherShortcut.commandGrave.frontAppOnly)
}
