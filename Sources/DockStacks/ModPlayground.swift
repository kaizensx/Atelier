import AppKit
import DockCore
import SwiftUI

// MARK: - Templates

/// A starting point for the Playground: the same templates `atelier-mod new` uses, from
/// sdk/cli/templates/plugin/<name>/ (copied into the app as Resources/ModTemplates by build.sh).
struct PlaygroundTemplate: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let permissions: [PluginPermission]
    let hosts: [String]
    let source: String

    static let hello = PlaygroundTemplate(
        id: "hello", title: "Hello", detail: "A widget and a command.", permissions: [], hosts: [],
        source: """
        // A widget and a command. Press Run, then try the command on the right.
        let count = 0;

        const hello = atelier.widget({
          id: "hello",
          title: "Hello",
          view: () => atelier.ui.vstack([
            atelier.ui.text("Hello", { size: 22, weight: "bold" }),
            atelier.ui.text("Said hello " + count + " times", { color: "secondary" }),
          ]),
        });

        atelier.command({ title: "Say Hello", run: () => { count += 1; console.log("Hello!"); hello.refresh(); } });

        """)

    /// Every template the app carries, in their own order, with Hello first when none are found.
    static func all() -> [PlaygroundTemplate] {
        var folders: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ModTemplates/plugin") { folders.append(bundled) }
        #if DEBUG
        // Development builds run outside an app bundle: read the repository's own templates.
        folders.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sdk/cli/templates/plugin"))
        #endif
        for folder in folders {
            let found = load(folder)
            if !found.isEmpty { return found }
        }
        return [hello]
    }

    static func load(_ folder: URL) -> [PlaygroundTemplate] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (Int, PlaygroundTemplate)? in
            let dir = folder.appendingPathComponent(name)
            guard let meta = try? Data(contentsOf: dir.appendingPathComponent("template.json")),
                  let json = try? JSONValue.parse(meta),
                  let source = try? String(contentsOf: dir.appendingPathComponent("main.js"), encoding: .utf8) else { return nil }
            let template = PlaygroundTemplate(
                id: name, title: json["title"]?.string ?? name, detail: json["description"]?.string ?? "",
                permissions: (json["permissions"]?.array ?? []).compactMap { $0.string.flatMap(PluginPermission.init(rawValue:)) },
                hosts: (json["hosts"]?.array ?? []).compactMap(\.string), source: source)
            return (Int(json["order"]?.number ?? 99), template)
        }
        .sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.map(\.1)
    }
}

// MARK: - Model

/// Runs the script being written in the real PluginRuntime, under a throwaway id
/// (`playground.<uuid>`), with only the permissions ticked in the Playground and allowed on the
/// permission sheet. What it registers stays here: nothing reaches the board, the Dock or the
/// Command palette until it is saved as a plugin and installed.
@MainActor
final class PlaygroundModel: ObservableObject {
    static let shared = PlaygroundModel()

    @Published var source: String
    @Published var name = "My Plugin"
    @Published var permissions: Set<PluginPermission> = []
    @Published var hosts = ""
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var widgets: [PluginWidget] = []
    @Published private(set) var tiles: [PluginDockTile] = []
    @Published private(set) var commands: [PluginCommand] = []
    @Published private(set) var corners: [PluginCornerAction] = []
    @Published private(set) var events: Set<PluginEvent> = []
    @Published private(set) var log: [PluginLogLine] = []
    @Published var notice: String?

    private var runtime: PluginRuntime?
    private var runID = ""
    private var folder: URL?
    private(set) var granted: Set<PluginPermission> = []

    init(source: String = PlaygroundTemplate.all().first?.source ?? PlaygroundTemplate.hello.source) {
        self.source = source
    }

    var hostList: [String] {
        hosts.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map { $0.lowercased() }
            .filter(PluginNetwork.isValidHost)
    }

    /// The manifest the script runs under.
    func manifest(id: String) -> PluginManifest {
        let asked = PluginPermission.allCases.filter(permissions.contains)
        return PluginManifest(id: id, name: name.isEmpty ? "Playground" : name, version: "1.0.0", author: nil,
                              summary: "Written in the Mods Playground.", permissions: asked,
                              hosts: asked.contains(.network) ? hostList : [])
    }

    /// The plugin the permission sheet asks about before a run with permissions.
    var pendingPlugin: InstalledPlugin {
        InstalledPlugin(manifest: manifest(id: "playground.preview"), folder: FileManager.default.temporaryDirectory, warnings: [])
    }

    func use(_ template: PlaygroundTemplate) {
        stop()
        source = template.source
        permissions = Set(template.permissions)
        hosts = template.hosts.joined(separator: ", ")
        name = template.title
        notice = nil
    }

    /// Starts the script. `grant` is what the owner allowed; it never covers more than is ticked.
    func run(granting grant: Set<PluginPermission> = []) {
        stop()
        clearResults()
        let id = "playground." + UUID().uuidString.lowercased()
        let manifest = self.manifest(id: id)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierPlayground/\(id).\(PluginManifest.bundleExtension)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: dir.appendingPathComponent(manifest.entry))
        } catch {
            status = "Couldn’t write the script: \(error.localizedDescription)"
            return
        }
        if manifest.permissions.contains(.network), manifest.hosts.isEmpty {
            append("warn", "Network is ticked but no host is listed, so every request will be refused.")
        }
        folder = dir
        runID = id
        granted = grant.intersection(manifest.permissions)
        let runtime = PluginRuntime(manifest: manifest, folder: dir, granted: granted) { signal in
            DispatchQueue.main.async { MainActor.assumeIsolated { PlaygroundModel.deliver(signal, run: id) } }
        }
        self.runtime = runtime
        running = true
        status = "Starting…"
        runtime.start()
    }

    func stop() {
        guard let runtime else { return }
        runtime.stop()
        self.runtime = nil
        running = false
        status = "Stopped"
        let id = runID, dir = folder
        runID = ""
        // The runtime saves its storage as it stops; the throwaway files go after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let dir { try? FileManager.default.removeItem(at: dir) }
            try? FileManager.default.removeItem(at: PluginRuntime.dataFolder.appendingPathComponent(id + ".json"))
        }
    }

    private func clearResults() {
        widgets = []; tiles = []; commands = []; corners = []; events = []
        log = []
    }

    private static func deliver(_ signal: PluginSignal, run id: String) {
        // Every model that is running this id, in practice the shared one or a render's own.
        for model in live where model.runID == id { model.receive(signal) }
    }
    private static var live: [PlaygroundModel] { [shared] + extra.compactMap(\.value) }
    private static var extra: [WeakModel] = []
    private struct WeakModel { weak var value: PlaygroundModel? }
    /// For models other than `shared` (offscreen renders) so their signals arrive.
    func register() { if self !== Self.shared { Self.extra.append(WeakModel(value: self)) } }

    private func receive(_ signal: PluginSignal) {
        switch signal {
        case .started: status = "Running"
        case .failed(let reason):
            append("error", reason)
            status = reason
            runtime?.stop(); runtime = nil; running = false
        case .log(let level, let text): append(level, text)
        case .message(let message): handle(message)
        }
    }

    private func handle(_ message: PluginMessage) {
        let id = runID, name = name
        switch message {
        case .widget(let spec):
            if let i = widgets.firstIndex(where: { $0.spec.id == spec.id }) { widgets[i].spec = spec }
            else { widgets.append(PluginWidget(plugin: id, spec: spec)) }
        case .widgetView(let widget, let view):
            if let i = widgets.firstIndex(where: { $0.spec.id == widget }) {
                widgets[i].view = view; widgets[i].error = nil; widgets[i].updated = Date()
            }
        case .widgetError(let widget, let text):
            if let i = widgets.firstIndex(where: { $0.spec.id == widget }) { widgets[i].error = text }
            append("error", "\(widget): \(text)")
        case .tile(let spec):
            if let i = tiles.firstIndex(where: { $0.spec.id == spec.id }) { tiles[i].spec = spec }
            else { tiles.append(PluginDockTile(plugin: id, spec: spec)) }
        case .command(let spec):
            commands.removeAll { $0.spec.id == spec.id }
            commands.append(PluginCommand(plugin: id, pluginName: name, spec: spec))
        case .corner(let spec):
            corners.removeAll { $0.spec.id == spec.id }
            corners.append(PluginCornerAction(plugin: id, pluginName: name, spec: spec))
        case .subscribe(let event, _):
            events.insert(event)
        case .notify(let title, let body):
            // The runtime refuses this without the grant; with it, a real notification.
            PluginNotifier.post(title: title, body: body, from: name)
            append("info", "Notification: \(title)")
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            append("info", "Opened \(url.absoluteString)")
        case .themeApply(let patch):
            if let error = ThemeEngine.shared.applyPatch(patch, from: id) { append("error", "theme.apply: \(error)") }
            else { append("info", "Changed the theme: \(patch.keys.sorted().joined(separator: ", ")). Revert in Looks undoes it.") }
        case .log(let level, let text):
            append(level, text)
        case .prompt(let request, let title, let message, let placeholder, let secure):
            PluginPrompt.ask(title: title, message: message, placeholder: placeholder, secure: secure, from: name) { [weak self] answer in
                self?.runtime?.settle(request, ok: true, payload: .object(["text": answer.map(JSONValue.string) ?? .null]))
            }
        default:
            // Calls the Playground does not draw yet are still listed, so nothing is silent.
            append("debug", "\(message)")
        }
    }

    private func append(_ level: String, _ text: String) {
        log.append(PluginLogLine(date: Date(), plugin: runID, level: level, text: text))
        if log.count > PluginRegistry.maxLogLines { log.removeFirst(log.count - PluginRegistry.maxLogLines) }
    }

    func clearLog() { log.removeAll() }

    // Interactions, as the real places would call them.
    func render(_ widget: PluginWidget) { runtime?.render(widget: widget.spec.id) }
    func click(_ tile: PluginDockTile) { runtime?.invoke("tile:\(tile.spec.id):onClick") }
    func run(_ command: PluginCommand) { runtime?.invoke("command:\(command.spec.id):run") }
    func fire(_ corner: PluginCornerAction) { runtime?.invoke("corner:\(corner.spec.id):run") }
    func send(_ event: PluginEvent) {
        let payload: JSONValue = switch event {
        case .appActivated: .object(["name": .string("Finder"), "bundleID": .string("com.apple.finder")])
        case .themeChanged: .object(["id": .null])
        case .timer: .object(["date": .number(Date().timeIntervalSince1970 * 1000)])
        default: .object([:])
        }
        runtime?.emit(event, payload: payload)
        append("debug", "Sent \(event.rawValue)")
    }

    // MARK: Save

    /// Writes `<folder>/<name>.atelierplugin` with manifest.json and main.js, then installs it.
    @discardableResult
    func save(id: String, to parent: URL) throws -> InstalledPlugin {
        let manifest = self.manifest(id: id)
        let slug = id.split(separator: ".").last.map(String.init) ?? "plugin"
        let dir = parent.appendingPathComponent("\(slug).\(PluginManifest.bundleExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var root: [String: JSONValue] = [
            "format": .number(1), "id": .string(id), "name": .string(manifest.name), "version": .string("1.0.0"),
            "description": .string("Written in the Mods Playground."), "icon": .string("puzzlepiece.extension"), "entry": .string("main.js"),
        ]
        if !manifest.permissions.isEmpty { root["permissions"] = .array(manifest.permissions.map { .string($0.rawValue) }) }
        if !manifest.hosts.isEmpty { root["network"] = .object(["hosts": .array(manifest.hosts.map(JSONValue.string))]) }
        try JSONValue.object(root).data(pretty: true).write(to: dir.appendingPathComponent(PluginManifest.fileName))
        try Data(source.utf8).write(to: dir.appendingPathComponent("main.js"))
        return try PluginRegistry.shared.install(from: dir)
    }

    static func suggestedID(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "io.github.you." + (slug.isEmpty ? "my-plugin" : slug)
    }
}

// MARK: - The Create tab

/// Mods › Create: write a plugin, run it, see what it registers, save it.
struct PlaygroundView: View {
    @ObservedObject var model: PlaygroundModel
    var templates: [PlaygroundTemplate] = PlaygroundTemplate.all()
    var editorHeight: CGFloat = 360
    @State private var asking: InstalledPlugin?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Write a plugin and run it here. It runs sandboxed like any plugin, with only the permissions you tick, and nothing appears elsewhere in Atelier until you save it.")
                .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.xs)
            toolbar
            permissionRow
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    editor.frame(minWidth: 380)
                    PlaygroundResults(model: model).frame(width: 260)
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    editor
                    PlaygroundResults(model: model)
                }
            }
            PlaygroundConsole(model: model)
            RowGroup {
                Button { NSWorkspace.shared.open(URL(string: "https://kaizensx.github.io/Atelier/make.html")!) } label: {
                    SettingRow(title: "Making mods", detail: "The API reference, the atelier-mod command-line kit and how to share a mod in the catalog.",
                               symbol: "book", density: .compact) {
                        Image(systemName: "arrow.up.right").foregroundStyle(DS.Ink.tertiary)
                    }
                }
                .buttonStyle(Pressable(scale: 0.99))
            }
        }
        .navTarget("playground")
        .sheet(item: $asking) { plugin in
            PluginPermissionsSheet(plugin: plugin) { granted in
                asking = nil
                if let granted { model.run(granting: granted) }
            }
        }
        .sheet(isPresented: $saving) { PlaygroundSaveSheet(model: model) { saving = false } }
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.s) {
            if model.running {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(ModPill(hue: ModsHue.danger))
                Button { start() } label: { Label("Run Again", systemImage: "arrow.clockwise") }.buttonStyle(ModPill(prominent: false))
            } else {
                Button { start() } label: { Label("Run", systemImage: "play.fill") }.buttonStyle(ModPill())
                    .keyboardShortcut("r", modifiers: .command)
            }
            Menu {
                ForEach(templates) { template in
                    Button("\(template.title) — \(template.detail)") { model.use(template) }
                }
            } label: { Label("Templates", systemImage: "doc.on.doc") }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: DS.Space.s)
            if let status = model.status {
                Text(status).font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
            }
            Button("Save as Plugin…") { saving = true }.buttonStyle(ModPill(prominent: false))
        }
        .padding(.horizontal, DS.Space.xs)
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            WrapStack(spacing: 6, lineSpacing: 6) {
                Text("Permissions").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                ForEach(PluginPermission.allCases) { permission in
                    let on = model.permissions.contains(permission)
                    Button {
                        if on { model.permissions.remove(permission) } else { model.permissions.insert(permission) }
                    } label: {
                        Label(permission.title, systemImage: permission.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(on ? ModsHue.tint.opacity(0.22) : DS.Ink.fill, in: .capsule)
                            .overlay { Capsule().strokeBorder(on ? ModsHue.tint.opacity(0.45) : DS.Ink.hairline, lineWidth: 0.5) }
                            .foregroundStyle(on ? DS.Ink.primary : DS.Ink.tertiary)
                    }
                    .buttonStyle(Pressable(scale: 0.96))
                    .help(permission.detail)
                    .accessibilityLabel(permission.title)
                    .accessibilityValue(on ? "Asked for" : "Not asked for")
                }
            }
            if model.permissions.contains(.network) {
                HStack(spacing: 8) {
                    Image(systemName: "network").foregroundStyle(DS.Ink.tertiary)
                    TextField("Hosts, like api.github.com", text: $model.hosts).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            }
        }
        .padding(.horizontal, DS.Space.xs)
    }

    private var editor: some View {
        CodeEditor(text: $model.source)
            .frame(minHeight: editorHeight)
            .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
    }

    /// Without permissions the script runs at once; with any, the permission sheet asks first.
    private func start() {
        if model.permissions.isEmpty { model.run() } else { asking = model.pendingPlugin }
    }
}

/// What the script registered, drawn with the real plugin renderers, and buttons to use it.
struct PlaygroundResults: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if model.widgets.isEmpty, model.tiles.isEmpty, model.commands.isEmpty, model.corners.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.running ? "hourglass" : "play.circle").font(.system(size: 22)).foregroundStyle(DS.Ink.tertiary)
                    Text(model.running ? "Nothing registered yet." : "Press Run to see what your script adds.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xl)
            }
            ForEach(model.widgets) { widget in
                label("Widget", widget.spec.title)
                PlaygroundWidget(widget: widget)
                    .frame(height: widget.spec.size == .small ? 150 : widget.spec.size == .medium ? 170 : 260)
                    .onTapGesture(count: 2) { model.render(widget) }
                    .help("Double-click to run data and view again")
            }
            if !model.tiles.isEmpty {
                label("Dock tiles", nil)
                HStack(spacing: 12) {
                    ForEach(model.tiles) { tile in
                        Button { model.click(tile) } label: { PluginDockTileView(key: tile.id, size: 52, spec: tile.spec) }
                            .buttonStyle(Pressable(scale: 0.94)).help("Click: \(tile.spec.title)")
                    }
                }
                .padding(.vertical, 4)
            }
            if !model.commands.isEmpty || !model.corners.isEmpty {
                label("Commands and corner actions", nil)
                WrapStack(spacing: 6, lineSpacing: 6) {
                    ForEach(model.commands) { command in
                        Button(command.spec.title + (command.spec.shortcut.map { "  " + PluginShortcut.symbols($0) } ?? "")) { model.run(command) }
                            .buttonStyle(ModPill(prominent: false))
                    }
                    ForEach(model.corners) { corner in
                        Button { model.fire(corner) } label: { Label(corner.spec.title, systemImage: corner.spec.symbol) }
                            .buttonStyle(ModPill(prominent: false))
                    }
                }
            }
            if !model.events.isEmpty {
                label("Send an event", nil)
                WrapStack(spacing: 6, lineSpacing: 6) {
                    ForEach(PluginEvent.allCases.filter(model.events.contains), id: \.self) { event in
                        Button(event.rawValue) { model.send(event) }.buttonStyle(ModPill(prominent: false))
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func label(_ title: String, _ detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(DS.eyebrow).tracking(1.2).foregroundStyle(DS.Ink.tertiary)
            if let detail { Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1) }
        }
    }
}

/// A widget as the board draws it: the real PluginNodeView inside a widget-like plate.
private struct PlaygroundWidget: View {
    let widget: PluginWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(widget.spec.title.uppercased()).font(DS.eyebrow).tracking(1.2).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
            if let error = widget.error {
                Label(error, systemImage: "exclamationmark.triangle").font(DS.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let view = widget.view {
                PluginNodeView(node: view).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.pluginAccent, DS.Ink.accent)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
    }
}

/// The Playground's own console: only this script's lines.
struct PlaygroundConsole: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CONSOLE").font(DS.eyebrow).tracking(1.2).foregroundStyle(DS.Ink.tertiary)
                Text(model.log.isEmpty ? "Quiet" : "\(model.log.count) lines").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Chip("Clear") { model.clearLog() }
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.log.isEmpty {
                            Text("console.log() and errors, with their line numbers, show up here.")
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DS.Ink.tertiary)
                        }
                        ForEach(model.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.date, format: .dateTime.hour().minute().second()).foregroundStyle(DS.Ink.tertiary)
                                Text(line.level.uppercased()).foregroundStyle(color(line.level)).frame(width: 40, alignment: .leading)
                                Text(line.text).foregroundStyle(DS.Ink.primary).textSelection(.enabled)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(10)
                .background(Color(red: 0.03, green: 0.035, blue: 0.045).opacity(0.85), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
                .onChange(of: model.log.last?.id) { _, last in
                    if let last { withAnimation(DS.Motion.arrive) { reader.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
        .padding(.horizontal, DS.Space.xs)
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

/// Save as Plugin: an id, a folder, then install. Switching it on asks for its permissions.
private struct PlaygroundSaveSheet: View {
    @ObservedObject var model: PlaygroundModel
    let done: () -> Void
    @State private var id = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save as Plugin").font(.system(size: 17, weight: .semibold))
            Text("Atelier writes a .atelierplugin folder with manifest.json and main.js where you choose, and installs it. It stays off until you switch it on in Mods › Installed.")
                .font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("Name", text: $model.name)
            field("Identifier", text: $id)
            Text("Reverse-DNS and yours, like io.github.you.focus. Updates follow it, so it never changes.")
                .font(DS.caption).foregroundStyle(.secondary)
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill").font(DS.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { save() }.keyboardShortcut(.defaultAction).disabled(!ThemeIdentifier.isValid(id))
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { if id.isEmpty { id = PlaygroundModel.suggestedID(for: model.name) } }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).font(DS.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to keep the plugin's folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plugin = try model.save(id: id, to: url)
            model.notice = "Saved and installed \(plugin.manifest.name)."
            done()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Code editor

/// A plain-text JavaScript editor: monospaced, line numbers, light syntax colouring, and none of
/// the smart quotes or autocorrect that would break code.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 throughout: the line-number ruler measures lines with the layout manager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1)
        view.delegate = context.coordinator
        view.font = CodeEditor.font
        view.textColor = CodeEditor.plain
        view.backgroundColor = scroll.backgroundColor
        view.insertionPointColor = .white
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.string = text
        view.setAccessibilityLabel("Plugin script")
        let ruler = LineNumberRuler(textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        CodeEditor.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        CodeEditor.highlight(view)
        scroll.verticalRulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            CodeEditor.highlight(view)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        /// Tab inserts two spaces; Return keeps the line's indentation.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) { view.insertText("  ", replacementRange: view.selectedRange()); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let text = view.string as NSString
                let line = text.lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
                let current = text.substring(with: line)
                let indent = current.prefix { $0 == " " || $0 == "\t" }
                view.insertText("\n" + indent, replacementRange: view.selectedRange())
                return true
            }
            return false
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let plain = NSColor(white: 0.88, alpha: 1)
    private static let rules: [(NSRegularExpression, NSColor)] = [
        (#"\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|try|catch|finally|throw|async|await|of|in|typeof|instanceof|class|extends|this|null|undefined|true|false)\b"#,
         NSColor(red: 0.98, green: 0.47, blue: 0.67, alpha: 1)),
        (#"\batelier\b"#, NSColor(red: 0.62, green: 0.58, blue: 1.0, alpha: 1)),
        (#"\b\d+(\.\d+)?\b"#, NSColor(red: 0.85, green: 0.72, blue: 0.45, alpha: 1)),
        (#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`(\\.|[^`\\])*`"#, NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1)),
        (#"//[^\n]*|/\*[\s\S]*?\*/"#, NSColor(white: 0.5, alpha: 1)),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Colours the whole text. Later rules win, so strings and comments override keywords inside them.
    static func highlight(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: plain], range: all)
        for (rule, color) in rules {
            rule.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        storage.endEditing()
    }
}

/// Line numbers beside the editor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1).setFill()
        rect.fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor(white: 0.42, alpha: 1),
        ]
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let start = layout.characterIndexForGlyph(at: visible.location)
        var line = text.substring(to: start).components(separatedBy: "\n").count
        var index = start
        let origin = convert(NSPoint.zero, from: view).y + view.textContainerInset.height
        while index <= NSMaxRange(layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)) {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            let box = layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: origin + box.minY + (box.height - size.height) / 2), withAttributes: attributes)
            line += 1
            if NSMaxRange(lineRange) <= index || NSMaxRange(lineRange) >= text.length { break }
            index = NSMaxRange(lineRange)
        }
    }
}

#if DEBUG
// MARK: - Offscreen render

private extension NSView {
    func subviewsDeep<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviewsDeep(of: type) }
    }
}

/// `DockStacks --render-playground <folder>` (debug builds): runs each template in a throwaway
/// Playground and writes PNGs of the Create tab. Nothing is shown on screen,
/// nothing is installed and no setting changes; the throwaway storage file is removed after.
@MainActor
enum PlaygroundRenders {
    static func run(into folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for template in PlaygroundTemplate.all() where template.permissions.isEmpty {
            let model = PlaygroundModel(source: template.source)
            model.register()
            model.name = template.title
            model.run()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            if let command = model.commands.first { model.run(command); RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
            if let tile = model.tiles.first { model.click(tile); RunLoop.main.run(until: Date().addingTimeInterval(1.2)) }
            // The Studio is dark; so is the render.
            for scheme in [ColorScheme.dark] {
                let view = PlaygroundView(model: model, templates: [template], editorHeight: 320)
                    .padding(20).frame(width: 760)
                    .background(scheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.11) : Color(red: 0.95, green: 0.95, blue: 0.97))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 760, height: max(host.fittingSize.height, 400))
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                // cacheDisplay skips the text of an NSTextView inside a hosting view's layers;
                // draw the editor's own snapshot over its place so the render shows the code.
                if let context = NSGraphicsContext(bitmapImageRep: rep) {
                    for scroll in host.subviewsDeep(of: NSScrollView.self) {
                        guard let text = scroll.documentView as? NSTextView,
                              let piece = text.bitmapImageRepForCachingDisplay(in: text.visibleRect) else { continue }
                        text.cacheDisplay(in: text.visibleRect, to: piece)
                        let place = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                        let y = host.isFlipped ? host.bounds.height - place.maxY : place.minY
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        piece.draw(in: NSRect(x: place.minX, y: y, width: place.width, height: place.height))
                        if let ruler = scroll.verticalRulerView, let marks = ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds) {
                            ruler.cacheDisplay(in: ruler.bounds, to: marks)
                            let at = ruler.convert(ruler.bounds, to: host)
                            marks.draw(in: NSRect(x: at.minX, y: host.isFlipped ? host.bounds.height - at.maxY : at.minY, width: at.width, height: at.height))
                        }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                let url = folder.appendingPathComponent("playground-\(template.id)-\(scheme == .dark ? "dark" : "light").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path, "widgets:", model.widgets.count, "tiles:", model.tiles.count, "commands:", model.commands.count,
                      "log:", model.log.map { "\($0.level) \($0.text)" })
            }
            model.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        }
    }
}
#endif
