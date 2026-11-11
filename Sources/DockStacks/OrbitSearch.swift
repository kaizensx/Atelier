import AppKit

/// What search can reach beyond apps, each one opt-in: System Settings panes, read once from
/// the system's settings extensions, and files, asked of Spotlight only while a query is typed.
@MainActor
final class OrbitSearchSources {
    private(set) var panes: [OrbitEntry] = []
    private(set) var files: [OrbitEntry] = []
    /// Called when files or panes arrive, so results can refresh.
    var changed: (() -> Void)?

    private var loadingPanes = false
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var pendingFiles: Task<Void, Never>?

    func loadPanes() {
        guard panes.isEmpty, !loadingPanes else { return }
        loadingPanes = true
        Task.detached(priority: .utility) {
            let found = Self.scanPanes()
            await MainActor.run {
                let sources = Orbit.shared.search
                sources.panes = found
                sources.loadingPanes = false
                sources.changed?()
            }
        }
    }

    /// Settings panes are extensions on the settings extension point that accept the URL scheme.
    private nonisolated static func scanPanes() -> [OrbitEntry] {
        let root = "/System/Library/ExtensionKit/Extensions"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var entries: [OrbitEntry] = []
        for name in names where name.hasSuffix(".appex") {
            let path = root + "/" + name
            guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  let identifier = info["CFBundleIdentifier"] as? String,
                  let title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            else { continue }
            let settings = attributes["SettingsExtensionAttributes"] as? [String: Any]
            if settings?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == false { continue }
            entries.append(OrbitEntry(id: "pane:\(identifier)", name: title, paths: [path], folder: nil, kind: .pane,
                                      url: "x-apple.systempreferences:\(identifier)"))
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// Spotlight by name in the home folder, a short pause after the last key so typing stays cheap.
    func findFiles(_ text: String) {
        pendingFiles?.cancel()
        pendingFiles = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.start(text)
        }
    }

    private func start(_ text: String) {
        stopQuery()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            files = []
            changed?()
            return
        }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND %K != %@", NSMetadataItemFSNameKey, "*\(trimmed)*",
                                      NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { Orbit.shared.search.gathered() }
        }
        self.query = query
        query.start()
    }

    private func gathered() {
        guard let query else { return }
        query.disableUpdates()
        var found: [OrbitEntry] = []
        for index in 0..<min(query.resultCount, 12) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? (path as NSString).lastPathComponent
            found.append(OrbitEntry(id: "file:\(path)", name: name, paths: [path], folder: nil, kind: .file,
                                    url: URL(fileURLWithPath: path).absoluteString))
        }
        stopQuery()
        files = found
        changed?()
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func stopFiles() {
        pendingFiles?.cancel()
        stopQuery()
        files = []
    }
}
