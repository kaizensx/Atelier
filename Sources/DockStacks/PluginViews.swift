import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rendering plugin views natively

private struct PluginAccentKey: EnvironmentKey { static let defaultValue = Color(red: 0.55, green: 0.72, blue: 1) }
extension EnvironmentValues {
    /// The accent plugin views resolve "accent" to: the widget style's, inside a widget.
    var pluginAccent: Color {
        get { self[PluginAccentKey.self] }
        set { self[PluginAccentKey.self] = newValue }
    }
}

extension PluginColor {
    func color(accent: Color) -> Color {
        switch self {
        case .hex(let value): Color(value)
        case .named(let name):
            switch name {
            case "primary": DS.Ink.primary
            case "secondary": DS.Ink.secondary
            case "tertiary": DS.Ink.tertiary
            case "accent": accent
            case "red": .red
            case "orange": .orange
            case "yellow": .yellow
            case "green": .green
            case "mint": .mint
            case "teal": .teal
            case "blue": .blue
            case "indigo": .indigo
            case "purple": .purple
            case "pink": .pink
            default: .gray
            }
        }
    }
}

extension PluginTextStyle {
    var font: Font {
        let weight: Font.Weight = switch self.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .light: .light
        }
        let design: Font.Design = switch self.design {
        case .default: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
        return .system(size: size, weight: weight, design: design)
    }
}

/// Draws a plugin's view tree. Every node maps to a native SwiftUI view; nothing a plugin
/// sends can run code here.
struct PluginNodeView: View {
    let node: PluginNode
    @Environment(\.pluginAccent) private var accent

    var body: some View { content.animation(DS.Motion.arrive, value: node) }

    @ViewBuilder private var content: some View {
        switch node {
        case .text(let text, let style):
            Text(text).font(style.font).lineLimit(style.lines)
                .foregroundStyle(style.color?.color(accent: accent) ?? DS.Ink.primary)
                .contentTransition(.numericText())
        case .symbol(let name, let style):
            Image(systemName: name).font(style.font)
                .foregroundStyle(style.color?.color(accent: accent) ?? DS.Ink.primary)
                .symbolRenderingMode(.hierarchical)
        case .ring(let value, let label, let color, let width):
            ZStack {
                Circle().stroke(DS.Ink.fillStrong, lineWidth: width)
                Circle().trim(from: 0, to: value)
                    .stroke(color?.color(accent: accent) ?? accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let label {
                    Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(DS.Ink.primary).minimumScaleFactor(0.6).lineLimit(1).padding(width + 2)
                }
            }
            .aspectRatio(1, contentMode: .fit)
        case .bar(let value, let label, let color):
            VStack(alignment: .leading, spacing: 4) {
                if let label { Text(label).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1) }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Ink.fillStrong)
                        Capsule().fill(color?.color(accent: accent) ?? accent).frame(width: max(6, geometry.size.width * value))
                    }
                }
                .frame(height: 6)
            }
        case .list(let rows):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        if let symbol = row.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(row.color?.color(accent: accent) ?? accent).frame(width: 14)
                        }
                        Text(row.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let detail = row.detail {
                            Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1).monospacedDigit()
                        }
                    }
                }
            }
        case .sparkline(let values, let color, let fill):
            PluginSparkline(values: values, color: color?.color(accent: accent) ?? accent, fill: fill)
                .frame(minHeight: 24)
        case .stack(let axis, let spacing, let alignment, let children):
            switch axis {
            case .vertical:
                VStack(alignment: alignment.horizontal, spacing: spacing) { nodes(children) }
            case .horizontal:
                HStack(alignment: alignment.vertical, spacing: spacing) { nodes(children) }
            case .overlay:
                ZStack(alignment: Alignment(horizontal: alignment.horizontal, vertical: alignment.vertical)) { nodes(children) }
            }
        case .spacer:
            Spacer(minLength: 0)
        }
    }

    private func nodes(_ children: [PluginNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in AnyView(PluginNodeView(node: child)) }
    }
}

private extension PluginNode.Alignment {
    var horizontal: HorizontalAlignment { self == .trailing ? .trailing : self == .center ? .center : .leading }
    var vertical: VerticalAlignment { self == .top ? .top : self == .bottom ? .bottom : .center }
}

struct PluginSparkline: View {
    let values: [Double]
    let color: Color
    let fill: Bool

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, .ulpOfOne)
            let step = size.width / Double(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: Double(index) * step, y: size.height - (value - low) / span * (size.height - 2) - 1)
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The body of a "Plugin" widget on the board (snippet S8). `key` is `pluginID/widgetID`.
struct PluginWidgetContent: View {
    let key: String?
    var accent: Color = DS.Ink.accent
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        Group {
            if let key, let widget = registry.widget(key) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(widget.spec.title.uppercased()).font(DS.eyebrow).tracking(1.2).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                    if let view = widget.view {
                        PluginNodeView(node: view).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let error = widget.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear { registry.render(widget: key) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 20)).foregroundStyle(DS.Ink.tertiary)
                    Text(key == nil ? "Choose a plugin widget" : "Plugin not running").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.pluginAccent, accent)
        .padding(14)
    }
}

/// A plugin's Dock tile (snippet S10). `key` is `pluginID/tileID`.
struct PluginDockTileView: View {
    let key: String
    let size: CGFloat
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        let tile = registry.tile(key)
        let tint = tile?.spec.tint?.color(accent: DS.Ink.accent) ?? DS.Ink.accent
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                .overlay { RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
            if let progress = tile?.spec.progress {
                Circle().trim(from: 0, to: progress).stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(size * 0.12)
                    .animation(DS.Motion.arrive, value: progress)
            }
            VStack(spacing: size * 0.02) {
                if let symbol = tile?.spec.symbol {
                    Image(systemName: symbol).font(.system(size: size * (tile?.spec.text == nil ? 0.44 : 0.3), weight: .semibold))
                }
                if let text = tile?.spec.text {
                    Text(text).font(.system(size: size * 0.2, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1).contentTransition(.numericText())
                }
            }
            .foregroundStyle(.white)
            .padding(size * 0.1)
            if tile == nil { Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.6)) }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge = tile?.spec.badge, !badge.isEmpty {
                Text(badge).font(.system(size: size * 0.18, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, size * 0.07).frame(minWidth: size * 0.3, minHeight: size * 0.3)
                    .background(.red, in: .capsule).offset(x: size * 0.08, y: -size * 0.08)
            }
        }
        .accessibilityLabel(tile?.spec.title ?? "Plugin tile")
    }
}

// MARK: - Plugin manager

struct PluginManagerSection: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @State private var asking: InstalledPlugin?
    @State private var logsFor: String?
    @State private var failure: String?

    var body: some View {
        SectionHeader("Plugins", symbol: "puzzlepiece.extension", hue: DS.Ink.accent)
            .help("Plugins are small JavaScript programs that add widgets, Dock tiles, commands and hot-corner actions. Each runs in its own sandboxed engine, off the main thread, with no file access and no network unless you allow it.")
        HStack(alignment: .center, spacing: DS.Space.s) {
            Text("Each runs sandboxed: no file access, and no network unless you allow it.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s)
            Chip("Install Plugin…") { installPanel() }
            Chip("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([PluginRegistry.folder]) }
        }
        .padding(.horizontal, DS.Space.xs)
        if registry.installed.isEmpty {
            ThemesEmptyShelf(symbol: "puzzlepiece.extension",
                             text: "No plugins yet. Drop a .atelierplugin folder on the tiles above, or try the examples in Atelier’s source.")
        } else {
            RowGroup {
                ForEach(registry.installed) { plugin in
                    PluginRow(plugin: plugin, ask: { asking = plugin }, logs: { logsFor = plugin.id })
                }
            }
        }
        ForEach(registry.problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
        }
        if let failure {
            Label(failure, systemImage: "xmark.octagon.fill").font(DS.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
        }
        PluginConsole(filter: $logsFor)
            .sheet(item: $asking) { plugin in
                PluginPermissionsSheet(plugin: plugin) { granted in
                    if let granted { registry.enable(plugin, granting: granted) }
                    asking = nil
                }
            }
    }

    private func installPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .atelierplugin folder"
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plugin = try registry.install(from: url)
            failure = nil
            asking = plugin
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct PluginRow: View {
    let plugin: InstalledPlugin
    let ask: () -> Void
    let logs: () -> Void
    @ObservedObject private var registry = PluginRegistry.shared
    @State private var expanded = false

    var body: some View {
        let on = registry.enabled.contains(plugin.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                        .fill(on ? AnyShapeStyle(DS.Ink.accent) : AnyShapeStyle(DS.Ink.fill))
                    Image(systemName: PluginNode.isSymbolName(plugin.manifest.symbol) ? plugin.manifest.symbol : "puzzlepiece.extension")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? Color.black.opacity(0.8) : DS.Ink.secondary)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plugin.manifest.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        Text(plugin.manifest.version).font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    }
                    Text(registry.status[plugin.id] ?? plugin.manifest.summary ?? plugin.manifest.author ?? "")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { withAnimation(DS.Motion.reveal) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(DS.Ink.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
                LuxSwitch(isOn: Binding(get: { on }, set: { value in
                    if value {
                        if plugin.manifest.permissions.isEmpty { registry.enable(plugin, granting: []) } else { ask() }
                    } else {
                        registry.disable(plugin.id)
                    }
                }), label: plugin.manifest.name)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let author = plugin.manifest.author { detail("By", author) }
                    detail("Identifier", plugin.manifest.id)
                    if plugin.manifest.permissions.isEmpty {
                        detail("Permissions", "None. It can only draw and remember its own settings.")
                    } else {
                        HStack(spacing: 6) {
                            ForEach(plugin.manifest.permissions) { permission in
                                let granted = registry.grants[plugin.id]?.contains(permission) == true
                                Label(permission.title, systemImage: permission.symbol)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8).frame(height: 22)
                                    .background(granted ? DS.Ink.accent.opacity(0.2) : DS.Ink.fill, in: .capsule)
                                    .overlay { Capsule().strokeBorder(granted ? DS.Ink.accent.opacity(0.35) : DS.Ink.hairline, lineWidth: 0.5) }
                                    .foregroundStyle(granted ? DS.Ink.primary : DS.Ink.tertiary)
                                    .help(granted ? "Allowed" : "Not allowed")
                            }
                        }
                        if !plugin.manifest.hosts.isEmpty { detail("Network", plugin.manifest.hosts.joined(separator: ", ")) }
                    }
                    ForEach(plugin.warnings, id: \.description) { warning in
                        Label(warning.description, systemImage: "exclamationmark.triangle").font(DS.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        if !plugin.manifest.permissions.isEmpty { Chip("Permissions…") { ask() } }
                        Chip("Logs") { logs() }
                        if on { Chip("Restart") { registry.restart(plugin) } }
                        Chip("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([plugin.folder]) }
                        Spacer()
                        HoldButton(title: "Hold to Remove") { registry.remove(plugin) }
                    }
                }
                .padding(.leading, 46)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.vertical, 10)
        .animation(DS.Motion.settle, value: on)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.tertiary).frame(width: 78, alignment: .leading)
            Text(value).font(DS.caption).foregroundStyle(DS.Ink.secondary).textSelection(.enabled)
        }
    }
}

/// Asks before a plugin runs with any permission. Each can be allowed on its own.
struct PluginPermissionsSheet: View {
    let plugin: InstalledPlugin
    let done: (Set<PluginPermission>?) -> Void
    @State private var chosen: Set<PluginPermission>

    init(plugin: InstalledPlugin, done: @escaping (Set<PluginPermission>?) -> Void) {
        self.plugin = plugin
        self.done = done
        let existing = PluginRegistry.shared.grants[plugin.id] ?? []
        _chosen = State(initialValue: existing.isEmpty ? Set(plugin.manifest.permissions) : existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 24)).foregroundStyle(DS.Ink.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow “\(plugin.manifest.name)”?").font(.system(size: 17, weight: .semibold))
                    Text("\(plugin.manifest.author.map { "By \($0). " } ?? "")Version \(plugin.manifest.version).")
                        .font(DS.caption).foregroundStyle(.secondary)
                }
            }
            Text("Plugins never get file access. Allow only what you expect this plugin to need; you can change this later.")
                .font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                ForEach(plugin.manifest.permissions) { permission in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: permission.symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(DS.Ink.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.system(size: 13, weight: .semibold))
                            Text(permission.detail).font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if permission == .network {
                                Text(plugin.manifest.hosts.joined(separator: " · ")).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { chosen.contains(permission) }, set: { on in
                            if on { chosen.insert(permission) } else { chosen.remove(permission) }
                        }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(permission.title)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Turn On") { done(chosen) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// A scrolling console of what plugins logged, newest at the bottom.
struct PluginConsole: View {
    @Binding var filter: String?
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        let lines = registry.log.filter { filter == nil || $0.plugin == filter }
        SectionHeader("Console", symbol: "terminal", hue: DS.Ink.accent)
        Card(padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(lines.isEmpty ? "Quiet" : "\(lines.count) lines").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                        .padding(.leading, DS.Space.s)
                    Spacer()
                    Menu(filter.flatMap { id in registry.installed.first { $0.id == id }?.manifest.name } ?? "All Plugins") {
                        Button("All Plugins") { filter = nil }
                        ForEach(registry.installed) { plugin in Button(plugin.manifest.name) { filter = plugin.id } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Chip("Clear") { registry.clearLog(filter) }
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if lines.isEmpty {
                                Text("Nothing logged yet. console.log() in a plugin shows up here.")
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DS.Ink.tertiary)
                            }
                            ForEach(lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.date, format: .dateTime.hour().minute().second()).foregroundStyle(DS.Ink.tertiary)
                                    Text(line.level.uppercased()).foregroundStyle(color(line.level)).frame(width: 40, alignment: .leading)
                                    if filter == nil { Text(line.plugin.split(separator: ".").last.map(String.init) ?? line.plugin).foregroundStyle(DS.Ink.secondary) }
                                    Text(line.text).foregroundStyle(DS.Ink.primary).textSelection(.enabled)
                                }
                                .font(.system(size: 11.5, design: .monospaced))
                                .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    .padding(10)
                    .background(Color(red: 0.03, green: 0.035, blue: 0.045).opacity(0.85), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5)
                    }
                    .onChange(of: lines.last?.id) { _, last in
                        if let last { withAnimation(DS.Motion.arrive) { reader.scrollTo(last, anchor: .bottom) } }
                    }
                }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        case "info": DS.Ink.accent
        case "debug": DS.Ink.tertiary
        default: DS.Ink.secondary
        }
    }
}
