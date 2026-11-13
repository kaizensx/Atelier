import AppKit
import Combine
import DockCore
import SwiftUI
@preconcurrency import UserNotifications

/// A plugin found in the Plugins folder.
struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let folder: URL
    let warnings: [ThemeIssue]
    var id: String { manifest.id }
}

/// A widget a plugin registered, and what it last drew.
struct PluginWidget: Identifiable, Equatable {
    let plugin: String
    var spec: PluginWidgetSpec
    var view: PluginNode?
    var error: String?
    var updated: Date?
    /// `pluginID/widgetID`: what a widget placement stores to find this again.
    var id: String { plugin + "/" + spec.id }
}

struct PluginDockTile: Identifiable, Equatable {
    let plugin: String
    var spec: PluginTileSpec
    var id: String { plugin + "/" + spec.id }
}

struct PluginCommand: Identifiable, Equatable {
    let plugin: String
    let pluginName: String
    var spec: PluginCommandSpec
    var id: String { plugin + "/" + spec.id }
}

struct PluginCornerAction: Identifiable, Equatable {
    let plugin: String
    let pluginName: String
    var spec: PluginCornerSpec
    var id: String { plugin + "/" + spec.id }
}

struct PluginLogLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let plugin: String
    let level: String
    let text: String
}

/// Plugins: what is installed, what runs, and everything running plugins have registered.
/// Other modules read the registries (`widgets`, `dockTiles`, `commands`, `cornerActions`)
/// and call back in through `render`, `click`, `run` and `runCorner`.
@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()
    private let store = UserDefaults.standard

    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var enabled: Set<String> { didSet { store.set(Array(enabled).sorted(), forKey: Key.enabled) } }
    /// What the owner granted, per plugin. A grant never covers more than the manifest asks.
    @Published private(set) var grants: [String: Set<PluginPermission>] {
        didSet { store.set(grants.mapValues { $0.map(\.rawValue).sorted() }, forKey: Key.grants) }
    }
    @Published private(set) var status: [String: String] = [:]
    @Published private(set) var problems: [String] = []

    @Published private(set) var widgets: [PluginWidget] = []
    @Published private(set) var dockTiles: [PluginDockTile] = []
    @Published private(set) var commands: [PluginCommand] = []
    @Published private(set) var cornerActions: [PluginCornerAction] = []
    @Published private(set) var log: [PluginLogLine] = []

    private var runtimes: [String: PluginRuntime] = [:]
    private var subscriptions: [String: Set<PluginEvent>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var lastPrompt: [String: Date] = [:]

    private enum Key { static let enabled = "plugins.enabled", grants = "plugins.grants" }
    static let maxLogLines = 400

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Plugins", isDirectory: true)
    }

    private init() {
        enabled = Set(store.stringArray(forKey: Key.enabled) ?? [])
        let saved = store.dictionary(forKey: Key.grants) as? [String: [String]] ?? [:]
        grants = saved.mapValues { Set($0.compactMap(PluginPermission.init(rawValue:))) }
    }

    /// Call once at launch. Scans the folder and starts the plugins the owner enabled.
    func start() {
        guard !started else { return }
        started = true
        // Off until the owner enables one: a plugin never runs without its permission sheet.
        ThemeEngine.seedExamples(kind: "plugins", into: Self.folder, pathExtension: PluginManifest.bundleExtension)
        reload()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let payload: JSONValue = .object(["name": .string(app?.localizedName ?? ""), "bundleID": .string(app?.bundleIdentifier ?? "")])
            MainActor.assumeIsolated { PluginRegistry.shared.emit(.appActivated, payload: payload) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PluginRegistry.shared.emit(.spaceChanged, payload: .object([:])) }
        })
        // Atelier's own wallpaper changes. A wallpaper picked in System Settings is not seen.
        LiveWallpaper.shared.$shader.dropFirst().removeDuplicates().sink { shader in
            PluginRegistry.shared.emit(.wallpaperChanged, payload: .object(["live": .string(shader.rawValue)]))
        }.store(in: &cancellables)
        LiveWallpaper.shared.$enabled.dropFirst().removeDuplicates().sink { on in
            PluginRegistry.shared.emit(.wallpaperChanged, payload: .object(["live": on ? .string(LiveWallpaper.shared.shader.rawValue) : .null]))
        }.store(in: &cancellables)
        Effects.shared.$living.dropFirst().removeDuplicates().sink { hue in
            PluginRegistry.shared.emit(.wallpaperChanged, payload: .object(["mesh": hue.map { .string($0.rawValue) } ?? .null]))
        }.store(in: &cancellables)
    }

    // MARK: Library

    func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let urls = (try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var found: [InstalledPlugin] = [], problems: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == PluginManifest.bundleExtension {
            do { found.append(try Self.load(url)) } catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        installed = found
        self.problems = problems
        for id in Array(runtimes.keys) where !found.contains(where: { $0.id == id }) { stopRuntime(id) }
        for plugin in found where enabled.contains(plugin.id) && runtimes[plugin.id] == nil { launch(plugin) }
    }

    nonisolated static func load(_ folder: URL) throws -> InstalledPlugin {
        let manifestURL = folder.appendingPathComponent(PluginManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ThemeError.badURL("There is no \(PluginManifest.fileName) in the plugin.")
        }
        let (files, _) = ThemeEngine.inventory(folder)
        let (manifest, validation) = PluginManifest.parse(data, files: files)
        guard let manifest else { throw ThemeError.invalid(validation.issues) }
        return InstalledPlugin(manifest: manifest, folder: folder, warnings: validation.warnings)
    }

    /// Copies a `.atelierplugin` folder into the Plugins folder. It is not enabled: enabling
    /// asks for its permissions first.
    @discardableResult
    func install(from source: URL) throws -> InstalledPlugin {
        let plugin = try Self.load(source)
        let manager = FileManager.default
        try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let destination = Self.folder.appendingPathComponent(plugin.id + "." + PluginManifest.bundleExtension, isDirectory: true)
        let wasEnabled = enabled.contains(plugin.id)
        if manager.fileExists(atPath: destination.path) {
            stopRuntime(plugin.id)
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: source, to: destination)
        // An update that asks for more than was granted has to ask again.
        if wasEnabled, !plugin.manifest.permissions.allSatisfy({ grants[plugin.id]?.contains($0) == true }) {
            enabled.remove(plugin.id)
            status[plugin.id] = "Updated. It asks for new permissions, so it is off until you allow them."
        }
        reload()
        return installed.first { $0.id == plugin.id } ?? plugin
    }

    /// Moves a plugin to the Trash. Its stored data stays, in case it comes back.
    func remove(_ plugin: InstalledPlugin) {
        disable(plugin.id)
        do {
            try FileManager.default.trashItem(at: plugin.folder, resultingItemURL: nil)
            grants[plugin.id] = nil
        } catch {
            problems.append("Couldn’t remove \(plugin.manifest.name): \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: Enable, disable, permissions

    /// The permissions the manifest asks for that the owner has not granted.
    func missing(_ plugin: InstalledPlugin) -> [PluginPermission] {
        plugin.manifest.permissions.filter { grants[plugin.id]?.contains($0) != true }
    }

    func enable(_ plugin: InstalledPlugin, granting permissions: Set<PluginPermission>) {
        grants[plugin.id] = permissions.intersection(plugin.manifest.permissions)
        enabled.insert(plugin.id)
        stopRuntime(plugin.id)
        launch(plugin)
    }

    func disable(_ id: String) {
        enabled.remove(id)
        stopRuntime(id)
        status[id] = nil
    }

    func restart(_ plugin: InstalledPlugin) {
        stopRuntime(plugin.id)
        if enabled.contains(plugin.id) { launch(plugin) }
    }

    func isRunning(_ id: String) -> Bool { runtimes[id] != nil }
    /// A running plugin, for the hooks (PluginHooks.swift) to call back into.
    func runtime(_ id: String) -> PluginRuntime? { runtimes[id] }

    private func launch(_ plugin: InstalledPlugin) {
        let id = plugin.id
        let runtime = PluginRuntime(manifest: plugin.manifest, folder: plugin.folder, granted: grants[id] ?? []) { signal in
            // Main queue, not a Task: signals must arrive in the order the script sent them.
            DispatchQueue.main.async { MainActor.assumeIsolated { PluginRegistry.shared.receive(signal, from: id) } }
        }
        runtimes[id] = runtime
        status[id] = "Starting…"
        runtime.start()
    }

    private func stopRuntime(_ id: String) {
        runtimes.removeValue(forKey: id)?.stop()
        subscriptions[id] = nil
        widgets.removeAll { $0.plugin == id }
        dockTiles.removeAll { $0.plugin == id }
        commands.removeAll { $0.plugin == id }
        cornerActions.removeAll { $0.plugin == id }
        PluginHooks.shared.clear(id)
    }

    // MARK: Signals from runtimes

    private func receive(_ signal: PluginSignal, from id: String) {
        guard runtimes[id] != nil, let plugin = installed.first(where: { $0.id == id }) else { return }
        let name = plugin.manifest.name
        switch signal {
        case .started:
            status[id] = "Running"
        case .failed(let reason):
            append(id, "error", reason)
            stopRuntime(id)
            status[id] = reason
        case .log(let level, let text):
            append(id, level, text)
        case .message(let message):
            handle(message, from: id, name: name)
        case .hook(let message):
            PluginHooks.shared.handle(message, from: id, name: name)
        }
    }

    private func handle(_ message: PluginMessage, from id: String, name: String) {
        switch message {
        case .widget(let spec):
            if let index = widgets.firstIndex(where: { $0.plugin == id && $0.spec.id == spec.id }) { widgets[index].spec = spec }
            else { widgets.append(PluginWidget(plugin: id, spec: spec)) }
        case .widgetView(let widget, let view):
            if let index = widgets.firstIndex(where: { $0.plugin == id && $0.spec.id == widget }) {
                widgets[index].view = view
                widgets[index].error = nil
                widgets[index].updated = Date()
            }
        case .widgetError(let widget, let text):
            if let index = widgets.firstIndex(where: { $0.plugin == id && $0.spec.id == widget }) { widgets[index].error = text }
            append(id, "error", "\(widget): \(text)")
        case .tile(let spec):
            if let index = dockTiles.firstIndex(where: { $0.plugin == id && $0.spec.id == spec.id }) { dockTiles[index].spec = spec }
            else { dockTiles.append(PluginDockTile(plugin: id, spec: spec)) }
        case .command(let spec):
            commands.removeAll { $0.plugin == id && $0.spec.id == spec.id }
            commands.append(PluginCommand(plugin: id, pluginName: name, spec: spec))
        case .corner(let spec):
            cornerActions.removeAll { $0.plugin == id && $0.spec.id == spec.id }
            cornerActions.append(PluginCornerAction(plugin: id, pluginName: name, spec: spec))
        case .subscribe(let event, _):
            subscriptions[id, default: []].insert(event)
        case .notify(let title, let body):
            PluginNotifier.post(title: title, body: body, from: name)
            append(id, "info", "Notification: \(title)")
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            append(id, "info", "Opened \(url.absoluteString)")
        case .themeApply(let patch):
            if let error = ThemeEngine.shared.applyPatch(patch, from: id) { append(id, "error", "theme.apply: \(error)") }
            else { append(id, "info", "Changed the theme: \(patch.keys.sorted().joined(separator: ", "))") }
        case .log(let level, let text):
            append(id, level, text)
        case .prompt(let request, let title, let message, let placeholder, let secure):
            // At most one question every ten seconds per plugin, so a plugin cannot nag.
            if let last = lastPrompt[id], Date().timeIntervalSince(last) < 10 {
                runtimes[id]?.settle(request, ok: false, payload: .object(["error": .string("prompt: at most one question every 10 seconds.")]))
                return
            }
            lastPrompt[id] = Date()
            PluginPrompt.ask(title: title, message: message, placeholder: placeholder, secure: secure, from: name) { [weak self] answer in
                self?.runtimes[id]?.settle(request, ok: true, payload: .object(["text": answer.map(JSONValue.string) ?? .null]))
            }
        case .timer, .clearTimer, .http:
            break
        }
    }

    private func append(_ plugin: String, _ level: String, _ text: String) {
        log.append(PluginLogLine(date: Date(), plugin: plugin, level: level, text: text))
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    func clearLog(_ plugin: String? = nil) {
        if let plugin { log.removeAll { $0.plugin == plugin } } else { log.removeAll() }
    }

    // MARK: Calls in, for other modules

    /// Re-renders a plugin widget now, for example when it appears on screen.
    func render(widget key: String) {
        guard let widget = widgets.first(where: { $0.id == key }) else { return }
        runtimes[widget.plugin]?.render(widget: widget.spec.id)
    }

    func widget(_ key: String) -> PluginWidget? { widgets.first { $0.id == key } }
    func tile(_ key: String) -> PluginDockTile? { dockTiles.first { $0.id == key } }

    /// A click on a plugin's Dock tile.
    func click(tile key: String) {
        guard let tile = dockTiles.first(where: { $0.id == key }) else { return }
        runtimes[tile.plugin]?.invoke("tile:\(tile.spec.id):onClick")
    }

    func run(_ command: PluginCommand) {
        runtimes[command.plugin]?.invoke("command:\(command.spec.id):run")
    }

    /// For a hot corner bound to `pluginID/actionID`. Returns false when it is not running.
    @discardableResult
    func runCorner(_ key: String) -> Bool {
        guard let action = cornerActions.first(where: { $0.id == key }) else { return false }
        runtimes[action.plugin]?.invoke("corner:\(action.spec.id):run")
        return true
    }

    /// Sends an event to every plugin that listens for it.
    func emit(_ event: PluginEvent, payload: JSONValue) {
        for (id, events) in subscriptions where events.contains(event) {
            runtimes[id]?.emit(event, payload: payload)
        }
    }

    /// The Command palette's rows for plugin commands (snippet S9).
    func commandResults() -> [CommandResult] {
        let icon = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSApp.applicationIconImage!
        return commands.map { command in
            let shortcut = command.spec.shortcut.map { "  " + PluginShortcut.symbols($0) } ?? ""
            return CommandResult(title: command.spec.title, subtitle: (command.spec.subtitle ?? command.pluginName) + shortcut, icon: icon) {
                CommandController.shared.close()
                PluginRegistry.shared.run(command)
            }
        }
    }
}

/// A plain alert with one text field. Secure fields never echo, and the answer goes only to
/// the plugin that asked.
@MainActor
enum PluginPrompt {
    private static var open: NSPanel?

    /// Asks in Atelier's own small window, in front and focused, without blocking the app:
    /// an NSAlert run modally from a background app could come up blank or behind other windows.
    static func ask(title: String, message: String?, placeholder: String?, secure: Bool, from plugin: String,
                    answer: @escaping @MainActor (String?) -> Void) {
        open?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Whatever had focus before, so closing the prompt hands it back instead of letting the
        // window behind pick its first focusable view and draw a stray focus ring.
        let before = NSApp.keyWindow
        let beforeResponder = before?.firstResponder
        var finished = false
        let finish: @MainActor (String?) -> Void = { text in
            guard !finished else { return }
            finished = true
            // Drop the field's focus first: closing with it focused can strand its focus ring on screen.
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.close()
            if open === panel { open = nil }
            if let before, before !== panel { before.makeFirstResponder(beforeResponder) }
            DispatchQueue.main.async {
                if let key = NSApp.keyWindow, key !== before, key.firstResponder is NSText { key.makeFirstResponder(nil) }
            }
            answer(text)
        }
        let view = PluginPromptView(title: title, message: message, placeholder: placeholder ?? "", secure: secure,
                                    plugin: plugin, done: finish)
        panel.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { finish(nil) }
        }
        open = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct PluginPromptView: View {
    let title: String
    let message: String?
    let placeholder: String
    let secure: Bool
    let plugin: String
    let done: @MainActor (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Ink.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Asked by the plugin \u{201C}\(plugin)\u{201D}").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
            if let message, !message.isEmpty {
                Text(message).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            // Own field look: AppKit's focus ring could outlive this window and stay on screen.
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DS.Ink.accent : Color.white.opacity(0.12),
                                                                    lineWidth: focused ? 1.5 : 1))
            .focused($focused)
            .onSubmit { done(text) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(text) }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

/// Notifications from plugins. Posted only with the notifications permission, and only when
/// Atelier runs as an app bundle: UserNotifications needs a bundle identifier.
@MainActor
enum PluginNotifier {
    private static var authorised: Bool?

    static func post(title: String, body: String?, from plugin: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("Atelier plugin %@: %@ %@", plugin, title, body ?? "")
            return
        }
        let plugin = plugin, known = authorised
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted: Bool
            if let known { granted = known } else {
                granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                authorised = granted
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = plugin
            if let body { content.body = body }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
