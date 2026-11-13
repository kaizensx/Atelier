import AppKit
import Combine
import DockCore
import Foundation

// MARK: - Atelier Mods: the app side
//
// Browse the community catalog, install, update and remove plugins and themes (and, with the
// Dock Bridge ready, native mods). The catalog lives at github.com/kaizensx/atelier-mods; its
// workflow publishes a signed index on the `dist` branch. ModClient does the downloading and the
// checking; this store keeps what the Mods chapter shows and hands verified packages to the
// existing PluginRegistry and ThemeEngine, which install them exactly as a dropped file.
//
// Test hook: atelier://mods?catalog=http://127.0.0.1:<port>/index.json | catalog=default | check=1 |
//            install=<id> | update=all | remove=<id> | report=1
// The override must be on 127.0.0.1 (http or https) and still be signed with the catalog key.
// It lasts until Atelier quits and keeps its own cache, so it never touches the real catalog's.
// install, update and remove act only while such a local catalog is in use, so a link on a web
// page cannot install or remove anything. The report goes to $TMPDIR/atelier-mods.txt.

enum ModsConfig {
    static let repository = "kaizensx/atelier-mods"
    static var indexURL: URL { URL(string: "https://raw.githubusercontent.com/\(repository)/dist/index.json")! }
    static var repositoryPage: URL { URL(string: "https://github.com/\(repository)")! }
    static var submitPage: URL { URL(string: "https://github.com/\(repository)/blob/main/CONTRIBUTING.md")! }
    static var reportPage: URL { URL(string: "https://github.com/\(repository)/issues/new?template=report-mod.yml")! }
    /// Public half of the catalog signing key. The private half is the catalog repository's
    /// MODS_SIGNING_KEY secret and a file on the maintainer's Mac; it is never in a repository.
    static let publicKey = "SATwJOjY3lMsJm4Ak8pOlyv54/DlSPynY0qz71XiGSY="

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Mods", isDirectory: true)
    }
    static var nativeFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Mods/Native", isDirectory: true)
    }
}

@MainActor
final class ModStore: ObservableObject {
    static let shared = ModStore()
    private let store = UserDefaults.standard

    enum Phase: Equatable {
        case idle, loading
        case loaded
        /// Showing the cached catalog because the network failed.
        case offline(String)
        /// No catalog at all: nothing cached and the network failed, or the catalog was refused.
        case failed(String)
    }

    enum Work: Equatable { case downloading, installing, removing }

    @Published private(set) var index: ModIndex?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date? { didSet { if !testing { store.set(lastCheck, forKey: Key.lastCheck) } } }
    @Published var autoCheck: Bool { didSet { store.set(autoCheck, forKey: Key.autoCheck) } }
    @Published private(set) var work: [String: Work] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published var notice: String?
    /// A mod page asked for by a link (the website's "Open in Atelier"); the chapter opens it.
    @Published var requestedPage: String?

    /// A plugin just installed or updated that needs the owner's permission before it runs.
    @Published var pendingPermission: InstalledPlugin?
    /// Plugins that an update left switched off until their new permissions are allowed.
    @Published private(set) var needsReview: [String] = []
    /// Ids installed from the catalog, for "From the catalog" in Installed.
    @Published private(set) var fromCatalog: [String: String] { didSet { if !testing { store.set(fromCatalog, forKey: Key.installed) } } }
    @Published private(set) var nativeInstalled: [InstalledModInfo] = []

    private var client: ModClient
    private var override: URL?
    private var testing: Bool { override != nil }
    private var testAccepted: Date?
    private var timer: Timer?
    private var started = false
    private var refreshTask: Task<Void, Never>?

    private enum Key {
        static let lastCheck = "mods.lastCheck", autoCheck = "mods.autoCheck", accepted = "mods.acceptedGenerated", installed = "mods.installed"
    }

    private init() {
        autoCheck = store.object(forKey: Key.autoCheck) as? Bool ?? true
        lastCheck = store.object(forKey: Key.lastCheck) as? Date
        fromCatalog = store.dictionary(forKey: Key.installed) as? [String: String] ?? [:]
        client = ModClient(config: .init(indexURL: ModsConfig.indexURL, publicKey: ModsConfig.publicKey,
                                         cacheFolder: ModsConfig.cacheFolder, allowLoopback: false))
    }

    /// Call once at launch: shows the cached catalog at once, and checks once a day.
    func start() {
        guard !started else { return }
        started = true
        if let cached = client.cached() { index = cached; phase = .loaded }
        scanNative()
        // Daily, quietly, and never in the first minute after launch.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { ModStore.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.checkIfDue() }
    }

    func checkIfDue() {
        guard autoCheck, ModUpdates.checkDue(last: lastCheck, now: Date()) else { return }
        refresh()
    }

    /// When the chapter opens: a catalog older than an hour is refreshed.
    func refreshIfStale() {
        if index == nil || phase == .idle || ModUpdates.checkDue(last: lastCheck, now: Date(), interval: 3600) { refresh() }
    }

    private var accepted: Date? {
        get { testing ? testAccepted : store.object(forKey: Key.accepted) as? Date }
        set { if testing { testAccepted = newValue } else { store.set(newValue, forKey: Key.accepted) } }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        phase = .loading
        let client = client, accepted = accepted
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                let fresh = try await client.refresh(accepted: accepted)
                index = fresh
                self.accepted = fresh.generated
                phase = .loaded
                lastCheck = Date()
                client.pruneScreenshots(keeping: fresh)
            } catch {
                let message = (error as? ModCatalogError)?.description ?? error.localizedDescription
                if case .stale = error as? ModCatalogError, index != nil { phase = .loaded; lastCheck = Date(); return }
                if let cached = index ?? client.cached() {
                    index = cached
                    phase = .offline(message)
                } else {
                    phase = .failed(message)
                }
            }
        }
    }

    func screenshot(_ shot: ModScreenshot) async -> Data? { await client.screenshot(shot) }

    // MARK: What is installed

    /// Every installed plugin, theme and native mod, wherever it came from.
    var installed: [InstalledModInfo] {
        PluginRegistry.shared.installed.map {
            InstalledModInfo(id: $0.id, kind: .plugin, version: $0.manifest.version,
                             permissions: $0.manifest.permissions.map(\.rawValue), hosts: $0.manifest.hosts)
        } + ThemeEngine.shared.installed.map {
            InstalledModInfo(id: $0.id, kind: .theme, version: $0.document.version)
        } + nativeInstalled + ModPackStore.shared.installedInfo
    }

    func installedVersion(_ id: String) -> String? { installed.first { $0.id == id }?.version }

    var updates: [ModUpdate] {
        guard let index else { return [] }
        return ModUpdates.available(installed: installed, index: index, atelier: AtelierInfo.version)
    }

    var nativeAvailable: Bool { DockBridge.shared.status.isReady }

    func isCompatible(_ entry: ModEntry) -> Bool { ModVersions.isCompatible(minAtelier: entry.minAtelier, running: AtelierInfo.version) }

    private func scanNative() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: ModsConfig.nativeFolder, includingPropertiesForKeys: nil)) ?? []
        nativeInstalled = urls.filter { $0.pathExtension == ModKind.native.packageExtension }.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent(NativeModManifest.fileName)),
                  let files = try? ModClient.inventory(url).files,
                  case .success(let m) = NativeModManifest.parse(data, files: files) else { return nil }
            return InstalledModInfo(id: m.id, kind: .native, version: m.version)
        }
    }

    // MARK: Install, update, remove

    /// Downloads, verifies and installs. A plugin is not switched on until its permissions are
    /// allowed: a new one asks at once; an update that asks for more is left off until allowed.
    func install(_ entry: ModEntry) async {
        guard work[entry.id] == nil else { return }
        guard entry.kind != .native || nativeAvailable else {
            failures[entry.id] = "Native mods need the Dock Bridge. Set it up in Beyond SIP first."
            return
        }
        guard isCompatible(entry) else {
            failures[entry.id] = "Needs Atelier \(entry.minAtelier ?? "") or newer."
            return
        }
        failures[entry.id] = nil
        work[entry.id] = .downloading
        defer { work[entry.id] = nil }
        let prepared: ModClient.Prepared
        do { prepared = try await client.prepare(entry) } catch {
            failures[entry.id] = (error as? ModCatalogError)?.description ?? error.localizedDescription
            return
        }
        defer { prepared.discard() }
        work[entry.id] = .installing
        do {
            switch entry.kind {
            case .plugin:
                let registry = PluginRegistry.shared
                let wasInstalled = registry.installed.contains { $0.id == entry.id }
                let wasEnabled = registry.enabled.contains(entry.id)
                let plugin = try registry.install(from: prepared.folder)
                if !wasInstalled {
                    if plugin.manifest.permissions.isEmpty { registry.enable(plugin, granting: []) } else { pendingPermission = plugin }
                } else if wasEnabled, !registry.enabled.contains(entry.id) {
                    needsReview.append(entry.id)
                    if pendingPermission == nil { pendingPermission = plugin }
                }
            case .theme:
                try ThemeEngine.shared.install(from: prepared.folder)
            case .native:
                try installNative(prepared.folder, id: entry.id)
            default:
                // Data-only packs: checked again and copied into their own folder.
                if let pack = entry.kind.pack { try ModPackStore.shared.install(from: prepared.folder, expecting: pack) }
            }
            fromCatalog[entry.id] = entry.version
            notice = "Installed \(entry.name) \(entry.version)."
        } catch {
            failures[entry.id] = error.localizedDescription
        }
    }

    private func installNative(_ folder: URL, id: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: ModsConfig.nativeFolder, withIntermediateDirectories: true)
        let destination = ModsConfig.nativeFolder.appendingPathComponent(id + "." + ModKind.native.packageExtension, isDirectory: true)
        if manager.fileExists(atPath: destination.path) { try manager.trashItem(at: destination, resultingItemURL: nil) }
        try manager.copyItem(at: folder, to: destination)
        scanNative()
    }

    /// One click: every compatible update, one after another.
    func updateAll() async {
        for update in updates where update.compatible { await install(update.entry) }
        if needsReview.isEmpty, failures.isEmpty { notice = "Everything is up to date." }
    }

    func reviewed(_ id: String) { needsReview.removeAll { $0 == id } }

    /// Removes cleanly: the package to the Trash, and for a plugin its permissions and its stored
    /// data too (to the Trash, so nothing is lost by accident).
    func remove(_ id: String) {
        let manager = FileManager.default
        work[id] = .removing
        defer { work[id] = nil }
        if let plugin = PluginRegistry.shared.installed.first(where: { $0.id == id }) {
            PluginRegistry.shared.remove(plugin)
            let data = PluginRuntime.dataFolder.appendingPathComponent(id + ".json")
            if manager.fileExists(atPath: data.path) { try? manager.trashItem(at: data, resultingItemURL: nil) }
        } else if let theme = ThemeEngine.shared.installed.first(where: { $0.id == id }) {
            ThemeEngine.shared.remove(theme)
        } else if ModPackStore.shared.pack(id) != nil {
            ModPackStore.shared.remove(id)
        } else {
            let folder = ModsConfig.nativeFolder.appendingPathComponent(id + "." + ModKind.native.packageExtension)
            try? manager.trashItem(at: folder, resultingItemURL: nil)
            scanNative()
        }
        fromCatalog[id] = nil
        needsReview.removeAll { $0 == id }
        failures[id] = nil
        objectWillChange.send()
    }

    // MARK: Test hook

    func handleTest(_ items: [URLQueryItem]) {
        let value = { (n: String) in items.first { $0.name == n }?.value }
        if let c = value("catalog") {
            if c == "default" { use(nil) } else if let url = URL(string: c) { use(url) }
        }
        if value("check") != nil { refresh() }
        // Acting on mods from a link: only against a local test catalog. A link from the website
        // (atelier://mods?install=<id> or open=<id>) only opens that mod's page; installing it
        // still takes the person's own click there.
        guard testing else {
            if let id = value("install") ?? value("open") {
                // After the Studio has switched to Mods (which rebuilds the chapter), not before.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { ModStore.shared.requestedPage = id }
                }
            }
            if value("report") != nil { writeReport() }
            return
        }
        Task {
            if let id = value("install") {
                while refreshTask != nil { try? await Task.sleep(for: .milliseconds(100)) }
                if let entry = index?.mod(id) { await install(entry) }
            }
            if value("update") == "all" { await updateAll() }
            if let id = value("remove") { remove(id) }
            if value("report") != nil {
                while refreshTask != nil { try? await Task.sleep(for: .milliseconds(100)) }
                writeReport()
            }
        }
    }

    /// Points at a local test catalog until Atelier quits, or back at the real one (nil).
    private func use(_ url: URL?) {
        let loopback = url.flatMap { $0.host() }.map(ModURLPolicy.isLoopback) ?? false
        if let url, !(loopback && ModURLPolicy.isAllowed(url, allowLoopback: true)) {
            phase = .failed("A test catalog must be on 127.0.0.1.")
            return
        }
        override = url
        testAccepted = nil
        index = nil
        let cache = url == nil ? ModsConfig.cacheFolder : FileManager.default.temporaryDirectory.appendingPathComponent("atelier-mods-test", isDirectory: true)
        client = ModClient(config: .init(indexURL: url ?? ModsConfig.indexURL, publicKey: ModsConfig.publicKey,
                                         cacheFolder: cache, allowLoopback: loopback))
        if url == nil, let cached = client.cached() { index = cached }
        phase = .idle
    }

    private func writeReport() {
        var lines = ["catalog \(client.config.indexURL.absoluteString)", "phase \(phase)",
                     "mods \(index?.mods.count ?? 0) generated \(index.map { ModDates.format($0.generated) } ?? "-")"]
        for mod in index?.mods ?? [] {
            lines.append("  \(mod.id) \(mod.kind.rawValue) \(mod.version) installed=\(installedVersion(mod.id) ?? "-")")
        }
        lines.append("updates " + updates.map { "\($0.id) \($0.from)->\($0.to)" }.joined(separator: ", "))
        lines.append("failures " + failures.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-mods.txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
