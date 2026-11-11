import Foundation
import Testing
@testable import DockCore

@Test func aShakeIsFourQuickReversals() {
    var detector = ShakeDetector()
    var time = 0.0
    var fired = false
    for swing in 0..<6 {
        let from = swing % 2 == 0 ? 100.0 : 300.0, to = swing % 2 == 0 ? 300.0 : 100.0
        for step in 0...10 {
            time += 0.008
            if detector.add(x: from + (to - from) * Double(step) / 10, time: time) { fired = true }
        }
    }
    #expect(fired)
}

@Test func slowOrSmallMovesAreNotAShake() {
    var small = ShakeDetector()
    var time = 0.0
    for swing in 0..<12 {
        let x = swing % 2 == 0 ? 100.0 : 120.0
        time += 0.02
        let fired = small.add(x: x, time: time)
        #expect(!fired)
    }
    var slow = ShakeDetector()
    time = 0
    for swing in 0..<8 {
        time += 0.5
        let fired = slow.add(x: swing % 2 == 0 ? 0 : 400, time: time)
        #expect(!fired)
    }
}

@Test func nightRampsInAndOut() {
    // 21:00 to 07:00, 60 minute fades.
    let start = 21.0 * 60, end = 7.0 * 60
    #expect(NightSchedule.strength(minute: 20 * 60, start: start, end: end, fade: 60) == 0)
    #expect(NightSchedule.strength(minute: 21 * 60 + 30, start: start, end: end, fade: 60) == 0.5)
    #expect(NightSchedule.strength(minute: 2 * 60, start: start, end: end, fade: 60) == 1)
    #expect(NightSchedule.strength(minute: 6 * 60 + 30, start: start, end: end, fade: 60) == 0.5)
    #expect(NightSchedule.strength(minute: 12 * 60, start: start, end: end, fade: 60) == 0)
}

@Test func nightTimerSleepsUntilTheNextRamp() {
    let start = 21.0 * 60, end = 7.0 * 60
    // Noon: next change is the start, nine hours away.
    #expect(NightSchedule.secondsUntilNextUpdate(minute: 12 * 60, start: start, end: end, fade: 60) == 9 * 3600)
    // Inside the evening ramp: every minute.
    #expect(NightSchedule.secondsUntilNextUpdate(minute: 21 * 60 + 10, start: start, end: end, fade: 60) == 60)
    // Deep night: wake for the morning ramp at 06:00.
    #expect(NightSchedule.secondsUntilNextUpdate(minute: 1 * 60, start: start, end: end, fade: 60) == 5 * 3600)
}

@Test func emptyNightWindowIsOff() {
    #expect(NightSchedule.strength(minute: 100, start: 600, end: 600, fade: 30) == 0)
}
