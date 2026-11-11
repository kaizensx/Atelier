import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import DockCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model, drawing side

extension OwnDockEdge {
    /// The side of a tile that stays put while it grows.
    var anchor: UnitPoint {
        switch self {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }
}

extension DockAccent {
    var color: Color {
        switch self {
        case .blue: DS.Ink.accent
        case .purple: Color(red: 0.72, green: 0.56, blue: 1)
        case .pink: Color(red: 1, green: 0.52, blue: 0.74)
        case .orange: Color(red: 1, green: 0.67, blue: 0.36)
        case .green: Color(red: 0.46, green: 0.88, blue: 0.62)
        case .graphite: Color(red: 0.74, green: 0.76, blue: 0.8)
        }
    }
}

// MARK: - Theme

struct DockTheme: Equatable {
    var style = DockStyle.glass
    var indicator = DockIndicator.bar
    var accent = DS.Ink.accent
    var tint: Color?
    /// Clear glass lets more of the desktop through than regular glass.
    var clear = false
    var rim: [Color] = [.white.opacity(0.28), .white.opacity(0.07), .white.opacity(0.16)]
    var rimWidth = 0.75
    /// A soft light around the rim, for Neon Edge.
    var glow: Color?
    var shadow = 0.28
    var rings: [Color] = [DS.Ink.accent, .purple, .green]
    /// A soft shadow under each icon.
    var iconShadow = true
    /// The icons mirrored in the glass below them.
    var reflection = false
    var badges = true
    /// A halo while an app opens.
    var launchGlow = false
    /// The design, icon treatment and effects.
    var fx = DockFX()

    var glass: AGlass {
        let base: AGlass = clear ? .clear : .regular
        if let tint { return base.tint(tint) }
        return base
    }

    /// The colours of the Look in use: its icon tint, then its skin, then its wallpaper hue.
    @MainActor static func lookColors() -> (accent: Color, second: Color)? {
        let effects = Effects.shared
        let look = Look.all.first { $0.name == effects.look }
        let skin = effects.skin
        var picked = look?.tintColor
        if picked == nil, skin != .none, skin != .notchless { picked = skin.colors[min(1, skin.colors.count - 1)] }
        if picked == nil, let hue = effects.living ?? look?.hue, hue != .mono {
            picked = hue.mesh(hour: 13)[4]
        }
        guard let accent = picked else { return nil }
        return (accent, skin.colors.count > 2 ? skin.colors[2] : Color.purple)
    }

    /// The theme for a set of settings. Following the Look overrides the accent; the
    /// Wallpaper style takes its accent from the desktop picture instead.
    @MainActor static func make(_ look: DockAppearance, follow: Bool, wallpaper: Color?, fx: DockFX = DockFX()) -> DockTheme {
        let fromLook = follow ? lookColors() : nil
        var accent = fromLook?.accent ?? look.accent.color
        if look.style == .wallpaper, let wallpaper { accent = wallpaper }
        var theme = DockTheme(style: look.style, indicator: look.indicator, accent: accent)
        theme.fx = fx
        theme.rings = [accent, fromLook?.second ?? .purple, .green]
        theme.iconShadow = look.iconShadow
        theme.reflection = look.reflection
        theme.badges = look.badges
        theme.launchGlow = look.launch == .glow
        switch look.style {
        case .glass:
            if let fromLook {
                theme.tint = fromLook.accent.opacity(0.17)
                theme.rim = [fromLook.accent.opacity(0.6), .white.opacity(0.08), fromLook.accent.opacity(0.28)]
            }
        case .tinted:
            theme.tint = accent.opacity(0.34)
            theme.rim = [accent.opacity(0.7), .white.opacity(0.1), accent.opacity(0.36)]
        case .midnight:
            theme.tint = Color(red: 0.02, green: 0.03, blue: 0.08).opacity(0.72)
            theme.rim = [.white.opacity(0.16), .white.opacity(0.03), .white.opacity(0.08)]
            theme.shadow = 0.42
        case .frost:
            theme.tint = .white.opacity(0.26)
            theme.rim = [.white.opacity(0.72), .white.opacity(0.2), .white.opacity(0.45)]
            theme.shadow = 0.18
        case .neon:
            theme.clear = true
            theme.tint = .black.opacity(0.3)
            theme.rim = [accent, accent.opacity(0.3), theme.rings[1]]
            theme.rimWidth = 1.4
            theme.glow = accent
        case .wallpaper:
            theme.tint = accent.opacity(0.3)
            theme.rim = [accent.opacity(0.65), .white.opacity(0.08), accent.opacity(0.3)]
        }
        theme.design(fx.design)
        return theme
    }

    /// What a design changes beyond the glass finish: the tint its cards wear and its rim.
    private mutating func design(_ design: DockDesign) {
        guard !design.usesGlassFinish else { return }
        clear = false
        glow = nil
        rimWidth = 0.75
        switch design {
        case .neonRim:
            clear = true
            tint = Color.black.opacity(0.42)
            rim = [accent.opacity(0.35), .white.opacity(0.05), rings[1].opacity(0.3)]
            shadow = 0.36
        case .aurora:
            tint = Color(red: 0.03, green: 0.04, blue: 0.1).opacity(0.5)
            rim = [.white.opacity(0.3), .white.opacity(0.05), accent.opacity(0.35)]
        case .ceramic:
            tint = .white.opacity(0.14)
        case .paper:
            tint = Color(red: 0.96, green: 0.92, blue: 0.84).opacity(0.16)
        case .darkMetal:
            tint = Color(white: 0.08).opacity(0.62)
        case .retro:
            tint = Color(red: 0.01, green: 0.05, blue: 0.03).opacity(0.7)
        case .minimalLine:
            tint = nil
        case .liquidGlass, .islands, .holographic:
            break
        }
    }
}

/// The most colourful part of the desktop picture, worked out once per picture.
@MainActor
enum WallpaperTone {
    private static var cached: (url: URL, color: Color?)?

    static func color(for screen: NSScreen?) -> Color? {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached, cached.url == url { return cached.color }
        var isFolder: ObjCBool = false
        let color: Color?
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
           let image = NSImage(contentsOf: url) {
            color = Effects.dominant(of: image)
        } else {
            color = nil
        }
        cached = (url, color)
        return color
    }
}

@MainActor
enum DockIcons {
    private static var images: [String: NSImage] = [:]
    private static var colors: [String: Color] = [:]

    /// Called when an icon that was loading in the background arrives.
    static var loaded: (() -> Void)?
    private static var loading: Set<String> = []

    static func image(_ path: String) -> NSImage {
        if let image = images[path] { return image }
        // A folder's icon can mean reading a protected folder (Downloads, Desktop). macOS
        // then asks for access and blocks the asking thread, so never ask from this one.
        var isDirectory: ObjCBool = false
        let folder = path.hasSuffix(".app") == false
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard folder else {
            // An icon picked in Atelier (macOSicons or a file) shows everywhere Atelier draws
            // the app: this dock, the stage, Orbit, widgets, the Studio's lists.
            let image = AtelierIcons.shared.custom(path) ?? NSWorkspace.shared.icon(forFile: path)
            images[path] = image
            return image
        }
        if !loading.contains(path) {
            loading.insert(path)
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSWorkspace.shared.icon(forFile: path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        images[path] = image
                        loading.remove(path)
                        loaded?()
                    }
                }
            }
        }
        return NSWorkspace.shared.icon(for: .folder)
    }

    /// A picture the user chose for a tile, read once.
    static func custom(_ file: String) -> NSImage {
        if let image = images["custom:" + file] { return image }
        let image = NSImage(contentsOfFile: file) ?? NSWorkspace.shared.icon(for: .image)
        images["custom:" + file] = image
        return image
    }

    /// Forgets a picture that was replaced.
    static func forget(_ file: String) { images["custom:" + file] = nil }

    /// Reads a file's icon again, after a stack's icon was rewritten.
    static func reload(_ path: String) {
        images[path] = nil
        colors[path] = nil
    }

    /// The Trash as Finder draws it, empty or full.
    static func trash(full: Bool) -> NSImage {
        let key = full ? "trash.full" : "trash.empty"
        if let image = images[key] { return image }
        let image = NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName)
            ?? NSWorkspace.shared.icon(forFile: TrashWatcher.url.path)
        images[key] = image
        return image
    }

    static func color(_ path: String) -> Color {
        if let color = colors[path] { return color }
        let color = Effects.dominant(of: image(path))
        colors[path] = color
        return color
    }
}

// MARK: - Bar

struct OwnDockBar: View {
    let scene: DockScene
    let theme: DockTheme
    let vitals: Vitals
    var feed = OwnDockFeed.shared
    /// Arrange mode: spacers show where they are, and the tile under the pointer its ×.
    var arranging = false
    /// A flat stand-in for live glass, for previews inside the settings panel's own glass.
    var flat = false
    /// The icons' shared resting shadow. Off while the stage camera flies.
    var rowShadow = true
    /// The design's own animations may run. They also stop while the bar is hidden.
    var animating = true
    var activate: (String) -> Void = { _ in }

    var body: some View {
        // Section names sit over their own tiles. Worked out from this frame's tiles, so they
        // ride the magnification with no state and no extra pass.
        let labels = showsSectionNames ? OwnDockSectionNames.place(scene) : []
        let named = Set(labels.map(\.section))
        ZStack(alignment: .topLeading) {
            DockBarBackdrop(scene: scene, theme: theme, flat: flat, animating: animating && scene.hide < 0.98)
                .position(x: scene.bar.midX, y: scene.bar.midY)
            if theme.reflection { reflections }
            ZStack(alignment: .topLeading) {
            ForEach(Array(scene.tiles.enumerated()), id: \.element.id) { index, tile in
                if tile.slot.kind == .divider || tile.slot.kind == .section {
                    // The dock's own separators and the sections' share one mark, in the
                    // Separator style chosen in Sections, drawn in the design's own ink.
                    OwnDockSectionMark(tile: tile, edge: scene.edge, bar: scene.bar, accent: theme.accent, arranging: arranging,
                                       named: named.contains(index), ink: DockDesignStyle.ink(theme.fx.design))
                } else if tile.slot.empty {
                    if tile.focused { OwnDockFocusRing(size: tile.icon, accent: theme.accent).position(tile.center) }
                    if arranging {
                        OwnDockSpacerMark(size: tile.size, base: tile.base, edge: scene.edge, armed: tile.armed)
                            .position(tile.center)
                            .opacity(tile.alpha)
                    }
                } else {
                    indicator(tile)
                    OwnDockTileView(tile: tile, edge: scene.edge, theme: theme, vitals: vitals, feed: feed)
                        .overlay(alignment: .topLeading) {
                            if tile.armed {
                                DockRemoveBadge(size: tile.icon).offset(x: -tile.icon * 0.06, y: -tile.icon * 0.06)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if tile.slot.face.caption, !tile.dragging {
                                Text(tile.slot.title)
                                    .font(.system(size: max(tile.icon * 0.15, 8), weight: .medium))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.7), radius: 1.5)
                                    .lineLimit(1)
                                    .frame(width: tile.icon * 1.15)
                                    .offset(y: tile.icon * 0.16)
                                    .opacity(tile.alpha)
                            }
                        }
                        .position(tile.center)
                        .zIndex(tile.dragging ? 2 : 1)
                        .accessibilityElement()
                        .accessibilityLabel(tile.slot.title)
                        .accessibilityValue(Self.value(tile.slot))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { activate(tile.id) }
                }
            }
            }
            .frame(width: scene.panel.width, height: scene.panel.height, alignment: .topLeading)
            .modifier(OwnDockRowShadow(on: theme.iconShadow && rowShadow))
            ForEach(labels, id: \.section) { label in
                OwnDockSectionName(title: scene.tiles[label.section].slot.title, label: label, edge: scene.edge,
                                   panel: scene.panel, unit: scene.unit)
                    .opacity(scene.tiles[label.section].alpha)
            }
        }
        .frame(width: scene.panel.width, height: scene.panel.height, alignment: .topLeading)
    }

    /// Names show for the Label style, and for every style while arranging.
    private var showsSectionNames: Bool {
        arranging || scene.tiles.contains { $0.slot.kind == .section && $0.slot.sectionStyle == .label }
    }

    private static func value(_ slot: DockSlot) -> String {
        var parts: [String] = []
        if slot.running { parts.append("Running") }
        if let badge = slot.badge { parts.append("Badge \(badge)") }
        if slot.attention { parts.append("Needs attention") }
        if slot.kind == .window { parts.append("Minimised window") }
        return parts.joined(separator: ", ")
    }

    /// The icons mirrored in the glass, faded within a few points, and kept inside the bar.
    private var reflections: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scene.tiles) { tile in
                if !tile.slot.empty, !tile.dragging {
                    OwnDockTileView(tile: tile, edge: scene.edge, theme: theme, vitals: vitals, feed: feed, mirrored: true)
                        .scaleEffect(x: scene.edge.horizontal ? 1 : -1, y: scene.edge.horizontal ? -1 : 1)
                        .mask(LinearGradient(colors: [.white.opacity(0.42), .clear], startPoint: Self.from(scene.edge),
                                             endPoint: Self.to(scene.edge)))
                        .position(tile.mirror)
                }
            }
        }
        .frame(width: scene.panel.width, height: scene.panel.height, alignment: .topLeading)
        .mask {
            RoundedRectangle(cornerRadius: scene.radius, style: .continuous)
                .frame(width: max(scene.bar.width, 1), height: max(scene.bar.height, 1))
                .position(x: scene.bar.midX, y: scene.bar.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The mirrored icon is brightest where it touches the real one.
    private static func from(_ edge: OwnDockEdge) -> UnitPoint {
        switch edge {
        case .bottom: .top
        case .top: .bottom
        case .left: .trailing
        case .right: .leading
        }
    }

    private static func to(_ edge: OwnDockEdge) -> UnitPoint {
        switch edge {
        case .bottom: UnitPoint(x: 0.5, y: 0.3)
        case .top: UnitPoint(x: 0.5, y: 0.7)
        case .left: UnitPoint(x: 0.7, y: 0.5)
        case .right: UnitPoint(x: 0.3, y: 0.5)
        }
    }

    @ViewBuilder private func indicator(_ tile: DockTile) -> some View {
        if tile.slot.running || tile.slot.launching, !tile.dragging, tile.slot.kind == .app {
            let strength = tile.slot.launching || tile.slot.attention ? 0.35 + 0.65 * tile.glow : tile.slot.frontmost ? 1 : 0.7
            let horizontal = scene.edge.horizontal
            Group {
                if let mark = theme.fx.mark {
                    DockDesignMarkView(mark: mark, design: theme.fx.design, accent: theme.accent, icon: tile.icon,
                                       horizontal: horizontal, frontmost: tile.slot.frontmost, strength: strength)
                } else {
                switch theme.indicator {
                case .bar:
                    let long = tile.slot.frontmost ? max(14, tile.icon * 0.27) : 5.0
                    Capsule()
                        .fill(theme.accent.opacity(strength))
                        .frame(width: horizontal ? long : 3, height: horizontal ? 3 : long)
                        .shadow(color: theme.accent.opacity(tile.slot.frontmost ? 0.8 : 0.35), radius: 4)
                case .dot:
                    Circle()
                        .fill(theme.accent.opacity(strength))
                        .frame(width: tile.slot.frontmost ? 5 : 4, height: tile.slot.frontmost ? 5 : 4)
                case .glow:
                    let long = tile.icon * 0.72
                    Ellipse()
                        .fill(theme.accent.opacity(strength * (tile.slot.frontmost ? 0.95 : 0.55)))
                        .frame(width: horizontal ? long : 7, height: horizontal ? 7 : long)
                        .blur(radius: 4)
                        .blendMode(.plusLighter)
                case .none:
                    EmptyView()
                }
                }
            }
            .position(tile.indicator)
            .accessibilityHidden(true)
        }
    }
}

/// The ring around the tile chosen with the keyboard.
struct OwnDockFocusRing: View {
    let size: Double
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(accent, lineWidth: 2.5)
            .frame(width: size + 8, height: size + 8)
            .shadow(color: accent.opacity(0.7), radius: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The icons' resting shadow, drawn once for the whole row in a single pass.
struct OwnDockRowShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.compositingGroup().shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        } else {
            content
        }
    }
}

struct OwnDockTileView: View {
    let tile: DockTile
    let edge: OwnDockEdge
    let theme: DockTheme
    let vitals: Vitals
    var feed = OwnDockFeed.shared
    /// The copy drawn as a reflection: no rings, badges or shadows.
    var mirrored = false

    private var arriving: Bool { tile.slot.kind == .window && tile.appear < 0.999 && !tile.dragging }

    private var shown: Double {
        // Fade keeps a minimised window's icon at its full size while it fades in.
        if arriving, theme.fx.minimize == .fade { return min(tile.icon / max(tile.appear, 0.05), tile.base * 0.96) }
        return tile.icon
    }

    /// Wave and Drop In move the icon off its rest line, away from the screen edge.
    private var rise: Double {
        var amount = 0.0
        if theme.fx.hover == .wave, tile.near > 0.001 {
            amount += shown * 0.16 * tile.near * (0.55 + 0.45 * cos(tile.lean * .pi * 3))
        }
        if arriving, theme.fx.minimize == .genie { amount += (1 - tile.appear) * shown * 1.6 }
        return amount
    }

    /// Tilt: neighbours lean toward the pointer, the icon under it faces you.
    private var tilt: Double {
        guard theme.fx.hover == .tilt, !tile.dragging else { return 0 }
        return -tile.lean * (1 - abs(tile.lean)) * 4 * 26
    }

    var body: some View {
        let deform = DockBurstView.deform(progress: tile.ring, burst: tile.burst, fx: theme.fx)
        let genie = arriving && theme.fx.minimize == .genie ? 1 - tile.appear : 0
        let out = edge.outward
        ZStack {
            if !mirrored, theme.launchGlow, tile.glow > 0 {
                Circle()
                    .fill(RadialGradient(colors: [glowColor.opacity(0.75 * tile.glow), .clear], center: .center,
                                         startRadius: 0, endRadius: shown * 0.75))
                    .frame(width: shown * 1.6, height: shown * 1.6)
                    .blendMode(.plusLighter)
            }
            if !mirrored, theme.fx.hover == .glow, tile.near > 0.02 {
                Circle()
                    .fill(RadialGradient(colors: [theme.accent.opacity(0.6 * tile.near), .clear], center: .center,
                                         startRadius: 0, endRadius: shown * 0.78))
                    .frame(width: shown * 1.7, height: shown * 1.7)
                    .blendMode(.plusLighter)
            }
            if !mirrored, let ring = tile.ring {
                DockBurstView(progress: ring, burst: tile.burst, fx: theme.fx, color: glowColor, size: shown)
            }
            if !mirrored, tile.focused { OwnDockFocusRing(size: shown, accent: theme.accent) }
            content
                .frame(width: shown, height: shown)
                .background { if theme.fx.backplate, tile.slot.kind != .vitals { DockBackplate(design: theme.fx.design, accent: theme.accent, size: shown) } }
                .overlay(alignment: .topTrailing) {
                    if !mirrored, theme.badges, let badge = tile.slot.badge {
                        DockBadge(text: badge, size: shown).offset(x: shown * 0.06, y: -shown * 0.04)
                    }
                }
                .scaleEffect(x: (edge.horizontal ? tile.scaleAlong : tile.scaleCross) * deform.x * (1 - genie * 0.45),
                             y: (edge.horizontal ? tile.scaleCross : tile.scaleAlong) * deform.y * (1 + genie * 0.5),
                             anchor: edge.anchor)
                // Rotation and a 3D tilt make every icon render on its own, off screen, on every frame
                // its scale changes. Only pay for them while they are not zero.
                .modifier(OwnDockTileTurn(angle: deform.angle, tilt: tilt, edge: edge))
                .opacity(tile.alpha)
                // The resting shadow is drawn once for the whole row by OwnDockBar. One shadow per icon
                // is one offscreen GPU pass per icon on every frame the dock moves or scales.
                .shadow(color: .black.opacity(!mirrored && tile.dragging ? 0.4 : 0), radius: 14, y: 8)
        }
        .offset(x: out.width * rise, y: out.height * rise)
    }

    private var glowColor: Color {
        tile.slot.path.isEmpty || tile.slot.kind != .app ? theme.accent : DockIcons.color(tile.slot.path)
    }

    @ViewBuilder private var content: some View {
        // A tile given its own icon (Change Icon…) shows it in place of its live face.
        if let icon = tile.slot.icon, Self.ownFace.contains(tile.slot.kind) {
            BitmapIcon(image: DockIcons.custom(icon))
        } else {
            face
        }
    }

    private static let ownFace: Set<DockSlot.Kind> = [.vitals, .trash, .clock, .battery, .downloads, .clipboard, .orbit]

    @ViewBuilder private var face: some View {
        switch tile.slot.kind {
        case .vitals:
            DockVitalsGlyph(vitals: vitals, theme: theme, size: shown)
        case .trash:
            BitmapIcon(image: DockIcons.trash(full: tile.slot.full))
        case .clock:
            DockClockGlyph(feed: feed, size: shown, accent: theme.accent, face: tile.slot.face)
        case .battery:
            DockBatteryGlyph(feed: feed, size: shown, face: tile.slot.face, accent: theme.accent)
        case .downloads:
            DockDownloadsGlyph(feed: feed, size: shown, accent: theme.accent, face: tile.slot.face)
        case .clipboard:
            DockClipboardGlyph(feed: feed, size: shown, face: tile.slot.face, accent: theme.accent)
        case .orbit:
            DockOrbitGlyph(size: shown, accent: theme.accent, face: tile.slot.face)
        case .window:
            DockWindowGlyph(title: tile.slot.title, appPath: tile.slot.path, size: shown)
        case .smart:
            if let icon = tile.slot.icon {
                BitmapIcon(image: DockIcons.custom(icon))
            } else {
                DockSmartGlyph(symbol: tile.slot.symbol ?? "sparkles", size: shown, accent: theme.accent, face: tile.slot.face)
            }
        case .divider, .spacer, .spacerLarge, .section:
            EmptyView()
        case .app, .stack, .file, .folder:
            if !tile.slot.preview.isEmpty, tile.slot.icon == nil {
                DockFannedGlyph(paths: tile.slot.preview, size: shown)
            } else if let icon = tile.slot.icon {
                BitmapIcon(image: DockIcons.custom(icon))
            } else if !tile.slot.path.isEmpty {
                BitmapIcon(image: DockIcons.image(tile.slot.path))
            }
        }
    }
}

// The Vitals tile's face, `DockVitalsGlyph`, is in OwnDockVitals.swift with its options.

// MARK: - Live Peek

struct DockPeek: Equatable {
    var id: String
    var title: String
    var status: String
    var path = ""
    var rows: [String] = []
    /// Window frames, 0 to 1 across the desktop. They need no permission.
    var windows: [CGRect] = []
    var aspect = 1.6
    var items: [StackItem] = []
    var vitals = false
    /// Just the name, the way the system Dock labels a tile.
    var label = false
    /// Window Previews: a picture of each window.
    var thumbs: [DockThumb] = []
    /// A permission the card is missing, said plainly under it.
    var note: String?
}

struct OwnDockLabel: View {
    let title: String
    let theme: DockTheme

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Ink.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .atelierGlass(theme.tint.map { AGlass.regular.tint($0) } ?? .regular, in: .capsule)
            .overlay { Capsule().strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .fixedSize()
    }
}

struct OwnDockPeekCard: View {
    let peek: DockPeek
    let theme: DockTheme
    @ObservedObject var vitals: Vitals

    private var glass: AGlass {
        if let tint = theme.tint { return .regular.tint(tint) }
        return .regular
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if peek.vitals {
                    DockVitalsGlyph(vitals: vitals, theme: theme, size: 30).frame(width: 30, height: 30)
                } else if !peek.path.isEmpty {
                    Image(nsImage: peek.path.hasPrefix(DockCustomStore.folder.path) ? DockIcons.custom(peek.path) : DockIcons.image(peek.path))
                        .resizable().interpolation(.high).frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title).font(DS.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(peek.status).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !peek.rows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(peek.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 7) {
                            Circle().fill(theme.accent).frame(width: 4, height: 4)
                            Text(row).font(DS.caption).foregroundStyle(DS.Ink.primary.opacity(0.86))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if peek.rows.count > 5 {
                        Text("and \(peek.rows.count - 5) more").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    }
                }
            } else if !peek.windows.isEmpty {
                WindowMap(windows: peek.windows, aspect: peek.aspect, accent: theme.accent)
            }
            if peek.vitals {
                DockVitalsPeekRow(vitals: vitals, theme: theme)
            }
            if !peek.items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(peek.items.prefix(6)) { item in
                        Image(nsImage: ItemIcon.image(for: item)).resizable().interpolation(.high).frame(width: 32, height: 32)
                    }
                }
            }
            if let note = peek.note {
                Label(note, systemImage: "lock")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(width: 244)
        .atelierGlass(glass, in: .rect(cornerRadius: DS.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

/// With no window titles to show, a small map of where the app's windows are.
struct WindowMap: View {
    let windows: [CGRect]
    let aspect: Double
    let accent: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7, style: .continuous), with: .color(DS.Ink.fill))
            for (index, window) in windows.enumerated() {
                let box = CGRect(x: window.minX * size.width, y: window.minY * size.height,
                                 width: max(window.width * size.width, 8), height: max(window.height * size.height, 6))
                let shape = Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3, style: .continuous)
                context.fill(shape, with: .color(accent.opacity(index == 0 ? 0.5 : 0.24)))
                context.stroke(shape, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
        }
        .frame(height: min(218 / max(aspect, 0.5), 150))
        .accessibilityLabel("Map of \(windows.count) windows")
    }
}

// MARK: - Stage

/// The per-frame state lives here, apart from `OwnDock`, so the settings panel never redraws
/// at display rate.
@MainActor
final class OwnDockStage: ObservableObject {
    @Published var scene = DockScene()
    @Published var peek: DockPeek?
    @Published var theme = DockTheme()
    /// While the keyboard drives the dock: what has been typed. Nil otherwise.
    @Published var query: String?
    /// The window picture under the pointer in the peek card.
    @Published var peekHot: Int?
    @Published var arranging = false
    /// The panel can be seen and the displays are awake: the design's own animations may run.
    @Published var animating = true
}

struct OwnDockRoot: View {
    @ObservedObject var stage: OwnDockStage
    let vitals: Vitals
    var activate: (String) -> Void = { _ in }

    var body: some View {
        let scene = stage.scene
        ZStack {
            OwnDockBar(scene: scene, theme: stage.theme, vitals: vitals, arranging: stage.arranging,
                       animating: stage.animating, activate: activate)
                .offset(scene.hideOffset)
                .opacity(1 - scene.hide * scene.hide)
            if stage.arranging {
                let frame = DockArrangeLayout.frame(scene)
                DockArrangePill(theme: stage.theme)
                    .position(x: frame.midX, y: frame.midY)
                    .offset(scene.hideOffset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let query = stage.query {
                OwnDockQuery(text: query, theme: stage.theme)
                    .frame(width: 260)
                    .modifier(QueryPlacement(scene: scene))
            }
            if let peek = stage.peek, scene.peekShow > 0.01 {
                if !peek.thumbs.isEmpty, !peek.label {
                    let frame = DockPeekLayout.frame(count: peek.thumbs.count, scene: scene)
                    let show = scene.peekShow
                    DockThumbCard(peek: peek, theme: stage.theme, edge: scene.edge, hot: stage.peekHot,
                                  notch: DockPeekLayout.notchOffset(card: frame, scene: scene))
                        .overlay(alignment: .topLeading) { OwnDockPeekButtonsOverlay(peek: peek, edge: scene.edge, hot: stage.peekHot) }
                        .scaleEffect(0.86 + 0.14 * show, anchor: scene.edge.anchor)
                        .opacity(min(show * 1.5, 1))
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                } else if peek.label {
                    placed(OwnDockLabel(title: peek.title, theme: stage.theme), scene, half: CGSize(width: 90, height: 14))
                } else {
                    placed(OwnDockPeekCard(peek: peek, theme: stage.theme, vitals: vitals), scene)
                }
            }
        }
        .frame(width: scene.panel.width, height: scene.panel.height)
        .environment(\.colorScheme, .dark)
    }

    private func placed(_ card: some View, _ scene: DockScene, half: CGSize = CGSize(width: 122, height: 100)) -> some View {
        let halfWide = half.width, halfTall = half.height
        let panel = scene.panel
        let alignment: Alignment
        var offset = CGSize.zero
        switch scene.edge {
        case .bottom, .top:
            let x = min(max(scene.peekAlong, halfWide + 10), panel.width - halfWide - 10)
            offset.width = x - panel.width / 2
            offset.height = scene.edge == .bottom ? -scene.peekCross : scene.peekCross
            alignment = scene.edge == .bottom ? .bottom : .top
        case .left, .right:
            let y = min(max(scene.peekAlong, halfTall + 10), panel.height - halfTall - 10)
            offset.height = y - panel.height / 2
            offset.width = scene.edge == .left ? scene.peekCross : -scene.peekCross
            alignment = scene.edge == .left ? .leading : .trailing
        }
        let show = scene.peekShow
        return card
            .scaleEffect(0.86 + 0.14 * show, anchor: scene.edge.anchor)
            .opacity(min(show * 1.5, 1))
            .offset(offset)
            .frame(width: panel.width, height: panel.height, alignment: alignment)
            .allowsHitTesting(false)
    }
}

/// What has been typed to find a tile, beside the bar's leading end.
struct OwnDockQuery: View {
    let text: String
    let theme: DockTheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
            Text(text.isEmpty ? "Type to find · ← → · Return opens · Esc" : text)
                .font(.system(size: 12.5, weight: text.isEmpty ? .regular : .semibold))
                .foregroundStyle(text.isEmpty ? DS.Ink.secondary : DS.Ink.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .atelierGlass(theme.tint.map { AGlass.regular.tint($0) } ?? .regular, in: .capsule)
        .overlay { Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 0.75) }
        .fixedSize()
        .accessibilityLabel(text.isEmpty ? "Keyboard focus on the dock" : "Finding \(text)")
    }
}

private struct QueryPlacement: ViewModifier {
    let scene: DockScene

    func body(content: Content) -> some View {
        let panel = scene.panel, bar = scene.bar
        let point: CGPoint = switch scene.edge {
        case .bottom: CGPoint(x: max(bar.minX + 130, 140), y: bar.minY - 26)
        case .top: CGPoint(x: max(bar.minX + 130, 140), y: bar.maxY + 26)
        case .left: CGPoint(x: bar.maxX + 140, y: max(bar.minY - 20, 20))
        case .right: CGPoint(x: bar.minX - 140, y: max(bar.minY - 20, 20))
        }
        content
            .position(x: min(max(point.x, 130), panel.width - 130), y: min(max(point.y, 16), panel.height - 16))
            .offset(scene.hideOffset)
            .allowsHitTesting(false)
    }
}

// MARK: - Window plumbing

@MainActor
private final class DockTicker: NSObject {
    private var link: CADisplayLink?
    private let handler: (CADisplayLink) -> Void

    init(handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(fire))
        // As fast as the display goes: 120 Hz on ProMotion, never below 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    var paused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The link runs on the main run loop, so this always arrives on the main actor.
    @objc private func fire(_ link: CADisplayLink) { handler(link) }
}

private final class DockMenuItem: NSMenuItem {
    var handler: (() -> Void)?

    convenience init(_ title: String, state: NSControl.StateValue = .off, symbol: String? = nil, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() { handler?() }
}

/// All input lands here, in the panel's own coordinates. Tiles move under the pointer every
/// frame, so hit testing belongs to the physics and not to the view tree.
private final class DockInputView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) { OwnDock.shared.mouseDown(local(event)) }
    override func mouseDragged(with event: NSEvent) { OwnDock.shared.mouseDragged(local(event)) }
    override func mouseUp(with event: NSEvent) { OwnDock.shared.mouseUp(local(event), modifiers: event.modifierFlags) }
    override func rightMouseDown(with event: NSEvent) { OwnDock.shared.contextMenu(local(event), event: event, view: self) }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { OwnDock.shared.middleClick(local(event)) }
    }
    override func scrollWheel(with event: NSEvent) { OwnDock.shared.scroll(local(event), event: event) }
    override func magnify(with event: NSEvent) { OwnDockGestures.shared.magnify(event, slot: OwnDock.shared.gestureSlot(at: local(event))) }
    override func keyDown(with event: NSEvent) {
        if !OwnDock.shared.key(event) { super.keyDown(with: event) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        OwnDock.shared.dragOver(convert(sender.draggingLocation, from: nil))
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        OwnDock.shared.dragOver(convert(sender.draggingLocation, from: nil))
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { OwnDock.shared.dragOver(nil) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { OwnDock.shared.dragOver(nil) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        OwnDock.shared.drop(urls, at: convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// Stacks open from the tile that was clicked, on whichever edge the dock is on. The
/// bubble itself is the shared `BubbleHost`; this only places it over the tile.
@MainActor
private final class DockBubble {
    let host = BubbleHost()

    var isOpen: Bool { host.isOpen }
    func isShowing(_ url: URL) -> Bool { host.isShowing(url) }
    func close() { host.close() }

    func show(_ url: URL, title: String, items: [StackItem], style: StackStyle, tile: NSRect, edge: OwnDockEdge,
              screen: NSScreen, tint: Color?) {
        if host.justClosed(url) { return }
        if host.isShowing(url) { close(); return }
        host.load(url, title: title, items: items, style: style, tint: tint)
        host.present(frame: place(tile: tile, edge: edge, area: screen.visibleFrame))
    }

    private func place(tile: NSRect, edge: OwnDockEdge, area: NSRect) -> NSRect {
        let size = BubbleHost.size, model = host.model
        var origin: NSPoint
        switch edge {
        case .bottom:
            origin = NSPoint(x: tile.midX - size.width / 2, y: tile.maxY + 4)
            model.alignment = .bottom
        case .top:
            origin = NSPoint(x: tile.midX - size.width / 2, y: tile.minY - 4 - size.height)
            model.alignment = .top
        case .left:
            origin = NSPoint(x: tile.maxX + 4, y: tile.midY - size.height / 2)
            model.alignment = .leading
        case .right:
            origin = NSPoint(x: tile.minX - 4 - size.width, y: tile.midY - size.height / 2)
            model.alignment = .trailing
        }
        origin.x = min(max(origin.x, area.minX + 4), area.maxX - size.width - 4)
        origin.y = min(max(origin.y, area.minY + 4), area.maxY - size.height - 4)
        let frame = NSRect(origin: origin, size: size)
        if edge.horizontal {
            let limit = max(0, (size.width - host.drawnWidth) / 2 - 12)
            model.offset = CGSize(width: min(max(tile.midX - frame.midX, -limit), limit), height: 0)
        } else {
            let limit = max(0, size.height / 2 - 200)
            model.offset = CGSize(width: 0, height: min(max(frame.midY - tile.midY, -limit), limit))
        }
        model.anchor = edge.anchor
        return frame
    }
}

// MARK: - Trash

/// Whether the Trash holds anything, kept current by a kqueue source on the folder. No
/// polling: the source only fires when the folder changes.
@MainActor
final class TrashWatcher {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)

    private(set) var full = false
    var changed: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?

    func start() {
        update()
        guard source == nil else { return }
        let descriptor = open(Self.url.path, O_EVTONLY)
        // Without access to the folder the state is still read on every dock refresh.
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename, .link, .extend], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.update() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    func update() {
        let now = Self.read()
        guard now != full else { return }
        full = now
        changed?()
    }

    /// Lists the folder when allowed. When privacy settings block the listing, the folder's
    /// own entry count still tells, less a Finder `.DS_Store` if there is one.
    private static func read() -> Bool {
        let path = url.path
        if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            return DockRightSide.trashHasItems(names)
        }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var reply: (length: UInt32, count: UInt32) = (0, 0)
        guard getattrlist(path, &request, &reply, MemoryLayout.size(ofValue: reply), 0) == 0 else { return false }
        let store = FileManager.default.fileExists(atPath: path + "/.DS_Store") ? 1 : 0
        return Int(reply.count) - store > 0
    }
}

// MARK: - OwnDock

/// Which screen the dock is on.
enum OwnDockDisplay: String, CaseIterable, Identifiable, Sendable {
    case chosen, main, pointer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chosen: "Chosen"
        case .main: "Main Display"
        case .pointer: "Follows Pointer"
        }
    }
}

/// Bumped when what the real dock shows changes for a reason the settings do not publish:
/// badges, minimised windows, recent apps. Only the stage replica watches it.
@MainActor
final class OwnDockLive: ObservableObject {
    @Published private(set) var version = 0
    func bump() { version &+= 1 }
}

/// A dock of our own: a separate floating bar. It never writes the Dock's preferences; it
/// only reads its Accessibility tree for badges. The one exception is Replace System Dock,
/// an explicit switch, which goes through `SystemDockReplacer` and is always put back.
@MainActor
final class OwnDock: ObservableObject {
    static let shared = OwnDock()

    private enum Key {
        static let enabled = "ownDock.enabled", edge = "ownDock.edge", tile = "ownDock.tile"
        static let large = "ownDock.large", magnify = "ownDock.magnify", autoHide = "ownDock.autoHide"
        static let vitals = "ownDock.vitals", look = "ownDock.followLook", running = "ownDock.showRunning"
        static let items = "ownDock.items", screen = "ownDock.screen"
        static let hideSystem = "ownDock.hideSystem", systemBefore = "ownDock.systemAutoHideBefore"
        static let replaceSystem = "ownDock.replaceSystem", appearance = "ownDock.appearance"
        static let customs = "ownDock.customs", recents = "ownDock.recents", display = "ownDock.display"
        static let edges = "ownDock.edgesByDisplay", hotKey = "ownDock.hotKey"
        static let sections = "ownDock.sections", options = "ownDock.tileOptions", smart = "ownDock.smartStacks"
        static let hub = "ownDock.hub", design = "ownDock.design", reserve = "ownDock.reserve"
    }

    private let store = UserDefaults.standard

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: Key.enabled); enabledChanged() } }
    @Published var edge: OwnDockEdge { didSet { store.set(edge.rawValue, forKey: Key.edge); layout() } }
    @Published var tile: Double { didSet { store.set(tile, forKey: Key.tile); layout() } }
    @Published var large: Double { didSet { store.set(large, forKey: Key.large); layout() } }
    @Published var magnify: Bool { didSet { store.set(magnify, forKey: Key.magnify); layout() } }
    @Published var autoHide: Bool { didSet { store.set(autoHide, forKey: Key.autoHide); applyAutoHide() } }
    /// The Vitals tile's rings, outermost first. Up to four.
    @Published var vitalMetrics: [VitalMetric] = (UserDefaults.standard.array(forKey: "ownDock.vitalMetrics") as? [String])?
        .compactMap(VitalMetric.init(rawValue:)) ?? [.memory, .disk, .battery] {
        didSet {
            UserDefaults.standard.set(vitalMetrics.map(\.rawValue), forKey: "ownDock.vitalMetrics")
            vitals.wanted = Set(vitalMetrics)
            live.bump()
        }
    }
    @Published var showVitals: Bool { didSet { slotCache = nil; store.set(showVitals, forKey: Key.vitals); vitalsChanged(); refresh() } }
    @Published var showRunning: Bool { didSet { slotCache = nil; store.set(showRunning, forKey: Key.running); refresh() } }
    @Published var followLook: Bool { didSet { store.set(followLook, forKey: Key.look); applyTheme() } }
    @Published var screenName: String? { didSet { store.set(screenName, forKey: Key.screen); layout() } }
    @Published var display: OwnDockDisplay { didSet { store.set(display.rawValue, forKey: Key.display); layout() } }
    /// An edge per display, by display name. Displays not listed use `edge`.
    @Published var edgeOverrides: [String: OwnDockEdge] {
        didSet {
            guard edgeOverrides != oldValue else { return }
            store.set(edgeOverrides.mapValues(\.rawValue), forKey: Key.edges)
            layout()
        }
    }
    @Published var appearance: DockAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if let data = try? JSONEncoder().encode(appearance) { store.set(data, forKey: Key.appearance) }
            slotCache = nil
            appearanceChanged(from: oldValue)
        }
    }
    /// Names and pictures the user gave tiles, by tile id.
    @Published private(set) var customs: [String: DockCustom] { didSet { slotCache = nil } }
    /// Index into `DockShortcut.all`, -1 for none. Kept for older settings: the shortcuts now
    /// live in `hub.shortcuts`, and this only seeds Focus the Dock once.
    @Published var hotKey: Int {
        didSet { store.set(hotKey, forKey: Key.hotKey) }
    }
    /// The user's sections, in order.
    @Published private(set) var sections: [DockSection] { didSet { slotCache = nil } }
    /// Options per tile id. Tiles with none use the defaults.
    @Published private(set) var options: [String: DockTileOptions] { didSet { slotCache = nil } }
    /// What each smart stack shows, by tile id.
    @Published private(set) var smart: [String: DockSmartStack] { didSet { slotCache = nil } }
    /// Window Previews, Focus Mode, auto-hide timing, Spaces and the shortcuts.
    @Published var hub: DockHubPrefs {
        didSet {
            guard hub != oldValue else { return }
            if let data = try? JSONEncoder().encode(hub) { store.set(data, forKey: Key.hub) }
            hubChanged(from: oldValue)
        }
    }
    /// The bar's design, icon treatment and effects.
    @Published var design: DockDesignPrefs {
        didSet {
            guard design != oldValue else { return }
            if let data = try? JSONEncoder().encode(design) { store.set(data, forKey: Key.design) }
            applyTheme()
        }
    }
    /// Reserve Dock Space: zoomed and tiled windows stop at the dock instead of under it.
    @Published var reserve: DockReservePrefs {
        didSet {
            guard reserve != oldValue else { return }
            if let data = try? JSONEncoder().encode(reserve) { store.set(data, forKey: Key.reserve) }
            DockReserve.shared.update()
        }
    }
    /// Arrange Dock: tiles show a remove button, spacers show where they are, and the lens
    /// stays still so nothing moves under the pointer. Never saved.
    @Published var arranging = false {
        didSet {
            guard arranging != oldValue else { return }
            slotCache = nil
            stage.arranging = arranging
            field.armedID = nil
            if arranging { field.peekTarget = false }
            layout()
            refresh()
        }
    }
    /// Keep the macOS Dock out of sight while this dock is on.
    @Published var replaceSystem: Bool {
        didSet {
            guard replaceSystem != oldValue else { return }
            slotCache = nil
            store.set(replaceSystem, forKey: Key.replaceSystem)
            // Taking the Dock's place starts on the Dock's own edge.
            if replaceSystem, enabled {
                edge = Self.systemDockEdge()
                // And it brings what sits right of the Dock's divider: folders and stacks.
                merge(Self.systemOthers())
            }
            applyReplacement()
        }
    }
    @Published private(set) var items: [OwnDockItem] = [] { didSet { slotCache = nil } }
    /// True while the system Dock really is kept hidden by us.
    @Published private(set) var systemReplaced = false {
        didSet { if systemReplaced != oldValue { MinimizeRedirect.shared.update() } }
    }
    @Published private(set) var replaceError: String?
    @Published private(set) var trashFull = false { didSet { slotCache = nil } }

    let stage = OwnDockStage()
    let vitals = Vitals()
    let live = OwnDockLive()
    let feed = OwnDockFeed.shared

    private var field = DockField()
    /// One for the life of the app: it owns the guardian that covers a crash.
    private let replacer = SystemDockReplacer.live()
    private let trash = TrashWatcher()
    private let reader = SystemDockReader()
    private let minimized = MinimizedWatcher.shared
    private var panel: FloatingPanel?
    private var input: NSView?
    private var ticker: DockTicker?
    private var poll: Timer?
    private var started = false
    private var batching = false
    private var vitalsRunning = false
    private var bubble = DockBubble()
    private var lastTick: CFTimeInterval = 0
    private var metrics = DockMetrics()
    private var watchers: [AnyCancellable] = []
    /// The edge the bar is on right now: the display's own edge, or `edge`.
    private(set) var placedEdge = OwnDockEdge.bottom
    /// In Follows Pointer, the display the dock moved to last.
    private var pointerScreen: String?

    private var launching: [String: Date] = [:] { didSet { slotCache = nil } }
    private var launchedAt: [String: Date] = [:]
    /// Apps the macOS Dock is bouncing for attention, by resolved path, with when it was last seen.
    private var attention: [String: Date] = [:] { didSet { slotCache = nil } }
    private var recentPaths: [String] { didSet { slotCache = nil } }
    /// The last `slots()`, until something it reads changes. The Studio asks for it on every
    /// render, and building it lists running apps and checks files.
    private var slotCache: [DockSlot]?
    /// Stack documents' styles, read once each when the pointer first rests on the tile.
    private var stackStyles: [String: StackStyle] = [:]
    private var canonicalCache: [String: String] = [:]
    private var revealed = false
    private var edgeSince: Date?
    private var awaySince: Date?
    private var menuOpen = false
    private var pressID: String?
    private var pressPoint = CGPoint.zero
    private var hoverID: String?
    private var hoverSince = Date.distantPast
    private var peekLeft: Date?
    private var peekRequest = 0
    private var lastMouse = NSPoint.zero
    private var tickMouse = NSPoint.zero
    private var scrollID: String?
    private var scrollTravel = 0.0
    private var lastScrollStep = Date.distantPast
    /// Window pictures in the peek card: the AX window for each, to raise it on a click.
    private var peekRefs: [CGWindowID: AXRef] = [:]
    private var peekPID: pid_t = 0
    private var peekTask: Task<Void, Never>?
    /// For the minimise sound: how many minimised windows there were.
    private var minimizedCount = 0
    /// A stack opened by resting on it, so it does not open again until the pointer leaves.
    private var hoverOpened: String?
    private let contents = DockHubContents.shared

    /// The keyboard drives the dock: arrows move, typing finds, Return opens.
    private(set) var keyboardActive = false
    private var query = ""

    private init() {
        // Before reading the switch, which an older build's setting may turn on.
        Self.migrateLegacyHide(.standard)
        enabled = store.bool(forKey: Key.enabled)
        edge = OwnDockEdge(rawValue: store.string(forKey: Key.edge) ?? "") ?? .bottom
        tile = store.object(forKey: Key.tile) as? Double ?? 56
        large = store.object(forKey: Key.large) as? Double ?? 96
        magnify = store.object(forKey: Key.magnify) as? Bool ?? true
        autoHide = store.bool(forKey: Key.autoHide)
        showVitals = store.object(forKey: Key.vitals) as? Bool ?? true
        showRunning = store.object(forKey: Key.running) as? Bool ?? true
        followLook = store.object(forKey: Key.look) as? Bool ?? true
        screenName = store.string(forKey: Key.screen)
        display = OwnDockDisplay(rawValue: store.string(forKey: Key.display) ?? "") ?? .chosen
        edgeOverrides = (store.dictionary(forKey: Key.edges) as? [String: String] ?? [:]).compactMapValues(OwnDockEdge.init(rawValue:))
        replaceSystem = store.bool(forKey: Key.replaceSystem)
        let oldHotKey = store.object(forKey: Key.hotKey) as? Int ?? 0
        hotKey = oldHotKey
        recentPaths = store.stringArray(forKey: Key.recents) ?? []
        if let data = store.data(forKey: Key.customs), let saved = try? JSONDecoder().decode([String: DockCustom].self, from: data) {
            customs = saved
        } else {
            customs = [:]
        }
        if let data = store.data(forKey: Key.appearance), let saved = try? JSONDecoder().decode(DockAppearance.self, from: data) {
            appearance = saved
        } else {
            appearance = DockAppearance()
        }
        sections = (store.data(forKey: Key.sections)).flatMap { try? JSONDecoder().decode([DockSection].self, from: $0) } ?? []
        options = (store.data(forKey: Key.options)).flatMap { try? JSONDecoder().decode([String: DockTileOptions].self, from: $0) } ?? [:]
        smart = (store.data(forKey: Key.smart)).flatMap { try? JSONDecoder().decode([String: DockSmartStack].self, from: $0) } ?? [:]
        var prefs = (store.data(forKey: Key.hub)).flatMap { try? JSONDecoder().decode(DockHubPrefs.self, from: $0) } ?? DockHubPrefs()
        if !prefs.shortcutsSeeded {
            // The one shortcut older builds offered becomes Focus the Dock's.
            prefs.shortcutsSeeded = true
            if DockShortcut.all.indices.contains(oldHotKey) {
                let old = DockShortcut.all[oldHotKey]
                prefs.shortcuts[DockHubAction.focusDock.rawValue] = DockKeyCombo(keyCode: old.key, modifiers: old.modifiers)
            }
            if let data = try? JSONEncoder().encode(prefs) { store.set(data, forKey: Key.hub) }
        }
        hub = prefs
        design = (store.data(forKey: Key.design)).flatMap { try? JSONDecoder().decode(DockDesignPrefs.self, from: $0) } ?? DockDesignPrefs()
        reserve = (store.data(forKey: Key.reserve)).flatMap { try? JSONDecoder().decode(DockReservePrefs.self, from: $0) } ?? DockReservePrefs()
        if let data = store.data(forKey: Key.items), let saved = try? JSONDecoder().decode([OwnDockItem].self, from: data) {
            items = saved
        } else {
            items = Self.seed()
            persist()
        }
        if Self.migrateStackOptions(items: items, options: &options, smart: &smart) {
            if let data = try? JSONEncoder().encode(options) { store.set(data, forKey: Key.options) }
            if let data = try? JSONEncoder().encode(smart) { store.set(data, forKey: Key.smart) }
        }
    }

    /// Call once at launch. Shows the dock if it was on. Never changes the system Dock.
    func start() {
        guard !started else { return }
        started = true
        DockIcons.loaded = { OwnDock.shared.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MinimizeRedirect.shared.update() }
        // Accessibility and Screen Recording, watched: a grant made now is used at once.
        DockPermissions.shared.start()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { OwnDock.shared.minimized.watch(app) }
                OwnDock.shared.launched(app?.bundleURL?.path)
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { OwnDock.shared.minimized.forget(pid) }
                OwnDock.shared.refresh()
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let path = app?.activationPolicy == .regular ? app?.bundleURL?.path : nil
            MainActor.assumeIsolated { OwnDock.shared.activated(path) }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { OwnDock.shared.refresh() }
            }
        }
        center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OwnDock.shared.field.motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            // Each desktop can have its own picture.
            MainActor.assumeIsolated { OwnDock.shared.applyTheme() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { OwnDock.shared.layout() } }
        // The app delegate may call `restoreOnQuit` too. Doing it twice is harmless.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { OwnDock.restoreOnQuit() } }
        watchers.append(Effects.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { OwnDock.shared.applyTheme() } }
        })
        applyTheme()
        reader.changed = { OwnDock.shared.systemDockChanged() }
        minimized.changed = {
            let dock = OwnDock.shared
            let count = dock.minimized.windows.count
            if count > dock.minimizedCount, dock.appearance.minimized { DockSounds.play(.minimize, prefs: dock.design) }
            dock.minimizedCount = count
            dock.refresh()
            dock.live.bump()
        }
        contents.changed = {
            OwnDock.shared.slotCache = nil
            OwnDock.shared.refresh()
            OwnDock.shared.live.bump()
        }
        NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil,
                                               queue: .main) { _ in MainActor.assumeIsolated { DockKeyNames.forget() } }
        OwnDockProfiles.shared.start()
        Self.recoverAtLaunch()
        if enabled { enabledChanged() } else { applyHotKey() }
    }

    // MARK: Items

    /// A first dock: the apps, folders and stacks already in the system Dock. Read only.
    private static func seed() -> [OwnDockItem] {
        guard let plist = try? DockStore.read() else { return [] }
        let found = Tiles.apps(plist).compactMap(Tiles.path(of:)).map { OwnDockItem(kind: .app, path: canonical($0)) }
            + others(plist)
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The system Dock's right side (`persistent-others`): folders, stacks and files. Read only.
    private static func systemOthers() -> [OwnDockItem] {
        guard let plist = try? DockStore.read() else { return [] }
        return others(plist)
    }

    private static func others(_ plist: DockPlist) -> [OwnDockItem] {
        let tiles = Tiles.others(plist).map { (type: Tiles.type(of: $0), path: Tiles.path(of: $0)) }
        return DockRightSide.others(tiles) { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &folder) ? folder.boolValue : nil
        }.map { found in
            let kind: OwnDockItem.Kind = switch found.kind {
            case .folder: .folder
            case .stack: .stack
            case .file: .file
            }
            return OwnDockItem(kind: kind, path: found.path)
        }
    }

    private func merge(_ found: [OwnDockItem]) {
        var merged = items
        for item in found where !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
        guard merged != items else { return }
        items = merged
        persist()
        refresh()
    }

    /// Running apps report their real location. Safari in /Applications is a symlink, and
    /// without this it would get two tiles and an alias badge.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `canonical`, remembered, since it asks the file system.
    private func resolved(_ path: String) -> String {
        if let known = canonicalCache[path] { return known }
        let found = Self.canonical(path)
        if canonicalCache.count > 400 { canonicalCache.removeAll() }
        canonicalCache[path] = found
        return found
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { store.set(data, forKey: Key.items) }
    }

    func add(_ url: URL) {
        let path = Self.canonical(url.path)
        guard !items.contains(where: { $0.id == path }) else { return }
        var folder: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
        let kind: OwnDockItem.Kind = path.hasSuffix(".app") ? .app
            : path.hasSuffix("." + StackStore.fileExtension) ? .stack : isFolder ? .folder : .file
        items.append(OwnDockItem(kind: kind, path: path))
        persist()
        refresh()
    }

    func remove(_ item: OwnDockItem) {
        items.removeAll { $0.id == item.id }
        if let custom = customs[item.id] {
            DockCustomStore.remove(custom.icon)
            customs[item.id] = nil
            persistCustoms()
        }
        persist()
        refresh()
    }

    func remove(id: String) {
        if let item = items.first(where: { $0.id == id }) { remove(item) }
    }

    /// Clock, Battery and the other tiles come once each; spacers as often as wanted.
    func addTile(_ kind: OwnDockItem.Kind) {
        guard kind != .app, kind != .file, kind != .folder, kind != .stack else { return }
        if kind != .spacer, kind != .spacerLarge, hasTile(kind) { return }
        items.append(.tile(kind))
        persist()
        refresh()
    }

    func hasTile(_ kind: OwnDockItem.Kind) -> Bool { items.contains { $0.kind == kind } }

    func removeTiles(_ kind: OwnDockItem.Kind) {
        items.removeAll { $0.kind == kind }
        persist()
        refresh()
    }

    func copyFromSystemDock() {
        merge(Self.seed())
    }

    // MARK: Arranging

    /// Moves `id` to just before `before`, or to the end of `section` when `before` is nil.
    /// The item joins the section of the place it lands in.
    func move(_ id: String, before: String?, section: UUID?) {
        guard let from = items.firstIndex(where: { $0.id == id }), id != before else { return }
        var list = items
        var item = list.remove(at: from)
        item.section = section
        if let before, let to = list.firstIndex(where: { $0.id == before }) {
            list.insert(item, at: to)
        } else if let last = list.lastIndex(where: { $0.section == section && (section != nil || $0.rightSide == item.rightSide) }) {
            list.insert(item, at: last + 1)
        } else {
            list.append(item)
        }
        guard list != items else { return }
        items = list
        persist()
        refresh()
    }

    /// Any kept tile, app or stack or folder, to either side of the divider.
    func setSide(_ id: String, right: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].rightSide != right else { return }
        var list = items
        var item = list.remove(at: index)
        item.right = right
        item.section = nil
        if let last = list.lastIndex(where: { $0.section == nil && $0.rightSide == right }) {
            list.insert(item, at: last + 1)
        } else if right {
            list.append(item)
        } else {
            list.insert(item, at: 0)
        }
        items = list
        persist()
        refresh()
    }

    func assign(_ id: String, to section: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].section != section else { return }
        move(id, before: nil, section: section)
    }

    @discardableResult
    func addSection(named name: String) -> DockSection {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = DockSection(name: clean.isEmpty ? "Section \(sections.count + 1)" : clean)
        sections.append(section)
        persistSections()
        refresh()
        return section
    }

    func renameSection(_ id: UUID, to name: String) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != sections[index].name else { return }
        sections[index].name = clean
        persistSections()
        refresh()
    }

    /// The section goes; its tiles stay, back in the dock's own order.
    func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        var list = items
        for index in list.indices where list[index].section == id { list[index].section = nil }
        if list != items { items = list; persist() }
        persistSections()
        refresh()
    }

    func moveSection(_ id: UUID, by step: Int) {
        guard let from = sections.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + step, 0), sections.count - 1)
        guard to != from else { return }
        sections.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persistSections()
        refresh()
    }

    func moveSection(_ id: UUID, before other: UUID) {
        guard let from = sections.firstIndex(where: { $0.id == id }), id != other else { return }
        var list = sections
        let section = list.remove(at: from)
        let to = list.firstIndex { $0.id == other } ?? list.count
        list.insert(section, at: to)
        sections = list
        persistSections()
        refresh()
    }

    private func persistSections() {
        if let data = try? JSONEncoder().encode(sections) { store.set(data, forKey: Key.sections) }
    }

    // MARK: Tile options

    /// The name a row shows: the user's own, a smart stack's, or the file's.
    func displayTitle(_ item: OwnDockItem) -> String {
        if let label = customs[item.id]?.label { return label }
        if item.kind == .smart, let stack = smart[item.id] { return stack.name }
        return item.title
    }

    func options(for id: String) -> DockTileOptions { options[id] ?? DockTileOptions() }

    func setOptions(_ value: DockTileOptions, for id: String) {
        let next: DockTileOptions? = value.isDefault ? nil : value
        guard options[id] != next else { return }
        options[id] = next
        if let data = try? JSONEncoder().encode(options) { store.set(data, forKey: Key.options) }
        refreshContents(force: true)
        refresh()
        live.bump()
    }

    /// Reads again what fanned and counted tiles show.
    func refreshContents(force: Bool = false) {
        contents.refresh(items, options: options, force: force)
    }

    // MARK: Smart stacks

    func addSmart(_ stack: DockSmartStack) {
        let item = OwnDockItem.tile(.smart)
        smart[item.id] = stack
        items.append(item)
        persist()
        persistSmart()
        refresh()
    }

    func updateSmart(_ id: String, _ stack: DockSmartStack) {
        guard smart[id] != stack else { return }
        smart[id] = stack
        persistSmart()
        refresh()
        live.bump()
    }

    private func persistSmart() {
        let kept = Set(items.map(\.id))
        let saved = smart.filter { kept.contains($0.key) }
        if let data = try? JSONEncoder().encode(saved) { store.set(data, forKey: Key.smart) }
    }

    /// Adds a `.dockstack` to this dock.
    func addStack(_ url: URL) { add(url) }

    // MARK: Shortcuts

    func setShortcut(_ combo: DockKeyCombo?, for action: DockHubAction) {
        var prefs = hub
        prefs.shortcuts[action.rawValue] = combo
        hub = prefs
    }

    /// What a Dock shortcut does.
    func perform(_ action: DockHubAction) {
        switch action {
        case .focusDock:
            guard enabled else { NSSound.beep(); return }
            toggleKeyboardFocus()
        case .toggleDock: enabled.toggle()
        case .showOrbit: Orbit.shared.toggle()
        case .arrange:
            guard enabled else { NSSound.beep(); return }
            arranging.toggle()
        case .autoHide: autoHide.toggle()
        case .magnify: magnify.toggle()
        case .focusMode: hub.focusMode.toggle()
        case .nextProfile: OwnDockProfiles.shared.applyNext()
        case .profile1: OwnDockProfiles.shared.apply(index: 0)
        case .profile2: OwnDockProfiles.shared.apply(index: 1)
        case .profile3: OwnDockProfiles.shared.apply(index: 2)
        }
    }

    private func hubChanged(from old: DockHubPrefs) {
        if hub.shortcuts != old.shortcuts { applyHotKey() }
        if hub.sectionStyle != old.sectionStyle { slotCache = nil; refresh(); live.bump() }
        field.focusDim = hub.focusMode ? hub.focusDim : 0
        field.hideStiffness = hub.hideSpeed.stiffness
        if hub.allSpaces != old.allSpaces || hub.fullScreen != old.fullScreen { applyBehaviour() }
        if !hub.windowPreviews { peekTask?.cancel() }
        wake()
    }

    private var collectionBehaviour: NSWindow.CollectionBehavior {
        var behaviour: NSWindow.CollectionBehavior = [.ignoresCycle]
        if hub.allSpaces { behaviour.formUnion([.canJoinAllSpaces, .stationary]) }
        if hub.fullScreen { behaviour.insert(.fullScreenAuxiliary) }
        return behaviour
    }

    private func applyBehaviour() {
        panel?.collectionBehavior = collectionBehaviour
    }

    var stacksAvailable: [URL] { StackStore.list().filter { url in !items.contains { $0.id == url.path } } }

    // MARK: Names and pictures

    private func persistCustoms() {
        if let data = try? JSONEncoder().encode(customs) { store.set(data, forKey: Key.customs) }
        live.bump()
    }

    func chooseIcon(for id: String, title: String) {
        guard let name = DockCustomStore.pickIcon(for: title) else { return }
        var custom = customs[id] ?? DockCustom()
        if let old = custom.icon {
            DockIcons.forget(DockCustomStore.folder.appendingPathComponent(old).path)
            DockCustomStore.remove(old)
        }
        custom.icon = name
        customs[id] = custom
        persistCustoms()
        refresh()
    }

    /// An image file of the owner's, for an icon.
    static func pickImageFile() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Icon"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NSImage(contentsOf: url)
    }

    /// A picture from the icon library, or any image, as a tile's icon.
    func setIcon(_ image: NSImage, for id: String) {
        guard let name = DockCustomStore.store(image) else { return }
        var custom = customs[id] ?? DockCustom()
        if let old = custom.icon {
            DockIcons.forget(DockCustomStore.folder.appendingPathComponent(old).path)
            DockCustomStore.remove(old)
        }
        custom.icon = name
        customs[id] = custom
        persistCustoms()
        refresh()
    }

    /// Acts on a tile as a click on it would: for the settings' item list.
    func activateSlot(_ id: String) { click(id) }

    func rename(_ id: String, original: String) {
        let current = customs[id]?.label ?? original
        guard let answer = DockCustomStore.askName(current: current, original: original) else { return }
        var custom = customs[id] ?? DockCustom()
        custom.label = answer
        customs[id] = custom.label == nil && custom.icon == nil ? nil : custom
        persistCustoms()
        refresh()
    }

    func resetCustom(_ id: String) {
        guard let custom = customs.removeValue(forKey: id) else { return }
        if let icon = custom.icon {
            DockIcons.forget(DockCustomStore.folder.appendingPathComponent(icon).path)
            DockCustomStore.remove(icon)
        }
        persistCustoms()
        refresh()
    }

    // MARK: Profiles

    /// What a profile saves.
    var setup: OwnDockSetup {
        OwnDockSetup(items: items, appearance: appearance, edge: edge, tile: tile, large: large, magnify: magnify,
                     autoHide: autoHide, showRunning: showRunning, showVitals: showVitals,
                     sections: sections, options: options, smart: smart, design: design)
    }

    /// Puts a saved dock back in one go: one layout, not one per setting.
    func apply(_ setup: OwnDockSetup) {
        batching = true
        items = setup.items.filter { $0.isTile || FileManager.default.fileExists(atPath: $0.path) }
        persist()
        if let saved = setup.sections { sections = saved; persistSections() }
        if let saved = setup.options {
            options = saved
            if let data = try? JSONEncoder().encode(options) { store.set(data, forKey: Key.options) }
        }
        if let saved = setup.smart { smart.merge(saved) { _, new in new }; persistSmart() }
        if let saved = setup.design { design = saved }
        appearance = setup.appearance
        edge = setup.edge
        tile = setup.tile
        large = setup.large
        magnify = setup.magnify
        showRunning = setup.showRunning
        showVitals = setup.showVitals
        batching = false
        autoHide = setup.autoHide
        layout()
    }

    // MARK: Contents

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
    }

    private func runningApp(_ path: String) -> NSRunningApplication? {
        guard !path.isEmpty else { return nil }
        return runningApps().first { $0.bundleURL?.path == path }
    }

    /// True when the bar ends with the Trash.
    var showsTrash: Bool { appearance.showTrash ?? replaceSystem }

    /// The kinds of Atelier tiles on the bar, which decide which data sources run.
    private var tileKinds: Set<OwnDockItem.Kind> {
        Set(items.lazy.filter(\.isTile).map(\.kind))
    }

    /// The list of slots as it stands right now: kept apps, open apps, recent apps, then the
    /// right side (folders, stacks, files, tiles, minimised windows, Now Vitals) and the
    /// Trash last, as in the macOS Dock.
    func slots() -> [DockSlot] {
        if let slotCache { return slotCache }
        let built = buildSlots()
        slotCache = built
        return built
    }

    private func buildSlots() -> [DockSlot] {
        let apps = runningApps()
        let byPath = Dictionary(apps.map { ($0.bundleURL?.path ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        let look = appearance
        let badges = look.badges ? reader.reading.badges : [:]
        func decorate(_ slot: inout DockSlot) {
            if slot.kind == .app, !slot.path.isEmpty, !badges.isEmpty || !attention.isEmpty {
                let key = resolved(slot.path)
                slot.badge = badges[key]
                slot.attention = look.attention && attention[key] != nil && !slot.frontmost
            }
            if let custom = customs[slot.id] {
                if let label = custom.label { slot.title = label }
                slot.icon = DockCustomStore.iconPath(custom)
            }
        }
        let counts = contents.counts, newest = contents.newest
        func slot(_ item: OwnDockItem) -> DockSlot {
            let app = item.kind == .app ? byPath[item.path] : nil
            var slot = DockSlot(id: item.id, kind: item.slotKind, path: item.isTile ? "" : item.path, title: item.title,
                                pinned: true, running: app != nil, frontmost: item.path == front, hidden: app?.isHidden ?? false,
                                launching: launching[item.path] != nil)
            if item.kind == .smart, let stack = smart[item.id] {
                slot.title = stack.name
                slot.symbol = stack.source.symbol
            }
            if let option = options[item.id] {
                slot.scale = option.size.scale
                slot.face = option.face
                if option.badge, let count = counts[item.id], count > 0 { slot.badge = count > 99 ? "99+" : "\(count)" }
                if option.folderLook == .stack { slot.preview = newest[item.id] ?? [] }
            }
            decorate(&slot)
            if item.kind == .smart, let stack = smart[item.id], let spec = stack.icon {
                slot.icon = Self.smartIcon(spec, title: stack.name)
            }
            return slot
        }
        // Tiles in a section of the user's sit together after the dock's own kept tiles,
        // each section opened by its separator.
        let known = Set(sections.map(\.id))
        let loose = items.filter { $0.section.map { !known.contains($0) } ?? true }
        var kept = loose.filter { !$0.rightSide }.map(slot)
        var right = loose.filter(\.rightSide).map(slot)
        if look.runningOnly {
            kept.removeAll { !$0.running && !$0.launching }
            right.removeAll()
        }
        for section in sections {
            var members = items.filter { $0.section == section.id }.map(slot)
            if look.runningOnly { members.removeAll { !$0.running && !$0.launching } }
            guard !members.isEmpty || arranging else { continue }
            var mark = DockSlot(id: "section:" + section.id.uuidString, kind: .section, title: section.name, pinned: true)
            mark.sectionStyle = hub.sectionStyle
            kept.append(mark)
            kept += members
        }
        let keptPaths = Set(items.map(\.id))
        var open: [DockSlot] = []
        if showRunning {
            for app in apps {
                guard let path = app.bundleURL?.path, !keptPaths.contains(path) else { continue }
                var slot = DockSlot(id: path, kind: .app, path: path, title: app.localizedName ?? "App",
                                    running: true, frontmost: path == front, hidden: app.isHidden)
                decorate(&slot)
                open.append(slot)
            }
        }
        if look.recents, !look.runningOnly {
            var recent: [DockSlot] = []
            for path in recentPaths where recent.count < look.recentCount {
                guard !keptPaths.contains(path), byPath[path] == nil, FileManager.default.fileExists(atPath: path) else { continue }
                var slot = DockSlot(id: path, kind: .app, path: path, title: FileManager.default.displayName(atPath: path)
                    .replacingOccurrences(of: ".app", with: ""), recent: true)
                decorate(&slot)
                recent.append(slot)
            }
            if !recent.isEmpty {
                if look.divider, !open.isEmpty { open.append(.recentDivider) }
                open += recent
            }
        }
        if look.minimized {
            for window in minimized.windows {
                right.append(DockSlot(id: window.id, kind: .window, path: window.appPath, title: window.title, pid: window.pid))
            }
        }
        if showVitals {
            var vitals = DockSlot.vitals
            decorate(&vitals)
            right.append(vitals)
        }
        if showsTrash {
            var trash = DockSlot(id: "trash", kind: .trash, path: TrashWatcher.url.path, title: "Trash", full: trashFull)
            decorate(&trash)
            right.append(trash)
        }
        var list = DockRightSide.arrange(kept: kept, open: open, right: right, separators: look.divider) {
            $0 == 0 ? .divider : .rightDivider
        }
        for index in list.indices where list[index].kind == .divider { list[index].sectionStyle = hub.sectionStyle }
        return list
    }

    func refresh() {
        // Running apps, the app in front, badges or windows changed: build the list again.
        slotCache = nil
        stackStyles = [:]
        guard enabled, field.dragID == nil else { return }
        if showsTrash { trash.update() }
        syncSources()
        refreshContents()
        field.sync(slots())
        wake()
    }

    /// Runs the readers the bar needs right now, and nothing else.
    func refreshSources() { syncSources() }

    private func syncSources() {
        let visible = enabled && panel?.isVisible == true
        feed.seconds = tileKinds.contains(.clock) && options.contains { $0.value.seconds }
        feed.run(visible ? tileKinds : [])
        let trusted = AXIsProcessTrusted()
        let attentionSeen = appearance.attention && SystemDockAX.readsBounces
        let wantsDock = visible && trusted && (appearance.badges || attentionSeen || tileKinds.contains(.downloads))
        if wantsDock != reader.running { wantsDock ? reader.start() : reader.stop() }
        // Minimise into the Atelier Dock needs to know when a window it shrank comes back.
        let wantsWindows = visible && trusted && (appearance.minimized || MinimizeRedirect.shared.active)
        if wantsWindows != minimized.running { wantsWindows ? minimized.start(runningApps()) : minimized.stop() }
    }

    /// The macOS Dock's tiles changed: badges, bounces, download bars.
    private func systemDockChanged() {
        let reading = reader.reading
        feed.dockProgress = reading.progress
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL.map { resolved($0.path) }
        // Only the tile the macOS Dock lifts, never one opening or just launched (a launch
        // bounces too), and a request that is answered or has stopped for a while is over.
        let next = OwnDockBounce.attention(previous: attention, bouncing: reading.bouncing, front: front,
                                           launched: launchedAt, opening: Set(launching.keys.map(resolved)), now: Date())
        if next != attention { attention = next }
        refresh()
        live.bump()
    }

    private func activated(_ path: String?) {
        if let path {
            attention[resolved(path)] = nil
            recentPaths.removeAll { $0 == path }
            recentPaths.insert(path, at: 0)
            if recentPaths.count > 20 { recentPaths.removeLast(recentPaths.count - 20) }
            store.set(recentPaths, forKey: Key.recents)
        }
        refresh()
        if appearance.recents { live.bump() }
    }

    // MARK: Showing

    private func enabledChanged() {
        guard started else { start(); return }
        // The system Dock goes before ours comes, and comes back after ours goes.
        if enabled {
            applyReplacement()
            show()
            applyHotKey()
            OwnDockProfiles.shared.evaluate(force: false)
        } else {
            hide()
            applyReplacement()
            applyHotKey()
            if vitalsRunning {
                vitals.stop()
                vitalsRunning = false
            }
        }
        vitalsChanged()
    }

    /// The shortcuts are claimed only while the dock is on, so they are free for others
    /// otherwise. Show or Hide the Dock is the one kept, so it can bring the dock back.
    private func applyHotKey() {
        DockHubHotKeys.shared.apply(hub.shortcuts, dockOn: enabled && started)
    }

    func ensureVitals() {
        guard !vitalsRunning else { return }
        DockVitalsSettings.shared.apply(to: vitals)
        vitals.start()
        vitalsRunning = true
    }

    private func vitalsChanged() {
        if enabled, showVitals { ensureVitals() }
    }

    /// The display the dock is on.
    var currentScreen: NSScreen? {
        let screens = NSScreen.screens
        switch display {
        case .main:
            return screens.first
        case .chosen:
            return screens.first { $0.localizedName == screenName } ?? screens.first
        case .pointer:
            if let pointerScreen, let found = screens.first(where: { $0.localizedName == pointerScreen }) { return found }
            let mouse = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first
        }
    }

    var screenNames: [String] { NSScreen.screens.map(\.localizedName) }

    /// True when this dock stands in for the macOS Dock.
    var replacesSystemDock: Bool { enabled && replaceSystem }

    /// The panel spans the edge it sits on. Beside the macOS Dock it stays inside the visible
    /// frame, above where that Dock is. In its place it sits flush with the screen edge, since
    /// the visible frame still keeps a few points for the hidden Dock. The menu bar is always kept.
    static func panelFrame(edge: OwnDockEdge, full: NSRect, visible area: NSRect, replacing: Bool,
                           tile: Double, large: Double, look: DockAppearance) -> NSRect {
        let bar = tile * (1 + 2 * look.padding)
        let thickness = look.gap + bar + max(large - tile, 0) + 280
        let base = replacing ? NSRect(x: full.minX, y: full.minY, width: full.width, height: area.maxY - full.minY) : area
        switch edge {
        case .bottom: return NSRect(x: full.minX, y: base.minY, width: full.width, height: thickness)
        case .top: return NSRect(x: full.minX, y: area.maxY - thickness, width: full.width, height: thickness)
        case .left: return NSRect(x: base.minX, y: base.minY, width: thickness, height: base.height)
        case .right: return NSRect(x: base.maxX - thickness, y: base.minY, width: thickness, height: base.height)
        }
    }

    private func edge(for screen: NSScreen) -> OwnDockEdge {
        edgeOverrides[screen.localizedName] ?? edge
    }

    private func show() {
        guard let screen = currentScreen else { return }
        field.motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        placedEdge = edge(for: screen)
        let frame = Self.panelFrame(edge: placedEdge, full: screen.frame, visible: screen.visibleFrame,
                                    replacing: replacesSystemDock, tile: tile, large: large, look: appearance)
        let panel = self.panel ?? makePanel(frame)
        panel.setFrame(frame, display: false)
        panel.collectionBehavior = collectionBehaviour
        // Arranging holds the lens still, so tiles stay put under the pointer.
        metrics = DockMetrics(edge: placedEdge, tile: tile, large: large, magnify: magnify && !arranging, panel: frame.size)
        metrics.apply(appearance)
        field.bounce = appearance.bounce
        field.launchPulse = appearance.launch == .pulse
        field.focusDim = hub.focusMode ? hub.focusDim : 0
        field.hideStiffness = hub.hideSpeed.stiffness
        applyTheme()
        if showsTrash { watchTrash() } else { trash.stop() }
        panel.orderFrontRegardless()
        updateAnimating()
        syncSources()
        field.sync(slots(), instant: stage.scene.tiles.isEmpty)
        field.hideTarget = autoHide ? 1 : 0
        field.hide = field.hideTarget
        revealed = !autoHide
        reader.active = revealed
        stage.scene = field.scene(metrics)
        if ticker == nil {
            let ticker = DockTicker { link in OwnDock.shared.tick(link) }
            ticker.attach(to: panel.contentView ?? NSView())
            self.ticker = ticker
        }
        startPolling()
        wake()
        DockReserve.shared.update()
    }

    private func hide() {
        endKeyboard()
        poll?.invalidate()
        poll = nil
        ticker?.stop()
        ticker = nil
        bubble.close()
        trash.stop()
        panel?.orderOut(nil)
        syncSources()
        DockReserve.shared.update()
    }

    private func watchTrash() {
        trash.changed = {
            OwnDock.shared.trashFull = OwnDock.shared.trash.full
            OwnDock.shared.refresh()
        }
        trash.start()
        if trashFull != trash.full { trashFull = trash.full }
    }

    private func layout() {
        guard enabled, started, !batching else { return }
        show()
    }

    private func applyAutoHide() {
        guard enabled else { return }
        revealed = !autoHide
        reader.active = revealed
        field.hideTarget = autoHide ? 1 : 0
        startPolling()
        wake()
        DockReserve.shared.update()
    }

    /// The theme for these settings, as the dock and its previews draw it.
    func theme(for look: DockAppearance? = nil, design: DockDesignPrefs? = nil) -> DockTheme {
        let look = look ?? appearance
        let wallpaper = look.style == .wallpaper ? WallpaperTone.color(for: currentScreen) : nil
        return DockTheme.make(look, follow: followLook, wallpaper: wallpaper, fx: DockFX(design ?? self.design, lift: look.hoverLift))
    }

    /// Puts on a design with what it recommends: its mark, curve, icon treatment and hover
    /// effect. All of them stay adjustable.
    /// A design with the parts it brings along, worked out without applying it, so the stage
    /// can wear it on hover exactly as a click would set it.
    static func choosing(_ picked: DockDesign, design: DockDesignPrefs, appearance: DockAppearance) -> (DockDesignPrefs, DockAppearance) {
        let look = picked.recommended
        var prefs = design
        prefs.design = picked
        prefs.mark = look.mark
        prefs.backplate = look.backplate
        prefs.hover = look.hover == .lift ? .none : look.hover
        var appearance = appearance
        appearance.indicator = look.indicator
        appearance.curve = look.curve
        appearance.iconShadow = look.shadow
        appearance.reflection = look.reflection
        appearance.hoverLift = look.hover == .lift
        if picked == .retro { appearance.accent = .green }
        return (prefs, appearance)
    }

    func selectDesign(_ picked: DockDesign) {
        let (prefs, appearance) = Self.choosing(picked, design: design, appearance: self.appearance)
        batching = true
        design = prefs
        self.appearance = appearance
        batching = false
        layout()
    }

    /// The Open App Mark, classic or the design's own.
    var mark: DockMarkChoice {
        get { design.mark.map(DockMarkChoice.design) ?? .classic(appearance.indicator) }
        set {
            switch newValue {
            case .classic(let indicator):
                design.mark = nil
                appearance.indicator = indicator
            case .design(let mark):
                design.mark = mark
                if appearance.indicator == .none { appearance.indicator = .dot }
            }
        }
    }

    /// The hover effect. Lift is the appearance's Hover Lift, since the physics needs it.
    var hoverEffect: DockHoverEffect {
        get { appearance.hoverLift ? .lift : design.hover }
        set {
            if newValue == .lift {
                appearance.hoverLift = true
            } else {
                design.hover = newValue
                appearance.hoverLift = false
            }
        }
    }

    private func applyTheme() {
        let theme = theme()
        if theme != stage.theme { stage.theme = theme }
    }

    /// The theme in use, worked out when a setting, the Look or the desktop changes. Views
    /// read this rather than `theme()`, which samples the wallpaper.
    var currentTheme: DockTheme { stage.theme }

    private func appearanceChanged(from old: DockAppearance) {
        field.bounce = appearance.bounce
        field.launchPulse = appearance.launch == .pulse
        applyTheme()
        if appearance.hover == .none || stage.peek?.label != (appearance.hover == .label) { field.peekTarget = false }
        if appearance.attention != old.attention, !appearance.attention { attention = [:] }
        layout()
    }

    private func makePanel(_ frame: NSRect) -> FloatingPanel {
        let panel = FloatingPanel(frame: frame)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = collectionBehaviour
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: OwnDockRoot(stage: stage, vitals: vitals) { id in
            OwnDock.shared.click(id)
        })
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: frame.size)
        let input = DockInputView(frame: host.frame)
        input.autoresizingMask = [.width, .height]
        let root = NSView(frame: host.frame)
        root.addSubview(host)
        root.addSubview(input)
        panel.contentView = root
        self.panel = panel
        self.input = input
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { OwnDock.shared.endKeyboard() }
        }
        // Covered, on another Space, or the displays asleep: animated designs pause.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { OwnDock.shared.updateAnimating() }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                let asleep = note.name == NSWorkspace.screensDidSleepNotification
                MainActor.assumeIsolated { OwnDock.shared.updateAnimating(asleep: asleep) }
            }
        }
        return panel
    }

    private var screensAsleep = false

    fileprivate func updateAnimating(asleep: Bool? = nil) {
        if let asleep { screensAsleep = asleep }
        let on = !screensAsleep && (panel?.occlusionState.contains(.visible) ?? false)
        if stage.animating != on { stage.animating = on }
    }

    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { _ in
            MainActor.assumeIsolated { OwnDock.shared.pollPointer() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func wake() {
        if let ticker, ticker.paused {
            lastTick = 0
            ticker.paused = false
        }
    }

    // MARK: Pointer

    private func local(_ mouse: NSPoint) -> CGPoint {
        guard let frame = panel?.frame else { return .zero }
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    /// Everything the pointer can touch right now, in panel coordinates.
    private func activeZone() -> CGRect {
        let scene = stage.scene
        let grow = (appearance.hoverLift ? metrics.rise : max(large - tile, 0)) * scene.ramp + 12
        var zone = scene.bar.insetBy(dx: -10, dy: -10)
        switch placedEdge {
        case .bottom: zone.origin.y -= grow; zone.size.height += grow
        case .top: zone.size.height += grow
        case .left: zone.size.width += grow
        case .right: zone.origin.x -= grow; zone.size.width += grow
        }
        return zone
    }

    /// Over the visible dock. A hidden dock must never catch a click.
    private func pointerInside(_ mouse: NSPoint) -> Bool {
        guard !autoHide || revealed else { return false }
        let point = local(mouse)
        return activeZone().contains(point) || overCard(point) || overDone(point)
    }

    /// The window-picture card is up and the pointer is on it.
    private func overCard(_ point: CGPoint) -> Bool {
        guard let peek = stage.peek, !peek.thumbs.isEmpty, field.peekTarget, stage.scene.peekShow > 0.5 else { return false }
        return DockPeekLayout.frame(count: peek.thumbs.count, scene: stage.scene).insetBy(dx: -6, dy: -6).contains(point)
    }

    private func overDone(_ point: CGPoint) -> Bool {
        arranging && DockArrangeLayout.frame(stage.scene).insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Is the pointer on the strip of screen that wakes a hidden dock?
    private func onEdgeStrip(_ mouse: NSPoint) -> Bool {
        guard let screen = currentScreen else { return false }
        let full = screen.frame, area = screen.visibleFrame, bar = stage.scene.bar
        guard let frame = panel?.frame else { return false }
        let horizontal = mouse.x >= frame.minX + bar.minX - 40 && mouse.x <= frame.minX + bar.maxX + 40
        let vertical = mouse.y >= frame.maxY - bar.maxY - 40 && mouse.y <= frame.maxY - bar.minY + 40
        switch placedEdge {
        case .bottom: return horizontal && mouse.y <= full.minY + 3 && mouse.y >= full.minY
        case .top: return horizontal && mouse.y >= area.maxY - 3 && mouse.y <= full.maxY
        case .left: return vertical && mouse.x <= full.minX + 3 && mouse.x >= full.minX
        case .right: return vertical && mouse.x >= full.maxX - 3 && mouse.x <= full.maxX
        }
    }

    /// In Follows Pointer, the dock moves when the pointer presses against the dock's edge
    /// of another display, the way the macOS Dock does.
    private func followPointer(_ mouse: NSPoint) {
        guard display == .pointer, NSScreen.screens.count > 1,
              let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              target.localizedName != currentScreen?.localizedName else { return }
        let full = target.frame, area = target.visibleFrame
        let pressed: Bool = switch edge(for: target) {
        case .bottom: mouse.y <= full.minY + 2
        case .top: mouse.y >= area.maxY - 2
        case .left: mouse.x <= full.minX + 2
        case .right: mouse.x >= full.maxX - 2
        }
        guard pressed else { return }
        pointerScreen = target.localizedName
        show()
    }

    /// Cheap, always running while the dock is on: decides whether the display link should be.
    private func pollPointer() {
        let mouse = NSEvent.mouseLocation
        let moved = mouse != lastMouse
        lastMouse = mouse
        if moved { followPointer(mouse) }
        let inside = pointerInside(mouse)
        if inside == (panel?.ignoresMouseEvents ?? true) { panel?.ignoresMouseEvents = !inside }
        // Also while a card is up: the pointer may leave the panel in one jump between frames
        // (a fast exit, the screen edge, a Space switch) and the card must still go.
        if inside ? moved : autoHide && (revealed || onEdgeStrip(mouse)) || field.peekTarget && (moved || !inside) { wake() }
    }

    private func updateHide(_ mouse: NSPoint, inside: Bool) {
        guard autoHide else { return }
        let held = menuOpen || pressID != nil || bubble.isOpen || field.dragID != nil || keyboardActive
        let was = revealed
        if !revealed {
            if onEdgeStrip(mouse) {
                let dwell = NSEvent.pressedMouseButtons != 0 ? 0 : placedEdge == .top ? max(hub.revealDelay, 0.3) : hub.revealDelay
                if let since = edgeSince {
                    if Date().timeIntervalSince(since) >= dwell { revealed = true; awaySince = nil }
                } else {
                    edgeSince = Date()
                }
            } else {
                edgeSince = nil
            }
        } else if inside || held {
            awaySince = nil
        } else if let since = awaySince {
            if Date().timeIntervalSince(since) > hub.hideDelay { revealed = false; edgeSince = nil }
        } else {
            awaySince = Date()
        }
        field.hideTarget = revealed ? 0 : 1
        if revealed != was {
            // Badges are read only while the dock can be seen, and at once when it comes back.
            reader.active = revealed
            if revealed { reader.poll() }
        }
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTick == 0 ? 1.0 / 60 : now - lastTick
        lastTick = now
        let mouse = NSEvent.mouseLocation
        let point = local(mouse)
        let inside = pointerInside(mouse) || menuOpen
        if panel?.ignoresMouseEvents != !(inside || pressID != nil) { panel?.ignoresMouseEvents = !(inside || pressID != nil) }

        updateHide(mouse, inside: inside)
        expireLaunches()

        let onCard = overCard(point)
        if keyboardActive, let focus = field.focusID,
           let tile = stage.scene.tiles.first(where: { $0.id == focus }) {
            // The keyboard steers the lens: it opens on the chosen tile.
            field.hovering = true
            field.pointer = (tile.span.lowerBound + tile.span.upperBound) / 2
        } else if onCard {
            // On the window card the lens stays on the tile the card belongs to.
            field.hovering = true
            field.pointer = field.peekAlongTarget ?? field.pointer
            let hot = stage.peek.flatMap { DockPeekLayout.hit(point, count: $0.thumbs.count, scene: stage.scene) }
            if stage.peekHot != hot { stage.peekHot = hot }
        } else {
            field.hovering = inside && !menuOpen
            field.pointer = placedEdge.horizontal ? Double(point.x) : Double(point.y)
        }
        if !onCard, stage.peekHot != nil { stage.peekHot = nil }
        OwnDockGestures.shared.pointer(onCard ? point : nil)
        if field.dragID != nil { updateDrag(point) }
        if arranging {
            let armed = inside && field.dragID == nil ? tileAt(point).flatMap { removable($0.slot) ? $0.id : nil } : nil
            if armed != field.armedID { field.armedID = armed }
        }
        field.step(elapsed, metrics)
        let scene = field.scene(metrics)
        stage.scene = scene
        if !onCard {
            updatePeek(point, inside: inside && pressID == nil && field.dragID == nil && !arranging, scene: scene)
        }

        // Sit still with the pointer still. The poll timer wakes the link on the next move.
        // A card that is up keeps the link running: leaving the tile starts a short countdown
        // that only a tick can finish, and a paused link left the card stuck on screen.
        let waiting = (hoverID != nil && !field.peekTarget) || peekLeft != nil
        if field.settled(), mouse == tickMouse, !waiting, pressID == nil, !bubble.isOpen {
            ticker?.paused = true
        }
        tickMouse = mouse
    }

    private func tileAt(_ point: CGPoint) -> DockTile? {
        let scene = stage.scene
        guard activeZone().contains(point) else { return nil }
        let along = placedEdge.horizontal ? Double(point.x) : Double(point.y)
        return scene.tiles.first { $0.span.contains(along) && $0.slot.kind != .divider && $0.slot.kind != .section }
    }

    /// What Arrange mode can take off the bar: anything kept, apart from the separators.
    private func removable(_ slot: DockSlot) -> Bool {
        slot.pinned && slot.kind != .section && slot.kind != .divider
    }

    // MARK: Peek

    private func updatePeek(_ point: CGPoint, inside: Bool, scene: DockScene) {
        if OwnDockGestures.shared.holdsPeek(inside: inside) { return }
        let hover = appearance.hover
        let hit: DockTile?
        if keyboardActive {
            hit = scene.tiles.first { $0.id == field.focusID && !$0.slot.empty }
        } else {
            hit = inside && hover != .none ? tileAt(point) : nil
        }
        // On the way up to a window picture the pointer crosses the neighbours' lens: the
        // card stays with its own app until the pointer is back down on the bar.
        if inside, !keyboardActive, field.peekTarget, stage.peek?.thumbs.isEmpty == false, beyondBar(point, scene) {
            peekLeft = nil
            return
        }
        if let hit, hit.id == hoverOpened {
            return
        } else if hoverOpened != nil, hit?.id != hoverOpened {
            hoverOpened = nil
        }
        guard let hit, !hit.slot.empty, !bubble.isOpen else {
            hoverID = nil
            if field.peekTarget {
                if peekLeft == nil { peekLeft = Date() }
                if let left = peekLeft, Date().timeIntervalSince(left) > 0.12 {
                    field.peekTarget = false
                    peekLeft = nil
                }
            }
            return
        }
        peekLeft = nil
        field.peekAlongTarget = (hit.span.lowerBound + hit.span.upperBound) / 2
        field.peekID = hit.id
        let labelOnly = hover == .label || keyboardActive
        if hit.id != hoverID {
            hoverID = hit.id
            hoverSince = Date()
            // Once a card is up, moving along the bar changes it at once.
            if field.peekTarget { present(hit.slot, label: labelOnly) }
        } else if !keyboardActive, let delay = hoverOpenDelay(hit.slot), Date().timeIntervalSince(hoverSince) > delay {
            // Open on Hover: resting on the tile opens it, once, until the pointer moves on.
            hoverOpened = hit.id
            field.peekTarget = false
            click(hit.id)
        } else if !field.peekTarget, Date().timeIntervalSince(hoverSince) > (labelOnly ? 0.06 : 0.3) {
            present(hit.slot, label: labelOnly)
            field.peekTarget = true
        }
    }

    private func beyondBar(_ point: CGPoint, _ scene: DockScene) -> Bool {
        let bar = scene.bar
        switch scene.edge {
        case .bottom: return point.y < bar.minY - 6
        case .top: return point.y > bar.maxY + 6
        case .left: return point.x > bar.maxX + 6
        case .right: return point.x < bar.minX - 6
        }
    }

    /// While a window Atelier opened from the dock (the icon picker) is up, no card opens over it.
    private(set) var peekHeld = false

    func holdPeek(_ on: Bool) {
        peekHeld = on
        guard on else { return }
        peekTask?.cancel()
        peekTask = nil
        field.peekTarget = false
        if stage.peek != nil { stage.peek = nil }
    }

    private func present(_ slot: DockSlot, label: Bool) {
        guard !peekHeld else { return }
        peekRequest += 1
        let request = peekRequest
        peekTask?.cancel()
        peekTask = nil
        if stage.peekHot != nil { stage.peekHot = nil }
        var peek = DockPeek(id: slot.id, title: slot.title, status: "", path: slot.icon ?? slot.path)
        if label {
            guard !slot.empty else { return }
            peek.label = true
            stage.peek = peek
            return
        }
        switch slot.kind {
        case .vitals:
            peek.status = "This Mac right now"
            peek.path = ""
            peek.vitals = true
        case .stack:
            if let document = try? StackStore.load(URL(fileURLWithPath: slot.path)) {
                peek.items = AppCatalog.shared.items(for: document.rule, fallback: document.items)
                peek.title = slot.title == OwnDockItem(kind: .stack, path: slot.path).title ? document.title : slot.title
                peek.status = peek.items.count == 1 ? "1 item" : "\(peek.items.count) items"
            } else {
                peek.status = "Stack"
            }
        case .smart:
            peek.path = ""
            let source = smart[slot.id]?.source
            peek.status = (source?.title ?? "Smart Stack") + ". Click to see what it holds."
            if let stack = smart[slot.id], [.recentApps, .recentlyInstalled, .running].contains(stack.source) {
                peek.items = Array(AppCatalog.shared.items(for: stack.source == .recentApps ? .recentlyUsed
                    : stack.source == .running ? .running : .recentlyInstalled, fallback: []).prefix(6))
            }
        case .section:
            return
        case .file:
            peek.status = "Click to open"
        case .folder:
            // Never listed on hover: that could ask for folder access the user did not mean to give.
            peek.status = "Folder. Click for its newest items."
        case .trash:
            peek.status = slot.full ? "Holds items" : "Empty"
        case .clock:
            peek.title = feed.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            peek.status = feed.now.formatted(.dateTime.hour().minute()) + ". Click for Calendar."
        case .battery:
            if let battery = feed.battery {
                var parts = ["\(Int((battery.level * 100).rounded()))%"]
                if battery.charging { parts.append("charging") } else if battery.plugged { parts.append("on power") }
                if let minutes = battery.minutesLeft {
                    parts.append(String(format: "%d:%02d %@", minutes / 60, minutes % 60, battery.charging ? "to full" : "left"))
                }
                peek.status = parts.joined(separator: ", ")
            } else {
                peek.status = "No battery in this Mac"
            }
        case .downloads:
            let state = feed.downloads
            if state.count == 0 {
                peek.status = "Nothing downloading. Click for the newest files."
            } else {
                let share = state.progress.map { ", \(Int(($0 * 100).rounded()))%" } ?? ""
                peek.status = (state.count == 1 ? "1 download" : "\(state.count) downloads") + share
                peek.rows = state.names
            }
        case .clipboard:
            if let clip = feed.clip {
                peek.status = "Click to copy it again"
                peek.rows = [String(clip.prefix(160))]
            } else {
                peek.status = "Copy some text and it shows here"
            }
        case .orbit:
            peek.status = "Click to open Orbit"
        case .window:
            let app = runningApps().first { $0.processIdentifier == slot.pid }
            peek.status = "Minimised" + (app?.localizedName.map { " · " + $0 } ?? "") + ". Click to bring it back."
        case .divider, .spacer, .spacerLarge:
            return
        case .app:
            let shown = describeApp(slot, into: &peek)
            if let badge = slot.badge { peek.status = "\(badge) new · " + peek.status }
            if slot.attention { peek.status = "Asks for attention · " + peek.status }
            if slot.recent { peek.status = "Recently used" }
            let pid = runningApps().first(where: { $0.bundleURL?.path == slot.path })?.processIdentifier
            if let pid, options[slot.id]?.quickActions ?? true { contents.prefetchCommands(pid) }
            // Window Previews: pictures with Screen Recording; without it, each window's icon
            // and its Accessibility title. Neither hangs on Dock Gestures being on.
            let pictures = DockWindowShots.shared.allowed
            if let pid, hub.windowPreviews, pictures || AXIsProcessTrusted() {
                previewWindows(pid: pid, shown: shown, request: request, peek: &peek)
            } else if peek.rows.isEmpty, slot.running, AXIsProcessTrusted(), let pid {
                Task.detached(priority: .userInitiated) {
                    let titles = DockAX.windows(pid).map { $0.minimized ? $0.title + " (minimised)" : $0.title }
                    await MainActor.run {
                        guard OwnDock.shared.peekRequest == request, !titles.isEmpty else { return }
                        OwnDock.shared.stage.peek?.rows = titles
                    }
                }
            }
            // Say why there are no pictures, rather than leave the card quietly plainer.
            if hub.windowPreviews, slot.running, peek.thumbs.isEmpty, !pictures {
                peek.note = AXIsProcessTrusted() ? "Window pictures need Screen Recording."
                    : "Window pictures need Screen Recording, titles need Accessibility."
            }
        }
        stage.peek = peek
    }

    /// The app's windows on this desktop, front to back, for Window Previews.
    private struct ShownWindow {
        var id: CGWindowID
        var title: String
        var frame: CGRect
    }

    /// Window Previews: the card lists the windows at once, and each picture arrives as it is
    /// taken. Minimised windows come from Accessibility, with a picture if one can be taken.
    private func previewWindows(pid: pid_t, shown: [ShownWindow], request: Int, peek: inout DockPeek) {
        let shots = DockWindowShots.shared
        peek.thumbs = shown.prefix(DockPeekLayout.most).map {
            DockThumb(id: $0.id, title: $0.title.isEmpty ? peek.title : $0.title, minimized: false,
                      aspect: $0.frame.width / max($0.frame.height, 1), image: shots.cached($0.id))
        }
        if peekPID != pid { peekRefs = [:] }
        peekPID = pid
        let trusted = AXIsProcessTrusted()
        let pixels = Int(DockPeekLayout.cell.width * (currentScreen?.backingScaleFactor ?? 2))
        peekTask = Task { @MainActor in
            if trusted {
                let found = await Task.detached(priority: .userInitiated) { () -> [(AXRef, String, Bool, CGWindowID?)] in
                    DockAX.windows(pid).map { ($0.ref, $0.title, $0.minimized, DockAX.windowID($0.ref)) }
                }.value
                guard !Task.isCancelled, OwnDock.shared.peekRequest == request else { return }
                let dock = OwnDock.shared
                for (ref, _, _, id) in found { if let id { dock.peekRefs[id] = ref } }
                var thumbs = dock.stage.peek?.thumbs ?? []
                if !DockWindowShots.shared.allowed { thumbs = OwnDockGestures.titled(thumbs, from: found) }
                let room = DockPeekLayout.most - thumbs.count
                if room > 0 {
                    let minimised = found.filter { $0.2 }.prefix(room)
                    thumbs += minimised.enumerated().map { index, window in
                        DockThumb(id: window.3 ?? CGWindowID(UInt32.max - UInt32(index)), title: window.1, minimized: true,
                                  aspect: 1.5, image: window.3.flatMap { shots.cached($0) })
                    }
                }
                if dock.stage.peek?.thumbs != thumbs { dock.stage.peek?.thumbs = thumbs }
            }
            guard let ids = OwnDock.shared.stage.peek?.thumbs.map(\.id), !Task.isCancelled else { return }
            await shots.capture(ids.filter { $0 < UInt32.max - 16 }, width: pixels) { id, image in
                let dock = OwnDock.shared
                guard dock.peekRequest == request, var peek = dock.stage.peek,
                      let index = peek.thumbs.firstIndex(where: { $0.id == id }) else { return }
                peek.thumbs[index].image = image
                peek.thumbs[index].aspect = image.size.width / max(image.size.height, 1)
                dock.stage.peek = peek
            }
            // Refused after all (the grant has not reached this process): draw the card again,
            // so the cells show icons and titles instead of waiting for pictures.
            if !shots.allowed, OwnDock.shared.peekRequest == request, OwnDock.shared.stage.peek != nil {
                OwnDock.shared.stage.objectWillChange.send()
            }
        }
    }

    /// Raises the window whose picture was clicked.
    private func raiseThumb(_ index: Int) {
        guard let peek = stage.peek, peek.thumbs.indices.contains(index) else { return }
        let thumb = peek.thumbs[index]
        let slot = DockSlot(id: peek.id, kind: .app, path: peek.path, running: true)
        field.peekTarget = false
        open(app: slot)
        guard let ref = peekRefs[thumb.id] else { return }
        let pid = peekPID
        Task.detached(priority: .userInitiated) {
            DockAX.raise(ref)
            await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
        }
    }

    @discardableResult
    private func describeApp(_ slot: DockSlot, into peek: inout DockPeek) -> [ShownWindow] {
        guard slot.running, let app = runningApps().first(where: { $0.bundleURL?.path == slot.path }) else {
            peek.status = slot.launching ? "Opening" : "Not running"
            return []
        }
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = listed.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        let frames = windows.compactMap { window -> CGRect? in
            guard let box = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: box as CFDictionary), rect.height > 40 else { return nil }
            return rect
        }
        peek.rows = windows.compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
        // The display the app's front window is on, not always the main one: with two displays
        // a window on the second would otherwise be drawn off the edge of the little map.
        var display = CGMainDisplayID(), found: UInt32 = 0
        if let first = frames.first {
            var hit: CGDirectDisplayID = 0
            if CGGetDisplaysWithPoint(CGPoint(x: first.midX, y: first.midY), 1, &hit, &found) == .success, found > 0 { display = hit }
        }
        let desktop = CGDisplayBounds(display)
        peek.aspect = desktop.width / max(desktop.height, 1)
        peek.windows = frames.filter { $0.intersects(desktop) }.map {
            CGRect(x: ($0.minX - desktop.minX) / desktop.width, y: ($0.minY - desktop.minY) / desktop.height,
                   width: $0.width / desktop.width, height: $0.height / desktop.height)
        }
        if app.isHidden {
            peek.status = "Hidden"
        } else if frames.isEmpty {
            peek.status = "Running, no windows on this desktop"
        } else {
            peek.status = frames.count == 1 ? "1 window on this desktop" : "\(frames.count) windows on this desktop"
        }
        return windows.compactMap { window -> ShownWindow? in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let box = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: box as CFDictionary), rect.height > 40, rect.width > 60 else { return nil }
            return ShownWindow(id: CGWindowID(number.uint32Value), title: window[kCGWindowName as String] as? String ?? "", frame: rect)
        }
    }

    /// True when window titles can be read without asking the user for anything.
    var windowTitlesAvailable: Bool { AXIsProcessTrusted() || CGPreflightScreenCaptureAccess() }

    // MARK: Launching

    private func launched(_ path: String?) {
        slotCache = nil
        guard let path, enabled else { return }
        let now = Date()
        launchedAt = launchedAt.filter { now.timeIntervalSince($0.value) < 60 }
        launchedAt[resolved(path)] = now
        // The tile's path and the one the app runs from can differ (a symlink, Safari's
        // Cryptex copy): the tile that was opening stops whichever path named it.
        let opened = OwnDockBounce.sameApp(Array(launching.keys), as: path, resolve: resolved)
        opened.forEach { launching[$0] = nil }
        let waiting = !opened.isEmpty
        field.sync(slots())
        // One tile, the app's own: found by resolved path, as its id may be the kept path.
        let key = resolved(path)
        let id = field.slots.first { $0.kind == .app && ($0.path == path || resolved($0.path) == key) }?.id ?? path
        field.ignite(id, tile: field.fitted(metrics).tile)
        if !waiting, appearance.bounce { field.pulse(id, strength: 0.6, tile: field.fitted(metrics).tile) }
        if waiting { DockSounds.play(.launch, prefs: design) }
        wake()
    }

    private func expireLaunches() {
        let stale = launching.filter { Date().timeIntervalSince($0.value) > 20 }
        guard !stale.isEmpty else { return }
        stale.keys.forEach { launching[$0] = nil }
        refresh()
    }

    // MARK: Keyboard

    func toggleKeyboardFocus() {
        keyboardActive ? endKeyboard() : beginKeyboard()
    }

    /// The tiles the keyboard can land on, in order along the bar.
    private func selectable() -> [DockSlot] {
        field.slots.filter { !$0.empty && (field.bodies[$0.id]?.appearTarget ?? 1) > 0 }
    }

    private func beginKeyboard() {
        guard enabled, let panel else { return }
        keyboardActive = true
        query = ""
        field.matches = nil
        let choices = selectable()
        field.focusID = choices.first(where: \.frontmost)?.id ?? choices.first?.id
        revealed = true
        reader.active = true
        field.hideTarget = 0
        stage.query = ""
        panel.makeKey()
        if let input { panel.makeFirstResponder(input) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        wake()
    }

    func endKeyboard() {
        guard keyboardActive else { return }
        keyboardActive = false
        field.focusID = nil
        field.matches = nil
        field.peekTarget = false
        stage.query = nil
        hoverID = nil
        // Hand the keyboard back to the app in front.
        if let panel, panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        wake()
    }

    /// Keys while the dock has keyboard focus. False for keys it leaves alone.
    fileprivate func key(_ event: NSEvent) -> Bool {
        guard keyboardActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            if query.isEmpty { endKeyboard() } else { setQuery("") }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let id = field.focusID else { return true }
            endKeyboard()
            click(id, modifiers: flags)
        case kVK_LeftArrow, kVK_UpArrow:
            move(-1)
        case kVK_RightArrow, kVK_DownArrow:
            move(1)
        case kVK_Tab:
            move(flags.contains(.shift) ? -1 : 1)
        case kVK_Delete:
            if !query.isEmpty { setQuery(String(query.dropLast())) }
        default:
            guard !flags.contains(.command), !flags.contains(.control),
                  let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            if text == " ", query.isEmpty { return true }
            setQuery(query + text)
        }
        return true
    }

    private func move(_ step: Int) {
        var choices = selectable()
        if let matches = field.matches, !matches.isEmpty { choices = choices.filter { matches.contains($0.id) } }
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex { $0.id == field.focusID } ?? (step > 0 ? -1 : 0)
        field.focusID = choices[(index + step + choices.count) % choices.count].id
        wake()
    }

    private func setQuery(_ text: String) {
        query = text
        stage.query = text
        defer { wake() }
        guard !text.isEmpty else { field.matches = nil; return }
        let hits = selectable().filter { $0.title.localizedStandardContains(text) }
        field.matches = Set(hits.map(\.id))
        let lower = text.lowercased()
        if let best = hits.first(where: { $0.title.lowercased().hasPrefix(lower) }) ?? hits.first {
            field.focusID = best.id
        }
    }

    // MARK: Actions

    fileprivate func click(_ id: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let slot = field.slots.first(where: { $0.id == id }) else { return }
        if modifiers.contains(.command), !slot.path.isEmpty, slot.kind != .trash {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.path)])
            return
        }
        let option = options[id]
        if let option, option.click != .standard {
            if runClickAction(option, slot: slot) { return }
        }
        switch slot.kind {
        case .app where runningApp(slot.path)?.processIdentifier == ProcessInfo.processInfo.processIdentifier:
            // Atelier's own tile never hides Atelier: that would take its Dock, widgets and
            // effects off the screen with it. It opens the Studio, or closes it to the menu bar.
            ManagerWindow.shared.toggle()
        case .app:
            if modifiers.contains(.option) {
                open(app: slot)
                hideOthers(except: slot.path)
            } else if appearance.clickToHide, slot.frontmost, let app = runningApp(slot.path), !app.isHidden {
                app.hide()
            } else {
                open(app: slot)
            }
        case .stack:
            showStack(slot)
        case .smart:
            showSmart(slot)
        case .section:
            break
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: slot.path))
        case .folder: showFolder(slot)
        case .trash: NSWorkspace.shared.open(TrashWatcher.url)
        case .vitals: DockVitalsSettings.shared.click()
        case .window: restore(slot)
        case .clock:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            field.pulse(id, strength: 0.3, tile: field.fitted(metrics).tile)
            wake()
        case .battery:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        case .downloads:
            var folder = slot
            folder.path = OwnDockFeed.downloadsFolder.path
            folder.title = "Downloads"
            showFolder(folder)
        case .clipboard:
            guard feed.clip != nil else { NSSound.beep(); return }
            feed.copyClipAgain()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            field.pulse(id, strength: 0.35, tile: field.fitted(metrics).tile)
            wake()
        case .orbit:
            Orbit.shared.toggle()
        case .divider, .spacer, .spacerLarge: break
        }
    }

    /// A tile's own click action. False when there is nothing to do, so the standard one runs.
    private func runClickAction(_ option: DockTileOptions, slot: DockSlot) -> Bool {
        let target = option.target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch option.click {
        case .standard:
            return false
        case .finder:
            let path = slot.kind == .downloads ? OwnDockFeed.downloadsFolder.path : slot.path
            guard !path.isEmpty else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .url:
            guard let url = URL(string: target), url.scheme != nil else { return false }
            if slot.kind == .app, !slot.path.isEmpty {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: slot.path),
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        case .app:
            guard target.hasSuffix(".app"), FileManager.default.fileExists(atPath: target) else { return false }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target), configuration: NSWorkspace.OpenConfiguration())
        }
        field.pulse(slot.id, strength: 0.3, tile: field.fitted(metrics).tile)
        wake()
        return true
    }

    /// How long the pointer rests before the tile opens by itself, or nil when it doesn't.
    private func hoverOpenDelay(_ slot: DockSlot) -> Double? {
        switch slot.kind {
        case .smart:
            guard let style = smart[slot.id]?.style, style.hoverOpen else { return nil }
            return style.hoverDelay
        case .stack:
            let style: StackStyle
            if let known = stackStyles[slot.id] {
                style = known
            } else {
                style = (try? StackStore.load(URL(fileURLWithPath: slot.path)))?.style ?? StackStyle()
                stackStyles[slot.id] = style
            }
            return style.hoverOpen ? style.hoverDelay : nil
        case .folder, .downloads:
            return options[slot.id]?.openOnHover == true ? 0.35 : nil
        default:
            return nil
        }
    }

    /// A Smart Stack's own icon, drawn once into Application Support. The file is named
    /// after what it shows, so a change makes a new file and nothing stale is drawn.
    static func smartIcon(_ spec: IconSpec, title: String) -> String? {
        let data = (try? JSONEncoder().encode(spec)) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data + Data(title.utf8) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let file = DockCustomStore.folder.appendingPathComponent("smart-\(String(hash, radix: 16)).png")
        if FileManager.default.fileExists(atPath: file.path) { return file.path }
        let image = IconRenderer.image(spec, title: title, items: [])
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: DockCustomStore.folder, withIntermediateDirectories: true)
        return (try? png.write(to: file, options: .atomic)) == nil ? nil : file.path
    }

    /// Tile options that used to set a stack's layout, sort and hover move into the stack's
    /// own style, once, so one place decides. Plain values for smart stacks; the document
    /// for a `.dockstack`. Returns whether anything moved.
    static func migrateStackOptions(items: [OwnDockItem], options: inout [String: DockTileOptions],
                                    smart: inout [String: DockSmartStack]) -> Bool {
        var moved = false
        for item in items where item.kind == .smart || item.kind == .stack {
            guard var option = options[item.id], option.layout != nil || option.openOnHover || item.kind == .stack && option.sort != .added
            else { continue }
            if item.kind == .smart, var stack = smart[item.id] {
                if let layout = option.layout { stack.style.layout = layout }
                if option.openOnHover { stack.style.hoverOpen = true }
                smart[item.id] = stack
            } else if item.kind == .stack {
                let url = URL(fileURLWithPath: item.path)
                guard var document = try? StackStore.load(url) else { continue }
                if let layout = option.layout { document.style.layout = layout }
                if option.openOnHover { document.style.hoverOpen = true }
                switch option.sort {
                case .name: document.style.sort = .name
                case .kind: document.style.sort = .kind
                default: break
                }
                guard (try? StackStore.save(document, to: url)) != nil else { continue }
            }
            option.layout = nil
            option.openOnHover = false
            option.sort = .added
            options[item.id] = option.isDefault ? nil : option
            moved = true
        }
        return moved
    }

    /// A stack opens with its own style. A smart one fills itself first.
    private func showStack(_ slot: DockSlot) {
        let url = URL(fileURLWithPath: slot.path)
        if bubble.isShowing(url) { bubble.close(); return }
        guard let document = try? StackStore.load(url) else { NSSound.beep(); return }
        field.pulse(slot.id, strength: 0.3, tile: field.fitted(metrics).tile)
        wake()
        let id = slot.id
        Task { @MainActor in
            var items = document.items
            if let smart = document.smart {
                let limit = document.style.limit > 0 ? document.style.limit : 60
                items = await StackFill.items(smart, limit: limit, sort: document.style.sort)
            }
            OwnDock.shared.present(url, id: id, title: document.title, items: items, style: document.style)
        }
    }

    /// A smart stack fills itself as it opens.
    private func showSmart(_ slot: DockSlot) {
        guard let stack = smart[slot.id] else { return }
        let url = URL(fileURLWithPath: "/atelier-smart/" + slot.id)
        if bubble.isShowing(url) { bubble.close(); return }
        field.pulse(slot.id, strength: 0.3, tile: field.fitted(metrics).tile)
        wake()
        let id = slot.id
        Task { @MainActor in
            let found = await DockHubContents.shared.items(for: stack)
            guard !found.isEmpty else {
                NSSound.beep()
                if stack.source == .folder || stack.source == .downloads {
                    NSWorkspace.shared.open(stack.source == .downloads ? OwnDockFeed.downloadsFolder : URL(fileURLWithPath: stack.folder))
                }
                return
            }
            OwnDock.shared.present(url, id: id, title: stack.name, items: found, style: stack.style)
        }
    }

    /// Opens the bubble over a tile that is still on the bar.
    private func present(_ url: URL, id: String, title: String, items: [StackItem], style: StackStyle) {
        guard let tile = stage.scene.tiles.first(where: { $0.id == id }), let screen = currentScreen else { return }
        bubble.show(url, title: title, items: items, style: style, tile: screenRect(of: tile), edge: placedEdge, screen: screen,
                    tint: stage.theme.tint == nil ? nil : stage.theme.accent)
    }

    /// A folder's or Downloads' bubble, from the tile's own options.
    static func folderStyle(_ option: DockTileOptions?) -> StackStyle {
        var style = StackStyle()
        style.layout = option?.layout ?? .grid
        style.hoverOpen = option?.openOnHover ?? false
        return style
    }

    private func hideOthers(except path: String) {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in runningApps() where app.bundleURL?.path != path && app.processIdentifier != me && !app.isHidden {
            app.hide()
        }
    }

    /// Brings a minimised window back and its app forward.
    private func restore(_ slot: DockSlot) {
        guard let window = minimized.windows.first(where: { $0.id == slot.id }) else { return }
        let ref = window.ref, pid = window.pid
        // A window Atelier minimised into this dock flies back out of its tile, this window
        // only (opening the app first would bring back its newest one too), and its app comes
        // forward when it lands. Shift held is slow motion, as in macOS.
        if MinimizeRedirect.shared.holds(ref.element),
           MinimizeRedirect.shared.restore(ref.element, slow: NSEvent.modifierFlags.contains(.shift)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MinimizedWatcher.shared.dirty(pid) }
            return
        }
        open(app: DockSlot(id: window.appPath, kind: .app, path: window.appPath, running: true))
        Task.detached(priority: .userInitiated) {
            DockAX.raise(ref)
            await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
        }
    }

    /// The app's own New Window command, pressed through Accessibility. No keystrokes are sent.
    private func newWindow(_ slot: DockSlot) {
        guard let app = runningApp(slot.path) else { open(app: slot); return }
        let pid = app.processIdentifier
        open(app: slot)
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(150))
            if let item = DockAX.newWindowItem(pid) {
                DockAX.press(item.ref)
            } else {
                await MainActor.run { NSSound.beep() }
            }
        }
    }

    fileprivate func middleClick(_ point: CGPoint) {
        guard let hit = tileAt(point) else { return }
        switch hit.slot.kind {
        case .app: newWindow(hit.slot)
        case .window: restore(hit.slot)
        default: click(hit.id)
        }
    }

    /// Scrolling on an app's icon walks through its windows.
    fileprivate func scroll(_ point: CGPoint, event: NSEvent) {
        if OwnDockGestures.shared.scroll(event, slot: gestureSlot(at: point)) { return }
        guard appearance.scrollWindows, event.momentumPhase.isEmpty, AXIsProcessTrusted(),
              let hit = tileAt(point), hit.slot.kind == .app, let app = runningApp(hit.slot.path) else { return }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        if scrollID != hit.id || event.phase == .began { scrollID = hit.id; scrollTravel = 0 }
        scrollTravel += delta
        let threshold = event.hasPreciseScrollingDeltas ? 26.0 : 0.9
        guard abs(scrollTravel) >= threshold, Date().timeIntervalSince(lastScrollStep) > 0.16 else { return }
        let forward = scrollTravel < 0
        scrollTravel = 0
        lastScrollStep = Date()
        let pid = app.processIdentifier
        if !hit.slot.frontmost || app.isHidden { open(app: hit.slot) }
        Task.detached(priority: .userInitiated) {
            if !DockAX.cycle(pid, forward: forward) { await MainActor.run { NSSound.beep() } }
        }
        field.pulse(hit.id, strength: 0.12, tile: field.fitted(metrics).tile)
        wake()
    }

    /// A folder opens like the Dock's stacks: its newest items in the bubble. A folder that
    /// is empty or cannot be read opens in Finder instead.
    private func showFolder(_ slot: DockSlot) {
        let url = URL(fileURLWithPath: slot.path)
        if bubble.isShowing(url) { bubble.close(); return }
        field.pulse(slot.id, strength: 0.3, tile: field.fitted(metrics).tile)
        wake()
        let path = slot.path, title = slot.title, id = slot.id
        let sort = options[id]?.sort ?? .added, style = Self.folderStyle(options[id])
        Task.detached(priority: .userInitiated) {
            let newest = sort == .added ? Self.newestItems(in: path) : DockHubContents.list(path, sort: sort, limit: 30)
            await MainActor.run {
                let dock = OwnDock.shared
                guard let newest, !newest.isEmpty,
                      let tile = dock.stage.scene.tiles.first(where: { $0.id == id }), let screen = dock.currentScreen else {
                    NSWorkspace.shared.open(url)
                    return
                }
                dock.bubble.show(url, title: title, items: newest.map(StackItem.path), style: style, tile: dock.screenRect(of: tile),
                                 edge: dock.placedEdge, screen: screen, tint: dock.stage.theme.tint == nil ? nil : dock.stage.theme.accent)
            }
        }
    }

    private nonisolated static func newestItems(in path: String) -> [String]? {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let dated = entries.map { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            return (path: entry.path, date: values?.addedToDirectoryDate ?? values?.contentModificationDate)
        }
        return DockRightSide.newest(dated, limit: 30)
    }

    /// Asks first, then lets Finder empty the Trash, so Finder deals with locked items.
    func emptyTrash() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash will be deleted right away. You can't undo this."
        let confirm = alert.addButton(withTitle: "Empty Trash")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        finder.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        finder.standardOutput = FileHandle.nullDevice
        finder.standardError = FileHandle.nullDevice
        finder.terminationHandler = { process in
            let ok = process.terminationStatus == 0
            Task { @MainActor in
                OwnDock.shared.refresh()
                guard !ok else { return }
                let failed = NSAlert()
                failed.messageText = "Finder did not empty the Trash."
                failed.informativeText = "Atelier may need permission to control Finder, in System Settings, Privacy & Security, Automation. You can also empty the Trash in Finder."
                failed.addButton(withTitle: "Open Trash")
                failed.addButton(withTitle: "Cancel")
                if failed.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(TrashWatcher.url) }
            }
        }
        do { try finder.run() } catch { NSWorkspace.shared.open(TrashWatcher.url) }
    }

    /// Where a window being minimised should fly: the slot a new window tile takes, just
    /// before the Trash (or the dock's last tile). Cocoa screen coordinates.
    /// With minimised windows not shown in the bar, the window goes into its app's own tile.
    func minimizeTarget(appPath: String? = nil) -> NSRect? {
        guard panel?.isVisible == true else { return nil }
        let tiles = stage.scene.tiles.filter { !$0.slot.empty && $0.slot.kind != .divider && $0.slot.kind != .section }
        if !appearance.minimized {
            // The app's own tile, by resolved path too (a kept tile can name a symlink). An app
            // with no tile of its own still goes into this Dock, by the right end, never to the
            // hidden macOS Dock.
            let key = appPath.map(resolved)
            if let appPath, let own = tiles.first(where: { $0.slot.kind == .app && ($0.slot.path == appPath || resolved($0.slot.path) == key) }) {
                let rect = screenRect(of: own)
                if rect.width > 0 { return rect }
            }
        }
        guard let last = tiles.last(where: { $0.slot.kind == .trash }) ?? tiles.last else { return nil }
        var rect = screenRect(of: last)
        guard rect.width > 0 else { return nil }
        let step = last.base + 4
        let before = last.slot.kind == .trash ? -1.0 : 1.0
        if stage.scene.edge.horizontal { rect.origin.x += step * before } else { rect.origin.y -= step * before }
        return rect
    }

    /// The rect a tile is drawn at right now, by its id, or nil when the bar has no such tile.
    /// Cocoa screen coordinates.
    func tileRect(id: String) -> NSRect? {
        guard panel?.isVisible == true, let tile = stage.scene.tiles.first(where: { $0.id == id }) else { return nil }
        let rect = screenRect(of: tile)
        return rect.width > 0 ? rect : nil
    }

    /// The bar shows a tile for each minimised window.
    var showsMinimizedWindows: Bool { appearance.minimized }

    private func screenRect(of tile: DockTile) -> NSRect {
        guard let frame = panel?.frame else { return .zero }
        return NSRect(x: frame.minX + tile.center.x - tile.icon / 2, y: frame.maxY - tile.center.y - tile.icon / 2,
                      width: tile.icon, height: tile.icon)
    }

    private func open(app slot: DockSlot) {
        // All its windows minimised into this tile: the newest flies back out of it.
        if slot.running, MinimizeRedirect.shared.restoreNewest(appPath: slot.path, slow: NSEvent.modifierFlags.contains(.shift)) {
            runningApp(slot.path)?.activate()
            return
        }
        // System launchers (Apps, Launchpad, Mission Control) open a system overlay and quit at
        // once: they never become a running app, so they must not bounce waiting for one.
        let launcher = Self.launcherStubs.contains(URL(fileURLWithPath: slot.path).lastPathComponent)
        if !slot.running, !launcher {
            launching[slot.path] = Date()
            field.sync(slots())
            wake()
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let option = options[slot.id] {
            // Arguments reach an app only when it starts, as with `open --args`.
            let arguments = Self.split(option.arguments)
            if !arguments.isEmpty, !slot.running { configuration.arguments = arguments }
            if let url = URL(string: option.url.trimmingCharacters(in: .whitespaces)), url.scheme != nil, option.click == .standard {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: slot.path), configuration: configuration)
                return
            }
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: slot.path), configuration: configuration) { app, error in
            let path = slot.path
            nonisolated(unsafe) let app = app
            let failed = error != nil
            Task { @MainActor in
                // Failed, or an app with no Dock presence of its own (a helper that quits at once,
                // a menu bar app): stop the bounce now, and check once more a moment later.
                @MainActor func settle() {
                    guard OwnDock.shared.launching[path] != nil else { return }
                    // Already running under another path (the tile names a symlink or the
                    // app's public copy): no launch notification will come, so stop here.
                    let already = app.map { $0.isFinishedLaunching && Date().timeIntervalSince($0.launchDate ?? .distantPast) > 2 } ?? false
                    if failed || app == nil || app?.isTerminated == true || app?.activationPolicy != .regular || already {
                        OwnDock.shared.launching[path] = nil
                        OwnDock.shared.refresh()
                    }
                }
                settle()
                try? await Task.sleep(for: .seconds(1.2))
                settle()
            }
        }
    }

    static let launcherStubs: Set<String> = ["Apps.app", "Launchpad.app", "Mission Control.app"]

    /// Launch arguments as a shell would split them: spaces separate, quotes keep together.
    static func split(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    fileprivate func mouseDown(_ point: CGPoint) {
        if keyboardActive { endKeyboard() }
        if overDone(point) {
            arranging = false
            return
        }
        if overCard(point), let peek = stage.peek {
            if OwnDockGestures.shared.cardClick(point, peek: peek, scene: stage.scene) { return }
            if let index = DockPeekLayout.hit(point, count: peek.thumbs.count, scene: stage.scene) { raiseThumb(index) }
            return
        }
        guard let hit = tileAt(point) else { return }
        if arranging, removable(hit.slot), hitsRemove(hit, point) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            field.armedID = nil
            remove(id: hit.id)
            return
        }
        pressID = hit.id
        pressPoint = point
        field.setPressed(hit.id, true)
        field.peekTarget = false
        wake()
    }

    fileprivate func mouseDragged(_ point: CGPoint) {
        guard let id = pressID else { return }
        if field.dragID == nil {
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 5,
                  let slot = field.slots.first(where: { $0.id == id }), slot.movable else { return }
            if !slot.pinned {
                items.append(OwnDockItem(kind: .app, path: slot.path))
                if let index = field.slots.firstIndex(where: { $0.id == id }) {
                    field.slots[index].pinned = true
                    field.slots[index].recent = false
                    if let divider = field.slots.firstIndex(where: { $0.kind == .divider }), divider < index {
                        field.slots.remove(at: index)
                        var moved = slot
                        moved.pinned = true
                        moved.recent = false
                        field.slots.insert(moved, at: divider)
                    }
                }
            }
            field.setPressed(id, false)
            field.dragID = id
        }
        field.dragPoint = point
        wake()
    }

    private func updateDrag(_ point: CGPoint) {
        field.dragPoint = point
        let bar = stage.scene.bar
        let pulled: Double
        switch placedEdge {
        case .bottom: pulled = bar.minY - point.y
        case .top: pulled = point.y - bar.maxY
        case .left: pulled = point.x - bar.maxX
        case .right: pulled = bar.minX - point.x
        }
        field.dragOut = pulled > tile * 1.5
        if !field.dragOut { field.reorder(using: stage.scene) }
    }

    fileprivate func mouseUp(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let id = pressID
        pressID = nil
        field.setPressed(id, false)
        if let drag = field.dragID {
            let remove = field.dragOut
            field.dragID = nil
            field.dragOut = false
            let order = field.slots.filter(\.pinned).map(\.id)
            let landed = sectionsOnBar()
            var sorted = order.compactMap { id in items.first { $0.id == id } }
            if remove { sorted.removeAll { $0.id == drag } }
            for index in sorted.indices {
                if let section = landed[sorted[index].id] { sorted[index].section = section }
            }
            items = Self.merge(items, shown: Set(order), reordered: sorted)
            persist()
            field.sync(slots())
            wake()
        } else if let id, tileAt(point)?.id == id, !arranging {
            click(id, modifiers: modifiers.intersection(.deviceIndependentFlagsMask))
        }
        wake()
    }

    /// Arrange mode: a spacer goes with a click anywhere on it; other tiles with their ×.
    private func hitsRemove(_ tile: DockTile, _ point: CGPoint) -> Bool {
        if tile.slot.spacer { return true }
        let badge = max(tile.icon * 0.36, 16)
        let corner = CGPoint(x: tile.center.x - tile.icon / 2 + badge * 0.3, y: tile.center.y - tile.icon / 2 + badge * 0.3)
        return hypot(point.x - corner.x, point.y - corner.y) <= badge * 0.75
    }

    /// Where the dragged tiles landed, and in which section: the section whose separator
    /// came last before each tile. The dock's own dividers end a section.
    private func sectionsOnBar() -> [String: UUID?] {
        var current: UUID?
        var found: [String: UUID?] = [:]
        for slot in field.slots {
            switch slot.kind {
            case .section: current = UUID(uuidString: String(slot.id.dropFirst("section:".count)))
            case .divider: current = nil
            default: if slot.pinned { found[slot.id] = current }
            }
        }
        return found
    }

    /// A file is held over the bar: the tile that would take it grows a little.
    @discardableResult
    fileprivate func dragOver(_ point: CGPoint?) -> NSDragOperation {
        let hit = point.flatMap(tileAt)
        let takes = hit.map { [.app, .stack, .trash].contains($0.slot.kind) } ?? false
        let target = takes ? hit?.id : nil
        if field.dropID != target {
            field.dropID = target
            if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            wake()
        }
        if hit?.slot.kind == .trash { return .move }
        return .copy
    }

    fileprivate func drop(_ urls: [URL], at point: CGPoint) {
        field.dropID = nil
        let hit = tileAt(point)
        if let hit, hit.slot.kind == .trash {
            NSWorkspace.shared.recycle(urls)
            if design.trash == .none { field.pulse(hit.id, strength: 0.4, tile: field.fitted(metrics).tile) }
            field.burst(hit.id, .trash)
            DockSounds.play(.trash, prefs: design)
            wake()
        } else if let hit, hit.slot.kind == .folder || hit.slot.kind == .downloads || hit.slot.empty || hit.slot.kind == .window {
            // Moving files into a folder is Finder's job; the dock does not do it.
            return
        } else if let hit, hit.slot.kind == .app, !urls.allSatisfy({ $0.pathExtension == "app" }) {
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: hit.slot.path),
                                    configuration: NSWorkspace.OpenConfiguration())
            dropped(hit.id)
        } else if let hit, hit.slot.kind == .stack,
                  let stackURL = Optional(URL(fileURLWithPath: hit.slot.path)),
                  var document = try? StackStore.load(stackURL) {
            document.items += urls.map { StackItem.path($0.path) }
            try? StackStore.save(document, to: stackURL)
            refreshContents(force: true)
            dropped(hit.id)
        } else {
            urls.forEach(add)
        }
    }

    /// A tile took a drop: it plays the drop effect.
    private func dropped(_ id: String) {
        switch design.drop {
        case .pulse: field.pulse(id, strength: 0.4, tile: field.fitted(metrics).tile)
        case .ripple, .swallow: field.burst(id, .drop)
        case .none: break
        }
        DockSounds.play(.drop, prefs: design)
        wake()
    }

    // MARK: Menus

    private func item(_ title: String, symbol: String? = nil, state: NSControl.StateValue = .off, enabled: Bool = true,
                      _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = DockMenuItem(title, state: state, symbol: symbol, handler: handler)
        item.isEnabled = enabled
        return item
    }

    private func submenu(_ title: String, symbol: String? = nil, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { holder.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    /// Keep, remove, rename and the picture: what every kept tile offers.
    private func options(for slot: DockSlot) -> NSMenuItem {
        var list: [NSMenuItem] = []
        if slot.kind == .app {
            if slot.pinned {
                list.append(item("Keep in Dock", state: .on) { OwnDock.shared.remove(id: slot.id) })
            } else {
                list.append(item("Keep in Dock") { OwnDock.shared.add(URL(fileURLWithPath: slot.path)) })
            }
        }
        if !slot.path.isEmpty {
            list.append(item("Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.path)])
            })
        }
        if slot.pinned, let kept = items.first(where: { $0.id == slot.id }), kept.section == nil {
            list.append(item(kept.rightSide ? "Move to Left Side" : "Move to Right Side", symbol: kept.rightSide ? "arrow.left" : "arrow.right") {
                OwnDock.shared.setSide(slot.id, right: !kept.rightSide)
            })
        }
        if slot.pinned {
            list.append(.separator())
            let original = items.first { $0.id == slot.id }?.title ?? slot.title
            list.append(item("Rename…", symbol: "character.cursor.ibeam") { OwnDock.shared.rename(slot.id, original: original) })
            if customs[slot.id] != nil {
                list.append(item("Use Original Icon and Name") { OwnDock.shared.resetCustom(slot.id) })
            }
            list.append(item("Tile Options…", symbol: "slider.horizontal.3") {
                ManagerWindow.shared.show(chapter: Chapter.dock.rawValue)
            })
            if slot.kind != .app {
                list.append(.separator())
                list.append(item("Remove from Dock") { OwnDock.shared.remove(id: slot.id) })
            }
        }
        return submenu("Options", list)
    }

    /// Move to Section: every section, a new one, and none.
    private func sectionMenu(for slot: DockSlot) -> NSMenuItem? {
        guard slot.pinned, let current = items.first(where: { $0.id == slot.id }) else { return nil }
        var list = sections.map { section in
            item(section.name, state: current.section == section.id ? .on : .off) { OwnDock.shared.assign(slot.id, to: section.id) }
        }
        if !list.isEmpty {
            list.append(item("No Section", state: current.section == nil ? .on : .off) { OwnDock.shared.assign(slot.id, to: nil) })
            list.append(.separator())
        }
        list.append(item("New Section…", symbol: "plus") {
            guard let name = DockCustomStore.askSectionName() else { return }
            let section = OwnDock.shared.addSection(named: name)
            OwnDock.shared.assign(slot.id, to: section.id)
        })
        return submenu("Move to Section", symbol: "square.split.2x1", list)
    }

    /// The app's own menu commands, read ahead while the pointer rested on its tile.
    private func quickActions(_ slot: DockSlot, pid: pid_t, into menu: NSMenu) {
        guard options[slot.id]?.quickActions ?? true, AXIsProcessTrusted() else { return }
        let commands = contents.cachedCommands(pid) ?? DockAX.menuCommands(pid)
        guard !commands.isEmpty else { return }
        let header = NSMenuItem.sectionHeader(title: "Quick Actions")
        menu.addItem(header)
        for command in commands {
            let ref = command.ref
            let entry = item(command.title) {
                OwnDock.shared.open(app: slot)
                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .milliseconds(120))
                    DockAX.press(ref)
                }
            }
            entry.toolTip = command.keys
            entry.title = command.title + "    " + command.keys
            menu.addItem(entry)
        }
        menu.addItem(.separator())
    }

    private func appMenu(_ slot: DockSlot, into menu: NSMenu) {
        let app = runningApp(slot.path)
        if let app {
            let pid = app.processIdentifier
            // One read of the app's windows when the menu opens, with a short timeout.
            let windows = AXIsProcessTrusted() ? DockAX.windows(pid) : []
            if !windows.isEmpty {
                for window in windows.prefix(15) {
                    let ref = window.ref
                    menu.addItem(item(window.title, symbol: window.minimized ? "minus.square" : "macwindow") {
                        OwnDock.shared.open(app: slot)
                        Task.detached(priority: .userInitiated) {
                            DockAX.raise(ref)
                            await MainActor.run { MinimizedWatcher.shared.dirty(pid) }
                        }
                    })
                }
                if windows.count > 15 {
                    menu.addItem(item("\(windows.count - 15) more windows", enabled: false) {})
                }
                menu.addItem(.separator())
            }
            if AXIsProcessTrusted() {
                menu.addItem(item("New Window", symbol: "plus.square.on.square") { OwnDock.shared.newWindow(slot) })
            }
            quickActions(slot, pid: pid, into: menu)
            if !windows.isEmpty {
                menu.addItem(item("Show All Windows", symbol: "rectangle.3.group") {
                    OwnDock.shared.open(app: slot)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        MainActor.assumeIsolated { if !DockAX.showAllWindows() { NSSound.beep() } }
                    }
                })
            }
            menu.addItem(.separator())
        } else {
            menu.addItem(item("Open", symbol: "arrow.up.forward.app") { OwnDock.shared.open(app: slot) })
            menu.addItem(.separator())
        }
        menu.addItem(options(for: slot))
        if let section = sectionMenu(for: slot) { menu.addItem(section) }
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            menu.addItem(.separator())
            menu.addItem(item(app.isHidden ? "Unhide" : "Hide") {
                if app.isHidden { app.unhide() } else { app.hide() }
            })
            menu.addItem(item("Hide Others") {
                OwnDock.shared.open(app: slot)
                OwnDock.shared.hideOthers(except: slot.path)
            })
            menu.addItem(item("Quit") { app.terminate() })
            let force = item("Force Quit") { app.forceTerminate() }
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            menu.addItem(force)
        }
    }

    /// Change Icon on every tile that shows one: apps, folders, stacks, smart stacks, the Trash
    /// and the dock's own tiles. An app's icon changes everywhere Atelier draws that app; any
    /// other tile's icon belongs to the tile.
    private func addIconItems(for slot: DockSlot, to menu: NSMenu) {
        switch slot.kind {
        case .divider, .spacer, .spacerLarge, .section, .window: return
        default: break
        }
        let title = slot.title.isEmpty ? Self.tileName(slot.kind) : slot.title
        menu.addItem(.separator())
        if slot.kind == .app, !slot.path.isEmpty {
            let path = slot.path
            menu.addItem(item("Change Icon…", symbol: "photo") {
                IconPickerPanel.show(query: title, title: "Icon for \(title)", near: NSEvent.mouseLocation,
                                     onPick: { AtelierIcons.shared.set($0, for: path) },
                                     onFile: { if let image = OwnDock.pickImageFile() { AtelierIcons.shared.set(image, for: path) } })
            })
            if AtelierIcons.shared.has(path) {
                menu.addItem(item("Use Original Icon") { AtelierIcons.shared.reset(path) })
            }
        } else {
            let id = slot.id
            menu.addItem(item("Change Icon…", symbol: "photo") {
                IconPickerPanel.show(query: title, title: "Icon for \(title)", near: NSEvent.mouseLocation,
                                     onPick: { OwnDock.shared.setIcon($0, for: id) },
                                     onFile: { OwnDock.shared.chooseIcon(for: id, title: title) })
            })
            if customs[id]?.icon != nil {
                menu.addItem(item("Use Original Icon") { OwnDock.shared.resetIcon(id) })
            }
        }
    }

    static func tileName(_ kind: DockSlot.Kind) -> String {
        switch kind {
        case .trash: "Trash"
        case .vitals: "Vitals"
        case .clock: "Clock"
        case .battery: "Battery"
        case .downloads: "Downloads"
        case .clipboard: "Clipboard"
        case .orbit: "Orbit"
        case .smart: "Smart Stack"
        default: "Tile"
        }
    }

    func hasOwnIcon(_ id: String) -> Bool { customs[id]?.icon != nil }

    /// Drops a tile's own icon, keeping its name.
    func resetIcon(_ id: String) {
        guard var custom = customs[id], let old = custom.icon else { return }
        DockIcons.forget(DockCustomStore.folder.appendingPathComponent(old).path)
        DockCustomStore.remove(old)
        custom.icon = nil
        customs[id] = custom.label == nil ? nil : custom
        persistCustoms()
        refresh()
    }

    private func menu(for slot: DockSlot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let removeTile = { menu.addItem(self.item("Remove from Dock") { OwnDock.shared.remove(id: slot.id) }) }
        defer { addIconItems(for: slot, to: menu) }
        switch slot.kind {
        case .app:
            appMenu(slot, into: menu)
        case .stack, .file, .folder:
            menu.addItem(item("Open") { OwnDock.shared.click(slot.id) })
            if slot.kind == .folder {
                menu.addItem(item("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: slot.path)) })
            }
            if slot.kind == .folder || slot.kind == .stack {
                let current = options(for: slot.id)
                menu.addItem(submenu("View As", DockStackLayout.allCases.map { layout in
                    item(layout.title, state: (current.layout ?? .grid) == layout ? .on : .off) {
                        var next = OwnDock.shared.options(for: slot.id)
                        next.layout = layout
                        OwnDock.shared.setOptions(next, for: slot.id)
                    }
                }))
                if slot.kind == .folder {
                    menu.addItem(submenu("Sort By", DockSort.allCases.map { sort in
                        item(sort.title, state: current.sort == sort ? .on : .off) {
                            var next = OwnDock.shared.options(for: slot.id)
                            next.sort = sort
                            OwnDock.shared.setOptions(next, for: slot.id)
                        }
                    }))
                }
                menu.addItem(submenu("Display As", DockFolderLook.allCases.map { look in
                    item(look.title, state: current.folderLook == look ? .on : .off) {
                        var next = OwnDock.shared.options(for: slot.id)
                        next.folderLook = look
                        OwnDock.shared.setOptions(next, for: slot.id)
                    }
                }))
            }
            menu.addItem(.separator())
            menu.addItem(options(for: slot))
            if let section = sectionMenu(for: slot) { menu.addItem(section) }
        case .smart:
            menu.addItem(item("Open") { OwnDock.shared.click(slot.id) })
            menu.addItem(item("Edit Smart Stack…") { ManagerWindow.shared.show(chapter: Chapter.stacks.rawValue) })
            menu.addItem(.separator())
            menu.addItem(options(for: slot))
            if let section = sectionMenu(for: slot) { menu.addItem(section) }
        case .section:
            break
        case .trash:
            menu.addItem(item("Open") { NSWorkspace.shared.open(TrashWatcher.url) })
            menu.addItem(item("Empty Trash…", enabled: slot.full) { OwnDock.shared.emptyTrash() })
        case .vitals:
            menu.addItem(item("Open Activity Monitor") { DockVitalsSettings.openActivityMonitor() })
            menu.addItem(item("Vitals Options…") { NavFocus.shared.open(chapter: Chapter.dock.rawValue, focus: DockOwnTilesCard.vitalsTarget) })
            menu.addItem(item("Hide Vitals") { OwnDock.shared.showVitals = false })
        case .window:
            menu.addItem(item("Bring Back", symbol: "macwindow") { OwnDock.shared.restore(slot) })
            if let app = runningApps().first(where: { $0.processIdentifier == slot.pid }), let url = app.bundleURL {
                menu.addItem(item("Show \(app.localizedName ?? "App")") {
                    OwnDock.shared.open(app: DockSlot(id: url.path, kind: .app, path: url.path, running: true))
                })
            }
        case .clock:
            menu.addItem(item("Open Calendar") { OwnDock.shared.click(slot.id) })
            menu.addItem(item("Date & Time Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") { NSWorkspace.shared.open(url) }
            })
            menu.addItem(.separator())
            removeTile()
        case .battery:
            menu.addItem(item("Battery Settings…") { OwnDock.shared.click(slot.id) })
            menu.addItem(.separator())
            removeTile()
        case .downloads:
            menu.addItem(item("Newest Downloads") { OwnDock.shared.click(slot.id) })
            menu.addItem(item("Open Downloads in Finder") { NSWorkspace.shared.open(OwnDockFeed.downloadsFolder) })
            menu.addItem(.separator())
            removeTile()
        case .clipboard:
            menu.addItem(item("Copy Again", enabled: feed.clip != nil) { OwnDock.shared.click(slot.id) })
            menu.addItem(item("Forget It", enabled: feed.clip != nil) { OwnDock.shared.feed.clearClip() })
            menu.addItem(.separator())
            removeTile()
        case .orbit:
            menu.addItem(item("Open Orbit") { Orbit.shared.toggle() })
            menu.addItem(.separator())
            removeTile()
        case .spacer, .spacerLarge:
            menu.addItem(item("Remove Spacer") { OwnDock.shared.remove(id: slot.id) })
            if let section = sectionMenu(for: slot) { menu.addItem(section) }
            menu.addItem(item("Arrange Dock", state: arranging ? .on : .off) { OwnDock.shared.arranging.toggle() })
        case .divider:
            break
        }
        if [.clock, .battery, .downloads, .clipboard, .orbit].contains(slot.kind) {
            menu.addItem(item("Tile Options…", symbol: "slider.horizontal.3") {
                ManagerWindow.shared.show(chapter: Chapter.dock.rawValue)
            })
            if let section = sectionMenu(for: slot) { menu.addItem(section) }
        }
        return menu
    }

    func addTileMenu() -> [NSMenuItem] {
        let tiles: [(OwnDockItem.Kind, String, String)] = [
            (.clock, "Clock", "clock"), (.battery, "Battery", "battery.75percent"), (.downloads, "Downloads", "arrow.down.circle"),
            (.clipboard, "Clipboard", "doc.on.clipboard"), (.orbit, "Orbit", "circle.hexagongrid"),
        ]
        var list = tiles.map { kind, title, symbol in
            item(title, symbol: symbol, state: hasTile(kind) ? .on : .off) {
                let dock = OwnDock.shared
                dock.hasTile(kind) ? dock.removeTiles(kind) : dock.addTile(kind)
            }
        }
        list.append(.separator())
        list.append(item("Small Spacer", symbol: "space") { OwnDock.shared.addTile(.spacer) })
        list.append(item("Spacer", symbol: "space") { OwnDock.shared.addTile(.spacerLarge) })
        list.append(item("Section…", symbol: "square.split.2x1") {
            if let name = DockCustomStore.askSectionName() { OwnDock.shared.addSection(named: name) }
        })
        return list
    }

    private func profileMenu() -> [NSMenuItem] {
        let profiles = OwnDockProfiles.shared
        var list = profiles.profiles.map { profile in
            item(profile.name, state: profiles.active == profile.id ? .on : .off) { OwnDockProfiles.shared.apply(profile.id) }
        }
        if !list.isEmpty { list.append(.separator()) }
        list.append(item("Save This Dock…", symbol: "square.and.arrow.down") {
            if let name = DockCustomStore.askProfileName(suggested: "Dock \(OwnDockProfiles.shared.profiles.count + 1)") {
                OwnDockProfiles.shared.saveCurrent(named: name)
            }
        })
        return list
    }

    private func barMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(submenu("Position", OwnDockEdge.allCases.map { option in
            item(option.title, state: option == placedEdge ? .on : .off) {
                let dock = OwnDock.shared
                if let name = dock.currentScreen?.localizedName, dock.edgeOverrides[name] != nil {
                    dock.edgeOverrides[name] = option
                } else {
                    dock.edge = option
                }
            }
        }))
        menu.addItem(item("Auto-hide", state: autoHide ? .on : .off) { OwnDock.shared.autoHide.toggle() })
        menu.addItem(item("Magnification", state: magnify ? .on : .off) { OwnDock.shared.magnify.toggle() })
        menu.addItem(item("Focus Mode", state: hub.focusMode ? .on : .off) { OwnDock.shared.hub.focusMode.toggle() })
        menu.addItem(.separator())
        menu.addItem(item("Arrange Dock", symbol: "square.grid.3x1.below.line.grid.1x2", state: arranging ? .on : .off) {
            OwnDock.shared.arranging.toggle()
        })
        menu.addItem(submenu("Add Tile", symbol: "plus.square", addTileMenu()))
        menu.addItem(submenu("Profiles", symbol: "square.stack", profileMenu()))
        let shortcut = DockHubHotKeys.shared.label(.focusDock).map { " (\($0))" } ?? ""
        menu.addItem(item("Keyboard Focus" + shortcut, symbol: "keyboard") {
            DispatchQueue.main.async { MainActor.assumeIsolated { OwnDock.shared.toggleKeyboardFocus() } }
        })
        menu.addItem(.separator())
        menu.addItem(item("Replace System Dock", state: replaceSystem ? .on : .off) { OwnDock.shared.replaceSystem.toggle() })
        menu.addItem(item("Dock Settings…") { ManagerWindow.shared.show(chapter: Chapter.dock.rawValue) })
        menu.addItem(item("Turn Off This Dock") { OwnDock.shared.enabled = false })
        return menu
    }

    fileprivate func contextMenu(_ point: CGPoint, event: NSEvent, view: NSView) {
        if keyboardActive { endKeyboard() }
        field.peekTarget = false
        let chosen: NSMenu
        if let hit = tileAt(point) {
            chosen = menu(for: hit.slot)
        } else {
            chosen = barMenu()
        }
        menuOpen = true
        NSMenu.popUpContextMenu(chosen, with: event, for: view)
        menuOpen = false
        wake()
    }

    /// Puts the new order of the tiles on the bar back into the full list. Items that are not
    /// on the bar right now (Open Apps Only hides them) keep their places.
    static func merge(_ items: [OwnDockItem], shown: Set<String>, reordered: [OwnDockItem]) -> [OwnDockItem] {
        var queue = reordered[...]
        var merged: [OwnDockItem] = []
        for item in items {
            if shown.contains(item.id) {
                if let next = queue.popFirst() { merged.append(next) }
            } else {
                merged.append(item)
            }
        }
        merged += queue
        return merged
    }

    // MARK: System Dock

    /// The edge the macOS Dock is on. Read only.
    static func systemDockEdge() -> OwnDockEdge {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, SystemDockPlan.domain as CFString) as? String
        return OwnDockEdge(rawValue: value ?? "bottom") ?? .bottom
    }

    /// The one place that changes the system Dock, and only for Replace System Dock.
    private func applyReplacement() {
        guard started else { return }
        let want = replacesSystemDock
        if want {
            do {
                try replacer.engage()
                replaceError = nil
            } catch {
                replaceError = "The macOS Dock's settings could not be saved, so it was left as it was."
            }
        } else if replacer.engaged {
            replacer.restore()
        }
        systemReplaced = want && replacer.engaged
        layout()
    }

    /// For `applicationWillTerminate`: puts the macOS Dock back. The switch stays on, so the
    /// next launch takes its place again.
    static func restoreOnQuit() {
        shared.replacer.restore()
        shared.systemReplaced = false
    }

    /// For launch, before anything else: finishes what a crash or an older build left. If a
    /// restore is pending and Replace System Dock should not be on, the macOS Dock comes back.
    /// If it should be on, `start` takes over.
    static func recoverAtLaunch() {
        let defaults = UserDefaults.standard
        migrateLegacyHide(defaults)
        let active = defaults.bool(forKey: Key.enabled) && defaults.bool(forKey: Key.replaceSystem)
        guard !active else { return }
        shared.replacer.restore()
        shared.systemReplaced = false
    }

    /// Builds before this one only turned on auto-hide and kept the old auto-hide value.
    /// That becomes a backup of the new kind, so the restore puts back what the user had.
    private static func migrateLegacyHide(_ defaults: UserDefaults) {
        guard defaults.object(forKey: Key.hideSystem) != nil else { return }
        let wasHidden = defaults.bool(forKey: Key.hideSystem)
        let backups = DefaultsBackupStore(defaults)
        if wasHidden, backups.load() == nil {
            let preferences = CFDockPreferences()
            preferences.synchronize()
            let before = defaults.bool(forKey: Key.systemBefore)
            var backup = SystemDockPlan.backup(preferences.value(for:))
            if let index = backup.entries.firstIndex(where: { $0.key == "autohide" }) {
                backup.entries[index].value = .bool(before)
            }
            backups.save(backup)
            defaults.set(true, forKey: Key.replaceSystem)
        }
        defaults.removeObject(forKey: Key.hideSystem)
        defaults.removeObject(forKey: Key.systemBefore)
    }
}


/// Rotation and 3D tilt for a tile, applied only when there is any.
struct OwnDockTileTurn: ViewModifier {
    let angle: Double
    let tilt: Double
    let edge: OwnDockEdge

    func body(content: Content) -> some View {
        if abs(angle) < 0.01 && abs(tilt) < 0.01 {
            content
        } else {
            content
                .rotationEffect(.degrees(angle), anchor: edge.anchor)
                .rotation3DEffect(.degrees(tilt), axis: edge.horizontal ? (0, 1, 0) : (1, 0, 0), perspective: 0.55)
        }
    }
}

// MARK: - Gestures & Peek bridge
//
// The few things `OwnDockGestures` (OwnDockGestures.swift) needs from the dock's private state.
// Everything else about the feature lives in that file.

extension OwnDock {
    /// The running app's tile under a panel point, while the dock is free for a gesture.
    func gestureSlot(at point: CGPoint) -> DockSlot? {
        guard !arranging, field.dragID == nil, pressID == nil, !keyboardActive,
              let hit = tileAt(point), hit.slot.kind == .app, hit.slot.running else { return nil }
        return hit.slot
    }

    /// After a gesture: the tile pulses, and the card goes until the pointer moves to another tile.
    /// Nil only takes the card down.
    func gestureFeedback(_ id: String?) {
        peekTask?.cancel()
        peekTask = nil
        field.peekTarget = false
        hoverOpened = hoverID
        if let id, stage.scene.tiles.contains(where: { $0.id == id }) {
            field.pulse(id, strength: 0.18, tile: field.fitted(metrics).tile)
        }
        wake()
    }

    /// A tile's rect on screen, Cocoa coordinates.
    func gestureTileRect(_ id: String) -> NSRect? {
        guard let tile = stage.scene.tiles.first(where: { $0.id == id }) else { return nil }
        let rect = screenRect(of: tile)
        return rect.width > 0 ? rect : nil
    }

    /// The Accessibility window behind a picture on the card, and its app.
    func gesturePeekRef(_ id: CGWindowID) -> AXRef? { peekRefs[id] }
    var gesturePeekPID: pid_t { peekPID }

    /// For the test hook: opens the card at the app's tile as a hover would. False when the app
    /// has no tile on the bar.
    func gestureShowPeek(_ path: String) -> Bool {
        guard enabled, let tile = stage.scene.tiles.first(where: { $0.slot.kind == .app && $0.slot.path == path }) else { return false }
        hoverID = tile.id
        hoverSince = Date()
        hoverOpened = nil
        field.peekAlongTarget = (tile.span.lowerBound + tile.span.upperBound) / 2
        field.peekID = tile.id
        present(tile.slot, label: false)
        field.peekTarget = true
        wake()
        return true
    }
}
