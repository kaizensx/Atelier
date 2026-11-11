import Foundation
import Testing
@testable import DockCore

@Test func boostFactorStaysWithinHeadroom() {
    // Off, or a display with no headroom, changes nothing.
    #expect(LightMath.boostFactor(amount: 0, headroom: 2.667) == 1)
    #expect(LightMath.boostFactor(amount: 1, headroom: 1) == 1)
    #expect(LightMath.boostFactor(amount: 1, headroom: 0.5) == 1)
    // Full Boost reaches the headroom exactly, never past it.
    // A fixed multiplier, capped at 2× and at the headroom.
    #expect(abs(LightMath.boostFactor(amount: 1, headroom: 2.667) - LightMath.maxBoost) < 1e-9)
    #expect(abs(LightMath.boostFactor(amount: 3, headroom: 2.667) - LightMath.maxBoost) < 1e-9)
    #expect(LightMath.maxBoost < 2.7)
    #expect(abs(LightMath.boostFactor(amount: 1, headroom: 1.4) - 1.4) < 1e-9)
    #expect(abs(LightMath.boostFactor(amount: 0.5, headroom: 3) - (1 + 0.5 * (LightMath.maxBoost - 1))) < 1e-9)
    // Lower brightness (more headroom) must not raise the factor.
    #expect(LightMath.boostFactor(amount: 0.5, headroom: 11.4) == LightMath.boostFactor(amount: 0.5, headroom: 2.667))
}

@Test func nitsEstimateMatchesTheXDRPanel() {
    // At full brightness macOS reports 2.67× headroom: SDR white is about 600 nits.
    #expect(abs(LightMath.sdrNits(headroom: 2.667) - 600) < 1)
    #expect(abs(LightMath.boostedNits(headroom: 2.667, factor: 2.667) - 1600) < 1)
    // Never above the panel's peak, never below SDR white.
    #expect(LightMath.boostedNits(headroom: 2, factor: 5) == LightMath.xdrPeakNits)
    #expect(LightMath.boostedNits(headroom: 2, factor: 0.5) == 800)
}

@Test func dimScaleIsClampedSoTheScreenStaysReadable() {
    #expect(abs(LightMath.dimScale(amount: 0.35) - 0.65) < 1e-9)
    #expect(abs(LightMath.dimScale(amount: 0) - 0.9) < 1e-9)
    #expect(abs(LightMath.dimScale(amount: 1) - 0.2) < 1e-9)
}

@Test func neutralWhiteIsUntouched() {
    let g = LightMath.kelvinGains(LightMath.neutralKelvin)
    #expect(abs(g.red - 1) < 1e-9 && abs(g.green - 1) < 1e-9 && abs(g.blue - 1) < 1e-9)
    // Asking for cooler than neutral is held at neutral: Candlelight only warms.
    #expect(LightMath.kelvinGains(9000) == g)
}

@Test func warmthDropsBlueThenGreenAndNeverBrightens() {
    var previous = LightMath.kelvinGains(LightMath.neutralKelvin)
    for kelvin in stride(from: 6400.0, through: 1900, by: -100) {
        let g = LightMath.kelvinGains(kelvin)
        #expect(abs(g.red - 1) < 1e-9, "red stays full at \(kelvin) K")
        #expect(g.blue < g.green && g.green < g.red, "blue < green < red at \(kelvin) K")
        #expect(g.green <= previous.green + 1e-9 && g.blue <= previous.blue + 1e-9, "monotonic at \(kelvin) K")
        #expect(g.maximum <= 1 + 1e-9)
        previous = g
    }
    // Candlelight goes well past Night Shift's floor: a candle keeps about half the blue of 2700 K.
    let floor = LightMath.kelvinGains(LightMath.nightShiftFloor), candle = LightMath.kelvinGains(LightMath.candleKelvin)
    #expect(candle.blue < floor.blue * 0.6)
    #expect(candle.blue > 0.1 && candle.blue < 0.35)
    #expect(floor.green > 0.65 && floor.green < 0.8)
}

@Test func planckianLocusMatchesKnownPoints() {
    // Published black-body chromaticities (CIE 1931, 2°).
    let a = LightMath.planckianXY(2856)  // Illuminant A
    #expect(abs(a.x - 0.4476) < 0.002 && abs(a.y - 0.4074) < 0.002)
    let d = LightMath.planckianXY(6500)
    #expect(abs(d.x - 0.3135) < 0.002 && abs(d.y - 0.3237) < 0.002)
}

@Test func warmthBarIsEvenInMired() {
    #expect(LightMath.warmthFraction(6500) == 0)
    #expect(LightMath.warmthFraction(1900) == 1)
    #expect(LightMath.warmthFraction(100) == 1)
    for t in [0.0, 0.25, 0.5, 0.75, 1] {
        #expect(abs(LightMath.warmthFraction(LightMath.kelvin(warmthFraction: t)) - t) < 1e-9)
    }
    // Fading in moves through mired: half way to 1900 K is the mired midpoint, not 4200 K.
    let half = LightMath.blendedKelvin(1900, mix: 0.5)
    #expect(abs(LightMath.mired(half) - (LightMath.mired(6500) + LightMath.mired(1900)) / 2) < 1e-6)
    #expect(LightMath.blendedKelvin(1900, mix: 0) == 6500)
}

@Test func gainsComposeByMultiplying() {
    let g = LightMath.gains(boost: 2, dim: 0.5, kelvin: 6500)
    #expect(g == .identity)
    let warm = LightMath.gains(boost: 1.5, dim: 0.8, kelvin: 2200), alone = LightMath.kelvinGains(2200)
    #expect(abs(warm.red - 1.2) < 1e-9)
    #expect(abs(warm.blue - alone.blue * 1.2) < 1e-9)
}

@Test func scalingClampsTheBaselineSoItCannotCompound() {
    let table: [Float] = [0, 0.5, 1, 1.4]
    #expect(LightMath.scaled(table, by: 2) == [0, 1, 2, 2])
    #expect(LightMath.scaled([-0.2, 0.25], by: 0.5) == [0, 0.125])
}

@Test func driftAndBaselineAdoption() {
    let ours: [Float] = (0..<256).map { Float($0) / 255 * 1.8 }
    #expect(!LightMath.drifted(expected: ours, actual: ours))
    #expect(!LightMath.drifted(expected: ours, actual: ours.map { $0 + 0.001 }))
    #expect(LightMath.drifted(expected: ours, actual: (0..<256).map { Float($0) / 255 }))
    #expect(LightMath.drifted(expected: ours, actual: Array(ours.prefix(10))))
    // A profile's own curve is adopted; the engine's boosted, dimmed or warmed output is not.
    let profile: [Float] = (0..<256).map { Float($0) / 255 }
    #expect(LightMath.plausibleBaseline(profile))
    #expect(!LightMath.plausibleBaseline(ours))
    #expect(!LightMath.plausibleBaseline(profile.map { $0 * 0.65 }))
    #expect(!LightMath.plausibleBaseline(profile.map { $0 * 0.33 }))
    #expect(!LightMath.plausibleBaseline([]))
}

@Test func easeRunsZeroToOne() {
    #expect(LightMath.ease(0) == 0 && LightMath.ease(1) == 1 && LightMath.ease(2) == 1)
    #expect(abs(LightMath.ease(0.5) - 0.5) < 1e-9)
}

// MARK: Below Black and Candlelight, with and without Boost's overlay

@Test func belowBlackOffLeavesTheTableUntouched() {
    // Not engaged (switch off, or brightness above the start): exactly the system's curve.
    #expect(LightMath.belowBlackScale(amount: 0.8, engagement: 0) == 1)
    let gains = LightMath.gains(boost: 1, dim: LightMath.belowBlackScale(amount: 0.5, engagement: 0), kelvin: LightMath.neutralKelvin)
    #expect(gains == .identity)
    let baseline: [Float] = (0..<256).map { Float($0) / 255 }
    #expect(LightMath.scaled(baseline, by: gains.red) == baseline)
}

@Test func belowBlackOnlyWorksAtTheBottomOfTheBrightnessRange() {
    // Above a quarter brightness: nothing, at any amount.
    for b in [1.0, 0.75, 0.5, 0.3, LightMath.belowBlackStart] {
        #expect(LightMath.belowBlackEngagement(brightness: b) == 0, "no effect at \(b)")
    }
    // The lowest step and below: all of it.
    for b in [LightMath.belowBlackFull, 0.03, 0] {
        #expect(LightMath.belowBlackEngagement(brightness: b) == 1, "full at \(b)")
    }
    // In between it deepens step by step, never backwards.
    var previous = 0.0
    for step in stride(from: 4, through: 1, by: -1) {
        let e = LightMath.belowBlackEngagement(brightness: Double(step) / 16)
        #expect(e >= previous)
        previous = e
    }
    let mid = LightMath.belowBlackEngagement(brightness: 2.0 / 16)
    #expect(mid > 0.2 && mid < 0.9)
    // No built-in brightness to read: a plain dimmer, always on.
    #expect(LightMath.belowBlackEngagement(brightness: nil) == 1)
    // Engaged in full, the slider's amount is exactly what the table gets.
    #expect(abs(LightMath.belowBlackScale(amount: 0.35, engagement: 1) - 0.65) < 1e-12)
}

@Test func lightKeptDecodesTheGammaScale() {
    #expect(LightMath.lightKept(scale: 1) == 1)
    #expect(LightMath.lightKept(scale: 0) == 0)
    // 0.65 of the encoded value is about 39 % of the light.
    #expect(abs(LightMath.lightKept(scale: 0.65) - 0.3878) < 0.001)
}

@Test func overlayTintIsBoostAloneWhenNothingElseIsOn() {
    #expect(LightMath.overlayTint(dimScale: 1, kelvin: LightMath.neutralKelvin) == .identity)
    // Dim alone: a grey multiply, the light the gamma scale would have kept.
    let dim = LightMath.overlayTint(dimScale: 0.65, kelvin: LightMath.neutralKelvin)
    #expect(dim.red == dim.green && dim.green == dim.blue)
    #expect(abs(dim.red - LightMath.lightKept(scale: 0.65)) < 1e-12)
}

@Test func overlayTintGivesTheSameWarmWhiteAsTheGammaTable() {
    // The P3 to sRGB matrix keeps white white.
    let white = LightMath.sRGBLinear(fromP3: .identity)
    #expect(abs(white.red - 1) < 1e-5 && abs(white.green - 1) < 1e-5 && abs(white.blue - 1) < 1e-5)
    for kelvin in [2700.0, 2200, 1900] {
        let tint = LightMath.overlayTint(dimScale: 1, kelvin: kelvin)
        // Back to linear P3 (inverse matrix), it is the gamma gains decoded: the same white.
        let p3 = (red: 0.8224621 * tint.red + 0.1775380 * tint.green,
                  green: 0.0331941 * tint.red + 0.9668058 * tint.green,
                  blue: 0.0170827 * tint.red + 0.0723974 * tint.green + 0.9105199 * tint.blue)
        let g = LightMath.kelvinGains(kelvin)
        #expect(abs(p3.red - pow(g.red, 2.2)) < 1e-4, "red at \(kelvin) K")
        #expect(abs(p3.green - pow(g.green, 2.2)) < 1e-4, "green at \(kelvin) K")
        // A candle's blue is a sliver of light that sRGB would need below zero to express; the
        // multiply cannot go negative, so it is held at zero, a difference of under 1 % of white.
        #expect(abs(p3.blue - pow(g.blue, 2.2)) < (tint.blue > 0 ? 1e-4 : 0.01), "blue at \(kelvin) K")
        #expect(tint.green < 1 && tint.blue < tint.green, "warm at \(kelvin) K")
        #expect(tint.blue >= 0)
    }
    // Dim and warmth together multiply.
    let both = LightMath.overlayTint(dimScale: 0.5, kelvin: 2200), warm = LightMath.overlayTint(dimScale: 1, kelvin: 2200)
    #expect(abs(both.green - warm.green * LightMath.lightKept(scale: 0.5)) < 1e-12)
}
