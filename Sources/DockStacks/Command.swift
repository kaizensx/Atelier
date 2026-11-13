import AppKit
import Carbon.HIToolbox
import DockCore
import SwiftUI

struct CommandResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    /// Made when a row is drawn, not when the list is built: Command lists every app, and
    /// only seven rows are ever on screen.
    private let makeIcon: @MainActor () -> NSImage
    let run: @MainActor () -> Void

    init(title: String, subtitle: String, icon: @autoclosure @escaping @MainActor () -> NSImage,
         run: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.makeIcon = icon
        self.run = run
    }

    @MainActor var icon: NSImage { makeIcon() }
}

/// One plugin's answer in the palette.
struct CommandPluginSection: Identifiable {
    let id: String
    let title: String
    let results: [CommandResult]
}

@MainActor
final class CommandModel: ObservableObject {
    @Published var open = false
    @Published var query = "" { didSet { selection = 0; recompute(); askPlugins() } }
    @Published var selection = 0
    /// Worked out once per keystroke, from lists read once per opening. Before, every keystroke
    /// and every arrow key read the stacks folder and the scenes file again and drew every icon.
    @Published private(set) var results: [CommandResult] = []
    /// Rows from plugins' palette providers, a section per plugin, below Atelier's own.
    @Published private(set) var pluginSections: [CommandPluginSection] = []
    private var pluginAsk: Task<Void, Never>?
    private var pluginGeneration = 0

    /// Everything that can be chosen, in the order drawn.
    var choices: [CommandResult] { results + pluginSections.flatMap(\.results) }

    /// Palette providers are asked 120 ms after typing stops. An answer for an older query, or
    /// one that comes after 1 s, is dropped.
    private func askPlugins() {
        pluginAsk?.cancel()
        pluginGeneration += 1
        let generation = pluginGeneration, text = query
        let hooks = PluginHooks.shared
        guard hooks.palettes.contains(where: { $0.spec.query(for: text) != nil }) else { pluginSections = []; return }
        pluginAsk = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, generation == self.pluginGeneration else { return }
            let asked = hooks.search(text) { [weak self] palette, rows in
                guard let self, generation == self.pluginGeneration else { return }
                self.pluginSections.removeAll { $0.id == palette.id }
                guard !rows.isEmpty else { return }
                let section = CommandPluginSection(id: palette.id, title: palette.spec.title == palette.spec.id ? palette.pluginName : palette.spec.title,
                                                   results: rows.map { Self.result($0, palette: palette) })
                self.pluginSections.append(section)
                self.pluginSections.sort { $0.title < $1.title }
            }
            // Providers this query no longer fits lose their rows now.
            let keep = Set(asked.map(\.id))
            self.pluginSections.removeAll { !keep.contains($0.id) }
        }
    }

    private static func result(_ row: PluginResultItem, palette: PluginPalette) -> CommandResult {
        let plugin = palette.plugin, action = row.action
        let folder = PluginRegistry.shared.installed.first { $0.id == plugin }?.folder
        let image = row.image.flatMap { image in folder.flatMap { PluginHookIcons.resolve(image, in: $0) } }
        return CommandResult(title: row.title, subtitle: row.subtitle ?? palette.pluginName,
                             icon: PluginHookIcons.image(PluginStackValue(plugin: plugin, action: action, symbol: row.symbol, imagePath: image))) {
            CommandController.shared.close()
            if let action { PluginHooks.shared.perform(plugin, action) }
        }
    }

    private var stacks: [CommandResult] = []
    private var actions: [CommandResult] = []
    private var apps: [CommandResult] = []
    private var everything: [CommandResult] = []

    /// Reads what Command searches, once each time it opens.
    func reload() {
        stacks = StackStore.list().map { url in
            let title = url.deletingPathExtension().lastPathComponent
            return CommandResult(title: title, subtitle: "Stack", icon: NSWorkspace.shared.icon(forFile: url.path)) {
                CommandController.shared.close()
                BubbleController.shared.toggle(url)
            }
        }
        let icons = AtelierIcons.shared
        apps = AppCatalog.shared.apps.map { item in
            // The icon chosen for it in Atelier (Orbit, Launcher), when there is one.
            CommandResult(title: item.name, subtitle: "App", icon: icons.custom(item.value) ?? ItemIcon.image(for: item)) {
                Launcher.open(item)
                CommandController.shared.close()
            }
        }
        actions = [
            CommandResult(title: "Open Atelier", subtitle: "Action", icon: NSApp.applicationIconImage) {
                CommandController.shared.close()
                ManagerWindow.shared.show()
            },
        ]
        let scenes = ProfileStore.load().map { profile in
            CommandResult(title: profile.name, subtitle: "Scene", icon: NSApp.applicationIconImage) {
                CommandController.shared.close()
                let url = profile.url, name = profile.name
                Task.detached { try? DockStore.apply(snapshotAt: url, label: "Scene \(name)") }
            }
        }
        let system = [
            ("Mission Control", "/System/Applications/Mission Control.app"),
            ("System Settings", "/System/Applications/System Settings.app"),
        ].map { name, path in
            CommandResult(title: name, subtitle: "System", icon: NSWorkspace.shared.icon(forFile: path)) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                CommandController.shared.close()
            }
        }
        let clips = ClipboardHistory.shared.items.map { text in
            CommandResult(title: String(text.prefix(70)), subtitle: "Clipboard", icon: NSWorkspace.shared.icon(for: .plainText)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                CommandController.shared.close()
            }
        }
        everything = stacks + scenes + actions + PluginRegistry.shared.commandResults() + system + apps + clips
        recompute()
    }

    private func recompute() {
        if let answer = Calculator.evaluate(query) {
            results = [CommandResult(title: answer, subtitle: "Copy result", icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                CommandController.shared.close()
            }]
            return
        }
        guard !query.isEmpty else { results = Array((stacks + actions + apps).prefix(7)); return }
        // Studio places and settings come from the same search as the Studio's own ⌘F, so a
        // setting found by a keyword ("screenshot") shows here too, ranked below title matches.
        let settings = NavIndex.search(query, limit: 7).map { entry in
            let result = CommandResult(title: entry.title, subtitle: entry.path, icon: Self.symbol(entry.symbol)) {
                CommandController.shared.close()
                NavFocus.shared.open(entry)
            }
            return (result, Fuzzy.score(query, in: entry.title) ?? 1)
        }
        let found = everything.compactMap { result in Fuzzy.score(query, in: result.title).map { (result, $0) } }
        // A plugin asked by its prefix (`gh …`) gets the room: Atelier keeps its best three.
        let prefixed = PluginHooks.shared.palettes.contains { $0.spec.prefix != nil && $0.spec.query(for: query) != nil }
        results = (found + settings).sorted { $0.1 > $1.1 }.prefix(prefixed ? 3 : 7).map(\.0)
    }
}

extension CommandModel {
    /// A place's symbol, drawn as an icon the size of an app's.
    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium).applying(.init(hierarchicalColor: .white))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSApp.applicationIconImage
    }
}

struct CommandView: View {
    @ObservedObject var model: CommandModel
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.choices
        let sections = model.pluginSections
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search apps, stacks, settings and actions", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .focused($focused)
                    .onSubmit { if results.indices.contains(model.selection) { results[model.selection].run() } }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            if sections.isEmpty {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in row(result, index: index) }
            } else {
                // Plugins answered: their rows, a section each, scroll under Atelier's own.
                let own = model.results.count
                let lines = own + sections.reduce(0) { $0 + $1.results.count }
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in row(result, index: index).id(index) }
                            ForEach(Array(sections.enumerated()), id: \.element.id) { number, section in
                                let start = own + sections.prefix(number).reduce(0) { $0 + $1.results.count }
                                HStack(spacing: 6) {
                                    Image(systemName: "puzzlepiece.extension").font(.system(size: 10, weight: .semibold))
                                    Text(section.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 4)
                                ForEach(Array(section.results.enumerated()), id: \.element.id) { offset, result in
                                    row(result, index: start + offset).id(start + offset)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(CGFloat(lines) * 48 + CGFloat(sections.count) * 26, 7 * 48 + 26))
                    .onChange(of: model.selection) { _, selected in reader.scrollTo(selected) }
                }
            }
        }
        .padding(10)
        .frame(width: 560)
        .atelierGlass(.regular, in: .rect(cornerRadius: 28))
        .scaleEffect(model.open ? 1 : 0.94)
        .opacity(model.open ? 1 : 0)
        .blur(radius: model.open ? 0 : 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.open)
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.open) { _, open in focused = open }
    }

    private func row(_ result: CommandResult, index: Int) -> some View {
        Button { result.run() } label: {
            HStack(spacing: 11) {
                Image(nsImage: result.icon).resizable().frame(width: 30, height: 30)
                Text(result.title).font(.system(size: 14, weight: .medium, design: .rounded)).lineLimit(1)
                Spacer()
                Text(result.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(index == model.selection ? 0.15 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

@MainActor
final class CommandController {
    static let shared = CommandController()
    private let model = CommandModel()
    private var panel: FloatingPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?

    func toggle() { model.open ? close() : show() }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        BubbleController.shared.close()
        let size = NSSize(width: 580, height: 520)
        let area = screen.visibleFrame
        let frame = NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - area.height * 0.18,
                           width: size.width, height: size.height)
        let panel = self.panel ?? {
            let panel = FloatingPanel(frame: frame)
            panel.contentView = NSHostingView(rootView: CommandView(model: model))
            self.panel = panel
            return panel
        }()
        model.query = ""
        model.reload()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.async { self.model.open = true }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true else { return false }
        let count = model.choices.count
        switch event.keyCode {
        case 53: close()
        case 125: if count > 0 { model.selection = (model.selection + 1) % count }
        case 126: if count > 0 { model.selection = (model.selection + count - 1) % count }
        default: return false
        }
        return true
    }

    func close() {
        guard model.open else { return }
        model.open = false
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideMonitor = nil
        keyMonitor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.model.open else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// Carbon hot keys need no Accessibility permission.
@MainActor
enum HotKey {
    private static var reference: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// Why ⌥ Space is not Command's, when registering it failed (another app holds it, often
    /// Spotlight or an input-source switcher). Settings shows it instead of the keycaps.
    private(set) static var failure: String?

    static var registered: Bool { reference != nil }

    static func install() {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { CommandController.shared.toggle() }
                return noErr
            }, 1, &type, nil, &handler)
        }
        guard reference == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4453544B), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, reference != nil {
            failure = nil
        } else {
            reference = nil
            failure = status == -9878   // eventHotKeyExistsErr
                ? "Another app already uses ⌥ Space. Open Command from the menu bar, or free the shortcut and try again."
                : "macOS did not accept ⌥ Space (error \(status)). Open Command from the menu bar."
        }
    }
}
