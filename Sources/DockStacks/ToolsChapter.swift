import AppKit
import DockCore
import SwiftUI

/// The Tools half of the Window Engine chapter: shortcuts, custom layouts, app rules, pins.
/// Quiet grouped rows in the Windows light; the layouts are a gallery of their own.
struct ToolsCards: View {
    let trusted: Bool
    @ObservedObject private var tools = Tools.shared
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var keys = ToolsHotKeys.shared
    @State private var editing: CustomLayout?
    private let hue = DS.Spectrum.windows
    private let gallery = [GridItem(.adaptive(minimum: 172), spacing: DS.Space.m)]

    var body: some View {
        SectionHeader("Window tools", symbol: "macwindow.on.rectangle",
                      detail: "Global shortcuts you record yourself. Nothing is registered until you do.", hue: hue)
        shortcutsCard
        SectionHeader("Custom layouts", symbol: "rectangle.split.3x3",
                      detail: "Draw your own zones. Hold Shift while dragging a window to drop it into one.", hue: hue)
        layoutsCard
        if editing != nil { editorCard }
        SectionHeader("App rules", symbol: "app.badge.checkmark", detail: "Always open an app in the same place.", hue: hue)
        AppRulesCard(trusted: trusted)
        SectionHeader("Pin window", symbol: "pip", detail: "A live copy of a window that floats above everything.", hue: hue)
        pinCard
        honestNote
    }

    // MARK: Shortcuts

    @ViewBuilder private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            NeedsAccessRow(reason: "Shortcuts, custom layouts and app rules move windows with it.",
                           previewTrusted: trusted ? nil : false)
            RowGroup {
                ForEach([ToolAction.center, .resizePercent, .cycleWindows, .nextZone]) { action in
                    SettingRow(title: action.title, symbol: action.symbol, density: .compact) {
                        HStack(spacing: 6) {
                            Chip("Run") { action.perform() }
                            ShortcutRecorder(action: action)
                        }
                    }
                    if action == .resizePercent {
                        SettingRow(title: "Size", detail: "How much of the screen Resize to Percent fills.",
                                   symbol: "arrow.up.left.and.arrow.down.right", density: .compact) {
                            CommitSlider(value: $tools.percent, range: 0.4...1).frame(width: 220)
                        }
                    }
                }
            }
            if !keys.conflicts.isEmpty {
                Text("Taken by another app: \(keys.conflicts.map(\.title).sorted().joined(separator: ", ")). Record a different shortcut.")
                    .font(DS.caption).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.xs)
            }
        }
    }

    // MARK: Layouts

    private var layoutsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            RowGroup {
                SettingRow(title: "Shift-Drag into Zones", detail: "While you drag a window with Shift held, the active layout’s zones light up.",
                           symbol: "shift", density: .compact) {
                    LuxSwitch(isOn: $tools.shiftDragZones, label: "Shift-Drag into Zones", tint: hue)
                }
                .stagePreview(.demo("tools.shift", "Shift-Drag into Zones", isOn: tools.shiftDragZones, region: StageRegion.window, Demos.shiftDragZones))
            }
            LazyVGrid(columns: gallery, alignment: .leading, spacing: DS.Space.m) {
                ForEach(tools.layouts) { layout in
                    ToolsLayoutTile(layout: layout, active: tools.active?.id == layout.id, hue: hue,
                                    use: { tools.activeLayout = layout.id },
                                    edit: { withAnimation(DS.Motion.reveal) { editing = layout } },
                                    delete: { delete(layout) })
                }
                ToolsNewLayoutTile(hue: hue, empty: tools.layouts.isEmpty, new: {
                    withAnimation(DS.Motion.reveal) { editing = CustomLayout(name: "My Layout", zones: []) }
                }, preset: { preset in
                    tools.layouts.append(CustomLayout(name: preset.name, zones: preset.zones))
                    if tools.activeLayout == nil { tools.activeLayout = tools.layouts.last?.id }
                })
            }
        }
    }

    private func delete(_ layout: CustomLayout) {
        tools.layouts.removeAll { $0.id == layout.id }
        if tools.activeLayout == layout.id { tools.activeLayout = tools.layouts.first?.id }
        tools.rules.removeAll { if case let .zone(id, _) = $0.placement { id == layout.id } else { false } }
    }

    private var editorCard: some View {
        Card(style: .lit(hue)) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    TextField("Layout name", text: Binding(get: { editing?.name ?? "" }, set: { editing?.name = $0 }))
                        .textFieldStyle(.plain).font(DS.title)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    Chip("Clear") { editing?.zones = [] }
                }
                ZoneEditor(zones: Binding(get: { editing?.zones ?? [] }, set: { editing?.zones = $0 }), tint: hue)
                Text("Drag across the grid to draw a zone. Smaller zones drawn over bigger ones win.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                HStack {
                    Chip("Cancel") { withAnimation(DS.Motion.exit) { editing = nil } }
                    Spacer()
                    Chip("Save Layout") { save() }
                        .disabled((editing?.zones.isEmpty ?? true))
                }
            }
        }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    private func save() {
        guard var layout = editing, !layout.zones.isEmpty else { return }
        layout.name = layout.name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Layout" : layout.name
        if let index = tools.layouts.firstIndex(where: { $0.id == layout.id }) { tools.layouts[index] = layout }
        else { tools.layouts.append(layout) }
        if tools.activeLayout == nil { tools.activeLayout = layout.id }
        withAnimation(DS.Motion.exit) { editing = nil }
    }

    // MARK: Pin

    private var pinCard: some View {
        Card(style: pin.count > 0 ? .lit(hue) : .standard) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                // The shortcut and Pin move under the text when they would squeeze it.
                AdaptiveRowLayout(spacing: DS.Space.m, hasSymbol: true) {
                    Image(systemName: "pip").font(.system(size: 14, weight: .semibold)).foregroundStyle(hue)
                        .frame(width: 32, height: 32)
                        .background(hue.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pin Front Window").font(DS.title)
                        Text("Drag to move, double-click to go to it. Needs Screen Recording.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Streams one window with ScreenCaptureKit into a floating panel.")
                    ShortcutRecorder(action: .pinWindow)
                    Chip(pin.starting ? "Pinning…" : "Pin") { pin.pinFrontWindow() }
                }
                ScreenRecordingNeeded(detail: "A pin is a live capture of the window. Allow Atelier in System Settings, Privacy & Security, Screen Recording; Pin works as soon as you do.")
                RowGroup {
                    SettingRow(title: "Frame Rate", symbol: "speedometer", density: .compact) {
                        Segments(selection: $pin.fps, options: [(30, "30"), (60, "60"), (120, "120")]).frame(width: 180)
                    }
                    SettingRow(title: "Opacity", symbol: "circle.lefthalf.filled", density: .compact) {
                        CommitSlider(value: $pin.opacity, range: 0.3...1).frame(width: 220)
                    }
                }
                HStack {
                    Text(pin.count == 0 ? "Nothing pinned. Capture runs only while a pin is open." : "\(pin.count) pinned")
                        .font(DS.caption).foregroundStyle(pin.count == 0 ? DS.Ink.tertiary : DS.Ink.secondary)
                    Spacer()
                    if pin.count > 0 { Chip("Unpin All") { pin.unpinAll() } }
                }
                if let message = pin.message {
                    Text(message).font(DS.caption).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .animation(DS.Motion.reveal, value: pin.count)
    }

    private var honestNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold))
            Text("Why no Always on Top or Window Opacity here: Accessibility cannot change a window’s level or transparency.")
                .font(DS.caption).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DS.Ink.tertiary)
        .padding(.horizontal, DS.Space.xs)
        .help("Accessibility can move and resize another app’s windows, but it has no attribute for window level or transparency. Changing those needs private window-server calls or code injected into the app, which Atelier does not do. Pin Window gives the same result for watching a window.")
        .accessibilityElement(children: .combine)
    }
}

/// One layout in the gallery: its zones drawn large, the active one ringed in the Windows light.
/// Hover tints; nothing moves.
private struct ToolsLayoutTile: View {
    let layout: CustomLayout
    let active: Bool
    let hue: Color
    let use: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ZonePreview(zones: layout.zones, highlight: active, tint: hue) { index in
                WindowEngine.shared.moveFront(to: layout.zones[index])
            }
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(layout.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(active ? "Active" : "\(layout.zones.count) zones")
                        .font(DS.caption).foregroundStyle(active ? hue : DS.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(active ? "Active. Click a zone to move the front window there." : "\(layout.zones.count) zones")
                if !active {
                    tileButton("checkmark.circle", label: "Use \(layout.name)", action: use)
                }
                tileButton("slider.horizontal.3", label: "Edit \(layout.name)", action: edit)
                tileButton("xmark", label: "Delete \(layout.name)", action: delete)
            }
        }
        .padding(DS.Space.s)
        .background {
            shape.fill(active ? hue.opacity(0.12) : (hover ? DS.Ink.fillStrong : DS.Ink.fill))
        }
        .overlay {
            shape.strokeBorder(active ? hue.opacity(0.85) : DS.Ink.hairline, lineWidth: active ? 1.5 : 0.5)
        }
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
    }

    private func tileButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
                .frame(width: 26, height: 26).background(DS.Ink.fill, in: .circle).contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.92))
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The gallery's last tile: draw a new layout, or start from a preset.
private struct ToolsNewLayoutTile: View {
    let hue: Color
    let empty: Bool
    let new: () -> Void
    let preset: (CustomLayout) -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: DS.Space.s) {
            Button(action: new) {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(hue)
                    Text(empty ? "Draw a layout" : "New Layout").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                }
                .frame(maxWidth: .infinity).aspectRatio(1.6, contentMode: .fit)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.98))
            Menu {
                ForEach(CustomLayout.presets, id: \.name) { item in
                    Button(item.name) { preset(item) }
                }
            } label: {
                Text("Add Preset").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button).fixedSize()
        }
        .padding(DS.Space.s)
        .background { shape.fill(hover ? hue.opacity(0.08) : .clear) }
        .overlay { shape.strokeBorder(hover ? hue.opacity(0.6) : DS.Ink.edge, style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Zone views

/// A layout drawn small. Tapping a zone runs `tap` with its index.
struct ZonePreview: View {
    let zones: [ZoneRect]
    var highlight = false
    /// The light a hovered or active zone shows in.
    var tint: Color = DS.Ink.accent
    var tap: ((Int) -> Void)?
    @State private var hovered: Int?

    init(zones: [ZoneRect], highlight: Bool = false, tint: Color = DS.Ink.accent, tap: ((Int) -> Void)? = nil) {
        self.zones = zones
        self.highlight = highlight
        self.tint = tint
        self.tap = tap
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(zones.indices, id: \.self) { index in
                    let rect = ToolsGeometry.frame(of: zones[index], in: CGRect(origin: .zero, size: geometry.size), gap: 2)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered == index ? tint : (highlight ? tint.opacity(0.55) : DS.Ink.primary.opacity(0.3)))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .onHover { inside in if tap != nil { withAnimation(DS.Motion.hover) { hovered = inside ? index : nil } } }
                        .onTapGesture { tap?(index) }
                        .accessibilityLabel("Zone \(index + 1)")
                        .accessibilityAddTraits(tap == nil ? [] : .isButton)
                }
            }
        }
        .padding(4)
        .aspectRatio(1.6, contentMode: .fit)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
    }
}

/// Draw zones by dragging on a 12 × 8 grid.
struct ZoneEditor: View {
    @Binding var zones: [ZoneRect]
    var tint: Color = DS.Ink.accent
    @State private var start: CGPoint?
    @State private var now: CGPoint?
    private let columns = 12, rows = 8

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        var path = Path()
                        for column in 1..<columns {
                            let x = size.width * Double(column) / Double(columns)
                            path.addRect(CGRect(x: x, y: 0, width: 0.5, height: size.height))
                        }
                        for row in 1..<rows {
                            let y = size.height * Double(row) / Double(rows)
                            path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5))
                        }
                        context.fill(path, with: .color(.white.opacity(0.1)))
                    }
                    ForEach(zones.indices, id: \.self) { index in
                        zone(zones[index], label: "\(index + 1)", in: size, draft: false)
                    }
                    if let start, let now, let draft = ToolsGeometry.zone(from: unit(start, size), to: unit(now, size), columns: columns, rows: rows) {
                        zone(draft, label: "", in: size, draft: true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        now = value.location
                    }
                    .onEnded { value in
                        if let start, let zone = ToolsGeometry.zone(from: unit(start, size), to: unit(value.location, size), columns: columns, rows: rows) {
                            withAnimation(DS.Motion.settle) { zones.append(zone) }
                        }
                        start = nil
                        now = nil
                    })
                // Remove buttons sit above the drawing layer so a click on one never starts a zone.
                ForEach(zones.indices, id: \.self) { index in
                    let rect = frame(zones[index], size)
                    Button { _ = withAnimation(DS.Motion.settle) { zones.remove(at: index) } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(.black.opacity(0.55), in: .circle)
                    }
                    .buttonStyle(Pressable(scale: 0.9))
                    .offset(x: rect.maxX - 22, y: rect.minY + 4)
                    .accessibilityLabel("Remove zone \(index + 1)")
                }
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
    }

    private func unit(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
    }

    private func frame(_ zone: ZoneRect, _ size: CGSize) -> CGRect {
        ToolsGeometry.frame(of: zone, in: CGRect(origin: .zero, size: size), gap: 4)
    }

    private func zone(_ zone: ZoneRect, label: String, in size: CGSize, draft: Bool) -> some View {
        let rect = frame(zone, size)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(draft ? 0.25 : 0.5))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(draft ? 0.8 : 0.35), lineWidth: 1) }
            .overlay { Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

// MARK: - App rules

struct AppRulesCard: View {
    let trusted: Bool
    @ObservedObject private var tools = Tools.shared
    @State private var appID = ""
    @State private var placement = "layout:leftHalf"
    @State private var display = -1

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Every place a rule can point at, as (tag, title).
    private var places: [(String, String)] {
        var list = WindowGeometry.Layout.allCases.map { ("layout:\($0.rawValue)", $0.title) }
        for layout in tools.layouts {
            for index in layout.zones.indices { list.append(("zone:\(layout.id.uuidString):\(index)", "\(layout.name) · Zone \(index + 1)")) }
        }
        list += [0.6, 0.7, 0.8, 0.9].map { ("percent:\($0)", "Centred at \(Int($0 * 100))%") }
        return list
    }

    var body: some View {
        let hue = DS.Spectrum.windows
        RowGroup {
            SettingRow(title: "App Rules", detail: "A listed app's first window moves into place. Open apps are left alone.",
                       symbol: "app.badge.checkmark", density: .compact) {
                LuxSwitch(isOn: $tools.rulesEnabled, label: "App Rules", tint: hue)
            }
            ForEach(tools.rules) { rule in
                HStack(spacing: 10) {
                    Group {
                        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID)?.path {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(DS.Ink.glyph)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.appName).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text(describe(rule)).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip("Apply Now") { tools.applyRuleNow(rule) }
                    LuxSwitch(isOn: Binding(get: { rule.enabled }, set: { on in
                        if let index = tools.rules.firstIndex(where: { $0.id == rule.id }) { tools.rules[index].enabled = on }
                    }), label: "\(rule.appName) rule", tint: hue)
                    Button { tools.rules.removeAll { $0.id == rule.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable()).accessibilityLabel("Delete rule for \(rule.appName)")
                }
                .frame(minHeight: 44)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(hue).frame(width: 18)
                Picker("App", selection: $appID) {
                    Text("Choose an app").tag("")
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "App").tag(app.bundleIdentifier ?? "")
                    }
                }
                .labelsHidden().frame(maxWidth: 150)
                Picker("Place", selection: $placement) {
                    ForEach(places, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(maxWidth: 170)
                Picker("Display", selection: $display) {
                    Text("Same display").tag(-1)
                    ForEach(NSScreen.screens.indices, id: \.self) { index in
                        Text(NSScreen.screens[index].localizedName).tag(index)
                    }
                }
                .labelsHidden().frame(maxWidth: 140)
                Spacer(minLength: 0)
                Chip("Add") { add() }.disabled(appID.isEmpty)
            }
            .frame(minHeight: 44)
        }
    }

    private func add() {
        guard !appID.isEmpty, let rulePlacement = Self.decode(placement) else { return }
        let name = runningApps.first { $0.bundleIdentifier == appID }?.localizedName ?? appID
        tools.rules.removeAll { $0.bundleID == appID }
        tools.rules.append(AppRule(bundleID: appID, appName: name, placement: rulePlacement, display: display >= 0 ? display : nil))
        appID = ""
    }

    static func decode(_ tag: String) -> RulePlacement? {
        let parts = tag.split(separator: ":").map(String.init)
        switch parts.first {
        case "layout" where parts.count == 2: return .layout(parts[1])
        case "zone" where parts.count == 3: return UUID(uuidString: parts[1]).flatMap { id in Int(parts[2]).map { .zone(layout: id, index: $0) } }
        case "percent" where parts.count == 2: return Double(parts[1]).map(RulePlacement.percent)
        default: return nil
        }
    }

    private func describe(_ rule: AppRule) -> String {
        let place: String
        switch rule.placement {
        case let .layout(raw): place = WindowGeometry.Layout(rawValue: raw)?.title ?? raw
        case let .zone(id, index): place = "\(tools.layout(id)?.name ?? "Missing layout") · Zone \(index + 1)"
        case let .percent(share): place = "Centred at \(Int(share * 100))%"
        }
        guard let display = rule.display else { return place }
        let name = NSScreen.screens.indices.contains(display) ? NSScreen.screens[display].localizedName : "Display \(display + 1)"
        return "\(place) on \(name)"
    }
}
