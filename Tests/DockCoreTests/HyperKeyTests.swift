import Foundation
import Testing
@testable import DockCore

@Test func hyperMappingJSON() {
    // Hyper alone: Caps Lock (0x700000039) → F18 (0x70000006D).
    #expect(HyperMapping.json(remaps: [], hyper: true)
        == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}")
    // Off, the list is exactly what Remap Keys alone writes.
    #expect(HyperMapping.json(remaps: [.swapOptionCommand], hyper: false) == KeyRemap.json([.swapOptionCommand]))
    #expect(HyperMapping.json(remaps: [], hyper: false) == KeyRemap.json([]))
    // On beside other remaps, it adds its one entry after theirs.
    let merged = HyperMapping.json(remaps: [.rightCommandToOption], hyper: true)
    #expect(merged.contains("30064771303"))
    #expect(merged.hasSuffix("{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}"))
    #expect((try? JSONSerialization.jsonObject(with: Data(merged.utf8))) != nil)
}

@Test func hyperGivesWayToCapsRemaps() {
    #expect(HyperMapping.conflict(in: [.swapOptionCommand]) == nil)
    #expect(HyperMapping.conflict(in: [.sectionToGrave, .capsToEscape]) == .capsToEscape)
    #expect(HyperMapping.conflict(in: [.capsToControl]) == .capsToControl)
    // With Caps Lock already taken, Hyper adds nothing: Remap Keys' choice stands.
    #expect(HyperMapping.json(remaps: [.capsToEscape], hyper: true) == KeyRemap.json([.capsToEscape]))
}

@Test func hyperKeyStateChordsAndTaps() {
    var state = HyperKeyState()
    let ms: UInt64 = 1_000_000
    // Hold, press A, release: A gets the modifiers, no Escape.
    #expect(state.key(code: 79, down: true, isRepeat: false, now: 0, tapForEscape: true) == .swallow)
    #expect(state.key(code: 79, down: true, isRepeat: true, now: 50 * ms, tapForEscape: true) == .swallow)
    #expect(state.key(code: 0, down: true, isRepeat: false, now: 60 * ms, tapForEscape: true) == .passWithHyper)
    #expect(state.key(code: 0, down: false, isRepeat: false, now: 80 * ms, tapForEscape: true) == .passWithHyper)
    #expect(state.key(code: 79, down: false, isRepeat: false, now: 100 * ms, tapForEscape: true) == .swallow)
    // After release, keys pass untouched.
    #expect(state.key(code: 0, down: true, isRepeat: false, now: 120 * ms, tapForEscape: true) == .pass)
    // A lone quick tap is Escape.
    #expect(state.key(code: 79, down: true, isRepeat: false, now: 200 * ms, tapForEscape: true) == .swallow)
    #expect(state.key(code: 79, down: false, isRepeat: false, now: 300 * ms, tapForEscape: true) == .swallowAndEscape)
    // Unless the option is off.
    _ = state.key(code: 79, down: true, isRepeat: false, now: 400 * ms, tapForEscape: false)
    #expect(state.key(code: 79, down: false, isRepeat: false, now: 450 * ms, tapForEscape: false) == .swallow)
    // Or the press was long; repeats do not restart the clock.
    _ = state.key(code: 79, down: true, isRepeat: false, now: 1000 * ms, tapForEscape: true)
    _ = state.key(code: 79, down: true, isRepeat: true, now: 1250 * ms, tapForEscape: true)
    #expect(state.key(code: 79, down: false, isRepeat: false, now: 1400 * ms, tapForEscape: true) == .swallow)
    // A stray key-up with no press in progress is never a tap.
    #expect(state.key(code: 79, down: false, isRepeat: false, now: 1500 * ms, tapForEscape: true) == .swallow)
}

@Test func hyperRecoversFromLostKeyUp() {
    var state = HyperKeyState()
    #expect(state.key(code: 79, down: true, isRepeat: false, now: 0, tapForEscape: true) == .swallow)
    // Secure Input took the key-up; the HID system says F18 is no longer down.
    state.reconcile(hyperDown: true)
    #expect(state.held)
    state.reconcile(hyperDown: false)
    #expect(!state.held)
    #expect(state.key(code: 0, down: true, isRepeat: false, now: 10_000_000, tapForEscape: true) == .pass)
}

@Test func hyperMappingWatchRewritesThenReports() {
    let s: UInt64 = 1_000_000_000
    var watch = HyperMappingWatch()
    // Other keys and an unmapped Caps Lock are not news.
    #expect(watch.flagsChanged(keycode: 56, mapped: true, now: 0) == .none)
    #expect(watch.flagsChanged(keycode: 57, mapped: false, now: 0) == .none)
    // First leak: one fresh write.
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 10 * s) == .rewrite)
    // The key-up of the same press, before the write could land: nothing.
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 10 * s + s / 2) == .none)
    // Still leaking after it settled: report, once.
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 14 * s) == .report)
    #expect(watch.reported)
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 15 * s) == .none)
    // Much later, a leak starts over with a rewrite.
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 200 * s) == .rewrite)
    watch.reset()
    #expect(watch.flagsChanged(keycode: 57, mapped: true, now: 201 * s) == .rewrite)
}

@Test func quitHoldSurvivesLostKeyUp() {
    #expect(QuitHoldDecision.keyDown(command: false, otherModifiers: false, isRepeat: false, holding: false) == .pass)
    #expect(QuitHoldDecision.keyDown(command: true, otherModifiers: true, isRepeat: false, holding: false) == .pass)
    #expect(QuitHoldDecision.keyDown(command: true, otherModifiers: false, isRepeat: false, holding: false) == .begin)
    #expect(QuitHoldDecision.keyDown(command: true, otherModifiers: false, isRepeat: true, holding: true) == .swallowRepeat)
    // A fresh press while a hold seemed on: its key-up was lost, so start over rather than swallow forever.
    #expect(QuitHoldDecision.keyDown(command: true, otherModifiers: false, isRepeat: false, holding: true) == .begin)
}

// MARK: - Hold ⌘Q: which key is Q

@Test func quitKeyFollowsTheLayoutNotThePosition() {
    // QWERTY: keycode 12 types q.
    #expect(QuitHoldDecision.isQuitKey(characters: "q", keyCode: 12))
    // AZERTY: the Q is where QWERTY has A, keycode 0.
    #expect(QuitHoldDecision.isQuitKey(characters: "q", keyCode: 0))
    // Dvorak: keycode 12 is an apostrophe, and ⌘' is not Quit.
    #expect(!QuitHoldDecision.isQuitKey(characters: "'", keyCode: 12))
    // AZERTY's keycode 12 is A: ⌘A is Select All, never held back.
    #expect(!QuitHoldDecision.isQuitKey(characters: "a", keyCode: 12))
    // Caps Lock or Shift may report a capital.
    #expect(QuitHoldDecision.isQuitKey(characters: "Q", keyCode: 12))
}

@Test func quitKeyWithoutCharactersFallsBackToTheANSIPosition() {
    #expect(QuitHoldDecision.isQuitKey(characters: "", keyCode: 12))
    #expect(!QuitHoldDecision.isQuitKey(characters: "", keyCode: 0))
}
