import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

/// A theme Atelier knows about: one of the curated Looks, or one installed in the Themes folder.
struct InstalledTheme: Identifiable, Equatable {
    let document: ThemeDocument
    /// The `.ateliertheme` folder. Nil for built-in Looks.
    let bundle: URL?
    let warnings: [ThemeIssue]
    var id: String { document.id }
    var builtIn: Bool { bundle == nil }
    var previewImage: URL? {
        guard let bundle, let path = document.string("preview") else { return nil }
        return bundle.appendingPathComponent(path)
    }
}

/// Themes: the library, apply and revert, preview, import and export, and the day schedule.
@MainActor
final class ThemeEngine: ObservableObject {
    static let shared = ThemeEngine()
    private let store = UserDefaults.standard

    @Published private(set) var installed: [InstalledTheme] = []
    /// Built-in Looks and installed themes, Looks first.
    var all: [InstalledTheme] { LooksCatalog.all + installed }
    /// The theme last applied, by id. Nil once the owner reverts.
    @Published private(set) var appliedID: String? { didSet { store.set(appliedID, forKey: Key.applied) } }
    /// The setup from just before the first theme of this run of themes, for Revert.
    @Published private(set) var revertPoint: ThemeDocument? {
        didSet { store.set(try? revertPoint?.data(), forKey: Key.revert) }
    }
    @Published var schedule: ThemeSchedule { didSet { store.set(try? JSONEncoder().encode(schedule), forKey: Key.schedule) } }
    /// Problems from the last scan, import or apply, for the chapter to show.
    @Published var problem: String?
    @Published var notice: String?
    @Published private(set) var downloading = false

    /// A Studio accent colour used exactly, laid over the nearest named accent.
    static var exactAccent: String? {
        get { UserDefaults.standard.string(forKey: Key.exactAccent) }
        set { UserDefaults.standard.set(newValue, forKey: Key.exactAccent) }
    }

    private enum Key {
        static let applied = "theme.applied", revert = "theme.revert", schedule = "theme.schedule", exactAccent = "theme.exactAccent"
    }

    private var lastHour: Double?
    private var started = false

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Themes", isDirectory: true)
    }

    private init() {
        appliedID = store.string(forKey: Key.applied)
        revertPoint = store.data(forKey: Key.revert).flatMap { try? JSONValue.parse($0).object }.map(ThemeDocument.init(root:))
        schedule = store.data(forKey: Key.schedule).flatMap { try? JSONDecoder().decode(ThemeSchedule.self, from: $0) } ?? ThemeSchedule()
        // The old day and night Looks carry over, mapped to their new names.
        if !schedule.enabled, schedule.slots.isEmpty {
            var slots: [ThemeSchedule.Slot] = []
            if let day = store.string(forKey: "dayLook").flatMap(LooksCatalog.migrate) { slots.append(.init(hour: 7, theme: day)) }
            if let night = store.string(forKey: "nightLook").flatMap(LooksCatalog.migrate) { slots.append(.init(hour: 20, theme: night)) }
            if !slots.isEmpty { schedule = ThemeSchedule(enabled: true, slots: slots) }
        }
    }

    /// Call once at launch, after the modules have started.
    func start() {
        guard !started else { return }
        started = true
        if let hex = Self.exactAccent, let color = ThemeColor(hex: hex) { DS.Ink.current = Color(color) }
        reload()
        lastHour = Self.hourNow()
    }

    // MARK: Library

    func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let urls = (try? manager.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var found: [InstalledTheme] = [], problems: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == ThemeSchema.bundleExtension {
            do { found.append(try Self.load(url)) } catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        installed = found.filter { theme in !LooksCatalog.all.contains { $0.id == theme.id } }
        if !problems.isEmpty { problem = problems.joined(separator: "\n\n") }
    }

    func theme(_ id: String) -> InstalledTheme? { all.first { $0.id == id } }

    /// Reads and validates a `.ateliertheme` folder without installing it.
    nonisolated static func load(_ bundle: URL) throws -> InstalledTheme {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: bundle.path, isDirectory: &isFolder), isFolder.boolValue else { throw ThemeError.notABundle }
        let manifest = bundle.appendingPathComponent(ThemeSchema.fileName)
        guard manager.fileExists(atPath: manifest.path) else { throw ThemeError.missingManifest }
        let (files, bytes) = inventory(bundle)
        guard bytes <= ThemeSchema.maxBundleBytes else { throw ThemeError.tooLarge(bytes) }
        let data = try Data(contentsOf: manifest)
        let (value, validation) = ThemeValidator.validate(data: data, files: files)
        guard let root = value?.object, validation.isValid else { throw ThemeError.invalid(validation.issues) }
        return InstalledTheme(document: ThemeDocument(root: root), bundle: bundle, warnings: validation.warnings)
    }

    /// Relative paths of the regular files in a bundle, and their total size. Links are skipped,
    /// so a theme can never point outside its own folder.
    nonisolated static func inventory(_ bundle: URL) -> (Set<String>, Int) {
        var files = Set<String>(), bytes = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let base = bundle.standardizedFileURL.path + "/"
        let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            bytes += values.fileSize ?? 0
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { files.insert(String(path.dropFirst(base.count))) }
        }
        return (files, bytes)
    }

    // MARK: Apply, preview, revert

    /// Applies a theme. The setup before the first theme is kept, so Revert undoes a whole run
    /// of trying themes on, not only the last one.
    func apply(_ theme: InstalledTheme) {
        problem = nil
        if revertPoint == nil { revertPoint = ThemeApplier.capture(name: "Before Themes", id: "local.before-themes") }
        ThemeApplier.apply(theme.document, bundle: theme.bundle)
        appliedID = theme.id
        ThemePreview.shared.document = nil
        if let error = ThemeWallpaper.lastError { problem = error }
        PluginRegistry.shared.emit(.themeChanged, payload: .object(["id": .string(theme.id), "name": .string(theme.document.name)]))
    }

    /// Applies a theme patch from a plugin with the appearance permission. Only theme keys are
    /// accepted; the patch is validated as a theme of its own first.
    func applyPatch(_ patch: [String: JSONValue], from plugin: String) -> String? {
        var root = patch
        root["format"] = .number(1); root["id"] = .string("plugin." + plugin.replacingOccurrences(of: ".", with: "-") + ".patch")
        root["name"] = .string("Plugin change"); root["version"] = .string("1.0.0")
        let validation = ThemeValidator.validate(.object(root), files: [])
        guard validation.isValid else { return validation.errors.map(\.description).joined(separator: "; ") }
        if revertPoint == nil { revertPoint = ThemeApplier.capture(name: "Before Themes", id: "local.before-themes") }
        ThemeApplier.apply(ThemeDocument(root: root), bundle: nil)
        notice = "A plugin changed your theme. Revert undoes it."
        return nil
    }

    func revert() {
        guard let point = revertPoint else { return }
        ThemeApplier.apply(point, bundle: nil)
        if point.string("studio.accent").flatMap(ThemeColor.init(hex:)) == nil { Self.exactAccent = nil }
        revertPoint = nil
        appliedID = nil
        Effects.shared.look = point.root["x-look"]?.string
        PluginRegistry.shared.emit(.themeChanged, payload: .object(["id": .null, "name": .string("Reverted")]))
    }

    var canRevert: Bool { revertPoint != nil }

    // MARK: Schedule

    static func hourNow(_ date: Date = Date()) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    /// Call every minute. Applies a slot's theme only as its hour arrives.
    func tick() {
        let now = Self.hourNow()
        defer { lastHour = now }
        guard let last = lastHour, let id = schedule.change(from: last, to: now), let theme = theme(id), id != appliedID else { return }
        apply(theme)
    }

    // MARK: Import

    /// Installs a `.ateliertheme` folder or a bare `atelier-theme.json`, after validating it.
    /// Returns the installed theme; the caller decides whether to apply it.
    @discardableResult
    func install(from source: URL) throws -> InstalledTheme {
        let manager = FileManager.default
        let staged: URL
        if source.lastPathComponent == ThemeSchema.fileName || source.pathExtension == "json" {
            let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ThemeSchema.bundleExtension)
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: temp.appendingPathComponent(ThemeSchema.fileName))
            staged = temp
        } else if source.pathExtension == ThemeSchema.bundleExtension {
            staged = source
        } else {
            throw ThemeError.notABundle
        }
        let theme = try Self.load(staged)
        if LooksCatalog.all.contains(where: { $0.id == theme.id }) {
            throw ThemeError.badURL("\"\(theme.id)\" is the id of a built-in Look. Give the theme its own id.")
        }
        try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let destination = Self.folder.appendingPathComponent(theme.id + "." + ThemeSchema.bundleExtension, isDirectory: true)
        if manager.fileExists(atPath: destination.path) {
            // An update replaces the old copy; the old one goes to the Trash, not into the void.
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: staged, to: destination)
        if staged != source { try? manager.removeItem(at: staged) }
        reload()
        notice = "Installed \(theme.document.name)."
        return self.theme(theme.id) ?? theme
    }

    /// Follows an `atelier://theme?url=…` link: downloads over https, validates, installs.
    /// Nothing is applied: the gallery shows the theme so the owner can preview it first.
    func open(link: URL) async throws -> InstalledTheme {
        let target = try ThemeLink.download(from: link)
        downloading = true
        defer { downloading = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        let (file, response) = try await session.download(from: target)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ThemeError.badURL("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ThemeSchema.maxBundleBytes else { throw ThemeError.tooLarge(size) }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("atelier-theme-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        if target.pathExtension.lowercased() == "json" {
            let json = work.appendingPathComponent(ThemeSchema.fileName)
            try manager.moveItem(at: file, to: json)
            return try install(from: json)
        }
        let zip = work.appendingPathComponent("theme.zip")
        try manager.moveItem(at: file, to: zip)
        let out = work.appendingPathComponent("out", isDirectory: true)
        try await Self.unzip(zip, to: out)
        let walker = manager.enumerator(at: out, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == ThemeSchema.bundleExtension { return try install(from: url) }
        }
        let bare = out.appendingPathComponent(ThemeSchema.fileName)
        if manager.fileExists(atPath: bare.path) {
            let bundle = work.appendingPathComponent("theme." + ThemeSchema.bundleExtension)
            try manager.moveItem(at: out, to: bundle)
            return try install(from: bundle)
        }
        throw ThemeError.missingManifest
    }

    /// `ditto` refuses paths that escape the destination, which is why it is used over a hand
    /// rolled unzip. Runs off the main thread.
    nonisolated static func unzip(_ zip: URL, to destination: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", "--noqtn", zip.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ThemeError.badURL("The download is not a zip archive.") }
        }.value
    }

    /// For `application(_:open:)`: a `.ateliertheme` or `.atelierplugin` opened from Finder, or
    /// an `atelier://theme?url=` link. Installs, never applies or enables, then shows the
    /// Themes & Plugins chapter so the owner can preview and decide. Returns false for
    /// anything that is not a theme or plugin.
    @discardableResult
    func handleOpen(_ url: URL) -> Bool {
        let chapter = Chapter(rawValue: "themes")?.rawValue ?? Chapter.looks.rawValue
        if url.isFileURL {
            do {
                switch url.pathExtension {
                case ThemeSchema.bundleExtension: try install(from: url)
                case PluginManifest.bundleExtension: try PluginRegistry.shared.install(from: url)
                default: return false
                }
            } catch {
                problem = error.localizedDescription
            }
            ManagerWindow.shared.show(chapter: chapter)
            return true
        }
        guard url.host() == "theme" else { return false }
        let target: URL
        do { target = try ThemeLink.download(from: url) } catch {
            problem = error.localizedDescription
            ManagerWindow.shared.show(chapter: chapter)
            return true
        }
        // A link can come from any web page, so ask before downloading anything.
        let alert = NSAlert()
        alert.messageText = "Download a theme from \(target.host() ?? "the web")?"
        alert.informativeText = "\(target.absoluteString)\n\nAtelier checks the theme and adds it to your themes. Nothing changes until you apply it."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        Task {
            do { _ = try await open(link: url) } catch { problem = error.localizedDescription }
            ManagerWindow.shared.show(chapter: chapter)
        }
        return true
    }

    func remove(_ theme: InstalledTheme) {
        guard let bundle = theme.bundle else { return }
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            if appliedID == theme.id { appliedID = nil }
            schedule.slots.removeAll { $0.theme == theme.id }
            reload()
            notice = "Moved \(theme.document.name) to the Trash."
        } catch {
            problem = "Couldn’t remove \(theme.document.name): \(error.localizedDescription)"
        }
    }

    // MARK: Export

    /// Writes the Mac's current setup as a `.ateliertheme` folder.
    func export(name: String, author: String, to folder: URL) throws -> URL {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let user = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }
        var theme = ThemeApplier.capture(name: name, id: "local.\(user.isEmpty ? "me" : user).\(slug.isEmpty ? "theme" : slug)")
        theme.root["author"] = .string(author)
        theme.root["description"] = .string("Made with Create Theme from my Mac.")
        theme.root["x-originalImage"] = nil
        theme.root["x-look"] = nil
        let palette = theme.colors("wallpaper.palette")
        if palette == nil, theme.string("wallpaper.palette").map(ThemeSchema.palettes.contains) == false {
            theme.set("wallpaper.palette", nil)
        }
        let validation = ThemeValidator.validate(.object(theme.root), files: [])
        guard validation.isValid else { throw ThemeError.invalid(validation.issues) }
        let bundle = folder.appendingPathComponent("\(name).\(ThemeSchema.bundleExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try theme.data().write(to: bundle.appendingPathComponent(ThemeSchema.fileName), options: .atomic)
        return bundle
    }

    /// Saves an installed or built-in theme as a bundle, for sharing.
    func share(_ theme: InstalledTheme, to folder: URL) throws -> URL {
        let bundle = folder.appendingPathComponent("\(theme.document.name).\(ThemeSchema.bundleExtension)", isDirectory: true)
        if let source = theme.bundle {
            try FileManager.default.copyItem(at: source, to: bundle)
        } else {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try theme.document.data().write(to: bundle.appendingPathComponent(ThemeSchema.fileName), options: .atomic)
        }
        return bundle
    }
}

/// What the stage shows while the pointer rests on a theme. The Look preview the stage
/// already understands is set alongside; this carries what a Look cannot say (snippet S3).
@MainActor
final class ThemePreview: ObservableObject {
    static let shared = ThemePreview()
    @Published var document: ThemeDocument?

    var shader: LivingShader? {
        guard let document, document.string("wallpaper.mode") == "live" || document.value("wallpaper.shader") != nil else { return nil }
        return document.string("wallpaper.shader").flatMap(LivingShader.init(rawValue:))
    }
    var dockStyle: DockStyle? { document?.string("dock.style").flatMap(DockStyle.init(rawValue:)) }
    var accent: Color? { document?.color("colors.accent").map(Color.init) }
    var studioBackdrop: StudioBackdrop? { document?.string("studio.backdrop").flatMap(StudioBackdrop.init(rawValue:)) }

    private var pending: String?

    func show(_ theme: InstalledTheme?, on model: ManagerModel) {
        // A whole Look on the stage costs a full redraw. While the gallery scrolls under the
        // pointer, only the card it rests on once the scroll stops is shown.
        if ScrollActivity.scrolling {
            let id = theme?.document.name
            pending = id
            ScrollActivity.whenSettled { [weak self, weak model] in
                guard let self, let model, self.pending == id else { return }
                self.pending = nil
                self.apply(theme, on: model)
            }
            return
        }
        pending = nil
        apply(theme, on: model)
    }

    private func apply(_ theme: InstalledTheme?, on model: ManagerModel) {
        withAnimation(DS.Motion.camera) {
            document = theme?.document
            model.previewLook = theme.map { ThemeApplier.look(for: $0.document) }
        }
    }
}
