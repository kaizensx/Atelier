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

@MainActor
final class CommandModel: ObservableObject {
    @Published var open = false
    @Published var query = "" { didSet { selection = 0; recompute() } }
    @Published var selection = 0
    /// Worked out once per keystroke, from lists read once per opening. Before, every keystroke
    /// and every arrow key read the stacks folder and the scenes file again and drew every icon.
    @Published private(set) var results: [CommandResult] = []

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
        results = (found + settings).sorted { $0.1 > $1.1 }.prefix(7).map(\.0)
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
        let results = model.results
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
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                Button { result.run() } label: {
                    HStack(spacing: 11) {
                        Image(nsImage: result.icon).resizable().frame(width: 30, height: 30)
                        Text(result.title).font(.system(size: 14, weight: .medium, design: .rounded))
                        Spacer()
                        Text(result.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
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
        let size = NSSize(width: 580, height: 410)
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
        let count = model.results.count
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
