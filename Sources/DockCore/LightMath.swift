import Foundation

/// The arithmetic behind the Light Engine, kept free of AppKit so it can be tested.
///
/// The engine owns each display's gamma table: 256 encoded output values per channel that the
/// panel applies after everything else is composited. Boost, dimming and warmth are all
/// expressed as a multiplier per channel, and the three multiply into a single table, so the
/// features compose instead of fighting over who wrote last.
public enum LightMath {
    /// The white point that means "no change". Warmth is measured against it, so 6500 K gives
    /// gains of exactly 1.
    public static let neutralKelvin = 6500.0
    /// Night Shift cannot go warmer than this; CoreBrightness clamps its range to 2700–6000 K.
    public static let nightShiftFloor = 2700.0
    /// The warmest Candlelight goes: the colour of a candle flame.
    public static let candleKelvin = 1900.0
    /// Apple's rated peak for the XDR panel, in nits. SDR white sits at peak / headroom.
    public static let xdrPeakNits = 1600.0

    public struct Gains: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
        public static let identity = Gains(red: 1, green: 1, blue: 1)
        public static func uniform(_ value: Double) -> Gains { Gains(red: value, green: value, blue: value) }
        public static func * (lhs: Gains, rhs: Gains) -> Gains {
            Gains(red: lhs.red * rhs.red, green: lhs.green * rhs.green, blue: lhs.blue * rhs.blue)
        }
        public var maximum: Double { max(red, green, blue) }
    }

    // MARK: Boost

    /// The gamma multiplier for a Boost amount of 0...1. Zero is untouched and one reaches the
    /// display's current EDR headroom. Values above the headroom would only clip, so they are
    /// never asked for, and a display without headroom (EDR not engaged yet, or an SDR panel)
    /// gets exactly 1.
    ///
    /// The multiplier itself does not follow the headroom: the headroom grows as the brightness
    /// keys lower the backlight (about 11× at half brightness), and a factor that tracked it
    /// undid every step down, so 44 % looked brighter than 100 %. A fixed multiplier keeps the
    /// brightness keys working as they always have, only lifted. Two times is the ceiling: past
    /// it mid-tones bleach and the picture looks artificial, and BrightIntosh stops near 1.5×.
    public static func boostFactor(amount: Double, headroom: Double, ceiling: Double = maxBoost) -> Double {
        let room = max(headroom, 1)
        return min(1 + clamp(amount, 0, 1) * (ceiling - 1), room)
    }

    /// The most Boost multiplies by: SDR white (600 nits) up to the XDR panel's 1600-nit peak.
    public static let maxBoost = 1600.0 / 600.0

    /// The brightness of SDR white on the XDR panel. macOS keeps the panel's peak fixed and
    /// reports how far above SDR white it can still go; at full brightness that is 2.67×, so
    /// SDR white is about 600 nits.
    public static func sdrNits(headroom: Double, peak: Double = xdrPeakNits) -> Double {
        peak / max(headroom, 1)
    }

    /// A fair estimate of white with Boost applied: SDR white times the multiplier, never above
    /// the panel's peak.
    public static func boostedNits(headroom: Double, factor: Double, peak: Double = xdrPeakNits) -> Double {
        min(sdrNits(headroom: headroom, peak: peak) * max(factor, 1), peak)
    }

    // MARK: Dim

    /// What Below Black leaves of the light: amount 0.35 lets 65% through. The amount stays in
    /// 0.1...0.8, so the screen never goes fully black and can always be read to turn it off.
    public static func dimScale(amount: Double) -> Double {
        1 - clamp(amount, 0.1, 0.8)
    }

    /// The share of light a gamma scale lets through. The table scales encoded values, and the
    /// panel turns encoded values into light by about the power 2.2, so a scale of 0.65 leaves
    /// 39 % of the light, not 65 %. Cards say this number, never the raw scale.
    public static func lightKept(scale: Double) -> Double {
        pow(clamp(scale, 0, 1), 2.2)
    }

    /// Below Black starts under this brightness (DisplayServices' 0…1, four of Apple's sixteen
    /// steps)...
    public static let belowBlackStart = 0.25
    /// ...and has its full depth at the lowest step and below.
    public static let belowBlackFull = 1.0 / 16

    /// How much of Below Black applies at a backlight brightness: none above `belowBlackStart`,
    /// all of it at `belowBlackFull` and below, an even glide between, so each press of the
    /// brightness-down key past a quarter takes the screen further down instead of one jump at
    /// the bottom. Unknown brightness (no built-in panel answers) applies it all: then it is a
    /// plain dimmer.
    public static func belowBlackEngagement(brightness: Double?) -> Double {
        guard let brightness else { return 1 }
        let t = clamp((belowBlackStart - brightness) / (belowBlackStart - belowBlackFull), 0, 1)
        return ease(t)
    }

    /// The gamma scale Below Black asks for: `dimScale` blended in by the engagement and by how
    /// far its switch has faded in. Zero engagement is exactly 1, so off means untouched.
    public static func belowBlackScale(amount: Double, engagement: Double) -> Double {
        1 - (1 - dimScale(amount: amount)) * clamp(engagement, 0, 1)
    }

    // MARK: Warmth

    /// Mired, the reciprocal of colour temperature. Equal steps in mired look like equal steps
    /// of warmth, so sliders and bars are laid out in it.
    public static func mired(_ kelvin: Double) -> Double { 1_000_000 / kelvin }
    public static func kelvin(mired: Double) -> Double { 1_000_000 / mired }

    /// Where a temperature sits on a bar that runs from neutral (0) to candle (1), evenly in mired.
    public static func warmthFraction(_ kelvin: Double) -> Double {
        let low = mired(neutralKelvin), high = mired(candleKelvin)
        return clamp((mired(clamp(kelvin, candleKelvin, neutralKelvin)) - low) / (high - low), 0, 1)
    }

    public static func kelvin(warmthFraction t: Double) -> Double {
        let low = mired(neutralKelvin), high = mired(candleKelvin)
        return kelvin(mired: low + clamp(t, 0, 1) * (high - low))
    }

    /// Chromaticity of a black body, by the cubic splines of Kim et al. (2002), accurate to a
    /// fraction of a just-noticeable difference between 1667 K and 25000 K.
    public static func planckianXY(_ kelvin: Double) -> (x: Double, y: Double) {
        let t = clamp(kelvin, 1667, 25000)
        let t1 = 1e3 / t, t2 = 1e6 / (t * t), t3 = 1e9 / (t * t * t)
        let x = t <= 4000
            ? -0.2661239 * t3 - 0.2343589 * t2 + 0.8776956 * t1 + 0.179910
            : -3.0258469 * t3 + 2.1070379 * t2 + 0.2226347 * t1 + 0.240390
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// Linear Display P3 for a chromaticity at unit luminance. Apple's panels are P3 and the
    /// gamma table acts in the panel's own space, so P3 primaries are the right ones here.
    static func linearP3(x: Double, y: Double) -> Gains {
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        return Gains(red: 2.4934969 * X - 0.9313836 * Y - 0.4027108 * Z,
                     green: -0.8294890 * X + 1.7626641 * Y + 0.0236247 * Z,
                     blue: 0.0358458 * X - 0.0761724 * Y + 0.9568845 * Z)
    }

    /// Per-channel multipliers for the encoded gamma table that turn neutral white into the
    /// white of a black body at `kelvin`.
    ///
    /// The black body's colour is taken to linear light, white-balanced against the black body
    /// at 6500 K (so 6500 K changes nothing), scaled so the strongest channel is 1 (warmth never
    /// brightens), then encoded with the panel's 2.2 response. Encoding matters: the table maps
    /// encoded values, and multiplying an encoded value by g multiplies its light by g^2.2.
    public static func kelvinGains(_ kelvin: Double) -> Gains {
        let k = clamp(kelvin, candleKelvin, neutralKelvin)
        let (wx, wy) = planckianXY(neutralKelvin), (x, y) = planckianXY(k)
        let white = linearP3(x: wx, y: wy), color = linearP3(x: x, y: y)
        var linear = Gains(red: max(color.red / white.red, 0),
                           green: max(color.green / white.green, 0),
                           blue: max(color.blue / white.blue, 0))
        let top = max(linear.maximum, 1e-9)
        linear = Gains(red: linear.red / top, green: linear.green / top, blue: linear.blue / top)
        func encode(_ v: Double) -> Double { pow(clamp(v, 0, 1), 1 / 2.2) }
        return Gains(red: encode(linear.red), green: encode(linear.green), blue: encode(linear.blue))
    }

    /// Mixes warmth in by a fraction, evenly in mired, for fading Candlelight in and out.
    public static func blendedKelvin(_ kelvin: Double, mix: Double) -> Double {
        let from = mired(neutralKelvin), to = mired(clamp(kelvin, candleKelvin, neutralKelvin))
        return LightMath.kelvin(mired: from + clamp(mix, 0, 1) * (to - from))
    }

    // MARK: Riding Boost's overlay

    /// Linear Display P3 to linear sRGB (D65 both), for colours the overlay is drawn in.
    static func sRGBLinear(fromP3 c: Gains) -> Gains {
        Gains(red: 1.2249401 * c.red - 0.2249404 * c.green,
              green: -0.0420569 * c.red + 1.0420571 * c.green,
              blue: -0.0196376 * c.red - 0.0786361 * c.green + 1.0982735 * c.blue)
    }

    /// Below Black and Candlelight as a multiplier for Boost's overlay, in the overlay's own
    /// extended linear sRGB. While Boost's layer is up the gamma table cannot carry them: the
    /// multiply lifts white past 1, and Apple silicon XDR keeps the table off those EDR pixels
    /// (GCPBypassesEDRPixels), so dimming and warmth vanished exactly where they show most. The
    /// layer multiplies light, not encoded values, so the gamma gains are decoded first (^2.2)
    /// and warmth goes from the panel's P3 to sRGB. Neutral and undimmed is exactly 1, so the
    /// overlay is Boost alone; white comes out as the same warm white the table would give.
    public static func overlayTint(dimScale: Double, kelvin: Double) -> Gains {
        let light = lightKept(scale: dimScale)
        guard kelvin < neutralKelvin - 0.5 else { return .uniform(light) }
        let g = kelvinGains(kelvin)
        let linearP3 = Gains(red: pow(g.red, 2.2), green: pow(g.green, 2.2), blue: pow(g.blue, 2.2))
        let srgb = sRGBLinear(fromP3: linearP3)
        return Gains(red: max(srgb.red, 0) * light, green: max(srgb.green, 0) * light, blue: max(srgb.blue, 0) * light)
    }

    // MARK: Composition

    /// The three features multiplied into one set of gains.
    public static func gains(boost: Double, dim: Double, kelvin: Double) -> Gains {
        .uniform(max(boost, 0) * clamp(dim, 0, 1)) * kelvinGains(kelvin)
    }

    /// The table the engine writes: the display's own curve times the gains. The baseline is
    /// clamped to 0...1 first, so a curve someone else had already raised can never compound.
    public static func scaled(_ baseline: [Float], by gain: Double) -> [Float] {
        baseline.map { Float(Double(min(max($0, 0), 1)) * gain) }
    }

    /// Whether a table read back from the display is no longer the one written: macOS, ColorSync
    /// or another app has replaced it. A small tolerance absorbs the hardware's rounding.
    public static func drifted(expected: [Float], actual: [Float], tolerance: Float = 0.004) -> Bool {
        guard expected.count == actual.count, !expected.isEmpty else { return true }
        for (e, a) in zip(expected, actual) where abs(e - a) > tolerance { return true }
        return false
    }

    /// Whether a table read back from a display looks like the system's own curve: it ends near 1
    /// and never goes above it. Only such a table is taken as a new baseline, so a boosted, dimmed
    /// or warmed table, the engine's own output, can never be scaled a second time.
    public static func plausibleBaseline(_ table: [Float]) -> Bool {
        guard let top = table.max(), let bottom = table.min() else { return false }
        return top <= 1.0005 && top >= 0.97 && bottom >= -0.0005
    }

    /// Ease used when the engine fades a change in, so the screen glides instead of jumping.
    public static func ease(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

// MARK: - Which Macs can do what

/// A display feature's verdict on this Mac, in DockCore's terms so it can be tested; the app
/// turns it into its FeatureAvailability.
public enum DisplayCompatVerdict: Equatable, Sendable {
    case available
    case limited(String)
    case unavailable(String)
}

/// One display as the Light Engine sees it, reduced to what decides compatibility.
public struct LightDisplayInfo: Equatable, Sendable {
    public var name: String
    public var builtIn: Bool
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue`.
    public var potentialHeadroom: Double
    /// Whether the display's gamma table could be read. AirPlay, Sidecar and DisplayLink
    /// screens have none, and nothing written to them would show.
    public var takesGamma: Bool

    public init(name: String, builtIn: Bool, potentialHeadroom: Double, takesGamma: Bool) {
        self.name = name
        self.builtIn = builtIn
        self.potentialHeadroom = potentialHeadroom
        self.takesGamma = takesGamma
    }
}

public enum LightCompat {
    /// The MacBook Pros with a Liquid Retina XDR panel (M1 Pro of 2021 onwards), by
    /// `hw.model`, as BrightIntosh lists them (BrightIntosh/Constants.swift, supportedDevices).
    public static let xdrModels: Set<String> = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
        "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
    ]
    /// External panels with real XDR headroom, by the name macOS gives them.
    public static let xdrDisplayNames: Set<String> = ["Pro Display XDR", "Studio Display XDR"]
    /// The potential headroom an XDR panel reports (16 on an M5 Pro at any brightness). Plain
    /// Retina panels that offer EDR at all report far less, so a model newer than the list
    /// above is still recognised by this.
    public static let xdrPotentialFloor = 8.0

    /// Whether a display is an XDR panel, which is what Boost is made for.
    public static func isXDR(_ display: LightDisplayInfo, model: String) -> Bool {
        if xdrDisplayNames.contains(display.name) { return true }
        if display.builtIn && xdrModels.contains(model) { return true }
        return display.potentialHeadroom >= xdrPotentialFloor
    }

    /// XDR Boost: everything on an XDR panel; on another display with some EDR headroom it can
    /// only give back what a lower brightness held back; without headroom, nothing.
    public static func boost(_ displays: [LightDisplayInfo], model: String) -> DisplayCompatVerdict {
        let usable = displays.filter(\.takesGamma)
        if usable.contains(where: { isXDR($0, model: model) }) { return .available }
        if usable.contains(where: { $0.potentialHeadroom > 1.01 }) {
            return .limited("No XDR panel here: Boost only gives back what a lower brightness held back")
        }
        return .unavailable("Needs a Liquid Retina XDR or Pro Display XDR")
    }

    /// Below Black and Candlelight work on any display with a gamma table.
    public static func gamma(_ displays: [LightDisplayInfo], runningApps: [String] = []) -> DisplayCompatVerdict {
        let takers = displays.filter(\.takesGamma)
        if takers.isEmpty { return .unavailable("These displays take no colour adjustments (AirPlay, Sidecar or DisplayLink)") }
        if let rival = rival(in: runningApps) { return .limited("\(rival) is adjusting the display too; the two will fight") }
        if let skipped = displays.first(where: { !$0.takesGamma }) { return .limited("Not on \(skipped.name), which takes no colour adjustments") }
        return .available
    }

    /// Apps that also own the gamma table. Both writing it makes the screen flicker between the two.
    public static let rivals = ["f.lux", "Lunar", "BetterDisplay", "BrightIntosh", "Vivid", "Iris"]

    public static func rival(in runningApps: [String]) -> String? {
        rivals.first { runningApps.contains($0) }
    }
}
