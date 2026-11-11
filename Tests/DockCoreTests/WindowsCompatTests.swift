import Foundation
import Testing
@testable import DockCore

// MARK: Instant Spaces across releases

@Test func swipeSignIsPlainBefore27() {
    // 14, 15 and 26: right is positive whatever the scrolling preference (ISS legacy, yabai).
    for major in [14, 15, 26] {
        for natural in [true, false] {
            #expect(DockSwipe.sign(right: true, naturalScrolling: natural, major: major) == 1)
            #expect(DockSwipe.sign(right: false, naturalScrolling: natural, major: major) == -1)
        }
    }
    // 27 and later: the Dock reads the sign through natural scrolling.
    #expect(DockSwipe.sign(right: true, naturalScrolling: true, major: 27) == -1)
    #expect(DockSwipe.sign(right: true, naturalScrolling: false, major: 27) == 1)
    #expect(DockSwipe.sign(right: false, naturalScrolling: true, major: 28) == 1)
}

@Test func payloadOnlyFrom27() {
    #expect(!DockSwipe.usesPayload(major: 14))
    #expect(!DockSwipe.usesPayload(major: 15))
    #expect(!DockSwipe.usesPayload(major: 26))
    #expect(DockSwipe.usesPayload(major: 27))
}

private func display(_ id: String, _ spaces: [Int], current: Int) -> ManagedDisplay {
    ManagedDisplay(identifier: id, current: current, spaces: spaces.map { .init(id: $0, uuid: "u\($0)", type: 0) })
}

@Test func routeStaysOnTheDisplayUnderThePointer() {
    let shared = [display("Main", [1, 2, 3], current: 1)]
    #expect(SpaceWalk.route(to: 3, in: shared, cursorDisplay: "ABC") == .display(0))
    #expect(SpaceWalk.route(to: 9, in: shared, cursorDisplay: nil) == .unknown)

    let separate = [display("AAAA-1", [1, 2], current: 1), display("bbbb-2", [5, 6], current: 5)]
    #expect(SpaceWalk.route(to: 6, in: separate, cursorDisplay: "BBBB-2") == .display(1))
    #expect(SpaceWalk.route(to: 2, in: separate, cursorDisplay: "BBBB-2") == .otherDisplay)
    // Pointer display unknown: trust the display that holds the target.
    #expect(SpaceWalk.route(to: 2, in: separate, cursorDisplay: nil) == .display(0))
    #expect(SpaceWalk.route(to: 2, in: separate, cursorDisplay: "CCCC") == .display(0))

    #expect(SpaceWalk.displayForShortcuts(separate, cursorDisplay: "bbbb-2")?.identifier == "bbbb-2")
    #expect(SpaceWalk.displayForShortcuts(separate, cursorDisplay: nil)?.identifier == "AAAA-1")
    #expect(SpaceWalk.displayForShortcuts(shared, cursorDisplay: "bbbb-2")?.identifier == "Main")
}

@Test func arrowShortcutsDefaultOn() {
    #expect(SpaceArrowShortcuts.enabled(nil) == (true, true))
    #expect(SpaceArrowShortcuts.enabled(["79": ["enabled": false]]) == (false, true))
    #expect(SpaceArrowShortcuts.enabled(["79": ["enabled": NSNumber(value: 1)], "81": ["enabled": NSNumber(value: 0)]]) == (true, false))
    #expect(SpaceArrowShortcuts.enabled(["81": ["value": [:]]]) == (true, true))
}

@Test func sendMethodsPerRelease() {
    // Sonoma before 14.5: the plain call works for any process.
    #expect(SpaceSendMethod.candidates(major: 14, minor: 4, bridgeAvailable: false) == [.direct])
    // 14.5+: Apple guarded it; the compat-ID pair still worked there.
    #expect(SpaceSendMethod.candidates(major: 14, minor: 6, bridgeAvailable: false) == [.compatID])
    // Sequoia closed both; without the bridge there is nothing.
    #expect(SpaceSendMethod.candidates(major: 15, minor: 5, bridgeAvailable: false).isEmpty)
    #expect(SpaceSendMethod.candidates(major: 26, minor: 0, bridgeAvailable: false).isEmpty)
    // The bridge comes first wherever it exists.
    #expect(SpaceSendMethod.candidates(major: 26, minor: 4, bridgeAvailable: true) == [.bridged])
    #expect(SpaceSendMethod.candidates(major: 27, minor: 3, bridgeAvailable: true) == [.bridged])
    #expect(SpaceSendMethod.candidates(major: 14, minor: 2, bridgeAvailable: true) == [.bridged, .direct])
}

// MARK: Window tiling and corners

@Test func appleTilingOnlyFrom15() {
    #expect(!WindowsCompatTiling.appleTilingReacts(major: 14, edgeDrag: nil, topEdgeDrag: nil))
    #expect(!WindowsCompatTiling.appleTilingReacts(major: 14, edgeDrag: true, topEdgeDrag: true))
    #expect(WindowsCompatTiling.appleTilingReacts(major: 15, edgeDrag: nil, topEdgeDrag: nil))
    #expect(WindowsCompatTiling.appleTilingReacts(major: 27, edgeDrag: false, topEdgeDrag: nil))
    #expect(!WindowsCompatTiling.appleTilingReacts(major: 26, edgeDrag: false, topEdgeDrag: false))
    #expect(!WindowsCompatTiling.stageManagerOn(nil))
    #expect(WindowsCompatTiling.stageManagerOn(true))
}

@Test func windowCornersFollowTheRelease() {
    #expect(WindowsCompatCorners.windowRadius(major: 14) == 10)
    #expect(WindowsCompatCorners.windowRadius(major: 15) == 10)
    #expect(WindowsCompatCorners.windowRadius(major: 26) == 16)
    #expect(WindowsCompatCorners.windowRadius(major: 27) == 16)
}
