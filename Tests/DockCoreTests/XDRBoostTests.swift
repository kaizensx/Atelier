import Testing
@testable import DockCore

private func run(_ state: XDRBoostState, _ events: [XDRBoostEvent], wanted: Bool = true) -> XDRBoostState {
    events.reduce(state) { XDRBoostMachine.next($0, $1, wanted: wanted) }
}

@Test func xdrBoostKnowsTheSDRWhiteOfThisPanel() {
    #expect(XDRBoostPolicy.sdrWhite(model: "Mac17,8", builtIn: true) == 600)
    #expect(XDRBoostPolicy.sdrWhite(model: "MacBookPro18,1", builtIn: true) == 500)
    #expect(XDRBoostPolicy.sdrNow(headroom: 1600.0 / 600.0, sdrWhite: 600) == 600)
    #expect(XDRBoostPolicy.sdrNow(headroom: 8, sdrWhite: 600) == 200)
    // Without EDR the headroom says nothing about brightness.
    #expect(XDRBoostPolicy.sdrNow(headroom: 1, sdrWhite: 600) == 600)
}

@Test func xdrBoostKeepsEveryBrightnessStep() {
    for sdr in [600.0, 500.0] {
        // From the lowest brightness to full, every step up gives more light: no flat top.
        var last = 0.0
        for headroom in stride(from: 16.0, through: 1600 / sdr, by: -0.05) {
            let s = XDRBoostPolicy.sdrNow(headroom: headroom, sdrWhite: sdr)
            let nits = s * XDRBoostPolicy.factor(amount: 1, headroom: headroom, sdrWhite: sdr)
            #expect(nits >= last - 1.5)      // hundredths rounding wobbles by under a nit or so
            last = max(last, nits)
        }
        // Full brightness lands on the top of the curve, not past it.
        let full = 1600 / sdr
        let nits = sdr * XDRBoostPolicy.factor(amount: 1, headroom: full, sdrWhite: sdr)
        #expect(abs(nits - XDRBoostPolicy.topNits) < 6)
    }
    // The 44 % bug: lower brightness must never end up brighter than full.
    let atFull = 600 * XDRBoostPolicy.factor(amount: 1, headroom: 2.667, sdrWhite: 600)
    let at44 = 200 * XDRBoostPolicy.factor(amount: 1, headroom: 8, sdrWhite: 600)
    #expect(at44 < atFull)
    // Lower brightness gets more of a lift, up to the whole peak ratio.
    #expect(XDRBoostPolicy.factor(amount: 1, headroom: 8, sdrWhite: 600) > XDRBoostPolicy.factor(amount: 1, headroom: 2.667, sdrWhite: 600))
    #expect(XDRBoostPolicy.factor(amount: 1, headroom: 16, sdrWhite: 600) <= 1600.0 / 600.0)
    // Amount 0 is 1×, and the factor never passes the headroom.
    #expect(XDRBoostPolicy.factor(amount: 0, headroom: 8, sdrWhite: 600) == 1)
    #expect(XDRBoostPolicy.factor(amount: 1, headroom: 1.3, sdrWhite: 600) == 1.3)
}

@Test func xdrBoostWaitsForTheScreenAndForEDR() {
    var s = run(.off, [.turnOn])
    #expect(!XDRBoostMachine.showsLayer(s))
    s = run(s, [.tick(now: 10, headroom: 1, target: 1.6)])        // settle starts
    s = run(s, [.tick(now: 10.5, headroom: 1, target: 1.6)])
    #expect(!XDRBoostMachine.showsLayer(s))                        // still settling
    s = run(s, [.tick(now: 11, headroom: 1, target: 1.6)])         // layer up at 1×
    #expect(XDRBoostMachine.showsLayer(s))
    #expect(XDRBoostMachine.factor(s, now: 11) == 1)
    s = run(s, [.tick(now: 11.2, headroom: 2.67, target: 1.6)])    // EDR engaged: glide starts
    #expect(XDRBoostMachine.factor(s, now: 11.2) == 1)
    #expect(XDRBoostMachine.factor(s, now: 11.5) > 1)
    s = run(s, [.tick(now: 12, headroom: 2.67, target: 1.6)])
    #expect(s == .on(1.6))
}

@Test func xdrBoostLeavesNothingBehindWhileLockedOrAsleep() {
    var s: XDRBoostState = .on(1.6)
    s = run(s, [.suspend])
    #expect(s == .suspended)
    #expect(!XDRBoostMachine.showsLayer(s))
    #expect(XDRBoostMachine.factor(s, now: 100) == 1)
    // Ticks while away change nothing.
    s = run(s, [.tick(now: 100, headroom: 2.67, target: 1.6), .tick(now: 200, headroom: 2.67, target: 1.6)])
    #expect(s == .suspended)
    // Back: settles, engages, glides from 1× — no jump straight to full Boost.
    s = run(s, [.resume, .tick(now: 300, headroom: 1, target: 1.6)])
    #expect(!XDRBoostMachine.showsLayer(s))
    s = run(s, [.tick(now: 301, headroom: 1, target: 1.6), .tick(now: 301.1, headroom: 2.67, target: 1.6)])
    #expect(XDRBoostMachine.factor(s, now: 301.1) == 1)
}

@Test func xdrBoostDropsBackWhenEDRGoesAway() {
    var s: XDRBoostState = .on(1.6)
    s = run(s, [.tick(now: 5, headroom: 1, target: 1.6)])
    #expect(XDRBoostMachine.factor(s, now: 5) == 1)
    #expect(XDRBoostMachine.showsLayer(s))
    // EDR never returns: it backs off and tries again instead of multiplying SDR.
    s = run(s, [.tick(now: 5 + XDRBoostPolicy.engageTimeout + 0.1, headroom: 1, target: 1.6)])
    #expect(!XDRBoostMachine.showsLayer(s))
}

@Test func xdrBoostFollowsBrightnessWithoutLag() {
    // Lit: a new target (the brightness keys moving the headroom) is taken at once, so the
    // multiplier never trails the backlight and overshoots.
    var s: XDRBoostState = .on(1.6)
    s = run(s, [.tick(now: 1, headroom: 3.2, target: 1.75)])
    #expect(s == .on(1.75))
    s = run(s, [.tick(now: 1.016, headroom: 2.9, target: 1.7)])
    #expect(s == .on(1.7))
}

@Test func xdrBoostGlidesToANewTargetFromWhereItIs() {
    var s: XDRBoostState = .ramping(from: 1, to: 1.6, start: 0)
    s = run(s, [.tick(now: 0.3, headroom: 2.67, target: 1.4)])     // changed mid-glide
    if case .ramping(let from, let to, _) = s {
        #expect(from > 1 && from < 1.6)
        #expect(to == 1.4)
    } else {
        Issue.record("expected a glide, got \(s)")
    }
}

@Test func xdrBoostTurnsOffFromAnyState() {
    for state: XDRBoostState in [.suspended, .settling(since: 1), .engaging(since: 1), .ramping(from: 1, to: 1.6, start: 0), .on(1.6)] {
        #expect(XDRBoostMachine.next(state, .turnOff, wanted: false) == .off)
    }
    // Suspending while not wanted is off; turning on while suspended waits for the screen.
    #expect(XDRBoostMachine.next(.on(1.6), .suspend, wanted: false) == .off)
    #expect(XDRBoostMachine.next(.suspended, .turnOn, wanted: true) == .suspended)
}

@Test func xdrBoostGlidesOutWhenTurnedOff() {
    var s: XDRBoostState = .on(1.6)
    s = XDRBoostMachine.next(s, .tick(now: 0, headroom: 2.67, target: 1.6), wanted: false)
    #expect(s == .ramping(from: 1.6, to: 1, start: 0))
    #expect(XDRBoostMachine.showsLayer(s))
    s = XDRBoostMachine.next(s, .tick(now: 1, headroom: 2.67, target: 1.6), wanted: false)
    #expect(s == .on(1))
    s = XDRBoostMachine.next(s, .tick(now: 1.2, headroom: 2.67, target: 1.6), wanted: false)
    #expect(s == .off)
    // Not yet lit: off at once.
    #expect(XDRBoostMachine.next(.engaging(since: 0), .tick(now: 1, headroom: 1, target: 1.6), wanted: false) == .off)
}
