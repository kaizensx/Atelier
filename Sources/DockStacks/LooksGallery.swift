import AppKit
import DockCore
import SwiftUI

/// The Looks chapter: curated themes as a gallery of miniature Macs. Resting on a card tries
/// it on the stage; clicking applies it to the whole Mac; Revert undoes the run.
struct LooksGalleryChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var engine = ThemeEngine.shared
    @State private var justApplied: String?

    var body: some View {
        Text("Each Look restyles the whole Mac at once: Dock, widgets, menu bar, live wallpaper, icons, clock and this window. Rest on one to try it on the stage.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)
        LooksStatusBar(model: model)
        // Icon styles write AppleIconAppearanceTheme, which only macOS 26 and later read; on
        // earlier releases ThemeApplier leaves icons alone and says so here, once.
        if !PersonalAvailability.themeIconStyleSupported("tinted") {
            AvailabilityNote(availability: .limited("Clear and tinted icons need macOS 26. Looks change everything else here"))
        }
        SectionHeader("The collection", symbol: "sparkles", hue: DS.Ink.accent)
        LooksGrid(themes: LooksCatalog.all, justApplied: justApplied, model: model, apply: apply)
        if !engine.installed.isEmpty {
            SectionHeader("Your themes", symbol: "paintpalette", hue: DS.Ink.accent)
            LooksGrid(themes: engine.installed, justApplied: justApplied, model: model, apply: apply)
        }
        SectionHeader("Through the day", symbol: "sun.horizon", hue: DS.Ink.accent)
        LookScheduleCard()
        // The Themes & Plugins chapter, once Chapter has its `themes` case (snippet S1).
        if let themes = Chapter(rawValue: "themes") {
            RowGroup {
                Button { model.go(themes) } label: {
                    SettingRow(title: "Make your own", detail: "Import themes, save your Mac as one, and add plugins.",
                               symbol: "paintpalette", density: .compact) {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(Pressable(scale: 0.99))
            }
        }
        Color.clear.frame(height: 0).onDisappear { ThemePreview.shared.show(nil, on: model) }
    }

    private func apply(_ theme: InstalledTheme) {
        ThemePreview.shared.show(nil, on: model)
        engine.apply(theme)
        model.applied += 1
        withAnimation(DS.Motion.settle) { justApplied = theme.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(DS.Motion.exit) { if justApplied == theme.id { justApplied = nil } }
        }
    }
}

/// A gallery of Looks: generous tiles, each a miniature Mac wearing it.
private struct LooksGrid: View {
    let themes: [InstalledTheme]
    let justApplied: String?
    let model: ManagerModel
    let apply: (InstalledTheme) -> Void
    @ObservedObject private var engine = ThemeEngine.shared

    var body: some View {
        LazyVGrid(columns: LookCard.columns, spacing: DS.Space.m) {
            ForEach(themes) { theme in
                LookCard(theme: theme, applied: engine.appliedID == theme.id, flash: justApplied == theme.id) {
                    apply(theme)
                } hover: { over in
                    ThemePreview.shared.show(over ? theme : nil, on: model)
                }
            }
        }
    }
}

/// What is on now, and the way back: the applied Look on its own small Mac, lit in its colour.
struct LooksStatusBar: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var engine = ThemeEngine.shared

    var body: some View {
        let current = engine.appliedID.flatMap(engine.theme)
        let hue = current.map { LookArt.accent($0.document) } ?? DS.Ink.accent
        HStack(spacing: DS.Space.l) {
            Group {
                if let current {
                    LooksScreen { LookMiniature(theme: current.document, bundle: current.bundle) }
                } else {
                    LooksScreen {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
                            Image(systemName: "apple.logo").font(.system(size: 20, weight: .medium)).foregroundStyle(DS.Ink.glyph)
                        }
                    }
                }
            }
            .frame(width: 112)
            .id(current?.id)
            .transition(.opacity)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: 6) {
                    Circle().fill(current == nil ? DS.Ink.glyph : hue).frame(width: 6, height: 6)
                    Text(current == nil ? "Now" : "On your Mac now").font(DS.Typo.section).foregroundStyle(current == nil ? DS.Ink.tertiary : hue)
                }
                Text(current?.document.name ?? "Your own setup")
                    .font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                    .contentTransition(.opacity)
                Text(engine.canRevert ? "Revert brings back your Mac as it was." : "Nothing applied yet. Pick a Look below.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if engine.canRevert {
                Button {
                    withAnimation(DS.Motion.settle) { engine.revert() }
                    model.applied += 1
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(DS.Ink.fillStrong, in: .capsule)
                        .overlay { Capsule().strokeBorder(DS.Ink.edge, lineWidth: 0.5) }
                        .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.95))
                .transition(.opacity)
                .padding(.trailing, DS.Space.s)
            }
        }
        .padding(DS.Inset.plate)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(style: current == nil ? .standard : .lit(hue)) }
        .animation(DS.Motion.settle, value: engine.canRevert)
        .animation(DS.Motion.arrive, value: engine.appliedID)
        if let problem = engine.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The card

/// A small Mac's display: a black bezel with a camera dot, concentric with the card around it
/// (card 20, plate inset 8, bezel 12, bezel width 4, screen 8). The screen is 16:10.
struct LooksScreen<Content: View>: View {
    var sweeps = 0
    var hovering = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                // A little glass on the screen: light from above, never animated.
                LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
            }
            .overlay { SweepLight(trigger: sweeps) }
            .clipShape(.rect(cornerRadius: DS.Radius.plate - 4, style: .continuous))
            .padding(4)
            .background(Color.black, in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
            .overlay(alignment: .top) {
                Circle().fill(.white.opacity(0.22)).frame(width: 2, height: 2).padding(.top, 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.24 : 0.12), lineWidth: 0.5)
            }
    }
}

/// A theme drawn as a tiny Mac: its wallpaper, menu bar, clock, widgets and Dock, in its own
/// colours. Drawn, not screenshotted, so it shows the theme rather than the current setup.
struct LookCard: View {
    let theme: InstalledTheme
    let applied: Bool
    var flash = false
    let apply: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false
    /// One sweep of light across the screen each time this Look is applied.
    @State private var sweeps = 0

    static let columns = [GridItem(.adaptive(minimum: 232, maximum: 420), spacing: DS.Space.m)]

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 0) {
                LooksScreen(sweeps: sweeps, hovering: hovering) {
                    LookMiniature(theme: theme.document, bundle: theme.bundle, hovering: hovering)
                }
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(alignment: .center, spacing: DS.Space.s) {
                        Text(theme.document.name).font(DS.title).foregroundStyle(DS.Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if applied {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy))
                                Text("ON").font(DS.Typo.badge).tracking(0.8)
                            }
                            .foregroundStyle(DS.Ink.accent)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(DS.Ink.accent.opacity(0.16), in: .capsule)
                            .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                        swatches
                    }
                    Text(theme.document.summary ?? "")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.s)
            }
            .padding(DS.Inset.plate)
            .background { CardSurface(style: applied ? .lit(DS.Ink.accent) : .standard) }
            .overlay {
                // The selection ring in the area's light; hover only brightens the edge.
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(applied ? DS.Ink.accent.opacity(0.9) : .white.opacity(hovering ? 0.16 : 0),
                                  lineWidth: applied ? 1.5 : 0.5)
            }
            .contentShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.985))
        .animation(DS.Motion.hover, value: hovering)
        .animation(DS.Motion.settle, value: applied)
        .onChange(of: flash) { _, on in if on { sweeps += 1 } }
        .onHover { inside in
            // While the gallery scrolls under a still pointer, cards do not light one after another.
            hovering = inside && !ScrollActivity.scrolling
            hover(inside)
        }
        .accessibilityLabel("\(theme.document.name) Look")
        .accessibilityHint(theme.document.summary ?? "")
        .accessibilityAddTraits(applied ? .isSelected : [])
        .contextMenu {
            Button("Apply") { apply() }
            Button("Save as Theme File…") { LookCard.share(theme) }
            if !theme.builtIn {
                Button("Show in Finder") { if let bundle = theme.bundle { NSWorkspace.shared.activateFileViewerSelecting([bundle]) } }
            }
        }
    }

    private var swatches: some View {
        HStack(spacing: -4) {
            ForEach(Array(LookArt.swatches(theme.document).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1) }
            }
        }
        .accessibilityHidden(true)
    }

    static func share(_ theme: InstalledTheme) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save “\(theme.document.name).\(ThemeSchema.bundleExtension)”"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let url = try ThemeEngine.shared.share(theme, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            ThemeEngine.shared.problem = error.localizedDescription
        }
    }
}

/// Colours and pictures for drawing a theme small.
@MainActor
enum LookArt {
    private static var wallpapers: [String: NSImage] = [:]

    static func accent(_ theme: ThemeDocument) -> Color {
        theme.color("colors.accent").map(Color.init) ?? DS.Ink.accent
    }
    static func secondary(_ theme: ThemeDocument) -> Color {
        theme.color("colors.secondary").map(Color.init) ?? accent(theme).opacity(0.6)
    }

    static func swatches(_ theme: ThemeDocument) -> [Color] {
        var colors: [Color] = []
        if let accent = theme.color("colors.accent") { colors.append(Color(accent)) }
        if let second = theme.color("colors.secondary") { colors.append(Color(second)) }
        if let palette = theme.string("wallpaper.palette").flatMap(LivingPalette.preset) {
            colors.append(LivingPalette.color(palette.stops[2]))
        } else if let custom = theme.colors("wallpaper.palette"), custom.count == 4 {
            colors.append(Color(custom[2]))
        }
        return colors
    }

    static func widgetTint(_ name: String?) -> Color? {
        guard let name else { return nil }
        if let color = ThemeColor(hex: name) { return Color(color) }
        return WidgetTint(rawValue: name)?.color
    }

    /// A still frame of the theme's live wallpaper, rendered once and kept.
    static func wallpaper(_ theme: ThemeDocument, size: CGSize) -> NSImage? {
        guard let shader = theme.string("wallpaper.shader").flatMap(LivingShader.init(rawValue:)),
              theme.string("wallpaper.mode") == "live" || theme.string("wallpaper.mode") == nil else { return nil }
        let key = theme.id + "@" + theme.version
        if let cached = wallpapers[key] { return cached }
        guard let engine = LivingEngine.shared else { return nil }
        var tuning = LivingTuning()
        if let palette = theme.string("wallpaper.palette") { tuning.palette = palette }
        else if let custom = theme.colors("wallpaper.palette"), custom.count == 4 { tuning.palette = ThemePalettes.nearestPreset(custom) }
        if let value = theme.number("wallpaper.intensity") { tuning.intensity = value }
        if let value = theme.number("wallpaper.scale") { tuning.scale = value }
        if let value = theme.number("wallpaper.dim") { tuning.dim = value }
        if let value = theme.number("wallpaper.grain") { tuning.grain = value }
        let hour = theme.string("wallpaper.cycle").flatMap(DayCycle.init(rawValue:))?.heldHour
            ?? (theme.string("appearance") == "light" ? 13 : 21)
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let image = engine.snapshot(shader, width: max(width, 64), height: max(height, 40), hour: hour, tuning: tuning) else { return nil }
        let result = NSImage(cgImage: image, size: size)
        wallpapers[key] = result
        return result
    }
}

/// The miniature Mac on a card.
struct LookMiniature: View {
    let theme: ThemeDocument
    let bundle: URL?
    var hovering = false
    @State private var picture: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = size.width / 320
            ZStack(alignment: .top) {
                backdrop(size)
                menuBar(unit)
                clock(unit).position(x: size.width * 0.27, y: size.height * 0.34)
                widgets(unit).position(x: size.width * 0.8, y: size.height * 0.4)
                dock(unit).position(x: size.width / 2, y: size.height - 18 * unit)
            }
            .frame(width: size.width, height: size.height)
            .task(id: theme.id) {
                // One frame of the shader, drawn after the card is on screen.
                if picture == nil { picture = LookArt.wallpaper(theme, size: CGSize(width: 320, height: 200)) }
            }
        }
    }

    @ViewBuilder private func backdrop(_ size: CGSize) -> some View {
        if let picture {
            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
        } else if let bundle, let path = theme.string("wallpaper.image"), let image = NSImage(contentsOf: bundle.appendingPathComponent(path)) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if theme.string("wallpaper.mode") == "mesh" {
            MeshCanvas(hue: theme.string("wallpaper.mesh").flatMap(Hue.init(rawValue:)) ?? .aurora, hour: 13)
        } else if let palette = theme.colors("wallpaper.palette"), palette.count == 4 {
            LinearGradient(colors: palette.reversed().map(Color.init), startPoint: .top, endPoint: .bottom)
        } else {
            let accent = LookArt.accent(theme)
            ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: size.width * 0.8)
                RadialGradient(colors: [LookArt.secondary(theme).opacity(0.3), .clear], center: .bottomTrailing, startRadius: 0, endRadius: size.width * 0.7)
            }
        }
    }

    private func menuBar(_ unit: CGFloat) -> some View {
        let skin = theme.string("menuBar.skin").flatMap(SkinPreset.init(rawValue:)) ?? .none
        return HStack(spacing: 4 * unit) {
            Image(systemName: "apple.logo").font(.system(size: 6.5 * unit, weight: .semibold))
            ForEach(0..<4, id: \.self) { index in
                Capsule().frame(width: (index == 0 ? 14 : 10) * unit, height: 2.4 * unit).opacity(index == 0 ? 0.9 : 0.55)
            }
            Spacer()
            ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.4 * unit, height: 3.4 * unit).opacity(0.7) }
            Text("9:41").font(.system(size: 6 * unit, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8 * unit)
        .frame(height: 12 * unit)
        .background {
            if skin == .none {
                Rectangle().fill(.black.opacity(0.12))
            } else {
                LinearGradient(colors: skin.colors.count > 1 ? skin.colors : skin.colors + skin.colors, startPoint: .leading, endPoint: .trailing)
            }
        }
    }

    @ViewBuilder private func clock(_ unit: CGFloat) -> some View {
        if theme.bool("clock.show") == true {
            let face = theme.string("clock.face") ?? "thin"
            let font: Font = switch face {
            case "bold": .system(size: 30 * unit, weight: .heavy)
            case "rounded": .system(size: 30 * unit, weight: .semibold, design: .rounded)
            case "serif": .system(size: 30 * unit, weight: .regular, design: .serif)
            case "mono", "flip": .system(size: 26 * unit, weight: .medium, design: .monospaced)
            case "words", "stacked": .system(size: 13 * unit, weight: .semibold)
            case "dot": .system(size: 14 * unit, weight: .medium, design: .rounded)
            default: .system(size: 32 * unit, weight: .ultraLight)
            }
            Group {
                switch face {
                case "analog":
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.2 * unit)
                        Capsule().fill(.white).frame(width: 1.6 * unit, height: 11 * unit).offset(y: -5 * unit).rotationEffect(.degrees(300))
                        Capsule().fill(.white).frame(width: 1.2 * unit, height: 15 * unit).offset(y: -7 * unit).rotationEffect(.degrees(246))
                        Circle().fill(LookArt.accent(theme)).frame(width: 3 * unit)
                    }
                    .frame(width: 40 * unit, height: 40 * unit)
                case "words": Text("ten to\nten").font(font).multilineTextAlignment(.leading)
                case "stacked": Text("09\n50").font(.system(size: 18 * unit, weight: .bold, design: .rounded)).multilineTextAlignment(.leading)
                case "dot":
                    HStack(spacing: 4 * unit) { Circle().fill(LookArt.accent(theme)).frame(width: 5 * unit); Text("9:50").font(font) }
                case "flip":
                    HStack(spacing: 2 * unit) {
                        ForEach(["09", "50"], id: \.self) { part in
                            Text(part).font(font).padding(.horizontal, 3 * unit)
                                .background(.black.opacity(0.45), in: .rect(cornerRadius: 3 * unit))
                        }
                    }
                default: Text("9:50").font(font)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 4 * unit)
        }
    }

    private func widgets(_ unit: CGFloat) -> some View {
        let material = theme.string("widgets.material") ?? "glass"
        let tint = LookArt.widgetTint(theme.string("widgets.tint") ?? theme.string("colors.glassTint")) ?? .blue
        let accent = LookArt.widgetTint(theme.string("widgets.accent")) ?? LookArt.accent(theme)
        let radius = (theme.number("widgets.radius") ?? 26) / 26 * 9 * unit
        let gradient = theme.value("widgets.gradient").map { _ in
            LinearGradient(colors: [LookArt.widgetTint(theme.string("widgets.gradient.from")) ?? tint,
                                    LookArt.widgetTint(theme.string("widgets.gradient.to")) ?? accent],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let font: Font.Design = switch theme.string("widgets.font") {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
        func surface<Content: View>(_ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
            content()
                .frame(width: width * unit, height: height * unit)
                .background {
                    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    ZStack {
                        switch material {
                        case "dark": shape.fill(.black.opacity(0.55))
                        case "frosted": shape.fill(.white.opacity(0.32))
                        case "clear": shape.fill(.white.opacity(0.06))
                        case "tinted": shape.fill(tint.opacity(0.38))
                        case "outline": shape.strokeBorder(.white.opacity(0.6), lineWidth: 1 * unit)
                        case "bare": Color.clear
                        default: shape.fill(.ultraThinMaterial)
                        }
                        if let gradient { shape.fill(gradient.opacity(0.55)) }
                        if material != "bare", material != "outline" { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                    }
                }
                .environment(\.colorScheme, .dark)
        }
        return VStack(spacing: 5 * unit) {
            surface(78, 36) {
                HStack(spacing: 6 * unit) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 3 * unit)
                        Circle().trim(from: 0, to: 0.68).stroke(accent, style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20 * unit, height: 20 * unit)
                    VStack(alignment: .leading, spacing: 2 * unit) {
                        Text("Focus").font(.system(size: 6.5 * unit, weight: .semibold, design: font))
                        Text("18:24").font(.system(size: 9 * unit, weight: .bold, design: font)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                }
            }
            surface(78, 30) {
                PluginSparkline(values: [3, 5, 4, 7, 6, 9, 8, 11, 9, 12], color: accent, fill: true)
                    .padding(.horizontal, 7 * unit).padding(.vertical, 6 * unit)
            }
        }
    }

    private func dock(_ unit: CGFloat) -> some View {
        let style = theme.string("dock.style") ?? "glass"
        let accent = theme.string("dock.accent").flatMap(ThemeColor.init(hex:)).map(Color.init)
            ?? theme.string("dock.accent").flatMap { name in ThemeApplier.dockAccents.first { $0.0 == name }?.1 }.map(Color.init)
            ?? LookArt.accent(theme)
        let roundness = theme.number("dock.roundness") ?? 0.67
        // The card shows what applying it will do on this Mac: plain icons before macOS 26.
        let iconStyle = (theme.string("icons.style")).flatMap { PersonalAvailability.themeIconStyleSupported($0) ? $0 : nil } ?? "default"
        let iconTint = theme.string("icons.tint").flatMap { raw in
            ThemeColor(hex: raw).map(Color.init) ?? ThemeApplier.iconTints.first { $0.0 == raw }.map { Color($0.1) }
        } ?? LookArt.accent(theme)
        let icons: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow]
        let height = 22 * unit
        let radius = height / 2 * (0.25 + 0.75 * roundness)
        return HStack(spacing: 3.5 * unit) {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, color in
                let shape = RoundedRectangle(cornerRadius: 3.6 * unit, style: .continuous)
                Group {
                    switch iconStyle {
                    case "clear": shape.fill(.white.opacity(0.22)).overlay { shape.strokeBorder(.white.opacity(0.5), lineWidth: 0.5) }
                    case "tinted": shape.fill(LinearGradient(colors: [iconTint.opacity(0.95), iconTint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    default: shape.fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(width: 15 * unit, height: 15 * unit)
                .scaleEffect(hovering && index == 3 ? 1.25 : 1, anchor: .bottom)
                .animation(DS.Motion.settle.delay(Double(index) * 0.02), value: hovering)
            }
        }
        .padding(.horizontal, 6 * unit)
        .frame(height: height)
        .background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            switch style {
            case "tinted": shape.fill(accent.opacity(0.32)).overlay { shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
            case "midnight": shape.fill(.black.opacity(0.62)).overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
            case "frost": shape.fill(.white.opacity(0.42)).overlay { shape.strokeBorder(.white.opacity(0.6), lineWidth: 0.5) }
            case "neon": shape.fill(.black.opacity(0.45)).overlay { shape.strokeBorder(accent, lineWidth: 1.2 * unit) }
                .shadow(color: accent.opacity(0.8), radius: 6 * unit)
            default: shape.fill(.ultraThinMaterial).overlay { shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
            }
        }
        .background {
            if theme.bool("effects.dockGlow") == true {
                // Soft light under the Dock from a gradient: a blur here was a pass per card.
                Ellipse().fill(RadialGradient(colors: [accent.opacity(0.7), accent.opacity(0)], center: .center,
                                              startRadius: 0, endRadius: 40 * unit))
                    .frame(width: 80 * unit, height: 26 * unit)
                    .scaleEffect(x: 1.6, y: 1)
                    .offset(y: 8 * unit)
            }
        }
    }
}

// MARK: - Schedule

/// Up to four Looks across the day. A stock Mac only switches light and dark; this switches everything.
struct LookScheduleCard: View {
    @ObservedObject private var engine = ThemeEngine.shared

    /// The next slot to begin, from now, wrapping past midnight.
    private var next: ThemeSchedule.Slot? {
        let slots = engine.schedule.slots.filter { (0..<24).contains($0.hour) }.sorted { $0.hour < $1.hour }
        let now = ThemeEngine.hourNow()
        return slots.first { $0.hour > now } ?? slots.first
    }

    var body: some View {
        let next = next
        HeroCard("Change with the Day", pitch: "Each Look takes over as its hour arrives.",
                 isOn: $engine.schedule.enabled, hue: DS.Ink.accent,
                 readout: next.map { Self.label($0.hour) },
                 readoutCaption: next.map { "Next: " + (engine.theme($0.theme)?.document.name ?? "Look") }) {
            LivePlate { _, since in LooksDayPlate(schedule: engine.schedule, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(engine.schedule.slots.enumerated()), id: \.offset) { index, slot in
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(slot.hour)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Ink.secondary).frame(width: 18)
                        Picker("Hour", selection: Binding(get: { slot.hour }, set: { engine.schedule.slots[index].hour = $0 })) {
                            ForEach(Array(stride(from: 0.0, to: 24, by: 0.5)), id: \.self) { hour in
                                Text(Self.label(hour)).tag(hour)
                            }
                        }
                        .labelsHidden().frame(width: 90)
                        Circle().fill(engine.theme(slot.theme).map { LookArt.accent($0.document) } ?? DS.Ink.glyph)
                            .frame(width: 8, height: 8)
                        Picker("Look", selection: Binding(get: { slot.theme }, set: { engine.schedule.slots[index].theme = $0 })) {
                            ForEach(engine.all) { Text($0.document.name).tag($0.id) }
                        }
                        .labelsHidden()
                        Spacer()
                        Button {
                            _ = withAnimation(DS.Motion.arrive) { engine.schedule.slots.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(DS.Ink.tertiary)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                        .accessibilityLabel("Remove")
                    }
                    .frame(minHeight: 32)
                    if index < engine.schedule.slots.count - 1 {
                        Rectangle().fill(DS.Ink.hairline).frame(height: 0.5).padding(.leading, 28)
                    }
                }
                HStack(spacing: 8) {
                    if engine.schedule.slots.count < 4 {
                        Chip("Add a Time") {
                            let next = ((engine.schedule.slots.map(\.hour).max() ?? 4) + 4).truncatingRemainder(dividingBy: 24)
                            withAnimation(DS.Motion.arrive) {
                                engine.schedule.slots.append(.init(hour: next, theme: LooksCatalog.all.first?.id ?? ""))
                            }
                        }
                    }
                    Chip("Day & Night") {
                        withAnimation(DS.Motion.arrive) {
                            engine.schedule.slots = [.init(hour: 7, theme: "atelier.look.glacier"), .init(hour: 19.5, theme: "atelier.look.midnight-glass")]
                        }
                    }
                    Chip("Four Seasons of a Day") {
                        withAnimation(DS.Motion.arrive) {
                            engine.schedule.slots = [.init(hour: 6.5, theme: "atelier.look.forest-dawn"), .init(hour: 10, theme: "atelier.look.paper-studio"),
                                                     .init(hour: 17.5, theme: "atelier.look.sunset-neon"), .init(hour: 21.5, theme: "atelier.look.deep-space")]
                        }
                    }
                }
                .padding(.top, DS.Space.xs)
                Text("Picking a Look by hand holds until the next one begins.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
    }

    static func label(_ hour: Double) -> String {
        String(format: "%02d:%02d", Int(hour), Int((hour - floor(hour)) * 60))
    }

    static func symbol(_ hour: Double) -> String {
        switch hour {
        case 5..<9: "sunrise"
        case 9..<17: "sun.max"
        case 17..<21: "sunset"
        default: "moon.stars"
        }
    }
}

/// The schedule's plate: the day as a ribbon, each stretch in the colour of the Look that holds
/// it, with a marker at now. Still at rest; under the pointer the marker runs through the day
/// (three hours a second) so you can watch the Looks hand over.
private struct LooksDayPlate: View {
    let schedule: ThemeSchedule
    let since: Date?
    @ObservedObject private var engine = ThemeEngine.shared

    private static let steps = 96

    var body: some View {
        // Colours by quarter hour, worked out once per render, not per frame.
        let colors: [Color] = (0..<Self.steps).map { step in
            schedule.theme(at: Double(step) * 24 / Double(Self.steps)).flatMap(engine.theme)
                .map { LookArt.accent($0.document) } ?? DS.Ink.fillStrong
        }
        let starts: [(hour: Double, name: String)] = schedule.slots
            .filter { (0..<24).contains($0.hour) }
            .sorted { $0.hour < $1.hour }
            .map { ($0.hour, engine.theme($0.theme)?.document.name ?? "") }
        let now = ThemeEngine.hourNow()
        GeometryReader { geometry in
            let inset = 24.0
            let width = max(geometry.size.width - inset * 2, 1)
            let bandTop = 58.0, bandHeight = 22.0
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let band = CGRect(x: inset, y: bandTop, width: width, height: bandHeight)
                    context.drawLayer { layer in
                        layer.clip(to: Path(roundedRect: band, cornerRadius: bandHeight / 2))
                        let step = width / Double(Self.steps)
                        for (index, color) in colors.enumerated() {
                            layer.fill(Path(CGRect(x: inset + Double(index) * step, y: bandTop, width: step + 0.5, height: bandHeight)),
                                       with: .color(color.opacity(0.85)))
                        }
                        // Each Look's name where its stretch begins, if the stretch has room for it.
                        for (index, start) in starts.enumerated() {
                            let end = index + 1 < starts.count ? starts[index + 1].hour : starts[0].hour + 24
                            let room = (end - start.hour) / 24 * width - 12
                            let text = context.resolve(Text(start.name.uppercased()).font(DS.Typo.badge).foregroundStyle(.black.opacity(0.72)))
                            let x = inset + start.hour / 24 * width
                            if text.measure(in: CGSize(width: 400, height: 20)).width <= room {
                                layer.draw(text, at: CGPoint(x: x + 7, y: bandTop + bandHeight / 2), anchor: .leading)
                            }
                            if start.hour > 0 {
                                layer.fill(Path(CGRect(x: x - 0.5, y: bandTop, width: 1, height: bandHeight)), with: .color(.black.opacity(0.35)))
                            }
                        }
                    }
                    context.stroke(Path(roundedRect: band, cornerRadius: bandHeight / 2), with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                    for hour in [0, 6, 12, 18] {
                        let x = inset + Double(hour) / 24 * width
                        context.draw(Text(String(format: "%02d", hour)).font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary),
                                     at: CGPoint(x: x, y: bandTop - 12), anchor: hour == 0 ? .leading : .center)
                    }
                }
                PlateClock(since: since) { seconds in
                    let hour = (now + seconds * 3).truncatingRemainder(dividingBy: 24)
                    let x = inset + hour / 24 * width
                    let color = colors[min(Int(hour / 24 * Double(Self.steps)), Self.steps - 1)]
                    ZStack(alignment: .topLeading) {
                        // The Look's light pooling under the marker. A gradient, never a blur.
                        RadialGradient(colors: [color.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 60)
                            .frame(width: 120, height: 120)
                            .offset(x: x - 60, y: bandTop + bandHeight / 2 - 60)
                            .blendMode(.plusLighter)
                        // The marker is a knob riding the ribbon, with the sun or moon of its hour.
                        Image(systemName: LookScheduleCard.symbol(hour)).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                            .frame(width: 28, height: 28)
                            .background(.white, in: .circle)
                            .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
                            .offset(x: x - 14, y: bandTop + bandHeight / 2 - 14)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
