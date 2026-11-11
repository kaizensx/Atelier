import SwiftUI

// MARK: - Settings

/// Orbit's chapter: the launcher as its hero, its themes as a gallery, then quiet grouped rows
/// by subject. One view per group, so the lazy stack builds only what shows.
struct OrbitChapter: View {
    private let hue = DockHubHue.tint

    var body: some View {
        OrbitHeroCard()
        SectionHeader("Theme", symbol: "swatchpalette", detail: "The look, the sky and the motion together. Apps, search and keys stay yours.", hue: hue)
        OrbitThemeCard()
        SectionHeader("Layout", symbol: "circle.grid.cross", hue: hue)
        OrbitLayoutCard()
        SectionHeader("Look", symbol: "textformat", hue: hue)
        OrbitLookCard()
        SectionHeader("Sky", symbol: "sparkles", detail: "What sits behind the apps.", hue: hue)
        OrbitBackgroundCard()
        SectionHeader("Motion", symbol: "wind", hue: hue)
        OrbitMotionCard()
        SectionHeader("Apps and Constellations", symbol: "star.circle",
                      detail: "Category keeps one constellation per page. The other sorts lay every app out in one order.", hue: hue)
        OrbitAppsCard()
        SectionHeader("Search", symbol: "magnifyingglass", hue: hue)
        OrbitSearchCard()
        SectionHeader("Opening Orbit", symbol: "command", hue: hue)
        OrbitShortcutCard()
    }
}

private struct OrbitHeroCard: View {
    @ObservedObject private var orbit = Orbit.shared

    var body: some View {
        DockHubActionHero(title: "Orbit",
                          pitch: "Your apps in orbit, over any desktop: sorted by what each app does, searched by typing.",
                          lit: orbit.enabled && orbit.activeShortcut != nil,
                          readout: orbit.enabled ? (orbit.activeShortcut?.label ?? "Taken") : "Off",
                          readoutCaption: "Shortcut",
                          button: "Enter Orbit", symbol: "arrow.up.forward",
                          action: { orbit.toggle() }) {
            // Still at rest; it drifts only while the pointer is on the plate.
            LivePlate { _, since in
                OrbitMiniature(options: orbit.options, animate: since != nil)
            }
        }
    }
}

private struct OrbitThemeCard: View {
    @ObservedObject private var orbit = Orbit.shared
    @State private var hovered: OrbitTheme?

    var body: some View {
        let matching = OrbitTheme.matching(orbit.options)
        Card(padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    ForEach(OrbitTheme.allCases) { theme in
                        Button { withAnimation(DS.Motion.settle) { orbit.apply(theme) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    theme.swatch.0.color
                                    RadialGradient(colors: [theme.swatch.1.color.opacity(0.9), .clear], center: .center,
                                                   startRadius: 0, endRadius: 40)
                                    // Three small worlds on a ring, in the theme's own ink.
                                    Ellipse().strokeBorder(theme.swatch.1.color.opacity(0.35), lineWidth: 0.75)
                                        .frame(width: 70, height: 30)
                                    ForEach(0..<3, id: \.self) { index in
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(theme == .paper ? Color.black.opacity(0.35) : Color.white.opacity(0.75))
                                            .frame(width: 10, height: 10)
                                            .offset(x: [-34.0, 0, 34][index], y: [2.0, -14, 2][index])
                                    }
                                }
                                .frame(height: 64)
                                .clipShape(.rect(cornerRadius: DS.Radius.plate - 4, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: DS.Radius.plate - 4, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                                }
                                Text(theme.title).font(DS.Typo.rowTitle)
                                    .foregroundStyle(matching == theme ? DS.Ink.primary : DS.Ink.secondary)
                                    .padding(.horizontal, 4)
                            }
                            .padding(4)
                            .padding(.bottom, 2)
                            .modifier(DockHubPickFrame(selected: matching == theme, hover: hovered == theme))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable(scale: 0.98))
                        .onHover { inside in hovered = inside ? theme : (hovered == theme ? nil : hovered) }
                        .accessibilityLabel("\(theme.title) theme")
                        .accessibilityAddTraits(matching == theme ? .isSelected : [])
                    }
                }
                if matching == nil {
                    Text("Custom: your own mix. Pick a theme to start again from it.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .padding(.horizontal, DS.Space.s).padding(.bottom, DS.Space.xs)
                }
            }
        }
    }
}

private struct OrbitLayoutCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    private static let glyphs: [OrbitLayoutStyle: String] = [
        .orbits: "circle.circle", .galaxy: "hurricane", .grid: "square.grid.3x3", .honeycomb: "hexagon",
        .arc: "rainbow", .pages: "rectangle.split.3x1",
    ]

    var body: some View {
        Card(padding: DS.Inset.plate) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(OrbitLayoutStyle.allCases, id: \.self) { style in
                    OrbitTile(title: style.title, symbol: Self.glyphs[style] ?? "circle",
                              selected: orbit.options.layout == style) {
                        withAnimation(DS.Motion.settle) { orbit.options.layout = style }
                    }
                }
            }
        }
        RowGroup {
            if orbit.options.layout == .orbits {
                SettingRow(title: "Rings", detail: "Auto fits as many as the screen holds.", density: .compact) {
                    Segments(selection: $orbit.options.rings, options: [(0, "Auto"), (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5")])
                        .frame(width: DockHubLayout.segmentsWidth)
                }
                .dockHubRow()
                .stagePreview(.demo("orbit.Rings", "Rings", isOn: false, region: nil, Demos.orbitRings))
            }
            if orbit.options.layout != .grid && orbit.options.layout != .pages {
                OrbitSliderRow(title: "Spacing", value: $orbit.options.ringSpacing, range: 60...160, format: { "\(Int($0)) pt" })
            }
            OrbitSliderRow(title: "Icon Size", value: $orbit.options.iconSize, range: 40...96, format: { "\(Int($0)) pt" })
            if orbit.options.layout == .orbits {
                SettingRow(title: "Ring Lines", detail: "The faint ellipses the apps travel.", density: .compact) {
                    LuxSwitch(isOn: $orbit.options.showRings, label: "Ring Lines", tint: hue)
                }
                .dockHubRow()
                .stagePreview(.demo("orbit.Ring Lines", "Ring Lines", isOn: orbit.options.showRings, region: nil, Demos.orbitLines))
            }
        }
    }
}

private struct OrbitLookCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            SettingRow(title: "Labels", density: .compact) {
                Segments(selection: $orbit.options.labels, options: OrbitLabelMode.allCases.map { ($0, $0.title) })
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
            .stagePreview(.demo("orbit.Labels", "Labels", isOn: false, region: nil, Demos.orbitLabels))
            if orbit.options.labels != .never {
                SettingRow(title: "Label Type", density: .compact) {
                    Segments(selection: $orbit.options.labelFont, options: OrbitLabelFont.allCases.map { ($0, $0.title) })
                        .frame(width: DockHubLayout.segmentsWidth)
                }
                .dockHubRow()
                SettingRow(title: "Dark Labels", detail: "For light backgrounds such as Paper.", density: .compact) {
                    LuxSwitch(isOn: Binding(get: { orbit.options.ink == .dark }, set: { orbit.options.ink = $0 ? .dark : .light }),
                              label: "Dark Labels", tint: hue)
                }
                .dockHubRow()
            }
            OrbitSliderRow(title: "Hover Magnification", value: $orbit.options.hoverScale, range: 1...1.4,
                           format: { "\(Int(($0 - 1) * 100 + 0.5))%" })
            SettingRow(title: "Running Indicators", detail: "A dot under apps that are open.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.showRunning, label: "Running Indicators", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("orbit.Running Indicators", "Running Indicators", isOn: orbit.options.showRunning, region: nil, Demos.orbitRunning))
            SettingRow(title: "Recent Apps", detail: "A row of what you used last, under the search.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.showRecents, label: "Recent Apps", tint: hue)
            }
            .dockHubRow()
        }
    }
}

private struct OrbitBackgroundCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            OrbitSliderRow(title: "Blur", value: $orbit.options.blur, range: 0...1, format: Self.percent)
            OrbitSliderRow(title: "Dim", value: $orbit.options.dim, range: 0...0.9, format: Self.percent)
            OrbitSliderRow(title: "Tint", value: $orbit.options.tintAmount, range: 0...0.9, format: Self.percent)
            if orbit.options.tintAmount > 0.001 {
                SettingRow(title: "Tint Colour", density: .compact) { OrbitColourWells(selection: $orbit.options.tint) }
                    .dockHubRow()
            }
            SettingRow(title: "Nebula", detail: "The wash of colour behind the apps.", density: .compact) {
                Segments(selection: $orbit.options.nebula, options: OrbitNebula.allCases.map { ($0, $0.title) })
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
            .stagePreview(.demo("orbit.Nebula", "Nebula", isOn: false, region: nil, Demos.orbitNebula))
            if orbit.options.nebula == .custom {
                SettingRow(title: "Nebula Colour", density: .compact) { OrbitColourWells(selection: $orbit.options.nebulaColour) }
                    .dockHubRow()
            }
            OrbitSliderRow(title: "Nebula Strength", value: $orbit.options.nebulaStrength, range: 0...0.6, format: Self.percent)
            SettingRow(title: "Starfield", density: .compact) {
                LuxSwitch(isOn: $orbit.options.stars, label: "Starfield", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("orbit.Starfield", "Starfield", isOn: orbit.options.stars, region: nil, Demos.orbitStars))
            SettingRow(title: "Live Wallpaper Behind",
                       detail: LiveWallpaper.shared.available ? "Your live wallpaper plays under Orbit. Uses the GPU while open."
                                                              : "Needs Metal, which is not available here.",
                       density: .compact) {
                LuxSwitch(isOn: $orbit.options.liveWallpaper, label: "Live Wallpaper Behind", tint: hue)
            }
            .dockHubRow()
            .disabled(!LiveWallpaper.shared.available)
        }
    }

    static func percent(_ value: Double) -> String { "\(Int(value * 100 + 0.5))%" }
}

private struct OrbitMotionCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            SettingRow(title: "Drift", detail: "Orbits turn gently and stop when you reach for them.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.drift, label: "Drift", tint: hue)
            }
            .dockHubRow()
            .help("Orbits and galaxies turn gently and stop when you reach for them. Still with Reduce Motion.")
            .stagePreview(.demo("orbit.Drift", "Drift", isOn: orbit.options.drift, region: nil, Demos.orbitDrift))
            if orbit.options.drift {
                OrbitSliderRow(title: "Drift Speed", value: $orbit.options.driftSpeed, range: 0.2...3,
                               format: { String(format: "%.1f×", $0) })
                SettingRow(title: "Direction", density: .compact) {
                    Segments(selection: $orbit.options.driftDirection, options: OrbitDriftDirection.allCases.map { ($0, $0.title) })
                        .frame(width: DockHubLayout.segmentsWidth)
                }
                .dockHubRow()
            }
            SettingRow(title: "Opening", detail: "How the apps arrive.", density: .compact) {
                Segments(selection: $orbit.options.openStyle, options: OrbitOpenStyle.allCases.map { ($0, $0.title) })
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
        }
    }
}

private struct OrbitAppsCard: View {
    @ObservedObject private var orbit = Orbit.shared
    @State private var newName = ""
    @State private var showingApps = false
    @State private var filter = ""

    var body: some View {
        RowGroup {
            SettingRow(title: "Sort", density: .compact) {
                Segments(selection: $orbit.options.sort, options: OrbitSort.allCases.map { ($0, $0.title) })
                    .frame(width: 340)
            }
            .dockHubRow()
        }
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(spacing: 6) {
                    ForEach(orbit.options.groups, id: \.id) { group in
                        OrbitGroupRow(orbit: orbit, group: group)
                    }
                }
                HStack(spacing: 8) {
                    TextField("New constellation", text: $newName)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .onSubmit(add)
                    OrbitPillButton(title: "Add", symbol: "plus", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !orbit.options.favourites.isEmpty {
                    DockSubhead(text: "Pinned to the Centre")
                    OrbitChips(paths: orbit.options.favourites, symbol: "pin.slash") { orbit.toggleFavourite($0) }
                }
                if !orbit.options.hidden.isEmpty {
                    DockSubhead(text: "Hidden")
                    OrbitChips(paths: orbit.options.hidden, symbol: "eye") { orbit.hide($0, false) }
                }
            }
        }
        RowGroup {
            SettingRow(title: "Arrange Apps", detail: "Pin, hide or move apps. Right-click one in Orbit does the same.", density: .compact) {
                OrbitPillButton(title: showingApps ? "Done" : "Show", symbol: showingApps ? "chevron.up" : "chevron.down") {
                    withAnimation(DS.Motion.reveal) { showingApps.toggle() }
                }
            }
            .dockHubRow()
            if showingApps { OrbitAppList(orbit: orbit, filter: $filter).dockHubRow() }
        }
        if !orbit.folders.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(orbit.folders.count == 1 ? "1 Folder" : "\(orbit.folders.count) Folders")
                        .font(DS.title).foregroundStyle(DS.Ink.primary)
                    Text("Folders live only in Orbit. Removing them leaves your apps untouched.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    HoldButton(title: "Hold to Remove Folders") { orbit.removeAllFolders() }
                }
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        orbit.addCategory(named: name)
        newName = ""
    }
}

private struct OrbitGroupRow: View {
    @ObservedObject var orbit: Orbit
    let group: OrbitGroup
    @State private var name = ""

    private var custom: Bool { group.id.hasPrefix("custom:") }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(group.rgb.color)
                .frame(width: 22)
            TextField(group.title, text: $name)
                .textFieldStyle(.plain)
                .font(DS.body)
                .foregroundStyle(DS.Ink.primary)
                .onSubmit(commit)
            Menu {
                ForEach(Array(OrbitRGB.palette.enumerated()), id: \.offset) { _, colour in
                    Button { recolour(colour) } label: {
                        Label(colour == group.rgb ? "Current" : "Colour", systemImage: "circle.fill")
                    }
                    .tint(colour.color)
                }
                if custom {
                    Divider()
                    ForEach(OrbitCustomCategory.symbols, id: \.self) { symbol in
                        Button { resymbol(symbol) } label: { Label(symbol, systemImage: symbol) }
                    }
                }
            } label: {
                Circle().fill(group.rgb.color).frame(width: 14, height: 14)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Colour for \(group.title)")
            if custom {
                Button { orbit.removeCategory(group.id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Ink.tertiary)
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Remove \(group.title)")
            } else if orbit.options.renamed[group.id] != nil || orbit.options.recoloured[group.id] != nil {
                Button {
                    orbit.options.renamed.removeValue(forKey: group.id)
                    orbit.options.recoloured.removeValue(forKey: group.id)
                    name = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(DS.Ink.tertiary)
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Restore \(group.title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .onAppear { name = group.title }
        .onChange(of: group.title) { _, value in name = value }
    }

    private func commit() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != group.title else { return }
        if let index = orbit.options.customCategories.firstIndex(where: { $0.id == group.id }) {
            orbit.options.customCategories[index].name = clean
        } else {
            orbit.options.renamed[group.id] = clean
        }
    }

    private func recolour(_ colour: OrbitRGB) {
        if let index = orbit.options.customCategories.firstIndex(where: { $0.id == group.id }) {
            orbit.options.customCategories[index].colour = colour
        } else {
            orbit.options.recoloured[group.id] = colour
        }
    }

    private func resymbol(_ symbol: String) {
        guard let index = orbit.options.customCategories.firstIndex(where: { $0.id == group.id }) else { return }
        orbit.options.customCategories[index].symbol = symbol
    }
}

/// Every app, filtered, with its constellation, pin and visibility. Built only when opened.
private struct OrbitAppList: View {
    @ObservedObject var orbit: Orbit
    @Binding var filter: String
    @State private var apps: [OrbitApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter apps", text: $filter)
                .textFieldStyle(.plain)
                .font(DS.body)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            let shown = filtered
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(shown, id: \.path) { app in
                        OrbitAppRow(orbit: orbit, app: app)
                    }
                }
            }
            .frame(height: 280)
            .scrollIndicators(.never)
        }
        .task {
            // Read the catalog once, when the list opens.
            apps = AppCatalog.shared.apps.map { OrbitApp(path: $0.value, name: $0.name) }
        }
    }

    private var filtered: [OrbitApp] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return apps }
        return apps.filter { OrbitPlanner.score(needle, in: $0.name, fuzzy: orbit.options.fuzzy) != nil }
    }
}

private struct OrbitAppRow: View {
    @ObservedObject var orbit: Orbit
    @ObservedObject private var icons = AtelierIcons.shared
    let app: OrbitApp

    var body: some View {
        let pinned = orbit.options.favourites.contains(app.path)
        let hidden = orbit.options.hidden.contains(app.path)
        let group = orbit.options.group(for: orbit.groupID(of: app.path))
        HStack(spacing: 10) {
            // Click the icon to give the app another one in Orbit (and Atelier's other places).
            IconChooserMenu(query: app.name, canReset: icons.has(app.path),
                            onPick: { icons.set($0, for: app.path) },
                            onReset: { icons.reset(app.path) }) {
                OrbitIconStore.shared.image(app.path).resizable().interpolation(.high).frame(width: 22, height: 22)
                    .id(icons.revision)
                    .contentShape(.rect)
            }
            .help("Change icon")
            Text(app.name).font(DS.body).foregroundStyle(hidden ? DS.Ink.tertiary : DS.Ink.primary).lineLimit(1)
            Spacer(minLength: 6)
            Menu {
                ForEach(orbit.options.groups, id: \.id) { choice in
                    Button { orbit.assign(app.path, to: choice.id) } label: {
                        Label(choice.title, systemImage: choice.id == group.id ? "checkmark" : choice.symbol)
                    }
                }
                if orbit.options.assigned[app.path] != nil {
                    Divider()
                    Button("Automatic") { orbit.assign(app.path, to: nil) }
                }
            } label: {
                Text(group.title).font(DS.caption).foregroundStyle(group.rgb.color)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Button { orbit.toggleFavourite(app.path) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin").foregroundStyle(pinned ? DockHubHue.tint : DS.Ink.tertiary)
            }
            .buttonStyle(Pressable(scale: 0.9))
            .accessibilityLabel(pinned ? "Unpin \(app.name)" : "Pin \(app.name) to the centre")
            Button { orbit.hide(app.path, !hidden) } label: {
                Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(hidden ? DockHubHue.tint : DS.Ink.tertiary)
            }
            .buttonStyle(Pressable(scale: 0.9))
            .accessibilityLabel(hidden ? "Show \(app.name)" : "Hide \(app.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

private struct OrbitSearchCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            SettingRow(title: "Fuzzy Matching", detail: "“sfr” finds Safari. Off, the letters must be together.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.fuzzy, label: "Fuzzy Matching", tint: hue)
            }
            .dockHubRow()
            SettingRow(title: "System Settings", detail: "Also find settings panes, like Sound or Displays.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.searchSettings, label: "System Settings", tint: hue)
            }
            .dockHubRow()
            SettingRow(title: "Files", detail: "Also ask Spotlight for files in your home folder by name.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.searchFiles, label: "Files", tint: hue)
            }
            .dockHubRow()
            .help("Also ask Spotlight for files in your home folder by name, while you type. Off by default.")
        }
    }
}

private struct OrbitShortcutCard: View {
    @ObservedObject private var orbit = Orbit.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            SettingRow(title: "Orbit Shortcut", detail: shortcutDetail, density: .compact) {
                LuxSwitch(isOn: $orbit.enabled, label: "Orbit", tint: hue)
            }
            .dockHubRow()
            DockHubWideRow("Keys") {
                Segments(selection: $orbit.shortcut, options: OrbitShortcut.all.indices.map { ($0, OrbitShortcut.all[$0].label) })
            }
            SettingRow(title: "Mouse Button", detail: "A spare button opens and closes Orbit.", density: .compact) {
                Segments(selection: $orbit.options.openButton, options: OrbitOpenButton.allCases.map { ($0, $0.title) })
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
            SettingRow(title: "Display", detail: "Where Orbit opens when you have more than one.", density: .compact) {
                Segments(selection: $orbit.options.display, options: OrbitDisplay.allCases.map { ($0, $0.title) })
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
            SettingRow(title: "Type to Search", detail: "Off, press / or ⌘F first, so letters never search by accident.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.typeToSearch, label: "Type to Search", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("orbit.Type to Search", "Type to Search", isOn: orbit.options.typeToSearch, region: nil, Demos.typeToSearch))
            SettingRow(title: "Wrap Around", detail: "Arrows past the last app come back from the other side.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.wrapNavigation, label: "Wrap Around", tint: hue)
            }
            .dockHubRow()
            SettingRow(title: "⌘1 to ⌘9", detail: "Jump straight to a constellation.", density: .compact) {
                LuxSwitch(isOn: $orbit.options.numberKeys, label: "Command Number Keys", tint: hue)
            }
            .dockHubRow()
        }
        HoldButton(title: "Hold to Reset Orbit Settings") { orbit.resetOptions() }
            .padding(.top, DS.Space.s)
    }

    private var shortcutDetail: String {
        guard orbit.enabled else { return "Off. Enter Orbit from the button above." }
        guard let active = orbit.activeShortcut else { return "Every shortcut is taken. Enter Orbit from above." }
        let chosen = OrbitShortcut.all[orbit.shortcut]
        return active == chosen ? "Press \(active.label) anywhere." : "\(chosen.label) is taken, so Orbit uses \(active.label)."
    }
}

// MARK: - Pieces

private struct OrbitSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                .frame(width: DockHubLayout.labelWidth + 16, alignment: .leading)
            LuxSlider(value: $value, range: range, label: title, tint: DockHubHue.tint)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value)).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                .fixedSize().frame(minWidth: 48, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }
}

private struct OrbitTile: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? DockHubHue.tint : DS.Ink.secondary)
                Text(title).font(DS.Typo.rowTitle)
                    .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .modifier(DockHubPickFrame(selected: selected, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OrbitColourWells: View {
    @Binding var selection: OrbitRGB

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(OrbitRGB.palette.enumerated()), id: \.offset) { _, colour in
                Button { selection = colour } label: {
                    Circle()
                        .fill(colour.color)
                        .frame(width: 20, height: 20)
                        .overlay { Circle().strokeBorder(.white.opacity(selection == colour ? 0.95 : 0.15), lineWidth: selection == colour ? 2 : 0.5) }
                        .contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Colour")
                .accessibilityAddTraits(selection == colour ? .isSelected : [])
            }
        }
    }
}

private struct OrbitPillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(DS.Ink.fillStrong, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
    }
}

private struct OrbitChips: View {
    let paths: [String]
    let symbol: String
    let action: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                Button { action(path) } label: {
                    HStack(spacing: 6) {
                        OrbitIconStore.shared.image(path).resizable().interpolation(.high).frame(width: 18, height: 18)
                        Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            .font(DS.caption).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(DS.Ink.fill, in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.96))
            }
        }
    }
}

// MARK: - Miniature

/// The real layout at small scale, with your own apps, in the sky you chose. A leaf: one Canvas
/// redrawn at display rate while it drifts, still otherwise.
struct OrbitMiniature: View {
    let options: OrbitOptions
    /// False holds it still at its rest pose, as a plate does while the pointer is elsewhere.
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var icons: [CGImage] = []

    private static let world = CGSize(width: 1440, height: 900)

    var body: some View {
        let drifting = animate && options.drift && options.layout.drifts && !reduceMotion
        let plan = Self.plan(options, count: max(icons.count, 14))
        let hue = options.nebula == .custom ? options.nebulaColour : (options.nebula == .wallpaper
            ? (Orbit.shared.wallpaperRGB ?? options.nebulaColour) : OrbitCategory.media.rgb)
        TimelineView(.animation(paused: !drifting)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            Canvas { context, size in
                draw(&context, size: size, time: drifting ? time : 0, plan: plan, hue: hue)
            }
        }
        .background(Color.black.opacity(0.35))
        .task { icons = Self.loadIcons() }
        .accessibilityHidden(true)
    }

    private static func loadIcons() -> [CGImage] {
        let recent = AppCatalog.shared.items(for: .recentlyUsed, fallback: []).map(\.value)
        let paths = Array((recent.isEmpty ? AppCatalog.shared.apps.map(\.value) : recent + AppCatalog.shared.apps.map(\.value)).prefix(18))
        return paths.compactMap { OrbitIconStore.shared.picture($0) }
    }

    private static func plan(_ options: OrbitOptions, count: Int) -> (spots: [OrbitSpot], rings: [OrbitRing], field: CGRect) {
        let params = OrbitLayoutParams(options)
        let field = OrbitLayout.field(world, params)
        let placed = OrbitLayout.spots(count: count, core: 0, params, field: field)
        return (placed.spots, placed.rings, field)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double,
                      plan: (spots: [OrbitSpot], rings: [OrbitRing], field: CGRect), hue: OrbitRGB) {
        let scale = min(size.width / Self.world.width, size.height / Self.world.height)
        let dx = (size.width - Self.world.width * scale) / 2, dy = (size.height - Self.world.height * scale) / 2
        let map = { (p: CGPoint) in CGPoint(x: dx + p.x * scale, y: dy + p.y * scale) }
        let all = CGRect(origin: .zero, size: size)

        context.fill(Path(all), with: .color(.black.opacity(options.dim)))
        if options.tintAmount > 0.001 { context.fill(Path(all), with: .color(options.tint.color.opacity(options.tintAmount))) }
        let centre = map(CGPoint(x: plan.field.midX, y: plan.field.midY))
        context.fill(Path(all), with: .radialGradient(Gradient(colors: [hue.color.opacity(options.nebulaStrength * 1.4), .clear]),
                                                      center: centre, startRadius: 4, endRadius: size.width * 0.5))
        if options.stars {
            var generator = OrbitSeed(state: 0x5EED)
            for _ in 0..<48 {
                let x = generator.next() * size.width, y = generator.next() * size.height
                let side = 0.6 + generator.next() * 1.1
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: side, height: side)),
                             with: .color(.white.opacity(0.1 + generator.next() * 0.35)))
            }
        }
        if options.showRings {
            for ring in plan.rings {
                let rect = CGRect(x: centre.x - ring.rx * scale, y: centre.y - ring.ry * scale, width: ring.rx * 2 * scale, height: ring.ry * 2 * scale)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.12)), lineWidth: 0.6)
            }
        }
        let side = max(options.iconSize * scale * 1.15, 8)
        let ink: Color = options.ink == .light ? .white.opacity(0.7) : .black.opacity(0.6)
        for (index, spot) in plan.spots.enumerated() {
            let (point, depth) = spot.place(time)
            let p = map(point)
            let depthScale = options.layout.drifts ? 0.85 + 0.2 * depth : 1
            let s = side * depthScale
            let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2 - (options.labels == .always ? 2 : 0), width: s, height: s)
            if icons.isEmpty {
                context.fill(Path(roundedRect: rect, cornerRadius: s * 0.24), with: .color(.white.opacity(0.25)))
            } else {
                context.draw(Image(decorative: icons[index % icons.count], scale: 2), in: rect)
            }
            if options.labels == .always {
                let bar = CGRect(x: p.x - s * 0.4, y: rect.maxY + 2, width: s * 0.8, height: 1.6)
                context.fill(Path(roundedRect: bar, cornerRadius: 0.8), with: .color(ink))
            }
        }
    }
}
