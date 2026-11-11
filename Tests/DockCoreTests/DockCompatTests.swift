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
