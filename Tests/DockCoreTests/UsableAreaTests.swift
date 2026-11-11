import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private typealias U = UsableArea
// This Mac in AppKit coordinates: 1728x1117, menu bar 33. With the macOS Dock hidden in favour
// of Atelier's, the visible frame keeps 4 points at the bottom for it.
private let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let hiddenDock = CGRect(x: 0, y: 4, width: 1728, height: 1080)

@Test func bottomDockReplacingSystemDockLiftsTheFloor() {
    let t = U.thickness(edge: .bottom, full: full, visible: hiddenDock, replacing: true, gap: 8, bar: 64, margin: 4)
    #expect(t == 76)
    let r = U.rect(full: full, visible: hiddenDock, band: .init(edge: .bottom, thickness: t))
    #expect(r == CGRect(x: 0, y: 76, width: 1728, height: 1084 - 76))
    // The menu bar is still left out.
    #expect(r.maxY == hiddenDock.maxY)
}

@Test func besideTheMacOSDockTheBandStartsAboveIt() {
    // macOS Dock showing: 70 points at the bottom. Atelier's bar sits above it.
    let visible = CGRect(x: 0, y: 70, width: 1728, height: 1014)
    let t = U.thickness(edge: .bottom, full: full, visible: visible, replacing: false, gap: 8, bar: 64, margin: 4)
    #expect(t == 146)
    #expect(U.rect(full: full, visible: visible, band: .init(edge: .bottom, thickness: t)).minY == 146)
}

@Test func topDockCountsTheMenuBar() {
    let t = U.thickness(edge: .top, full: full, visible: hiddenDock, replacing: true, gap: 8, bar: 64, margin: 4)
    #expect(t == 33 + 76)
    let r = U.rect(full: full, visible: hiddenDock, band: .init(edge: .top, thickness: t))
    #expect(Double(r.maxY) == 1117.0 - 109.0)
    #expect(r.minY == hiddenDock.minY)
}

@Test func sideDocksTrimTheirOwnEdge() {
    let left = U.rect(full: full, visible: hiddenDock, band: .init(edge: .left, thickness: 76))
    #expect(left == CGRect(x: 76, y: 4, width: 1728 - 76, height: 1080))
    let right = U.rect(full: full, visible: hiddenDock, band: .init(edge: .right, thickness: 76))
    #expect(right == CGRect(x: 0, y: 4, width: 1728 - 76, height: 1080))
}

@Test func secondDisplayUsesItsOwnOrigin() {
    // A display to the left of the main one, in AppKit's shared space.
    let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
    let r = U.rect(full: screen, visible: visible, band: .init(edge: .left, thickness: 80))
    #expect(r.minX == -1840)
    #expect(r.maxX == 0)
}

@Test func noBandOrAnAbsurdOneLeavesTheVisibleFrame() {
    #expect(U.rect(full: full, visible: hiddenDock, band: nil) == hiddenDock)
    #expect(U.rect(full: full, visible: hiddenDock, band: .init(edge: .bottom, thickness: 0)) == hiddenDock)
    #expect(U.rect(full: full, visible: hiddenDock, band: .init(edge: .bottom, thickness: 1000)) == hiddenDock)
    #expect(U.rect(full: full, visible: hiddenDock, band: .init(edge: .left, thickness: .infinity)) == hiddenDock)
}

@Test func aBandInsideTheVisibleInsetChangesNothing() {
    // The macOS Dock already keeps more room than Atelier's bar needs.
    let visible = CGRect(x: 0, y: 90, width: 1728, height: 994)
    #expect(U.rect(full: full, visible: visible, band: .init(edge: .bottom, thickness: 60)) == visible)
}
