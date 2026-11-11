import DockCore
import SwiftUI

// MARK: - Light: heroes and stage
//
// The three Light Engine features open Display & Appearance as hero cards, each with a plate
// drawn in the units the change is felt in: nits for Boost, the share of light for Below Black,
// kelvin for Candlelight. The plates are still pictures at rest and come alive only under the
// pointer. The stage is an SDR picture, so it cannot show more light than the panel has; Boost
// is drawn as bloom over the replica instead of darkening everything else. While a feature is
// on, the real screen (stage included) already shows it, so its preview draws only the caption,
// never the effect a second time.

/// The Light section: a heading and the three heroes, in the order of the light scale.
struct LightCards: View {
    var body: some View {
        SectionHeader("Light", symbol: "sun.max",
                      detail: "Past Apple's limits: brighter than the maximum, darker than the minimum, warmer than Night Shift.",
                      hue: DS.Spectrum.light)
        XDRBoostCard()
        ExtraDimCard()
        CandlelightCard()
    }
}

private func formatted(_ value: Double) -> String {
    // No grouping: display numbers read cleaner as "1200" than with a locale separator.
    value.formatted(.number.precision(.fractionLength(0)).grouping(.never))
}

// MARK: Availability on a hero

extension View {
    /// The card's availability note, pinned to the plate's top-right corner so it shows whether
    /// the switch is on or off (the controls below it only appear when on).
    func displayCompatNote(_ availability: FeatureAvailability) -> some View {
        overlay(alignment: .topTrailing) {
            // Starts clear of the plate's "Beyond macOS" badge at the top left: a long note
            // wraps onto a second line instead of running underneath it.
            AvailabilityNote(availability: availability).padding(10).padding(.leading, HeroBadge.clearance)
        }
    }
}

extension Binding where Value == Bool {
    /// A hero switch that can always be turned off but only turned on where the feature works,
    /// so a Mac that cannot do it never ends up with a switch that says on and does nothing.
    @MainActor func displayCompatGated(_ availability: FeatureAvailability) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { on in
            if !on || availability.isUsable { wrappedValue = on }
        })
    }
}

// MARK: Plate life

/// Hover-gated life for a hero plate. `live` is true only while the pointer rests on the plate
/// and Reduce Motion is off; at rest every plate is a still picture that costs nothing.
struct HeroLife<Content: View>: View {
    @ViewBuilder var content: (_ live: Bool) -> Content
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder content: @escaping (_ live: Bool) -> Content) { self.content = content }

    var body: some View {
        content(hover && !reduceMotion)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// A plate's clock: seconds while live, a fixed rest time otherwise, so the paused picture is
/// always the same composed frame rather than wherever the loop happened to stop.
struct HeroClock<Content: View>: View {
    let live: Bool
    var rest = 0.0
    @ViewBuilder var content: (_ t: Double) -> Content

    init(live: Bool, rest: Double = 0, @ViewBuilder content: @escaping (_ t: Double) -> Content) {
        self.live = live
        self.rest = rest
        self.content = content
    }

    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1 / 120)) { context in
                content(context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(rest)
        }
    }
}

// MARK: XDR Boost

struct XDRBoostCard: View {
    @ObservedObject private var light = LightEngine.shared

    private var note: String {
        if let level = light.brightness, level < 0.9 {
            return "Made for full brightness. Below the top step, Boost only gives back what the brightness keys took away."
        }
        return "Uses the headroom macOS keeps for HDR video. The panel runs warmer, and macOS may hold Boost back when hot."
    }

    var body: some View {
        let availability = light.boostAvailability
        HeroCard("XDR Boost",
                 pitch: availability.isUsable ? "Brighter than Apple's maximum, for sunlit rooms. Every app, not just HDR video."
                                              : "This display has no XDR headroom. Boost needs a Liquid Retina XDR or Pro Display XDR.",
                 isOn: $light.boostOn.displayCompatGated(availability), hue: DS.Spectrum.light,
                 // Nits are estimated against the XDR panel's rated peak, so only an XDR panel gets them.
                 readout: availability == .available ? "\(formatted(light.boostedNits)) nits" : "—",
                 readoutCaption: availability == .available ? (light.boostOn ? "Estimated now" : "With Boost")
                     : availability.isUsable ? "No XDR panel" : "Needs XDR",
                 preview: .overlay("display.xdrBoost", "XDR Boost", isOn: light.boostOn) { size in BoostPreview(size: size) }) {
            NitsPlate(light: light).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 12) {
                    Text("Boost").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 52, alignment: .leading)
                    LuxSlider(value: $light.boostAmount, range: 0...1, label: "Boost", tint: DS.Spectrum.light)
                    Text(String(format: "%.2f×", light.boostFactor)).font(DS.Typo.value)
                        .foregroundStyle(DS.Ink.secondary).frame(width: 46, alignment: .trailing)
                }
                .disabled(!availability.isUsable)
                HStack(spacing: DS.Space.l) {
                    Text(String(format: "Headroom %.2f×", light.headroom))
                    if let level = light.brightness { Text("Brightness \(Int((level * 100).rounded()))%") }
                    Text("Apple's maximum \(formatted(light.sdrNits)) nits")
                }
                .font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary)
                Text(note).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// White on a nits scale from black to the panel's peak. Up to Apple's maximum the bar is
/// plain grey; the part Boost adds is luminous, its bloom a gradient (never a shadow) that
/// breathes only while the pointer is on the plate.
private struct NitsPlate: View {
    @ObservedObject var light: LightEngine

    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: .pi / 3.2) { t in
                let breath = (sin(t * 1.6) + 1) / 2
                Canvas { g, size in draw(&g, size: size, breath: breath) }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, breath: Double) {
        let peak = LightMath.xdrPeakNits
        let sdr = light.sdrNits
        let boosted = light.xdrCapable ? light.boostedNits : sdr
        let x0 = 22.0, x1 = size.width - 22
        let w = x1 - x0
        let y = size.height * 0.46
        let h = 12.0
        let sdrX = x0 + w * min(sdr / peak, 1)
        let boostX = x0 + w * min(boosted / peak, 1)
        let on = light.boostOn

        // Bloom around what Boost adds: a radial gradient, its opacity breathing.
        if boostX - sdrX > 2 {
            let center = CGPoint(x: (sdrX + boostX) / 2, y: y)
            let reach = max(boostX - sdrX, 60)
            let glow = (on ? 0.32 : 0.14) + 0.12 * breath
            g.fill(Path(ellipseIn: CGRect(x: center.x - reach, y: y - 46, width: reach * 2, height: 92)),
                   with: .radialGradient(Gradient(colors: [DS.Spectrum.light.opacity(glow), .clear]),
                                         center: center, startRadius: 0, endRadius: reach))
        }
        // Ticks every 200 nits, so the bar reads as a scale.
        var ticks = Path()
        for nits in stride(from: 0.0, through: peak, by: 200) {
            let x = x0 + w * nits / peak
            ticks.move(to: CGPoint(x: x, y: y + h / 2 + 6))
            ticks.addLine(to: CGPoint(x: x, y: y + h / 2 + (nits.truncatingRemainder(dividingBy: 400) == 0 ? 11 : 8)))
        }
        g.stroke(ticks, with: .color(.white.opacity(0.22)), lineWidth: 1)

        let track = Path(roundedRect: CGRect(x: x0, y: y - h / 2, width: w, height: h), cornerRadius: h / 2)
        g.fill(track, with: .color(.black.opacity(0.45)))
        g.stroke(track, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        // Up to Apple's maximum: plain light.
        let base = Path(roundedRect: CGRect(x: x0, y: y - h / 2, width: max(sdrX - x0, h), height: h), cornerRadius: h / 2)
        g.fill(base, with: .linearGradient(Gradient(colors: [Color(white: 0.22), Color(white: 0.78)]),
                                           startPoint: CGPoint(x: x0, y: y), endPoint: CGPoint(x: sdrX, y: y)))
        // What Boost adds: luminous when on, an outline of the promise when off.
        if boostX - sdrX > 1 {
            let extra = Path(roundedRect: CGRect(x: sdrX - h / 2, y: y - h / 2, width: boostX - sdrX + h / 2, height: h), cornerRadius: h / 2)
            if on {
                g.fill(extra, with: .linearGradient(Gradient(colors: [Color(white: 0.92), .white, DS.Spectrum.light.opacity(0.9)]),
                                                    startPoint: CGPoint(x: sdrX, y: y), endPoint: CGPoint(x: boostX, y: y)))
            } else {
                g.stroke(extra, with: .color(DS.Spectrum.light.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        // Apple's maximum, marked.
        g.fill(Path(CGRect(x: sdrX - 0.75, y: y - 14, width: 1.5, height: 28)), with: .color(.white.opacity(0.75)))
        let label = Text("Apple's max \(formatted(sdr))").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        g.draw(label, at: CGPoint(x: sdrX, y: y - 22), anchor: .bottom)
        let floor = Text("0").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
        g.draw(floor, at: CGPoint(x: x0, y: y + h / 2 + 14), anchor: .topLeading)
        let top = Text("Panel peak \(formatted(peak))").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        g.draw(top, at: CGPoint(x: x1, y: y - 22), anchor: .bottomTrailing)
    }
}

/// More light than SDR can show, drawn as bloom: an even lift over everything, a brighter heart,
/// and a slow breath that says the light is alive. Reduce Motion holds the breath still.
struct BoostPreview: View {
    @ObservedObject private var light = LightEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGSize

    var body: some View {
        let a = light.boostOn ? 0 : max(light.boostAmount, 0.15)
        let nits = light.boostedNits(amount: max(light.boostAmount, 0.15))
        ZStack {
            if a > 0 {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let breath = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 1.6) + 1) / 2
                    ZStack {
                        Rectangle().fill(.white.opacity(0.07 + 0.1 * a))
                        RadialGradient(colors: [.white.opacity((0.22 + 0.06 * breath) * a), .clear],
                                       center: .center, startRadius: 0, endRadius: max(size.width, size.height) * (0.55 + 0.05 * breath))
                    }
                    .blendMode(.plusLighter)
                }
            }
            LightChip(symbol: "sun.max.fill", text: "≈ \(formatted(nits)) nits, \(String(format: "%.1f×", nits / light.sdrNits)) Apple's maximum")
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}


// MARK: Below Black

/// Below Black, which took over from Extra Dim: same settings, same place in search.
///
/// It follows the backlight: nothing above a quarter brightness, then deeper with each step
/// down, its full depth at the lowest step. The card says where the backlight is and what Below
/// Black is doing there right now, so a switch that is on at full brightness never looks broken.
struct ExtraDimCard: View {
    @ObservedObject private var light = LightEngine.shared

    private var percentStart: Int { Int((LightMath.belowBlackStart * 100).rounded()) }

    /// One line on what is happening now, in the units the eye judges.
    private var status: String {
        let taken = Int((light.dimLightTakenNow * 100).rounded())
        guard let level = light.dimBrightness else {
            return "Working now: \(taken)% less light on every display."
        }
        let at = Int((level * 100).rounded())
        if light.dimEngagement <= 0.001 {
            return "Brightness is \(at)%. Turn it down below \(percentStart)% and Below Black takes over."
        }
        if light.dimEngagement >= 0.999 {
            return "Working now at the lowest step: \(taken)% less light than Apple's lowest."
        }
        return "Working now at \(at)% brightness: \(taken)% less light. Deepest at the lowest step."
    }

    var body: some View {
        let availability = light.gammaAvailability
        HeroCard("Below Black",
                 pitch: "Takes the screen darker than Apple's lowest brightness: it starts below \(percentStart)% and is deepest at the lowest step.",
                 isOn: $light.dimOn.displayCompatGated(availability), hue: DS.Spectrum.light,
                 readout: "−\(Int((light.dimLightTaken * 100).rounded()))%",
                 readoutCaption: "Light at the lowest step",
                 preview: .overlay("display.extraDim", "Below Black", isOn: light.dimOn) { size in BelowBlackPreview(size: size) }) {
            BelowBlackPlate(scale: light.dimScale, on: light.dimOn, brightness: light.dimBrightness,
                            engagement: light.dimOn ? light.dimEngagement : 0)
                .displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 12) {
                    Text("Darker").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 52, alignment: .leading)
                    LuxSlider(value: $light.dimAmount, range: 0.1...0.8, label: "Below Black amount", tint: DS.Spectrum.light)
                    Text("Keeps \(Int(((1 - light.dimLightTaken) * 100).rounded()))%").font(DS.Typo.value)
                        .foregroundStyle(DS.Ink.secondary).frame(width: 82, alignment: .trailing)
                }
                Text(status).font(DS.caption).monospacedDigit()
                    .foregroundStyle(light.dimEngagement > 0.001 ? DS.Spectrum.light : DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Apple's brightness steps as a staircase of light, and past its lowest step the stairs
/// Below Black adds, going on down. A dot marks where the screen is now; under the pointer it
/// walks down the stairs instead.
private struct BelowBlackPlate: View {
    let scale: Double
    let on: Bool
    /// The backlight now, 0…1, when it can be read.
    let brightness: Double?
    /// How much of Below Black applies now, 0…1.
    let engagement: Double

    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: 0) { t in
                Canvas { g, size in draw(&g, size: size, t: t, live: live) }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, live: Bool) {
        let apple = 12, extra = 5
        let count = apple + extra
        let left = 22.0, right = size.width - 150
        let gap = 4.0
        let barW = max((right - left - gap * Double(count - 1)) / Double(count), 4)
        let base = size.height - 30
        let tallest = size.height - 66
        let lowest = 0.12
        // Brightness of each step, darkest on the left: Atelier's first, then Apple's.
        func level(_ i: Int) -> Double {
            if i >= extra { return lowest + (1 - lowest) * Double(i - extra) / Double(apple - 1) }
            let k = Double(extra - i) / Double(extra)
            return lowest * (1 - (1 - scale) * k)
        }
        // Under the pointer the marker loops from the brightest step down to the darkest and
        // holds there; at rest it shows where the screen is now (when Below Black is on).
        let cycle = 3.2
        let p = live ? t.truncatingRemainder(dividingBy: cycle) / cycle : 1
        let walking = Int((Double(count - 1) * (1 - min(p / 0.75, 1))).rounded())
        let now: Int? = {
            guard on else { return nil }
            if engagement > 0.001 { return extra - 1 - Int((Double(extra - 1) * engagement).rounded()) }
            guard let brightness else { return nil }
            return extra + Int((Double(apple - 1) * min(max(brightness, 0), 1)).rounded())
        }()
        let marker = live ? walking : now

        for i in 0..<count {
            let x = left + Double(i) * (barW + gap)
            let l = level(i)
            let h = max(tallest * (0.18 + 0.82 * Double(i) / Double(count - 1)), 8)
            let rect = CGRect(x: x, y: base - h, width: barW, height: h)
            let ours = i < extra
            let lum = 0.08 + 0.85 * pow(l, 0.6)
            let bar = Path(roundedRect: rect, cornerRadius: min(3, barW / 2))
            g.fill(bar, with: .color(Color(white: lum)))
            if ours {
                g.stroke(bar, with: .color(DS.Spectrum.light.opacity(on ? 0.4 + 0.5 * engagement : 0.4)), lineWidth: 0.75)
            }
            if i == marker {
                g.fill(Path(ellipseIn: CGRect(x: x + barW / 2 - 3, y: base - h - 10, width: 6, height: 6)),
                       with: .color(DS.Spectrum.light))
            }
        }
        // Apple's lowest step, marked: everything left of the line is Atelier's.
        let floorX = left + Double(extra) * (barW + gap) - gap / 2
        g.fill(Path(CGRect(x: floorX - 0.75, y: 34, width: 1.5, height: base - 34 + 6)), with: .color(.white.opacity(0.55)))
        g.draw(Text("Apple's lowest").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.6)),
               at: CGPoint(x: floorX + 6, y: 36), anchor: .topLeading)
        g.draw(Text("Below Black").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DS.Spectrum.light.opacity(on ? 1 : 0.7)),
               at: CGPoint(x: left, y: base + 8), anchor: .topLeading)
    }
}

/// The whole stage darkened by the share of light Below Black takes at its full depth, the way
/// the panel itself would be at the lowest step.
struct BelowBlackPreview: View {
    @ObservedObject private var light = LightEngine.shared
    let size: CGSize

    var body: some View {
        // What the real screen is already doing is not drawn a second time: only the part of
        // the full depth the backlight has not called for yet.
        let shown = light.dimLightTaken - light.dimLightTakenNow
        ZStack {
            Rectangle().fill(.black).opacity(max(shown, 0))
                .animation(DS.Motion.settle, value: shown)
            LightChip(symbol: "moon.stars.fill", text: "At the lowest step, keeps \(Int(((1 - light.dimLightTaken) * 100).rounded()))% of Apple's lowest")
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}


// MARK: Candlelight

struct CandlelightCard: View {
    @ObservedObject private var light = LightEngine.shared
    @ObservedObject private var display = Display.shared

    private var name: String {
        switch light.candleKelvin {
        case ..<2050: "Candle flame"
        case ..<2300: "Firelight"
        case ..<2550: "Sunset"
        default: "Warm bulb"
        }
    }

    var body: some View {
        // The readout is drawn by the plate itself, in the colour it names.
        let availability = light.gammaAvailability
        HeroCard("Candlelight",
                 pitch: "Warmer than Night Shift can go, down to the colour of a candle flame. Kind to your eyes late at night.",
                 isOn: $light.candleOn.displayCompatGated(availability), hue: DS.Spectrum.light,
                 preview: .overlay("display.candlelight", "Candlelight", isOn: light.candleOn) { size in CandlePreview(size: size) }) {
            CandlePlate(kelvin: light.candleKelvin, name: name).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                WarmthBar(kelvin: $light.candleKelvin)
                if display.nightShift {
                    Text("Night Shift is on too, and the two add up. Turn it off for true Candlelight colours.")
                        .font(DS.caption).foregroundStyle(DS.Spectrum.light)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Two pages side by side: one as warm as Night Shift goes, one at the chosen kelvin, with a
/// flame between them that flickers only under the pointer. The kelvin, tinted its own colour,
/// sits where every hero keeps its numeral.
private struct CandlePlate: View {
    let kelvin: Double
    let name: String

    var body: some View {
        let warm = WarmthBar.color(kelvin)
        HeroLife { live in
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 18) {
                    page(WarmthBar.color(LightMath.nightShiftFloor), width: 58, label: "Night Shift", dim: true)
                    HeroClock(live: live, rest: 0) { t in
                        let flicker = (sin(t * 11) + sin(t * 17.3) * 0.6) / 1.6
                        Image(systemName: "flame.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(LinearGradient(colors: [.white, warm], startPoint: .top, endPoint: .bottom))
                            .scaleEffect(x: 1 - 0.04 * flicker, y: 1 + 0.07 * flicker, anchor: .bottom)
                            .opacity(0.9 + 0.1 * flicker)
                            .background {
                                RadialGradient(colors: [warm.opacity(0.5 + 0.1 * flicker), .clear], center: .center,
                                               startRadius: 0, endRadius: 34)
                                    .frame(width: 80, height: 80)
                            }
                    }
                    .padding(.bottom, 34)
                    page(warm, width: 70, label: "Candlelight", dim: false)
                }
                .padding(.leading, 26)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(kelvin.formatted(.number.precision(.fractionLength(0)).grouping(.never))) K")
                        .font(DS.Typo.readout).foregroundStyle(warm)
                        .contentTransition(.numericText(value: kelvin))
                    Text(name.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
                }
                .padding(DS.Space.m)
            }
        }
        .animation(DS.Motion.settle, value: kelvin)
        .accessibilityHidden(true)
    }

    /// A page of white, as the screen would show it at that temperature.
    private func page(_ tint: Color, width: Double, label: String, dim: Bool) -> some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(.black.opacity(0.28)).frame(width: width * (i == 4 ? 0.45 : i == 0 ? 0.6 : 0.78), height: 3)
                }
            }
            .padding(10)
            .frame(width: width, height: width * 1.22, alignment: .topLeading)
            .background(tint, in: .rect(cornerRadius: 5, style: .continuous))
            .opacity(dim ? 0.7 : 1)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(dim ? 0.5 : 0.75))
        }
    }
}

/// White to candle, laid out evenly in mired so equal distances look like equal warmth. Night
/// Shift's half is shaded and ends at its 2700 K floor; the knob lives past it.
struct WarmthBar: View {
    @Binding var kelvin: Double
    @State private var dragging = false

    /// The colour white takes at a temperature, straight from the engine's own gains.
    static func color(_ kelvin: Double) -> Color {
        let g = LightMath.kelvinGains(kelvin)
        return Color(.displayP3, red: g.red, green: g.green, blue: g.blue)
    }

    private static let stops: [Gradient.Stop] = (0...12).map { i in
        let t = Double(i) / 12
        return .init(color: color(LightMath.kelvin(warmthFraction: t)), location: t)
    }

    var body: some View {
        let floor = LightMath.warmthFraction(LightMath.nightShiftFloor)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let w = geometry.size.width
                let x = w * LightMath.warmthFraction(kelvin)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(stops: Self.stops, startPoint: .leading, endPoint: .trailing))
                        .frame(height: dragging ? 14 : 10)
                    // Night Shift's own range, quieted, so the eye goes to what only Atelier does.
                    Capsule().fill(.black.opacity(0.45))
                        .frame(width: w * floor, height: dragging ? 14 : 10)
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 1.5, height: 20).offset(x: w * floor - 0.75)
                    Circle()
                        .fill(Self.color(kelvin))
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                        .frame(width: dragging ? 24 : 20, height: dragging ? 24 : 20)
                        .shadow(color: Self.color(kelvin).opacity(0.8), radius: 6)
                        .offset(x: x - (dragging ? 12 : 10))
                }
                .frame(maxHeight: .infinity)
                .animation(DS.Motion.touch, value: dragging)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        let t = min(max(gesture.location.x / w, floor), 1)
                        kelvin = (LightMath.kelvin(warmthFraction: t) / 10).rounded() * 10
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 26)
            HStack {
                Text("6,500 K")
                Spacer()
                Text("Night Shift stops at 2,700 K").frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
                Text("1,900 K")
            }
            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("Colour temperature")
        .accessibilityValue("\(Int(kelvin)) kelvin")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: kelvin = max(kelvin - 100, LightMath.candleKelvin)
            case .decrement: kelvin = min(kelvin + 100, LightMath.nightShiftFloor)
            @unknown default: return
            }
        }
    }
}

/// The stage multiplied by the colour white would take, which is exactly what the gamma table does.
struct CandlePreview: View {
    @ObservedObject private var light = LightEngine.shared
    let size: CGSize

    var body: some View {
        ZStack {
            // With the real screen already warm, the stage is too; tint it once.
            if !light.candleOn {
                Rectangle().fill(WarmthBar.color(light.candleKelvin)).blendMode(.multiply)
                    .animation(DS.Motion.settle, value: light.candleKelvin)
            }
            LightChip(symbol: "flame.fill", text: "\(Int(light.candleKelvin)) K, warmer than Night Shift's 2,700 K")
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// A caption on the stage, low in the middle, saying what the light would be.
private struct LightChip: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Label(text, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: .capsule)
                .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                .padding(.bottom, 18)
        }
    }
}
