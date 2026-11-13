import CoreServices
import DockCore
import Foundation

/// Plugins loaded with Load Plugin Folder…: they run straight from a folder anywhere on the
/// Mac, are marked Development, and restart within moments of a save, keeping their storage.
/// The folders are remembered as bookmarks, so a moved folder is still found.
@MainActor
final class PluginDevelopment {
    private let key = "plugins.development"
    private var watchers: [String: FolderWatcher] = [:]
    private var pending: [String: DispatchWorkItem] = [:]

    private var bookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Remembers a folder and returns the plugin in it. Throws when its manifest is invalid.
    func add(_ folder: URL) throws -> InstalledPlugin {
        var plugin = try PluginRegistry.load(folder)
        plugin.isDevelopment = true
        let mark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var list = bookmarks.filter { resolve($0)?.standardizedFileURL != folder.standardizedFileURL }
        // One development folder per plugin id.
        list.removeAll { data in resolve(data).flatMap { try? PluginRegistry.load($0) }?.id == plugin.id }
        list.append(mark)
        bookmarks = list
        return plugin
    }

    func forget(_ id: String) {
        bookmarks = bookmarks.filter { data in resolve(data).flatMap { try? PluginRegistry.load($0) }?.id != id }
        watchers.removeValue(forKey: id)?.stop()
    }

    /// The development plugins whose folders are still there and valid.
    func load(problems: inout [String]) -> [InstalledPlugin] {
        var out: [InstalledPlugin] = []
        for data in bookmarks {
            guard let folder = resolve(data) else { problems.append("A development plugin folder could not be found. Load it again."); continue }
            do {
                var plugin = try PluginRegistry.load(folder)
                plugin.isDevelopment = true
                if !out.contains(where: { $0.id == plugin.id }) { out.append(plugin) }
            } catch {
                problems.append("\(folder.lastPathComponent) (development): \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Watches each development plugin's folder; a save restarts that plugin.
    func watch(_ plugins: [InstalledPlugin]) {
        let ids = Set(plugins.map(\.id))
        for id in Array(watchers.keys) where !ids.contains(id) { watchers.removeValue(forKey: id)?.stop() }
        for plugin in plugins {
            if let existing = watchers[plugin.id], existing.folder == plugin.folder { continue }
            watchers[plugin.id]?.stop()
            let id = plugin.id
            watchers[id] = FolderWatcher(folder: plugin.folder) { [weak self] changed in
                self?.changed(id, files: changed)
            }
        }
    }

    /// Several saves in a burst restart once, 120 ms after the last.
    private func changed(_ id: String, files: [String]) {
        pending[id]?.cancel()
        let names = Array(Set(files.map { ($0 as NSString).lastPathComponent })).sorted()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { PluginRegistry.shared.reloadDevelopment(id, changed: names) }
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

extension PluginRegistry {
    /// Load Plugin Folder…: registers a plugin that runs from its own folder.
    @discardableResult
    func loadDevelopmentFolder(_ folder: URL) throws -> InstalledPlugin {
        let plugin = try development.add(folder)
        reload()
        append(plugin.id, "info", "Loaded for development from \(folder.path).")
        return installed.first { $0.id == plugin.id } ?? plugin
    }

    /// A development plugin's folder changed: read its manifest again and restart it.
    func reloadDevelopment(_ id: String, changed: [String]) {
        guard let current = installed.first(where: { $0.id == id && $0.isDevelopment }) else { return }
        let began = Date()
        do {
            var fresh = try PluginRegistry.load(current.folder)
            fresh.isDevelopment = true
            guard fresh.id == id else { reload(); return }
            if let index = installed.firstIndex(where: { $0.id == id }) { installed[index] = fresh }
            restart(fresh)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            append(id, "info", "Reloaded from disk in \(ms) ms" + (changed.isEmpty ? "." : " (\(changed.joined(separator: ", "))).") )
        } catch {
            append(id, "error", "Reload failed: \(error.localizedDescription)")
        }
    }
}

/// FSEvents on one folder, file by file. Calls back on the main queue.
final class FolderWatcher: @unchecked Sendable {
    let folder: URL
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String]) -> Void

    init(folder: URL, handler: @escaping @MainActor ([String]) -> Void) {
        self.folder = folder
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            // Hidden files (editor swap files, .DS_Store) do not restart the plugin.
            let visible = list.filter { !($0 as NSString).lastPathComponent.hasPrefix(".") }
            guard !visible.isEmpty else { return }
            MainActor.assumeIsolated { watcher.handler(Array(visible)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
