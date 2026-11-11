import Foundation
import Testing
@testable import DockCore

@Test func mediaKeyDecoding() {
    // Volume up, down, from a real keyboard: key 0, state 0xA.
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x000A00) == MediaKeyEvent(key: .volumeUp, down: true, isRepeat: false))
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x010B00) == MediaKeyEvent(key: .volumeDown, down: false, isRepeat: false))
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x070A00)?.key == .mute)
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x020A01) == MediaKeyEvent(key: .brightnessUp, down: true, isRepeat: true))
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x150A00)?.key == .keyboardUp)
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x160A00)?.key == .keyboardDown)
    // Play/pause (16), other subtypes and odd states pass untouched.
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x100A00) == nil)
    #expect(MediaKeyEvent.decode(subtype: 7, data1: 0x000A00) == nil)
    #expect(MediaKeyEvent.decode(subtype: 8, data1: 0x000C00) == nil)
    // Encoding round-trips for every key.
    for key in MediaKey.allCases {
        for down in [true, false] {
            let data1 = MediaKeyEvent.data1(key: key, down: down, isRepeat: !down)
            #expect(MediaKeyEvent.decode(subtype: 8, data1: data1) == MediaKeyEvent(key: key, down: down, isRepeat: !down))
        }
    }
    #expect(MediaKey.mute.raises == nil && MediaKey.keyboardDown.raises == false && MediaKey.brightnessUp.kind == .brightness)
}

@Test func appleStepMath() {
    // Sixteen steps; up then down from a mark lands back on it exactly.
    #expect(HUDStep.step(0.5, up: true, fine: false) == 9.0 / 16)
    #expect(HUDStep.step(9.0 / 16, up: false, fine: false) == 0.5)
    // Float32 read-back noise still counts as on the mark.
    #expect(HUDStep.step(Double(Float(0.5625)) - 1e-7, up: true, fine: false) == 10.0 / 16)
    // Between marks: to the next mark in the key's direction.
    #expect(HUDStep.step(0.53, up: true, fine: false) == 9.0 / 16)
    #expect(HUDStep.step(0.53, up: false, fine: false) == 8.0 / 16)
    // Quarter steps with ⌥⇧.
    #expect(HUDStep.step(0.5, up: true, fine: true) == 33.0 / 64)
    #expect(HUDStep.step(0.5, up: false, fine: true) == 31.0 / 64)
    // Clamped at both ends.
    #expect(HUDStep.step(1, up: true, fine: false) == 1)
    #expect(HUDStep.step(0, up: false, fine: true) == 0)
    #expect(HUDStep.step(0.01, up: false, fine: false) == 0)
    // Sixteen presses go from silent to full.
    var level = 0.0
    for _ in 0..<16 { level = HUDStep.step(level, up: true, fine: false) }
    #expect(level == 1)
}

@Test func chicletMath() {
    #expect(HUDStep.chiclets(0) == Array(repeating: 0, count: 16))
    #expect(HUDStep.chiclets(1) == Array(repeating: 1, count: 16))
    let half = HUDStep.chiclets(0.5)
    #expect(half.prefix(8).allSatisfy { $0 == 1 } && half.suffix(8).allSatisfy { $0 == 0 })
    // A quarter step fills a quarter of the next chiclet.
    let quarter = HUDStep.chiclets(33.0 / 64)
    #expect(quarter[7] == 1 && quarter[8] == 0.25 && quarter[9] == 0)
    #expect(HUDStep.chiclets(0.5, count: 4) == [1, 1, 0, 0])
    #expect(HUDStep.percent(9.0 / 16) == 56 && HUDStep.percent(1.2) == 100 && HUDStep.percent(-1) == 0)
}

@Test func hudSymbolsFollowTheLevel() {
    #expect(HUDSymbol.name(.volume, level: 0) == "speaker.slash.fill")
    #expect(HUDSymbol.name(.volume, level: 0.9, muted: true) == "speaker.slash.fill")
    #expect(HUDSymbol.name(.volume, level: 0.2) == "speaker.wave.1.fill")
    #expect(HUDSymbol.name(.volume, level: 0.5) == "speaker.wave.2.fill")
    #expect(HUDSymbol.name(.volume, level: 0.8) == "speaker.wave.3.fill")
    #expect(HUDSymbol.name(.brightness, level: 0.2) == "sun.min.fill")
    #expect(HUDSymbol.name(.brightness, level: 0.7) == "sun.max.fill")
    #expect(HUDSymbol.name(.keyboard, level: 0.1) == "light.min")
    #expect(HUDSymbol.name(.keyboard, level: 1) == "light.max")
}

@Test func keyboardIdleChoices() {
    #expect(KeyboardIdle.label(5) == "5 s" && KeyboardIdle.label(60) == "1 min" && KeyboardIdle.label(1800) == "30 min")
    #expect(KeyboardIdle.label(90) == "1.5 min" && KeyboardIdle.label(0) == "Never")
    #expect(KeyboardIdle.nearest(300) == 300 && KeyboardIdle.nearest(290) == 300 && KeyboardIdle.nearest(0) == 0)
    #expect(KeyboardIdle.nearest(7) == 5 || KeyboardIdle.nearest(7) == 10)
    #expect(KeyboardIdle.choices.first == 5 && KeyboardIdle.choices.contains(1800) && KeyboardIdle.choices.last == 0)
}
