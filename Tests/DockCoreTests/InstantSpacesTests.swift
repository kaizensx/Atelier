import Foundation
import Testing
@testable import DockCore

private func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    bytes[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

@Test func fixedPointNeverLosesDirection() {
    #expect(DockSwipe.fixed1616(1) == 65536)
    #expect(DockSwipe.fixed1616(-0.5) == -32768)
    // The swipe's "almost no travel" must stay non-zero, or the Dock loses the direction.
    #expect(DockSwipe.fixed1616(DockSwipe.progress) == 1)
    #expect(DockSwipe.fixed1616(-0.0000001) == -1)
    #expect(DockSwipe.fixed1616(0) == 0)
    #expect(DockSwipe.fixed1616(DockSwipe.fling) == 655_294_464)
    #expect(DockSwipe.fixed1616(1e9) == Int32.max)
}

@Test func swipeSignFollowsNaturalScrolling() {
    #expect(DockSwipe.sign(right: true, naturalScrolling: true) == -1)
    #expect(DockSwipe.sign(right: false, naturalScrolling: true) == 1)
    #expect(DockSwipe.sign(right: true, naturalScrolling: false) == 1)
    #expect(DockSwipe.sign(right: false, naturalScrolling: false) == -1)
}

@Test func swipePayloadLayout() {
    let began = DockSwipe.payload(phase: .began, progress: -DockSwipe.progress, positionX: 0.1, velocityX: 0, timestamp: 0x0102_0304_0506_0708)
    // Header (28) + fluid gesture (40), no velocity on the first phase.
    #expect(began.count == 68)
    #expect(began[0] == 0x08 && began[7] == 0x01)            // little-endian timestamp
    #expect(u32(began, 24) == 1)                              // one event
    #expect(u32(began, 28) == 40 && u32(began, 32) == 23)     // size, DockSwipe type
    #expect(u32(began, 36) == 1 << 24)                        // phase in the top byte of options
    #expect(Int32(bitPattern: u32(began, 44)) == DockSwipe.fixed1616(0.1))
    #expect(began[60] == 1 && began[62] == 3)                 // horizontal, Dock flavour
    #expect(Int32(bitPattern: u32(began, 64)) == -1)          // signed minimal progress

    let ended = DockSwipe.payload(phase: .ended, progress: 0, positionX: 0, velocityX: -DockSwipe.fling, timestamp: 1)
    #expect(ended.count == 96)
    #expect(u32(ended, 24) == 2)
    #expect(u32(ended, 36) == 4 << 24)
    #expect(u32(ended, 68) == 28 && u32(ended, 72) == 9 && ended[80] == 1)
    #expect(Int32(bitPattern: u32(ended, 84)) == DockSwipe.fixed1616(-DockSwipe.fling))
}

@Test func swipeAugmentAppendsTaggedPayload() {
    let event: [UInt8] = [0, 0, 0, 2, 9, 9]
    let payload = [UInt8](repeating: 7, count: 68)
    let out = DockSwipe.augment(eventData: event, payload: payload)
    #expect(out?.count == 6 + 4 + 68)
    #expect(Array(out?[6..<10] ?? []) == [0, 68, 0x10, 0x6D])   // size, then tag 4205
    #expect(out?.suffix(68).allSatisfy { $0 == 7 } == true)
    // Any other serialization format is refused rather than guessed at.
    #expect(DockSwipe.augment(eventData: [0, 0, 0, 3, 1], payload: payload) == nil)
    #expect(DockSwipe.augment(eventData: [0, 0], payload: payload) == nil)
}

@Test func managedDisplaysParse() {
    let raw: [[String: Any]] = [[
        "Display Identifier": "Main",
        "Current Space": ["ManagedSpaceID": 4],
        "Spaces": [["ManagedSpaceID": 1, "uuid": "A", "type": 0],
                   ["ManagedSpaceID": 9, "uuid": "F", "type": 4],
                   ["ManagedSpaceID": 4, "uuid": "B", "type": 0],
                   ["uuid": "broken"]],
    ]]
    let display = ManagedDisplay.parse(raw)[0]
    #expect(display.identifier == "Main" && display.current == 4)
    #expect(display.spaces.map(\.id) == [1, 9, 4])
    #expect(display.desktops.map(\.uuid) == ["A", "B"])
    #expect(ManagedDisplay.parse([[:]]) == [ManagedDisplay(identifier: "", current: 0, spaces: [])])
}

@Test func spaceWalkCountsFullScreenSpaces() {
    let order = [1, 9, 4, 6]   // 9 is a full-screen app between two desktops
    #expect(SpaceWalk.steps(in: order, from: 1, to: 4) == 2)
    #expect(SpaceWalk.steps(in: order, from: 6, to: 1) == -3)
    #expect(SpaceWalk.steps(in: order, from: 4, to: 4) == 0)
    #expect(SpaceWalk.steps(in: order, from: 1, to: 77) == nil)
}

@Test func spaceHotkeysMatchExactly() {
    let ctrl = SpaceChord.controlFlag, shift = SpaceChord.shiftFlag, opt = SpaceChord.optionFlag
    #expect(SpaceHotkey.match(keycode: 18, flags: ctrl, chord: .control) == .jump(1))
    #expect(SpaceHotkey.match(keycode: 25, flags: ctrl, chord: .control) == .jump(9))
    #expect(SpaceHotkey.match(keycode: 20, flags: ctrl | shift, chord: .control) == .send(3))
    // Extra modifiers mean someone else's shortcut: left alone.
    #expect(SpaceHotkey.match(keycode: 18, flags: ctrl | opt, chord: .control) == nil)
    #expect(SpaceHotkey.match(keycode: 18, flags: 0, chord: .control) == nil)
    // Caps Lock, Fn and the like do not get in the way.
    #expect(SpaceHotkey.match(keycode: 19, flags: ctrl | 0x10000 | 0x800000, chord: .control) == .jump(2))
    #expect(SpaceHotkey.match(keycode: 0, flags: ctrl, chord: .control) == nil)   // A is not a number
    #expect(SpaceHotkey.match(keycode: 18, flags: ctrl | opt, chord: .controlOption) == .jump(1))
    #expect(SpaceHotkey.match(keycode: 18, flags: opt | shift, chord: .option) == .send(1))
    // Hyper is all four: it jumps, and has no chord left for sending.
    let hyper = SpaceChord.hyper.jumpFlags
    #expect(SpaceHotkey.match(keycode: 21, flags: hyper, chord: .hyper) == .jump(4))
    #expect(SpaceChord.hyper.sendFlags == nil)
    #expect(SpaceChord.control.label(3) == "⌃3" && SpaceChord.control.label(3, send: true) == "⇧⌃3")
}

@Test func symbolTableWalkMatchesDlsym() {
    // An exported symbol: the walk must land exactly where dlsym does.
    let malloc = MachOSymbols.find(image: "/usr/lib/system/libsystem_malloc.dylib", symbol: "_malloc")
    #expect(malloc != nil)
    #expect(malloc == UnsafeRawPointer(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc")))
    #expect(MachOSymbols.find(image: "/usr/lib/system/libsystem_malloc.dylib", symbol: "_no_such_symbol_here") == nil)
    #expect(MachOSymbols.find(image: "/no/such/image", symbol: "_malloc") == nil)
    // SkyLight lives in the shared cache; the same walk works there.
    let sky = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    if dlopen(sky, RTLD_LAZY) != nil, let exported = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSMainConnectionID") {
        #expect(MachOSymbols.find(image: sky, symbol: "_SLSMainConnectionID") == UnsafeRawPointer(exported))
    }
}

@Test func instantSpacesDiagnosticsLine() {
    let line = InstantSpacesReport.line(instant: true, jumps: 3, sends: 1, probe: "works", send: "bridged", hotkeys: false,
                                        tap: false, lastMs: 34.6)
    #expect(line == "spacesInstant=true spacesJumps=3 spacesSends=1 spacesProbe=works spacesSend=bridged spacesHotkeys=false spacesTap=false spacesLastMs=35")
    #expect(InstantSpacesReport.line(instant: false, jumps: 0, sends: 0, probe: "untested", send: "unavailable", hotkeys: true,
                                     tap: true, lastMs: nil).hasSuffix("spacesLastMs=-"))
}

// MARK: - Send and jump policies

@Test func sendMethodSurvivesOneStubbornWindow() {
    var policy = SpaceSendPolicy<SpaceSendMethod>([.bridged, .compatID])
    // The same window missing twice is the window's problem, not the method's.
    #expect(policy.missed(.bridged, window: 7) == false)
    #expect(policy.missed(.bridged, window: 7) == false)
    #expect(policy.methods == [.bridged, .compatID])
    // A second, different window confirms it.
    #expect(policy.missed(.bridged, window: 9) == true)
    #expect(policy.methods == [.compatID])
}

@Test func sendMethodLandingClearsItsMisses() {
    var policy = SpaceSendPolicy<SpaceSendMethod>([.bridged, .compatID])
    policy.missed(.bridged, window: 1)
    policy.landed(.bridged)
    #expect(policy.missed(.bridged, window: 2) == false)
    #expect(policy.methods == [.bridged, .compatID])
}

@Test func lastSendMethodIsNeverDropped() {
    var policy = SpaceSendPolicy<SpaceSendMethod>([.bridged])
    for window in UInt32(1)...5 { #expect(policy.missed(.bridged, window: window) == false) }
    #expect(policy.methods == [.bridged])
}

@Test func sendOrderSkipsWhatThisSendTried() {
    let policy = SpaceSendPolicy<SpaceSendMethod>([.bridged, .direct, .compatID])
    #expect(policy.order(excluding: [.bridged]) == [.direct, .compatID])
    #expect(policy.order(excluding: Set(SpaceSendMethod.allCases)).isEmpty)
    #expect(SpaceSendPolicy<SpaceSendMethod>.landingTimeout >= 0.5)
}

@Test func oneLateJumpDoesNotSwitchTheSession() {
    var policy = SpaceJumpPolicy()
    #expect(policy.missed() == false)
    #expect(!policy.fallBack)
    policy.landed()
    #expect(policy.missed() == false)
    #expect(policy.missed() == true)
    #expect(policy.fallBack)
    // Only the switching miss reports the change.
    #expect(policy.missed() == false)
    policy.reset()
    #expect(!policy.fallBack)
}
