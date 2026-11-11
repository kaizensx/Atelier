import AppKit
import SwiftUI

/// How the Studio itself looks: the room around the stage and the accent of its controls.
/// None of this touches the Mac; it is Atelier's own window.
enum StudioBackdrop: String, CaseIterable, Identifiable {
    case light, wallpaper, live, midnight, aurora, ember, graphite, paper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Atelier Light"
        case .wallpaper: "Wallpaper"
        case .live: "Live"
        case .midnight: "Midnight"
        case .aurora: "Aurora"
        case .ember: "Ember"
        case .graphite: "Graphite"
        case .paper: "Dusk Paper"
        }
    }

    var detail: String {
        switch self {
        case .light: "The stage lights the room in your wallpaper's colours. Beams, aurora and drifting dust follow your pointer and the camera."
        case .wallpaper: "Your wallpaper, out of focus."
        case .live: "The live wallpaper you chose, slowed and softened."
        default: "A still room in Atelier's own colours."
        }
    }

    /// 3×3 mesh colours for the still rooms.
    var mesh: [Color] {
        switch self {
        case .midnight:
            [Color(red: 0.03, green: 0.04, blue: 0.09), Color(red: 0.05, green: 0.07, blue: 0.18), Color(red: 0.02, green: 0.03, blue: 0.08),
             Color(red: 0.07, green: 0.09, blue: 0.24), Color(red: 0.10, green: 0.12, blue: 0.32), Color(red: 0.04, green: 0.05, blue: 0.14),
             Color(red: 0.02, green: 0.02, blue: 0.05), Color(red: 0.04, green: 0.05, blue: 0.12), Color(red: 0.01, green: 0.01, blue: 0.03)]
        case .aurora:
            [Color(red: 0.02, green: 0.08, blue: 0.10), Color(red: 0.05, green: 0.30, blue: 0.30), Color(red: 0.10, green: 0.08, blue: 0.25),
             Color(red: 0.04, green: 0.22, blue: 0.20), Color(red: 0.18, green: 0.12, blue: 0.40), Color(red: 0.05, green: 0.25, blue: 0.32),
             Color(red: 0.01, green: 0.04, blue: 0.06), Color(red: 0.04, green: 0.08, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.06)]
        case .ember:
            [Color(red: 0.10, green: 0.03, blue: 0.03), Color(red: 0.32, green: 0.09, blue: 0.04), Color(red: 0.14, green: 0.04, blue: 0.08),
             Color(red: 0.28, green: 0.10, blue: 0.05), Color(red: 0.45, green: 0.18, blue: 0.06), Color(red: 0.22, green: 0.06, blue: 0.10),
             Color(red: 0.04, green: 0.01, blue: 0.02), Color(red: 0.10, green: 0.03, blue: 0.03), Color(red: 0.03, green: 0.01, blue: 0.02)]
        case .graphite:
            [Color(white: 0.09), Color(white: 0.13), Color(white: 0.08),
             Color(white: 0.12), Color(white: 0.17), Color(white: 0.11),
             Color(white: 0.05), Color(white: 0.08), Color(white: 0.04)]
        case .paper:
            [Color(red: 0.16, green: 0.12, blue: 0.16), Color(red: 0.30, green: 0.20, blue: 0.24), Color(red: 0.18, green: 0.14, blue: 0.22),
             Color(red: 0.26, green: 0.18, blue: 0.20), Color(red: 0.42, green: 0.28, blue: 0.26), Color(red: 0.22, green: 0.16, blue: 0.24),
             Color(red: 0.07, green: 0.05, blue: 0.08), Color(red: 0.12, green: 0.08, blue: 0.10), Color(red: 0.05, green: 0.04, blue: 0.06)]
        default:
            Array(repeating: Color(red: 0.035, green: 0.04, blue: 0.055), count: 9)
        }
    }
}

enum StudioAccent: String, CaseIterable, Identifiable {
    case sky, violet, mint, rose, amber, silver
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .sky: Color(red: 0.55, green: 0.72, blue: 1)
        case .violet: Color(red: 0.72, green: 0.6, blue: 1)
        case .mint: Color(red: 0.45, green: 0.9, blue: 0.75)
        case .rose: Color(red: 1, green: 0.55, blue: 0.68)
        case .amber: Color(red: 1, green: 0.76, blue: 0.4)
        case .silver: Color(white: 0.86)
        }
    }
}

@MainActor
final class StudioTheme: ObservableObject {
    static let shared = StudioTheme()
    private let store = UserDefaults.standard

    @Published var backdrop: StudioBackdrop { didSet { store.set(backdrop.rawValue, forKey: "studio.backdrop") } }
    @Published var accent: StudioAccent {
        didSet {
            store.set(accent.rawValue, forKey: "studio.accent")
            DS.Ink.current = accent.color
        }
    }
    /// The stage leans toward the pointer.
    @Published var tilt: Bool { didSet { store.set(tilt, forKey: "studio.tilt") } }
    /// How much of the room's colour shows, from a dark room to a bright one.
    @Published var glow: Double { didSet { store.set(glow, forKey: "studio.glow") } }

    private init() {
        backdrop = StudioBackdrop(rawValue: store.string(forKey: "studio.backdrop") ?? "") ?? .light
        accent = StudioAccent(rawValue: store.string(forKey: "studio.accent") ?? "") ?? .sky
        tilt = store.object(forKey: "studio.tilt") as? Bool ?? true
        glow = store.object(forKey: "studio.glow") as? Double ?? 0.5
        DS.Ink.current = accent.color
    }
}

/// The room behind the stage.
struct StudioRoom: View {
    @ObservedObject var theme: StudioTheme
    @ObservedObject private var living = LiveWallpaper.shared
    /// Effects announces wallpaper changes, so the room re-reads the wallpaper's colours.
    @ObservedObject private var effects = Effects.shared
    let entered: Bool
    /// Where the stage sits, in window fractions, for the rooms that are lit by it.
    var stage = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.055)
            switch theme.backdrop {
            case .light where StudioLightView.available:
                StudioLight(palette: StudioPalette.current(), glow: theme.glow, stage: stage)
                    .opacity(entered ? 1 : 0)
            case .light:
                EmptyView()
            case .wallpaper:
                if let image = Wallpaper.image() {
                    Color.clear.overlay {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: 70).saturation(1.3).opacity(entered ? theme.glow : 0)
                            .scaleEffect(1.25)
                    }
                    .clipped()
                }
            case .live:
                LivingPreview(shader: living.shader)
                    .blur(radius: 40)
                    .scaleEffect(1.15)
                    .opacity(entered ? theme.glow : 0)
                    .clipped()
                    .allowsHitTesting(false)
            default:
                AtelierMesh(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.55, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: theme.backdrop.mesh)
                .opacity(entered ? 0.5 + theme.glow : 0)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeOut(duration: 1.4), value: entered)
        .animation(.smooth(duration: 0.6), value: theme.backdrop)
    }
}

/// The settings card for the Studio's own look: a gallery of rooms, then the quiet controls.
struct StudioLookCard: View {
    @ObservedObject var theme = StudioTheme.shared

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 200), spacing: DS.Space.s)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                ForEach(StudioBackdrop.allCases) { backdrop in
                    StudioRoomTile(backdrop: backdrop, selected: theme.backdrop == backdrop) { theme.backdrop = backdrop }
                }
            }
            Text(theme.backdrop.detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.s)
                .contentTransition(.opacity)
                .animation(DS.Motion.hover, value: theme.backdrop)
        }
        .padding(DS.Inset.plate)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(style: .standard) }
        RowGroup {
            SettingRow(title: "Glow", detail: "How much of the room's colour shows.", symbol: "sun.max", density: .compact) {
                LuxSlider(value: $theme.glow, range: 0.15...0.9, label: "Glow").frame(width: 168)
            }
            SettingRow(title: "Accent", detail: "The light of switches and sliders.", symbol: "paintbrush.pointed", density: .compact) {
                HStack(spacing: DS.Space.s) {
                    ForEach(StudioAccent.allCases) { accent in
                        Button { theme.accent = accent } label: {
                            Circle().fill(accent.color).frame(width: 18, height: 18)
                                .overlay { Circle().strokeBorder(.white.opacity(theme.accent == accent ? 0.95 : 0), lineWidth: 2).padding(-4) }
                                .padding(4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(Pressable(scale: 0.9))
                        .accessibilityLabel(accent.rawValue.capitalized)
                        .accessibilityAddTraits(theme.accent == accent ? .isSelected : [])
                    }
                }
                .animation(DS.Motion.settle, value: theme.accent)
            }
            SettingRow(title: "Stage Tilt", detail: "The stage leans toward the pointer.", symbol: "rotate.3d", density: .compact) {
                LuxSwitch(isOn: $theme.tilt, label: "Stage Tilt")
            }
        }
    }
}

/// One room in the gallery: a 16:10 swatch, concentric in the card (20, inset 8, 12), its name below.
private struct StudioRoomTile: View {
    let backdrop: StudioBackdrop
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay { swatch }
                    .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                            .fill(.white.opacity(hovering && !selected ? 0.06 : 0))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                            .strokeBorder(selected ? DS.Ink.accent : .white.opacity(hovering ? 0.22 : 0.1), lineWidth: selected ? 2 : 0.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.black.opacity(0.8))
                                .frame(width: 16, height: 16)
                                .background(DS.Ink.accent, in: .circle)
                                .padding(6)
                                .transition(.opacity)
                        }
                    }
                Text(backdrop.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.xs)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(DS.Motion.hover, value: hovering)
        .animation(DS.Motion.settle, value: selected)
        .accessibilityLabel(backdrop.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var swatch: some View {
        switch backdrop {
        case .light:
            ZStack {
                Color(red: 0.02, green: 0.02, blue: 0.03)
                RadialGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.4).opacity(0.8), Color(red: 0.62, green: 0.36, blue: 0.55).opacity(0.35), .clear],
                               center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: 52)
                // The stage, lit, in the middle of its room.
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white.opacity(0.22))
                    .frame(width: 30, height: 19)
            }
        case .wallpaper:
            if let image = Wallpaper.image() {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 6)
            } else { Color.gray }
        case .live:
            LinearGradient(colors: [.teal, .indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.85)) }
        default:
            AtelierMesh(width: 3, height: 3, points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                         colors: backdrop.mesh.map { $0 }).brightness(0.12)
        }
    }
}
