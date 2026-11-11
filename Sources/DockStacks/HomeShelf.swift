import AppKit
import DockCore
import SwiftUI

// MARK: - Home: "Tonight, your Mac can…"
//
// Home has no panel. The stage stands on its plinth at the top; under it, the Impossible shelf:
// a counter of what Atelier has bent, then one tile per thing a stock Mac cannot do. Hovering a
// tile plays it on the stage; clicking flies to its place. Live readings sit on the stage's top
// right, sampled only while Home is on screen and the window is key.

/// One thing a stock Mac can't do, as a tile on Home.
struct ShelfItem: Identifiable {
    let id: String
    let title: String
    let claim: String
    let hue: Color
    let chapter: Chapter
    /// `NavLit` feature ids that light this tile.
    let lights: [String]
    let plate: Plate
    /// Whether this Mac has what the tile promises. Home only shows what this Mac can do tonight:
    /// a tile for XDR Boost on a Mac without an XDR display would be a promise it cannot keep.
    var availability: @MainActor () -> FeatureAvailability = { .available }
    /// The stage preview, made when the pointer arrives.
    let preview: @MainActor () -> StagePreviewSpec

    enum Plate { case boost, hud, gestures, windows, thermals, spaces }

    @MainActor static let all: [ShelfItem] = [
        ShelfItem(id: "xdr", title: "XDR Boost", claim: "Brighter than Apple allows.", hue: DS.Spectrum.light,
                  chapter: .appearance, lights: ["xdr", "belowBlack", "candle"], plate: .boost,
                  availability: { StudioThisMac.hasXDRDisplay ? .available : .unavailable("Needs an XDR display") }) {
            .overlay("display.xdrBoost", "XDR Boost", isOn: LightEngine.shared.boostOn) { BoostPreview(size: $0) }
        },
        ShelfItem(id: "hud", title: "Atelier HUD", claim: "Your own volume overlay.", hue: DS.Spectrum.surfaces,
                  chapter: .appearance, lights: ["hud"], plate: .hud) {
            let hud = AtelierHUD.shared
            return .overlay("hud", "Atelier HUD", isOn: hud.volume || hud.brightness || hud.keyboard) {
                HUDStagePreview(size: $0, kind: .volume)
            }
        },
        ShelfItem(id: "gestures", title: "Trackpad Gestures", claim: "Taps macOS ignores.", hue: DS.Spectrum.input,
                  chapter: NavLit.input, lights: ["gestures"], plate: .gestures,
                  availability: { StudioThisMac.hasTrackpad ? .available : .unavailable("Needs a trackpad") }) {
            let gestures = TrackpadGestures.shared
            let bound = gestures.binding(.threeTap).action
            return .overlay("input.gesture.threeTap", "Trackpad Gestures", isOn: gestures.enabled && bound != .none) {
                GestureStagePreview(gesture: .threeTap, action: bound == .none ? .middleClick : bound, size: $0)
            }
        },
        ShelfItem(id: "windows", title: "Window Superpowers", claim: "Borders, dim, grab.", hue: DS.Spectrum.windows,
                  chapter: .engine, lights: ["borders", "dim", "grab", "ffm", "switcher"], plate: .windows) {
            .overlay("engine.borders", "Window Borders", isOn: WindowBorders.shared.enabled) { BorderPreview(size: $0) }
        },
        ShelfItem(id: "thermals", title: "Thermals", claim: "Sensors Apple hides.", hue: DS.Spectrum.sensors,
                  chapter: .menubar, lights: ["thermals"], plate: .thermals) {
            .overlay("thermals.menu", "Thermals in the Menu Bar", isOn: ThermalsMenu.shared.enabled) { ThermalsPreview(size: $0) }
        },
        ShelfItem(id: "spaces", title: "Instant Spaces", claim: "Desktops with no slide.", hue: DS.Spectrum.surfaces,
                  chapter: .menubar, lights: ["spaces"], plate: .spaces) {
            .overlay("spaces.instant", "Switch Instantly", isOn: InstantSpaces.shared.instant) {
                SpacesSwitchPreview(size: $0, measured: InstantSpaces.shared.lastMs)
            }
        },
    ]
}

/// Home's band: the readings on the stage, and the counter and shelf under it. Laid out in window
/// points from the stage's rect, so it follows the stage exactly and never lays the stage out.
struct HomeShelf: View {
    @ObservedObject var model: ManagerModel
    /// The stage, in window points.
    let stage: CGRect
    let viewport: CGRect
    let entered: Bool

    static let tile = CGSize(width: 180, height: 112)
    static let counterWidth = 176.0
    /// The entrance plays once per launch. Later visits just fade in with the chapter.
    @MainActor private static var played = false

    @State private var shown = HomeShelf.played
    @State private var sweep = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = max(stage.width, Self.counterWidth + Self.tile.width + 24)
        let left = min(max(stage.minX, viewport.minX + 12), viewport.maxX - width)
        ZStack(alignment: .topLeading) {
            HomeReadings()
                .offset(x: stage.maxX - 12 - HomeReadings.width, y: stage.minY + stage.width * MacStage.menuBarFraction + 10)
            HStack(alignment: .top, spacing: 16) {
                ConstellationCounter(model: model)
                    .frame(width: Self.counterWidth, height: Self.tile.height, alignment: .topLeading)
                    .modifier(Arrival(index: 0, shown: shown))
                Rectangle().fill(DS.Ink.hairline).frame(width: 0.5, height: Self.tile.height - 16)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                shelf
            }
            .frame(width: width, height: Self.tile.height, alignment: .topLeading)
            .offset(x: left, y: stage.maxY + StudioLayout.captionSlot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: arrive)
        .onChange(of: entered) { arrive() }
    }

    private var shelf: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(ShelfItem.all.filter { $0.availability().isUsable }.enumerated()), id: \.element.id) { index, item in
                    ShelfTile(item: item) { model.go(item.chapter) }
                        .modifier(Arrival(index: index + 1, shown: shown))
                }
            }
            .overlay { SweepLight(trigger: sweep).clipShape(.rect(cornerRadius: 16, style: .continuous)) }
        }
        .scrollIndicators(.never)
        .scrollClipDisabled(false)
        // More tiles past the edge fade out instead of being cut.
        .mask {
            LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.92),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .frame(height: Self.tile.height)
    }

    /// Tiles come up 40 ms apart, then one sweep of light crosses the shelf. Once per launch.
    private func arrive() {
        guard entered, !shown else { return }
        Self.played = true
        shown = true
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { sweep += 1 }
    }
}

/// A tile's entrance: up 8 points and in, staggered by index. Reduce Motion: a plain 0.15 s fade.
private struct Arrival: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? .easeOut(duration: 0.15)
                                    : DS.Motion.arrive.delay(0.12 + Double(index) * 0.04), value: shown)
    }
}

// MARK: - Counter

/// "5 things your Mac couldn't do this morning", with one dot of light per thing.
struct ConstellationCounter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var lit = NavLitState.shared

    var body: some View {
        let features = lit.litFeatures
        VStack(alignment: .leading, spacing: 6) {
            if features.isEmpty {
                Text("Nothing bent yet.")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                Button { model.go(.appearance) } label: {
                    HStack(spacing: 4) {
                        Text("Start with the brightest one")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Spectrum.light)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(.rect)
                }
                .buttonStyle(Pressable())
                .accessibilityHint("Opens XDR Boost")
            } else {
                Text("\(features.count)")
                    .font(DS.Typo.readout)
                    .foregroundStyle(DS.Ink.primary)
                    .contentTransition(.numericText())
                    .animation(DS.Motion.settle, value: features.count)
                Text(features.count == 1 ? "thing your Mac couldn’t do this morning" : "things your Mac couldn’t do this morning")
                    .font(.system(size: 12)).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                dots(features)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(features.isEmpty ? "Nothing bent yet"
                            : "\(features.count) things your Mac couldn’t do this morning: "
                              + features.map(\.title).joined(separator: ", "))
    }

    private func dots(_ features: [NavLit.Feature]) -> some View {
        HStack(spacing: 5) {
            ForEach(features.prefix(14)) { feature in
                Circle().fill(feature.hue).frame(width: 6, height: 6)
                    .help(feature.title)
            }
        }
        .padding(.top, 2)
        .animation(DS.Motion.arrive, value: features.map(\.id))
    }
}

// MARK: - Tile

/// A hero in miniature: its plate lit in its family's hue, its name and one claim.
struct ShelfTile: View {
    let item: ShelfItem
    let action: () -> Void
    @ObservedObject private var lit = NavLitState.shared
    @State private var hover = false

    private var on: Bool { item.lights.contains { lit.lit.contains($0) } }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ShelfPlate(plate: item.plate, hue: item.hue, on: on, hover: hover)
                    .frame(height: 52)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        if on { Circle().fill(item.hue).frame(width: 5, height: 5).accessibilityHidden(true) }
                    }
                    Text(item.claim).font(.system(size: 12)).foregroundStyle(DS.Ink.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
            }
            .padding(DS.Inset.plate)
            .frame(width: HomeShelf.tile.width, height: HomeShelf.tile.height, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hover ? DS.Ink.fillStrong.opacity(0.7) : DS.Ink.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(on || hover ? item.hue.opacity(hover ? 0.5 : 0.3) : DS.Ink.hairline, lineWidth: 0.5)
                    }
            }
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(Pressable())
        .onHover { over in withAnimation(DS.Motion.hover) { hover = over } }
        .stagePreview(lazy: item.preview)
        .accessibilityLabel("\(item.title). \(item.claim)")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint("Opens its settings")
    }
}

/// The tile's live miniature. Shapes and gradients only, drawn once: nothing here animates by
/// itself except the thermals readout, which ticks with the sensors.
struct ShelfPlate: View {
    let plate: ShelfItem.Plate
    let hue: Color
    let on: Bool
    let hover: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.plate - 2, style: .continuous)
                .fill(Color(white: 0.06))
            // The plate's light: brighter when the feature is on, a hint of it on hover.
            RoundedRectangle(cornerRadius: DS.Radius.plate - 2, style: .continuous)
                .fill(RadialGradient(colors: [hue.opacity(0.42), hue.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: 90))
                .opacity(on ? 1 : hover ? 0.55 : 0.28)
            figure
        }
        .clipShape(.rect(cornerRadius: DS.Radius.plate - 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate - 2, style: .continuous)
                .strokeBorder(LinearGradient(colors: [DS.Ink.edge, .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var figure: some View {
        switch plate {
        case .boost:
            // A brightness scale from black to SDR white, and the part past white Apple keeps back.
            VStack(spacing: 5) {
                Image(systemName: "sun.max.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(hue)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 96, height: 5)
                    Capsule().fill(LinearGradient(colors: [.white, hue, hue.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 44, height: 5)
                        .offset(x: 92)
                }
                .frame(width: 136, alignment: .leading)
            }
        case .hud:
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(width: 74, height: 4)
                    Capsule().fill(hue).frame(width: 48, height: 4)
                }
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(hue.opacity(0.4), lineWidth: 0.5))
        case .gestures:
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { _ in
                    ZStack {
                        Circle().strokeBorder(hue.opacity(0.35), lineWidth: 1).frame(width: 20, height: 20)
                        Circle().fill(hue).frame(width: 9, height: 9)
                    }
                }
            }
        case .windows:
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.06))
                    .frame(width: 56, height: 30).offset(x: -18, y: 4)
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(white: 0.16))
                    .frame(width: 64, height: 34)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.35)).frame(width: 3.5, height: 3.5) }
                        }
                        .padding(5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [hue, hue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                          lineWidth: 1.5)
                            .padding(-2)
                    }
                    .offset(x: 12)
            }
        case .thermals:
            PlateTemperature(hue: hue)
        case .spaces:
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white.opacity(0.12)).frame(width: 34, height: 22)
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(hue)
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(hue.opacity(0.35)).frame(width: 34, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(hue.opacity(0.7), lineWidth: 0.5))
            }
        }
    }
}

/// The CPU's temperature as display type. Reads what `HomeReadings` already samples: it starts
/// no sampling of its own.
private struct PlateTemperature: View {
    let hue: Color
    @ObservedObject private var sensors = Sensors.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(sensors.cpu.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(DS.Typo.readout)
                .foregroundStyle(DS.Ink.primary)
                .contentTransition(.numericText())
                .animation(DS.Motion.hover, value: sensors.cpu.map { Int($0.rounded()) })
            Text("CPU").font(DS.Typo.badge).tracking(0.8).foregroundStyle(hue)
        }
    }
}

// MARK: - Readings

/// CPU temperature, fan speed and power draw, as glass chips on the stage. Samples only while it
/// is on screen and the window is key; the sensors stop the moment Home closes.
struct HomeReadings: View {
    static let width = 300.0
    @ObservedObject private var sensors = Sensors.shared
    @Environment(\.controlActiveState) private var active
    @State private var holding = false

    var body: some View {
        let chips = readings
        AtelierGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.label) { reading in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(reading.value)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(DS.Ink.primary)
                            .contentTransition(.numericText())
                        Text(reading.unit).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .atelierGlass(.regular.tint(.black.opacity(0.25)), in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(reading.label)
                }
            }
            .animation(DS.Motion.hover, value: chips.map(\.value))
        }
        .frame(width: Self.width, alignment: .trailing)
        .allowsHitTesting(false)
        .onAppear { hold(active != .inactive) }
        .onDisappear { hold(false) }
        .onChange(of: active) { _, state in hold(state != .inactive) }
    }

    private struct Reading { let label: String, value: String, unit: String }

    private var readings: [Reading] {
        var out: [Reading] = []
        if let cpu = sensors.cpu { out.append(Reading(label: "CPU temperature", value: "\(Int(cpu.rounded()))", unit: "°C")) }
        if let fans = sensors.fans, fans > 0 {
            out.append(Reading(label: "Fan speed", value: Self.grouped(Int((fans / 10).rounded()) * 10), unit: "rpm"))
        }
        if let watts = sensors.watts { out.append(Reading(label: "Power draw", value: "\(Int(watts.rounded()))", unit: "W")) }
        return out
    }

    /// 1840 as "1 840", with a thin space: digits that tick stay put.
    static func grouped(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        return "\(value / 1000)\u{2009}" + String(format: "%03d", value % 1000)
    }

    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        wanted ? Sensors.shared.acquire() : Sensors.shared.release()
    }
}
