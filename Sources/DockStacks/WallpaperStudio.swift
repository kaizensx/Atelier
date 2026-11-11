import AppKit
import SwiftUI

/// The Wallpaper chapter: generated wallpapers, set as the real desktop picture, and the way back.
struct WallpaperStudioChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var live = LiveWallpaper.shared
    @State private var hovered: Hue?
    /// What the hero's switch turns back on: the last palette worn.
    @AppStorage("wallpaperStudio.lastHue") private var lastHue = Hue.aurora.rawValue
    private let columns = [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m),
                           GridItem(.flexible(), spacing: DS.Space.m)]
    private let hue = DS.Spectrum.surfaces

    private var hour: Int {
        effects.livingCycle.heldHour.map { Int($0) } ?? Calendar.current.component(.hour, from: Date())
    }

    /// The palette on the plate: the one under the pointer, else the one worn, else the last one.
    private var shown: Hue { hovered ?? effects.living ?? Hue(rawValue: lastHue) ?? .aurora }

    /// The main display in pixels: generated wallpapers are painted at exactly this.
    private var pixels: String {
        guard let screen = NSScreen.main else { return "Retina" }
        let scale = screen.backingScaleFactor
        return "\(Int(screen.frame.width * scale))×\(Int(screen.frame.height * scale))"
    }

    private var wearing: Binding<Bool> {
        Binding(get: { effects.living != nil }, set: { on in
            if on {
                guard DesktopAvailability.metal.isUsable else { return }
                let pick = Hue(rawValue: lastHue) ?? .aurora
                if pick == .yours { live.sampleWallpaper() }
                withAnimation(DS.Motion.arrive) { effects.living = pick }
            } else {
                withAnimation(DS.Motion.arrive) { effects.living = nil }
            }
        })
    }

    var body: some View {
        Text("Wallpapers painted by your GPU at each display's full resolution, set as your desktop picture. Yours is kept and comes back with one click.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)

        OriginalWallpaperCard()

        HeroCard("Generated Wallpaper",
                 pitch: "Repainted as the light changes through the day: brighter by day, deeper at night.",
                 isOn: wearing, hue: hue, readout: pixels, readoutCaption: "Painted at") {
            WallpaperStudioPlate(hue: shown, hour: hour, seed: shown.defaultSeed + Float(effects.livingSeed))
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingRow(title: "Light", detail: effects.livingCycle == .clock
                               ? "Follows the hour, warm at golden hour."
                               : "Holds the look of \(effects.livingCycle.title.lowercased()).", density: .compact) {
                        Button {
                            withAnimation(DS.Motion.arrive) { effects.shuffleLiving() }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Ink.primary)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(DS.Ink.fillStrong, in: Capsule())
                                .fixedSize()
                        }
                        .buttonStyle(Pressable(scale: 0.95))
                    }
                    Segments(selection: $effects.livingCycle, options: DayCycle.allCases.map { ($0, $0.title) })
                }
                TuningSlider(title: "Grain", value: $effects.livingGrain, range: 0...1, tint: hue) { "\(Int(($0 * 100).rounded()))%" }
            }
        }

        SectionHeader("Palettes", symbol: "swatchpalette", detail: "Click one to wear it; click it again to put yours back.", hue: hue)
        // Without Metal the cards still preview with a plain gradient, but nothing can be painted
        // at full size, so they are held back and the reason is shown.
        AvailabilityNote(availability: DesktopAvailability.metal)
        LazyVGrid(columns: columns, spacing: DS.Space.m) {
            ForEach(Hue.allCases) { hue in card(hue) }
        }
        .disabled(!DesktopAvailability.metal.isUsable && effects.living == nil)

        Text("Prefer to leave your wallpaper setting alone? Still Background and Live Wallpaper draw above it instead, and never change it.")
            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)
    }

    private func card(_ hue: Hue) -> some View {
        let selected = effects.living == hue
        let shape = RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
        return Button {
            if hue == .yours { live.sampleWallpaper() }
            if !selected { lastHue = hue.rawValue }
            withAnimation(DS.Motion.arrive) { effects.living = selected ? nil : hue }
        } label: {
            ZStack(alignment: .bottomLeading) {
                MeshCanvas(hue: hue, hour: hour, seed: hue.defaultSeed + Float(effects.livingSeed))
                    .frame(height: 92)
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                Color.white.opacity(hovered == hue && !selected ? 0.07 : 0)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    if hue == .yours { Image(systemName: "photo").font(.system(size: 11, weight: .semibold)) }
                    Text(hue.title).font(DS.Typo.rowTitle)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(self.hue) }
                }
                .foregroundStyle(DS.Ink.primary)
                .padding(10)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? self.hue : .white.opacity(hovered == hue ? 0.26 : 0.1), lineWidth: selected ? 2 : 0.5)
            }
            .animation(DS.Motion.hover, value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .onHover { inside in if inside, !ScrollActivity.scrolling { hovered = hue } else if hovered == hue { hovered = nil } }
        .accessibilityLabel(hue.title)
        .accessibilityHint(selected ? "Restores your own wallpaper" : "Sets this as your wallpaper")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The generated wallpaper at plate size, the same shader as the real one. At rest it is the
/// painting; under the pointer the camera drifts across it, slowly. Transforms only, no repaint.
private struct WallpaperStudioPlate: View {
    let hue: Hue
    let hour: Int
    let seed: Float

    var body: some View {
        HeroLife { live in
            ZStack(alignment: .bottomLeading) {
                HeroClock(live: live, rest: 0) { t in
                    MeshCanvas(hue: hue, hour: hour, seed: seed)
                        .scaleEffect(1.12)
                        .offset(x: sin(t * 0.35) * 14, y: cos(t * 0.27) * 6)
                }
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                Text(hue.title).font(DS.title).foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .padding(DS.Space.m)
            }
            .animation(DS.Motion.hover, value: hue)
        }
    }
}
