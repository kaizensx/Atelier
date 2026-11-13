import AppKit
import DockCore
import SwiftUI

// Hooks into Atelier: what running plugins have plugged into Atelier's own features, and the
// calls back into them. Palette providers feed the Command palette (Command.swift), tile
// menus and drops reach the Atelier Dock (OwnDock.swift), stack providers become stacks on it,
// and menu bar items, live activities and panels have their own files beside this one.

struct PluginPalette: Identifiable, Equatable {
    let plugin: String
    let pluginName: String
    var spec: PluginPaletteSpec
    var id: String { plugin + "/" + spec.id }
}

struct PluginStack: Identifiable, Equatable {
    let plugin: String
    let pluginName: String
    var spec: PluginStackSpec
    /// `pluginID/stackID`, as an Atelier Dock tile stores it.
    var id: String { plugin + "/" + spec.id }
}

@MainActor
final class PluginHooks: ObservableObject {
    static let shared = PluginHooks()

    @Published private(set) var palettes: [PluginPalette] = []
    @Published private(set) var stacks: [PluginStack] = []
    /// Dock tile menus and drops, by `pluginID/tileID`.
    @Published private(set) var tileHooks: [String: PluginTileHooks] = [:]

    private struct Pending {
        let plugin: String
        let limit: Int
        let done: @MainActor (Result<[PluginResultItem], PluginFailure>) -> Void
    }
    private var pending: [Int: Pending] = [:]
    private var nextRequest = 1
    private var stackCache: [String: (date: Date, items: [PluginResultItem])] = [:]

    /// A palette provider has this long to answer; later answers are dropped.
    static let paletteLimit: Double = 1
    /// A stack provider usually fetches something, so it may take a little longer.
    static let stackLimit: Double = 4

    private var registry: PluginRegistry { PluginRegistry.shared }

    // MARK: Messages from runtimes

    func handle(_ message: PluginHookMessage, from plugin: String, name: String) {
        switch message {
        case .palette(let spec):
            let entry = PluginPalette(plugin: plugin, pluginName: name, spec: spec)
            if let index = palettes.firstIndex(where: { $0.id == entry.id }) { palettes[index] = entry } else { palettes.append(entry) }
        case .menuBar(let spec):
            PluginMenuBar.shared.set(spec, plugin: plugin, pluginName: name)
        case .menuBarRemove(let id):
            PluginMenuBar.shared.remove(plugin: plugin, id: id)
        case .tileHooks(let hooks):
            tileHooks[plugin + "/" + hooks.id] = hooks
        case .stack(let spec):
            let entry = PluginStack(plugin: plugin, pluginName: name, spec: spec)
            stackCache[entry.id] = nil
            if let index = stacks.firstIndex(where: { $0.id == entry.id }) { stacks[index] = entry } else { stacks.append(entry) }
            OwnDock.shared.refreshPluginTiles()
        case .stackChanged(let id):
            stackCache[plugin + "/" + id] = nil
        case .activity(let spec):
            if let refusal = PluginActivities.shared.set(spec, plugin: plugin, pluginName: name) {
                registry.runtime(plugin)?.note("error", "liveActivity: \(refusal)")
            }
        case .activityEnd(let id):
            PluginActivities.shared.end(plugin: plugin, id: id)
        case .panel(let spec):
            guard let folder = registry.installed.first(where: { $0.id == plugin })?.folder else { return }
            PluginPanels.shared.set(spec, plugin: plugin, pluginName: name, folder: folder)
        case .panelShow(let id):
            if !PluginPanels.shared.show(plugin: plugin, id: id) { registry.runtime(plugin)?.note("error", "panel \(id): there is no such panel.") }
        case .panelHide(let id):
            PluginPanels.shared.hide(plugin: plugin, id: id)
        case .panelPost(let id, let message):
            PluginPanels.shared.post(message, plugin: plugin, id: id)
        case .scenesList(let request):
            let names = ProfileStore.load().map { JSONValue.object(["name": .string($0.name)]) }
            registry.runtime(plugin)?.settle(request, ok: true, payload: .object(["scenes": .array(names)]))
        case .scenesApply(let request, let sceneName):
            applyScene(sceneName, request: request, plugin: plugin, pluginName: name)
        case .reply(let request, let ok, let value, let error):
            guard let waiting = pending[request], waiting.plugin == plugin else { return }
            pending[request] = nil
            if ok { waiting.done(.success(PluginResultItem.parse(value, limit: waiting.limit))) }
            else { waiting.done(.failure(.script(error ?? "Failed."))) }
        }
    }

    /// Everything a plugin plugged in goes when it stops.
    func clear(_ plugin: String) {
        palettes.removeAll { $0.plugin == plugin }
        stacks.removeAll { $0.plugin == plugin }
        tileHooks = tileHooks.filter { !$0.key.hasPrefix(plugin + "/") }
        stackCache = stackCache.filter { !$0.key.hasPrefix(plugin + "/") }
        for (request, waiting) in pending where waiting.plugin == plugin {
            pending[request] = nil
            waiting.done(.failure(.refused("The plugin stopped.")))
        }
        PluginMenuBar.shared.clear(plugin: plugin)
        PluginActivities.shared.clear(plugin: plugin)
        PluginPanels.shared.clear(plugin: plugin)
        OwnDock.shared.refreshPluginTiles()
    }

    // MARK: Calls back into plugins

    /// Runs the function behind a menu item, a palette row or a stack item.
    func perform(_ plugin: String, _ action: String) {
        guard PluginHookCheck.isActionKey(action) else { return }
        registry.runtime(plugin)?.invoke(action)
    }

    /// Asks a provider for rows. `done` runs once: with the rows, or with why there are none.
    private func ask(_ plugin: String, key: String, payload: JSONValue, limit: Int, within seconds: Double,
                     done: @escaping @MainActor (Result<[PluginResultItem], PluginFailure>) -> Void) {
        guard let runtime = registry.runtime(plugin) else { done(.failure(.refused("The plugin is off."))); return }
        let request = nextRequest
        nextRequest += 1
        pending[request] = Pending(plugin: plugin, limit: limit, done: done)
        runtime.ask(key, request: request, payload: payload)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let waiting = self.pending.removeValue(forKey: request) else { return }
            waiting.done(.failure(.timeout))
        }
    }

    // MARK: Command palette

    /// Asks every provider the query fits. `answer` runs once per provider that answers in
    /// time, with its rows (empty when it failed). Returns the providers asked.
    @discardableResult
    func search(_ query: String, answer: @escaping @MainActor (PluginPalette, [PluginResultItem]) -> Void) -> [PluginPalette] {
        let asked = palettes.filter { $0.spec.query(for: query) != nil }
        for palette in asked {
            guard let text = palette.spec.query(for: query) else { continue }
            ask(palette.plugin, key: "palette:\(palette.spec.id):search", payload: .string(text),
                limit: PluginPaletteSpec.maxResults, within: Self.paletteLimit) { [weak self] result in
                switch result {
                case .success(let rows): answer(palette, rows)
                case .failure(let failure):
                    let reason = failure == .timeout ? "took longer than 1 s; its answer was dropped." : failure.description
                    self?.registry.runtime(palette.plugin)?.note("warn", "paletteProvider \(palette.spec.id): \(reason)")
                    answer(palette, [])
                }
            }
        }
        return asked
    }

    // MARK: Stacks

    func stack(_ key: String) -> PluginStack? { stacks.first { $0.id == key } }

    /// The items of a plugin's stack, fresh or from the last answer while it is fresh enough.
    func items(forStack key: String, done: @escaping @MainActor (Result<[StackItem], PluginFailure>) -> Void) {
        guard let stack = stack(key) else { done(.failure(.refused("The plugin is off."))); return }
        if let cached = stackCache[key], stack.spec.refresh > 0, Date().timeIntervalSince(cached.date) < stack.spec.refresh {
            done(.success(stackItems(cached.items, plugin: stack.plugin)))
            return
        }
        ask(stack.plugin, key: "stack:\(stack.spec.id):items", payload: .null, limit: PluginStackSpec.maxItems,
            within: Self.stackLimit) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rows):
                self.stackCache[key] = (Date(), rows)
                done(.success(self.stackItems(rows, plugin: stack.plugin)))
            case .failure(let failure):
                self.registry.runtime(stack.plugin)?.note("error", "stackProvider \(stack.spec.id): \(failure.description)")
                done(.failure(failure))
            }
        }
    }

    private func stackItems(_ rows: [PluginResultItem], plugin: String) -> [StackItem] {
        let folder = registry.installed.first { $0.id == plugin }?.folder
        return rows.map { row in
            var imagePath: String?
            if let image = row.image, let folder { imagePath = PluginHookIcons.resolve(image, in: folder) }
            let value = PluginStackValue(plugin: plugin, action: row.action, symbol: row.symbol, imagePath: imagePath)
            return StackItem(kind: .plugin, name: row.title, value: value.encoded)
        }
    }

    // MARK: Dock tiles

    func tileMenu(_ key: String) -> [PluginMenuEntry] { tileHooks[key]?.menu ?? [] }
    func accepts(_ key: String) -> Set<PluginDropKind> { tileHooks[key]?.accepts ?? [] }

    /// A link or text dropped on a plugin's tile. Files never get here.
    func drop(on key: String, kind: PluginDropKind, value: String) {
        guard let tile = registry.tile(key), accepts(key).contains(kind) else { return }
        registry.runtime(tile.plugin)?.invoke("tile:\(tile.spec.id):onDrop", payload: .object(["kind": .string(kind.rawValue), "value": .string(value)]))
    }

    // MARK: Scenes

    private func applyScene(_ sceneName: String, request: Int, plugin: String, pluginName: String) {
        guard let profile = ProfileStore.load().first(where: { $0.name == sceneName }) else {
            registry.runtime(plugin)?.settle(request, ok: false, payload: .object(["error": .string("There is no Scene called \(sceneName).")]))
            return
        }
        let url = profile.url, label = "Scene \(sceneName) (from \(pluginName))"
        registry.runtime(plugin)?.note("info", "Switching to the Scene \(sceneName).")
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do { try DockStore.apply(snapshotAt: url, label: label); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                let runtime = PluginRegistry.shared.runtime(plugin)
                if let failure { runtime?.settle(request, ok: false, payload: .object(["error": .string(failure)])) }
                else { runtime?.settle(request, ok: true, payload: .object([:])) }
            }
        }
    }
}

/// Icons for plugin rows and stack items: an SF Symbol, or a picture from the plugin's folder.
enum PluginHookIcons {
    nonisolated static func image(_ value: PluginStackValue) -> NSImage {
        if let path = value.imagePath, let image = NSImage(contentsOfFile: path) { return image }
        return symbol(value.symbol)
    }

    nonisolated static func symbol(_ name: String?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium).applying(.init(hierarchicalColor: .white))
        return NSImage(systemSymbolName: name ?? "puzzlepiece.extension", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSImage()
    }

    /// A relative path inside `folder`, or nil when it leaves the folder or is not a small picture.
    nonisolated static func resolve(_ relative: String, in folder: URL) -> String? {
        guard ThemeIdentifier.isSafeRelativePath(relative) else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let file = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base + "/"),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 2 * 1024 * 1024 else { return nil }
        return file.path
    }
}
