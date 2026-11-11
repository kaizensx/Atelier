import CoreGraphics
import Foundation
import Testing
@testable import DockCore

// MARK: Launcher

@Test func dockCompatLauncherFollowsTheVersion() {
    let both: (String) -> Bool = { _ in true }
    #expect(DockCompat.launcherPath(major: 14, exists: both) == "/System/Applications/Launchpad.app")
    #expect(DockCompat.launcherPath(major: 15, exists: both) == "/System/Applications/Launchpad.app")
    #expect(DockCompat.launcherPath(major: 26, exists: both) == "/System/Applications/Apps.app")
    #expect(DockCompat.launcherPath(major: 27, exists: both) == "/System/Applications/Apps.app")
    #expect(DockCompat.launcherTitle(major: 15) == "Launchpad")
    #expect(DockCompat.launcherTitle(major: 26) == "Apps")
}

@Test func dockCompatLauncherTakesWhatIsThere() {
    let onlyLaunchpad: (String) -> Bool = { $0.hasSuffix("Launchpad.app") }
    let onlyApps: (String) -> Bool = { $0.hasSuffix("Apps.app") }
    #expect(DockCompat.launcherPath(major: 26, exists: onlyLaunchpad) == "/System/Applications/Launchpad.app")
    #expect(DockCompat.launcherPath(major: 14, exists: onlyApps) == "/System/Applications/Apps.app")
    #expect(DockCompat.launcherPath(major: 27, exists: { _ in false }) == "/System/Applications/Apps.app")
}

// MARK: Snapshots

@Test func dockCompatSnapshotKeepsTheRunningVersion() {
    let current: [String: Any] = ["version": 2, "tilesize": 48]
    let old: [String: Any] = ["version": 1, "tilesize": 64, "persistent-apps": [Any]()]
    let result = DockCompat.carryingBookkeeping(current: current, target: old)
    #expect(result["version"] as? Int == 2)
    #expect(result["tilesize"] as? Int == 64)
    #expect(result["persistent-apps"] != nil)
    // Absent now, so absent after: nothing the running Dock did not write is brought back.
    let none = DockCompat.carryingBookkeeping(current: [:], target: old)
    #expect(none["version"] == nil)
    #expect(Tiles.keysToDelete(current: ["version": 2], target: none) == ["version"])
}

// MARK: Minimise

@Test func dockCompatEdgeReadsTheOrientation() {
    #expect(DockCompat.edge(orientation: nil) == .bottom)
    #expect(DockCompat.edge(orientation: "left") == .left)
    #expect(DockCompat.edge(orientation: "right") == .right)
    #expect(DockCompat.edge(orientation: "top") == .bottom)
}

/// A 1728 × 1117 main display and a 1920 × 1080 one to its right, top-aligned, in AX space.
private let axMain = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let axSide = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

@Test func dockCompatParkSitsOnTheDockEdgeOfTheSlotsScreen() {
    let slot = CGRect(x: 2500, y: 1000, width: 48, height: 48)
    let bottom = DockCompat.parkRect(target: slot, screen: axSide, edge: .bottom)
    #expect(bottom.minY == axSide.maxY - 2)
    #expect(bottom.midX == slot.midX)
    #expect(axSide.minX <= bottom.minX && bottom.maxX <= axSide.maxX)

    let left = DockCompat.parkRect(target: CGRect(x: 4, y: 500, width: 48, height: 48), screen: axMain, edge: .left)
    #expect(left.maxX == axMain.minX + 2)
    #expect(left.midY == 524)

    let right = DockCompat.parkRect(target: CGRect(x: 3600, y: 2, width: 48, height: 48), screen: axSide, edge: .right)
    #expect(right.minX == axSide.maxX - 2)
    // Clamped to the screen rather than above its top.
    #expect(right.minY == axSide.minY)
}

@Test func dockCompatCoverBandFollowsTheEdge() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let target = CGRect(x: 800, y: 10, width: 48, height: 48)
    let bottom = DockCompat.coverBand(target: target, screen: screen, edge: .bottom)
    #expect(bottom == CGRect(x: 0, y: 0, width: 1728, height: 380))
    let left = DockCompat.coverBand(target: CGRect(x: 10, y: 500, width: 48, height: 48), screen: screen, edge: .left)
    #expect(left == CGRect(x: 0, y: 0, width: 380, height: 1117))
    let right = DockCompat.coverBand(target: CGRect(x: 1670, y: 500, width: 48, height: 48), screen: screen, edge: .right)
    #expect(right == CGRect(x: 1728 - 380, y: 0, width: 380, height: 1117))
    // A second screen below-left of the main one still gets its own band.
    let lower = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
    let band = DockCompat.coverBand(target: CGRect(x: -1000, y: -1070, width: 48, height: 48), screen: lower, edge: .bottom)
    #expect(band.minY == lower.minY && band.minX == lower.minX && band.width == lower.width)
}

@Test func dockCompatMinimizeKeyOnAnyLayout() {
    // ANSI and ISO: M on key 46.
    #expect(DockCompat.isMinimizeKey(characters: "m", keyCode: 46, commandOnly: true, autorepeat: false))
    // AZERTY: M is where ANSI has the semicolon.
    #expect(DockCompat.isMinimizeKey(characters: "m", keyCode: 41, commandOnly: true, autorepeat: false))
    // AZERTY's key 46 types a comma: not Minimize.
    #expect(!DockCompat.isMinimizeKey(characters: ",", keyCode: 46, commandOnly: true, autorepeat: false))
    // Russian: key 46 types "ь"; macOS maps the shortcut by position.
    #expect(DockCompat.isMinimizeKey(characters: "ь", keyCode: 46, commandOnly: true, autorepeat: false))
    #expect(DockCompat.isMinimizeKey(characters: nil, keyCode: 46, commandOnly: true, autorepeat: false))
    #expect(!DockCompat.isMinimizeKey(characters: "m", keyCode: 46, commandOnly: false, autorepeat: false))
    #expect(!DockCompat.isMinimizeKey(characters: "m", keyCode: 46, commandOnly: true, autorepeat: true))
}

@Test func dockCompatMinimizeNoteFromSequoia() {
    #expect(DockCompat.minimizeNote(major: 14) == nil)
    #expect(DockCompat.minimizeNote(major: 15) != nil)
    #expect(DockCompat.minimizeNote(major: 27) != nil)
}
