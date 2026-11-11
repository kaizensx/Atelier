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
