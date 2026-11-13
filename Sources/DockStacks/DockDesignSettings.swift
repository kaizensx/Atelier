import AppKit
import SwiftUI

// The Design and Effects cards of the Dock chapter. The gallery draws every design with the
// real bar view on a still scene, built once, with flat stand-ins for glass: live glass
// inside the panel's own glass is re-blurred every frame the panel moves. Only the selected
// design and the one under the pointer run their Core Animation layers.

// MARK: - Design

struct DockDesignCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @State private var lookTinted = false
    @State private var chipThemes: [DockStyle: DockTheme] = [:]
    private let hue = DockHubHue.tint

    private var accentNote: String? {
        if dock.appearance.style == .wallpaper, dock.design.design.usesGlassFinish {
            return "Wallpaper takes its colour from the desktop picture."
        }
        if dock.followLook, lookTinted { return "Follow the Look sets the colour while a Look has one." }
        return nil
    }

    private func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }

    private var isDefault: Bool {
        var look = dock.appearance
        look.resetLook()
        return dock.appearance == look && dock.design.design == .liquidGlass && dock.design.mark == nil && !dock.design.backplate
    }

    var body: some View {
        // The gallery: a plate-inset card, so each tile's radius sits concentric inside it.
        Card(padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DockDesignGallery()
                if dock.design.design.usesGlassFinish {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        DockSubhead(text: "Glass Finish").padding(.horizontal, DS.Space.s)
                        FlowRow(spacing: 6) {
                            ForEach(DockStyle.allCases) { style in
                                DockStyleChip(style: style, theme: chipThemes[style] ?? dock.currentTheme,
                                              selected: dock.appearance.style == style) {
                                    withAnimation(DS.Motion.settle) { dock.appearance.style = style }
                                }
                            }
                        }
                    }
                    .padding(.top, DS.Space.xs)
                    .padding(.bottom, DS.Space.xs)
                }
            }
        }
        .onAppear {
            lookTinted = DockTheme.lookColors() != nil
            makeChipThemes()
        }
        .onChange(of: dock.appearance.accent) { makeChipThemes() }
        .onChange(of: dock.followLook) { makeChipThemes() }
        RowGroup {
            SettingRow(title: "Colour", detail: accentNote, density: .compact) {
                HStack(spacing: 2) {
                    ForEach(DockAccent.allCases) { accent in
                        DockAccentSwatch(accent: accent, selected: dock.appearance.accent == accent) {
                            dock.appearance.accent = accent
                        }
                    }
                }
            }
            .dockHubRow()
            SettingRow(title: "Open App Mark", detail: "What sits under an app that is open.", density: .compact) {
                DockMenuPill(selection: Binding(get: { dock.mark }, set: { dock.mark = $0 }),
                             options: DockMarkChoice.all.map { ($0, $0.title) })
            }
            .dockHubRow()
            SettingRow(title: "Icon Shadow", detail: "A soft shadow under each icon.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.iconShadow, label: "Icon Shadow", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.dock("shadow", "Shadow", detail: dock.appearance.iconShadow ? "On → Off" : "Off → On") { $0.appearance.iconShadow.toggle() })
            SettingRow(title: "Reflection", detail: "Icons mirrored faintly in the bar below them.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.reflection, label: "Reflection", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.dock("reflection", "Reflection", detail: dock.appearance.reflection ? "On → Off" : "Off → On") { $0.appearance.reflection.toggle() })
            SettingRow(title: "Icon Plates", detail: "Each icon on a plate of the design's own material.", density: .compact) {
                LuxSwitch(isOn: $dock.design.backplate, label: "Icon Plates", tint: hue)
            }
            .dockHubRow()
            .help("Each icon on a plate of the design's material: glass, glaze, paper, metal or pixels.")
            .stagePreview(.dock("plates", "Plates", detail: dock.design.backplate ? "On → Off" : "Off → On") { $0.design.backplate.toggle() })
            DockSliderRow(title: "Corners", value: $dock.appearance.roundness, range: 0...1,
                          text: dock.appearance.roundness > 0.97 ? "Capsule" : "\(Int((dock.appearance.roundness * 100).rounded()))%")
            DockSliderRow(title: "Padding", value: $dock.appearance.padding, range: 0.04...0.3,
                          text: points(dock.tile * dock.appearance.padding))
            DockSliderRow(title: "Spacing", value: $dock.appearance.spacing, range: 0...0.5,
                          text: points(dock.tile * dock.appearance.spacing))
            SettingRow(title: "Follow the Look", detail: "Glass, rim and marks take the current Look's colours.", density: .compact) {
                LuxSwitch(isOn: $dock.followLook, label: "Follow the Look", tint: hue)
            }
            .dockHubRow()
            if !isDefault {
                SettingRow(title: "Back to Liquid Glass", detail: "The first design, with its own finish and marks.", density: .compact) {
                    RevertGlyph(was: "Liquid Glass") {
                        withAnimation(DS.Motion.settle) {
                            dock.appearance.resetLook()
                            dock.selectDesign(.liquidGlass)
                        }
                    }
                }
                .dockHubRow()
            }
        }
    }

    private func makeChipThemes() {
        var themes: [DockStyle: DockTheme] = [:]
        for style in DockStyle.allCases {
            var look = dock.appearance
            look.style = style
            themes[style] = dock.theme(for: look)
        }
        chipThemes = themes
    }
}

/// Every design, drawn live at small size. Picking one puts it on with what it recommends.
struct DockDesignGallery: View {
    @ObservedObject private var dock = OwnDock.shared
    @State private var scene: DockScene?
    @State private var themes: [DockDesign: DockTheme] = [:]
    @State private var hovered: DockDesign?
    @State private var width = 0.0
    /// The previews fill in one per frame or so, so opening the chapter never pays for all
    /// ten bars in a single frame.
    @State private var revealed = 0

    static let previewHeight = 84.0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], spacing: 8) {
            ForEach(Array(DockDesign.allCases.enumerated()), id: \.element) { index, design in
                DockDesignTile(design: design, scene: index < revealed ? scene : nil, theme: themes[design] ?? dock.currentTheme,
                               selected: dock.design.design == design, live: hovered == design || dock.design.design == design,
                               hover: hovered == design, vitals: dock.vitals) {
                    withAnimation(DS.Motion.settle) { dock.selectDesign(design) }
                }
                .stagePreview(.dock("design." + design.rawValue, design.title, detail: "Design") { look in
                    (look.design, look.appearance) = OwnDock.choosing(design, design: look.design, appearance: look.appearance)
                })
                .onHover { inside in
                    // A design's own animation starts under the pointer; not for bars that
                    // pass under it during a scroll.
                    if inside, ScrollActivity.scrolling { return }
                    if inside { hovered = design } else if hovered == design { hovered = nil }
                }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { width = geometry.size.width; build() }
                    .onChange(of: geometry.size.width) { _, new in
                        // Columns change only past a threshold; rebuild when the tile width really moves.
                        if abs(new - width) > 24 { width = new; build() }
                    }
            }
        }
        .task {
            for step in 1...DockDesign.allCases.count {
                try? await Task.sleep(for: .milliseconds(12))
                if Task.isCancelled { return }
                revealed = step
            }
        }
        .onChange(of: dock.appearance) { makeThemes() }
        .onChange(of: dock.design) { makeThemes() }
        .onChange(of: dock.followLook) { makeThemes() }
    }

    private func build() {
        let columns = max(Int((width + 8) / 204), 1)
        // Each tile insets its preview by 4 pt on either side.
        let tile = max((width - Double(columns - 1) * 8) / Double(columns) - 8, 120)
        scene = DockDesignSample.scene(dock.slots(), size: CGSize(width: tile, height: Self.previewHeight))
        makeThemes()
    }

    private func makeThemes() {
        var made: [DockDesign: DockTheme] = [:]
        for design in DockDesign.allCases {
            if design == dock.design.design { made[design] = dock.currentTheme; continue }
            let recommended = design.recommended
            var prefs = dock.design
            prefs.design = design
            prefs.mark = recommended.mark
            prefs.backplate = recommended.backplate
            prefs.hover = recommended.hover
            var look = dock.appearance
            look.indicator = recommended.indicator
            look.iconShadow = recommended.shadow
            look.reflection = recommended.reflection
            if design == .retro { look.accent = .green }
            made[design] = dock.theme(for: look, design: prefs)
        }
        themes = made
    }
}

private struct DockDesignTile: View {
    let design: DockDesign
    let scene: DockScene?
    let theme: DockTheme
    let selected: Bool
    let live: Bool
    let hover: Bool
    let vitals: Vitals
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.48), Color(red: 0.5, green: 0.26, blue: 0.46),
                                            Color(red: 0.9, green: 0.56, blue: 0.36)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let scene {
                        OwnDockBar(scene: scene, theme: theme, vitals: vitals, flat: true, rowShadow: false, animating: live)
                            .frame(width: scene.panel.width, height: scene.panel.height)
                    }
                }
                .frame(height: DockDesignGallery.previewHeight)
                .frame(maxWidth: .infinity)
                // Concentric: the tile's radius 12, less its 4 pt inset.
                .clipShape(.rect(cornerRadius: DS.Radius.plate - 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.plate - 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(design.title).font(DS.Typo.rowTitle)
                            .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
                        if design.animated {
                            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(selected ? DockHubHue.tint : DS.Ink.glyph)
                                .help("Animated")
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                .foregroundStyle(DockHubHue.tint)
                                .transition(.opacity)
                        }
                    }
                    Text(design.blurb).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(4)
            .modifier(DockHubPickFrame(selected: selected, hover: hover))
            .contentShape(.rect)
        }
        .buttonStyle(Pressable(scale: 0.985))
        .accessibilityLabel(design.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint(design.blurb)
    }
}

/// A still scene for previews: the dock's own apps, a separator, and a folder or the Trash.
enum DockDesignSample {
    @MainActor static func scene(_ slots: [DockSlot], size: CGSize) -> DockScene {
        var apps = slots.filter { $0.kind == .app && !$0.path.isEmpty }.prefix(5).map { slot -> DockSlot in
            var slot = slot
            slot.launching = false
            slot.attention = false
            slot.badge = nil
            return slot
        }
        if apps.isEmpty {
            apps = ["/System/Applications/Finder.app", "/System/Applications/Safari.app", "/System/Applications/Mail.app",
                    "/System/Applications/Music.app"].map { DockSlot(id: $0, kind: .app, path: $0, pinned: true) }
        }
        if let first = apps.indices.first { apps[first].running = true; apps[first].frontmost = true }
        if apps.count > 2 { apps[2].running = true }
        var list = Array(apps)
        list.append(.divider)
        list.append(DockSlot(id: "trash", kind: .trash, path: TrashWatcher.url.path, title: "Trash"))
        var field = DockField()
        field.motion = false
        field.sync(list, instant: true)
        var metrics = DockMetrics(edge: .bottom, tile: 30, large: 30, magnify: false, panel: size)
        let look = OwnDock.shared.appearance
        metrics.apply(look, scale: 0.5)
        metrics.gap = 14
        // A long bar must still fit the tile.
        let fitted = field.fitted(metrics)
        metrics.tile = fitted.tile
        return field.scene(metrics)
    }
}

// MARK: - Effects

struct DockEffectsCard: View {
    @ObservedObject private var dock = OwnDock.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            DockHubWideRow("While an App Opens") {
                Segments(selection: $dock.appearance.launch, options: DockLaunchStyle.allCases.map { ($0, $0.title) })
            }
            DockHubWideRow("When It Has Opened") {
                Segments(selection: $dock.design.launch, options: DockLaunchEffect.allCases.map { ($0, $0.title) })
            }
            DockHubWideRow("Hover", detail: dock.hoverEffect.note) {
                Segments(selection: Binding(get: { dock.hoverEffect }, set: { dock.hoverEffect = $0 }),
                         options: DockHoverEffect.allCases.map { ($0, $0.title) })
            }
            DockHubWideRow("Dropping a File") {
                Segments(selection: $dock.design.drop, options: DockDropEffect.allCases.map { ($0, $0.title) })
            }
            DockHubWideRow("Trash") {
                Segments(selection: $dock.design.trash, options: DockTrashEffect.allCases.map { ($0, $0.title) })
            }
            DockHubWideRow("Minimising") {
                Segments(selection: $dock.design.minimize, options: DockMinimizeEffect.allCases.map { ($0, $0.title) })
            }
            MinimizeEffectPicker()
            SettingRow(title: "Idle Breathing", detail: "The rim glows slowly in and out.", density: .compact) {
                LuxSwitch(isOn: $dock.design.breathing, label: "Idle Breathing", tint: hue)
            }
            .dockHubRow()
            .help("Played by Core Animation, and stopped while the dock is hidden.")
            .stagePreview(.dock("breathing", "Idle Breathing", detail: dock.design.breathing ? "On → Off" : "Off → On") { $0.design.breathing.toggle() })
            SettingRow(title: "Sounds", detail: "Quiet system sounds as apps open, files drop and windows minimise.", density: .compact) {
                LuxSwitch(isOn: $dock.design.sounds, label: "Sounds", tint: hue)
            }
            .dockHubRow()
            .help("Quiet macOS system sounds when an app opens, a file drops, the Trash takes something and a window minimises.")
            if dock.design.sounds {
                HStack(spacing: 10) {
                    DockSliderRow(title: "Volume", value: $dock.design.volume, range: 0.05...1,
                                  text: "\(Int((dock.design.volume * 100).rounded()))%")
                    DockPillButton(title: "Play", symbol: "speaker.wave.2") { DockSounds.play(.launch, prefs: dock.design) }
                }
                SoundPackPicker(typing: false).dockHubRow()
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                Text("Reduce Motion is on, so effects that move play as fades or not at all.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .dockHubRow()
            }
        }
    }
}
