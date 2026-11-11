import AppKit
import DockCore
import SwiftUI

/// The Menu Bar skin studio: a lit plate with the chosen skin, a gallery of every skin, then
/// quiet grouped rows for how it is drawn and when it changes. Surfaces light throughout.
struct MenuBarStudioChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var skin = MenuBarSkin.shared
    @State private var screens = NSScreen.screens
    @State private var apps: [NSRunningApplication] = []
    private let hue = DS.Spectrum.surfaces
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: DS.Space.m)]

    var body: some View {
        Text("A skin is painted directly behind the real menu bar, on every display that has one. Apple's menus and icons stay on top, untouched.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)

        hero
        gallery
        if effects.skin != .none {
            SectionHeader("Style", symbol: "paintbrush.pointed", hue: hue)
            styleCard
            SectionHeader("Legibility", symbol: "textformat", hue: hue)
            textCard
            SectionHeader("Per app", symbol: "app.badge",
                          detail: "While one of these apps is in front, its skin shows.", hue: hue)
            rulesCard
            SectionHeader("Night skin", symbol: "moon.stars", hue: hue)
            scheduleCard
            if screens.count > 1, NSScreen.screensHaveSeparateSpaces {
                SectionHeader("Displays", symbol: "display.2", hue: hue)
                displaysCard
            }
        }
        SectionHeader("What macOS doesn't allow", symbol: "lock", hue: DS.Ink.secondary)
        limitsCard
        SectionHeader("Menu bar switches", symbol: "slider.horizontal.3", hue: DS.Ink.secondary)
        TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .menubar))
        SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .menubar).map(\.compatHiddenItem))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
    }

    // MARK: Hero and gallery

    /// What this release lets a skin look like. Pure decision in DockCore's MenuBarSkinSupport.
    private var skinAvailability: FeatureAvailability {
        let support = MenuBarSkinSupport.evaluate(
            major: PersonalAvailability.runningMajor,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            anyNotch: screens.contains { $0.auxiliaryTopLeftArea != nil },
            notchSkin: effects.skin == .notchless)
        switch support {
        case .full: return .available
        case let .softened(text): return .limited(text)
        case let .covered(text): return .unavailable(text)
        }
    }

    /// The chosen skin on a desk in miniature: a screen whose top edge wears it.
    private var hero: some View {
        let on = effects.skin != .none
        return ZStack(alignment: .topLeading) {
            RadialGradient(colors: [hue.opacity(on ? 0.42 : 0.14), .clear],
                           center: UnitPoint(x: 0.5, y: 1.15), startRadius: 0, endRadius: 320)
            // The screen.
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    MenuBarSkinPreview(preset: effects.skin, width: geometry.size.width, height: 26)
                }
                .frame(height: 26)
                LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.36), Color(red: 0.1, green: 0.11, blue: 0.16)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, -12)
            .accessibilityLabel("Preview of the menu bar with \(effects.skin.title)")
            HeroBadge(text: "Beyond macOS", hue: hue).padding(10)
            VStack(alignment: .trailing, spacing: 0) {
                Text(effects.skin.title).font(DS.Typo.readout).foregroundStyle(.white)
                    .contentTransition(.opacity)
                Text("SKIN").font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
            }
            .padding(DS.Space.m)
            .background(alignment: .bottomTrailing) {
                // Keeps the readout legible over the little screen.
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    .frame(width: 260, height: 80)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(height: 168)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .clipShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(LinearGradient(colors: [on ? hue.opacity(0.6) : DS.Ink.edge, on ? hue.opacity(0.12) : DS.Ink.hairline],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .overlay(alignment: .topTrailing) {
            if on { AvailabilityNote(availability: skinAvailability).padding(10) }
        }
        .animation(DS.Motion.reveal, value: effects.skin)
    }

    private var gallery: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.m) {
            ForEach(SkinPreset.allCases) { preset in
                MenuBarSkinTile(preset: preset, selected: effects.skin == preset, hue: hue) {
                    withAnimation(DS.Motion.arrive) { effects.skin = preset }
                }
            }
        }
    }

    // MARK: Style

    private var styleCard: some View {
        RowGroup {
            if effects.skin == .solid || effects.skin == .glass {
                SettingRow(title: effects.skin == .glass ? "Glass Tint" : "Colour", symbol: "paintpalette", density: .compact) {
                    ColorPicker("Colour", selection: $skin.tint, supportsOpacity: false).labelsHidden()
                }
            }
            if effects.skin != .notchless {
                TuningSlider(title: "Strength", value: $skin.strength, range: 0.3...1) { "\(Int(($0 * 100).rounded()))%" }
                    .padding(.vertical, DS.Space.s)
            }
            SettingRow(title: "Floating Bar", detail: "Inset from the screen edges, with rounded ends. Menus stay put.",
                       symbol: "capsule", density: .compact) {
                LuxSwitch(isOn: $skin.floating, label: "Floating Bar", tint: hue)
            }
            .stagePreview(.demo("menu.float", "Floating Bar", isOn: skin.floating, region: StageRegion.menuBar, Demos.floatingBar))
            TuningSlider(title: skin.floating ? "End Radius" : "Corner Radius", value: $skin.radius, range: 0...16) { "\(Int($0)) pt" }
                .padding(.vertical, DS.Space.s)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingRow(title: "Lower Edge", detail: "A hairline, a soft shadow, or the day's progress along the bar.",
                           symbol: "line.horizontal.3.decrease", density: .compact) { EmptyView() }
                Segments(selection: $skin.edge, options: SkinEdge.allCases.map { ($0, $0.title) })
            }
            .padding(.bottom, DS.Space.s)
            if NSScreen.screens.contains(where: { $0.auxiliaryTopLeftArea != nil }) {
                SettingRow(title: "Notch Blend", detail: "Grows the notch into a black pill, so it reads as part of the design.",
                           symbol: "rectangle.topthird.inset.filled", density: .compact) {
                    LuxSwitch(isOn: $skin.notchBlend, label: "Notch Blend", tint: hue)
                }
                .stagePreview(.demo("menu.notch", "Notch Blend", isOn: skin.notchBlend, region: StageRegion.menuBar, Demos.notchBlend))
            }
            if effects.skin == .aurora {
                SettingRow(title: "Motion", detail: "The light drifts slowly. Off, or with Reduce Motion, it holds still.",
                           symbol: "wind", density: .compact) {
                    LuxSwitch(isOn: $skin.motion, label: "Motion", tint: hue)
                }
                .stagePreview(.demo("menu.motion", "Motion", isOn: skin.motion, region: StageRegion.menuBar, Demos.menuMotion))
            }
            if effects.skin == .frosted || effects.skin == .wallpaper {
                SettingRow(title: "Wallpaper Changed?", detail: "Reads the top of your wallpaper again.",
                           symbol: "arrow.clockwise", density: .compact) {
                    Chip("Refresh") { skin.readWallpaper() }
                }
            }
        }
    }

    // MARK: Text

    private var textCard: some View {
        RowGroup {
            SettingRow(title: "Keep Text Readable",
                       detail: "Keeps the skin dark under white text and light under black text.",
                       symbol: "eye", density: .compact) {
                LuxSwitch(isOn: $skin.legible, label: "Keep Text Readable", tint: hue)
            }
            .help("macOS picks the menu bar's text colour from your wallpaper, not from the skin. This keeps the skin dark under white text and light under black text.")
            .stagePreview(.demo("menu.readable", "Keep Text Readable", isOn: skin.legible, region: StageRegion.menuBar, Demos.readableText))
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingRow(title: "Text Colour macOS Uses",
                           detail: skin.textTone == .auto ? "Auto guesses \(skin.textIsLight ? "white" : "black"). Pick one if the guess is wrong." : "Set by hand.",
                           symbol: "character", density: .compact) { EmptyView() }
                Segments(selection: $skin.textTone, options: MenuTextTone.allCases.map { ($0, $0.title) })
            }
            .padding(.bottom, DS.Space.s)
        }
    }

    // MARK: Rules

    private var rulesCard: some View {
        RowGroup {
            ForEach(skin.appSkins.keys.sorted(), id: \.self) { bundle in
                HStack(spacing: 10) {
                    appIcon(bundle).resizable().frame(width: 20, height: 20)
                    Text(appName(bundle)).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Spacer()
                    SkinMenu(selection: skin.appSkins[bundle] ?? .none) { skin.setSkin($0, forApp: bundle) }
                    Button { skin.setSkin(nil, forApp: bundle) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .accessibilityLabel("Remove \(appName(bundle))")
                }
                .frame(minHeight: 44)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(hue).frame(width: 18)
                Text(skin.appSkins.isEmpty ? "No apps yet" : "Another app")
                    .font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.secondary)
                Spacer()
                Menu {
                    ForEach(apps, id: \.processIdentifier) { app in
                        if let bundle = app.bundleIdentifier, skin.appSkins[bundle] == nil {
                            Button(app.localizedName ?? bundle) { skin.setSkin(effects.skin, forApp: bundle) }
                        }
                    }
                } label: {
                    Label("Add App", systemImage: "plus").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .fixedSize()
                .onAppear { refreshApps() }
                .onHover { if $0 { refreshApps() } }
            }
            .frame(minHeight: 44)
        }
    }

    private func refreshApps() {
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func appIcon(_ bundle: String) -> Image {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return Image(systemName: "app") }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }

    private var scheduleCard: some View {
        RowGroup {
            SettingRow(title: "Night Skin", detail: "A different skin after dark. Off brings back the main one.",
                       symbol: "moon", density: .compact) {
                LuxSwitch(isOn: $skin.scheduled, label: "Night Skin", tint: hue)
            }
            .stagePreview(.demo("menu.night", "Night Skin", isOn: skin.scheduled, region: StageRegion.menuBar, Demos.nightSkin))
            if skin.scheduled {
                SettingRow(title: "At Night", detail: "From \(DayLight.text(skin.nightBegins)) to \(DayLight.text(skin.dayBegins))",
                           symbol: "moon.stars", density: .compact) {
                    SkinMenu(selection: skin.nightSkin) { skin.nightSkin = $0 }
                }
                TuningSlider(title: "Night Begins", value: Binding(get: { skin.nightBegins }, set: { skin.nightBegins = ($0 * 4).rounded() / 4 }),
                             range: 16...23.5) { DayLight.text($0) }
                    .padding(.vertical, DS.Space.s)
                TuningSlider(title: "Day Begins", value: Binding(get: { skin.dayBegins }, set: { skin.dayBegins = ($0 * 4).rounded() / 4 }),
                             range: 4...11) { DayLight.text($0) }
                    .padding(.vertical, DS.Space.s)
            }
        }
        .animation(DS.Motion.reveal, value: skin.scheduled)
    }

    private var displaysCard: some View {
        RowGroup {
            ForEach(screens.compactMap { screen in screen.displayID.map { (screen, LiveWallpaper.uuid(of: $0)) } }, id: \.1) { screen, uuid in
                SettingRow(title: screen.localizedName, detail: skin.displaySkins[uuid] == nil ? "Same as the main skin" : nil,
                           symbol: "display", density: .compact) {
                    HStack(spacing: 8) {
                        if skin.displaySkins[uuid] != nil {
                            Chip("Reset") { skin.setSkin(nil, forDisplay: uuid) }
                        }
                        SkinMenu(selection: skin.displaySkins[uuid] ?? effects.skin) { skin.setSkin($0, forDisplay: uuid) }
                    }
                }
            }
        }
    }

    private var limitsCard: some View {
        Card(style: .quiet) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Self.limits, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(DS.Ink.glyph).frame(width: 4, height: 4)
                        Text(line).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static let limits = [
        "Apple's own menus, the clock and Control Center can't be hidden, moved or recoloured. The skin only paints behind them.",
        "The text colour is chosen by macOS from your wallpaper. Keep Text Readable adapts the skin to it instead.",
        "With Automatically Hide the Menu Bar, the skin hides too: it can't slide in with the bar.",
        "Full-screen apps hide the bar, so the skin stays out of full-screen Spaces.",
        "Clock seconds on hover would mean rewriting the clock's settings on every hover. It's not offered; Show Seconds is in the list below.",
    ]
}

/// One skin in the gallery. Concentric: tile 16, inset 8, preview 8. Hover tints, the chosen
/// one is ringed in the Surfaces light. Nothing moves.
private struct MenuBarSkinTile: View {
    let preset: SkinPreset
    let selected: Bool
    let hue: Color
    let choose: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        MenuBarSkinPreview(preset: preset, width: geometry.size.width, height: 20, items: true)
                        LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.36), Color(red: 0.12, green: 0.13, blue: 0.19)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: 44)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(hue)
                        }
                    }
                    Text(preset.detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Space.xs)
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(selected ? hue.opacity(0.12) : (hover ? DS.Ink.fillStrong : DS.Ink.fill)))
            .overlay { shape.strokeBorder(selected ? hue.opacity(0.85) : DS.Ink.hairline, lineWidth: selected ? 1.5 : 0.5) }
            .contentShape(shape)
        }
        .buttonStyle(Pressable(scale: 0.98))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A compact menu of every skin.
struct SkinMenu: View {
    let selection: SkinPreset
    let choose: (SkinPreset) -> Void

    var body: some View {
        Menu {
            ForEach(SkinPreset.allCases) { preset in
                Button { choose(preset) } label: {
                    if preset == selection { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(Pressable(scale: 0.97))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Skin")
        .accessibilityValue(selection.title)
    }
}
