import AppKit
import AVFoundation
import DockCore
import SwiftUI

// MARK: - Mod packs: the app side
//
// Data-only mods (DockCore/ModPacks.swift has the format and every rule). This store installs,
// lists and removes them, the same way for a pack from the catalog and one dropped from Finder,
// and remembers which ones are in use. Each kind then reaches the part of Atelier it changes:
//   icons    AtelierIcons (Atelier Dock tiles, Orbit, the Launcher, Command) by bundle id
//   sounds   DockSounds, ThemeSounds, the timers' chime and Typing Sounds
//   shader   Live Wallpaper: a built-in shader with the pack's palette and tuning
//   layouts  Window Engine: added to the custom snap layouts
//   effects  the Atelier Dock's minimise effect picker
//   look     a theme, a wallpaper, Dock settings and packs at once; Revert undoes all of it
// Nothing in a pack runs. Real app bundles and Apple's Dock are never touched.

struct InstalledPack: Identifiable, Equatable {
    let pack: ModPack
    let bundle: URL
    let warnings: [String]
    var id: String { pack.header.id }
    var kind: ModPackKind { pack.kind }
    var name: String { pack.header.name }

    func file(_ path: String) -> URL { bundle.appendingPathComponent(path) }
}

@MainActor
final class ModPackStore: ObservableObject {
    static let shared = ModPackStore()
    private let store = UserDefaults.standard

    @Published private(set) var installed: [InstalledPack] = []
    @Published var problem: String?
    @Published var notice: String?

    /// The icon pack in use, and the bundle ids that keep their own icon.
    @Published var iconPackID: String? { didSet { store.set(iconPackID, forKey: Key.icons); applyIcons() } }
    @Published private(set) var iconOriginals: Set<String> { didSet { store.set(iconOriginals.sorted(), forKey: Key.originals); applyIcons() } }
    @Published var soundPackID: String? { didSet { store.set(soundPackID, forKey: Key.sounds); applySounds() } }
    /// Typing Sounds plays the sound pack's key sounds in place of the built-in voice.
    @Published var typingFromPack: Bool { didSet { store.set(typingFromPack, forKey: Key.typing); applySounds() } }
    /// The shader pack last worn, for the check mark. Live Wallpaper keeps the real state.
    @Published var shaderPackID: String? { didSet { store.set(shaderPackID, forKey: Key.shader) } }

    private enum Key {
        static let icons = "packs.icons.active", originals = "packs.icons.original", sounds = "packs.sounds.active"
        static let typing = "packs.sounds.typing", shader = "packs.shader.active"
    }

    private var started = false

    private init() {
        iconPackID = store.string(forKey: Key.icons)
        iconOriginals = Set(store.stringArray(forKey: Key.originals) ?? [])
        soundPackID = store.string(forKey: Key.sounds)
        typingFromPack = store.bool(forKey: Key.typing)
        shaderPackID = store.string(forKey: Key.shader)
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Atelier", isDirectory: true)
    }

    static func folder(_ kind: ModPackKind) -> URL { root.appendingPathComponent(kind.folderName, isDirectory: true) }

    /// Once at launch: read the folders and put the packs in use back in place.
    func start() {
        guard !started else { return }
        started = true
        reload()
        applyIcons()
        applySounds()
    }

    // MARK: Library

    func reload() {
        var found: [InstalledPack] = [], problems: [String] = []
        for kind in ModPackKind.allCases {
            let folder = Self.folder(kind)
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == kind.bundleExtension {
                switch ModPackDisk.load(url, kind: kind) {
                case .success(let (pack, report)): found.append(InstalledPack(pack: pack, bundle: url, warnings: report.warnings))
                case .failure(let error): problems.append("\(url.lastPathComponent): \(error.description)")
                }
            }
        }
        installed = found
        if !problems.isEmpty { problem = problems.joined(separator: "\n") }
        // A pack in use that is gone is no longer in use.
        if let id = iconPackID, pack(id, kind: .icons) == nil { iconPackID = nil }
        if let id = soundPackID, pack(id, kind: .sounds) == nil { soundPackID = nil }
    }

    func pack(_ id: String, kind: ModPackKind? = nil) -> InstalledPack? {
        installed.first { $0.id == id && (kind == nil || $0.kind == kind) }
    }

    func packs(_ kind: ModPackKind) -> [InstalledPack] { installed.filter { $0.kind == kind } }

    /// For the Mods chapter: every pack, as the catalog compares versions.
    var installedInfo: [InstalledModInfo] {
        installed.map { InstalledModInfo(id: $0.id, kind: ModKind($0.kind), version: $0.pack.header.version) }
    }

    // MARK: Install and remove

    /// Checks a pack folder and copies it into Atelier's folder for its kind. A pack with the
    /// same id is replaced; the old copy goes to the Trash.
    @discardableResult
    func install(from source: URL, expecting: ModPackKind? = nil) throws -> InstalledPack {
        guard let kind = expecting ?? ModPackKind.of(extension: source.pathExtension) else {
            throw ModCatalogError.package("\(source.lastPathComponent) is not a pack Atelier knows.")
        }
        let (pack, report): (ModPack, ModPackReport)
        switch ModPackDisk.load(source, kind: kind) {
        case .success(let value): (pack, report) = value
        case .failure(let error): throw error
        }
        let manager = FileManager.default
        let folder = Self.folder(kind)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(pack.header.id + "." + kind.bundleExtension, isDirectory: true)
        if manager.fileExists(atPath: destination.path) { try manager.trashItem(at: destination, resultingItemURL: nil) }
        try manager.copyItem(at: source, to: destination)
        reload()
        notice = "Installed \(pack.header.name)."
        let installed = self.pack(pack.header.id, kind: kind) ?? InstalledPack(pack: pack, bundle: destination, warnings: report.warnings)
        // A pack in use that was just updated is read again.
        if kind == .icons, iconPackID == installed.id { applyIcons() }
        if kind == .sounds, soundPackID == installed.id { applySounds() }
        if kind == .layouts, LayoutPackRuntime.isAdded(installed) { LayoutPackRuntime.add(installed) }
        return installed
    }

    /// Moves a pack to the Trash and stops using it. False when no pack has that id.
    @discardableResult
    func remove(_ id: String) -> Bool {
        guard let pack = pack(id) else { return false }
        if iconPackID == id { iconPackID = nil }
        if soundPackID == id { soundPackID = nil }
        if shaderPackID == id { shaderPackID = nil }
        if pack.kind == .layouts { LayoutPackRuntime.remove(pack) }
        if pack.kind == .effects, MinimizeEffectSetting.packEffect?.pack == id { MinimizeEffectSetting.packEffect = nil }
        do {
            try FileManager.default.trashItem(at: pack.bundle, resultingItemURL: nil)
            notice = "Moved \(pack.name) to the Trash."
        } catch {
            problem = "Couldn’t remove \(pack.name): \(error.localizedDescription)"
        }
        reload()
        return true
    }

    // MARK: Use

    func isInUse(_ pack: InstalledPack) -> Bool {
        switch pack.kind {
        case .icons: iconPackID == pack.id
        case .sounds: soundPackID == pack.id
        case .shader: shaderPackID == pack.id && LiveWallpaper.shared.enabled
        case .layouts: LayoutPackRuntime.isAdded(pack)
        case .effects: MinimizeEffectSetting.packEffect?.pack == pack.id
        case .look: ThemeEngine.shared.appliedID == LookApplier.themeID(pack)
        }
    }

    /// The one action a pack has: wear it, play it, add it.
    func use(_ pack: InstalledPack) {
        problem = nil
        switch pack.pack {
        case .icons: iconPackID = pack.id
        case .sounds: soundPackID = pack.id
        case .shader(let shader):
            ShaderPackRuntime.wear(shader)
            shaderPackID = pack.id
        case .layouts: LayoutPackRuntime.add(pack)
        case .effects(let effects):
            if let first = effects.effects.first { MinimizeEffectSetting.packEffect = (pack.id, first.id) }
        case .look: LookApplier.apply(pack)
        }
        objectWillChange.send()
    }

    func stopUsing(_ pack: InstalledPack) {
        switch pack.kind {
        case .icons: if iconPackID == pack.id { iconPackID = nil }
        case .sounds: if soundPackID == pack.id { soundPackID = nil }
        case .shader:
            if shaderPackID == pack.id {
                shaderPackID = nil
                if case .shader(let shader) = pack.pack { ShaderPackRuntime.stop(shader) }
            }
        case .layouts: LayoutPackRuntime.remove(pack)
        case .effects: if MinimizeEffectSetting.packEffect?.pack == pack.id { MinimizeEffectSetting.packEffect = nil }
        case .look: if ThemeEngine.shared.canRevert { ThemeEngine.shared.revert() }
        }
        objectWillChange.send()
    }

    // MARK: Icons

    /// Keeps an app's own icon while the pack is in use, or gives it the pack's again.
    func setOriginal(_ bundleID: String, _ original: Bool) {
        if original { iconOriginals.insert(bundleID) } else { iconOriginals.remove(bundleID) }
    }

    /// For the Dock's tile menu: the app at `path` keeps its own icon.
    func keepOriginal(path: String) {
        guard let id = IconPackRuntime.bundleID(path) else { return }
        setOriginal(id, true)
    }

    private func applyIcons() {
        if let id = iconPackID, let installed = pack(id, kind: .icons), case .icons(let icons) = installed.pack {
            IconPackRuntime.configure(folder: installed.bundle, icons: icons.icons, originals: iconOriginals)
        } else {
            IconPackRuntime.configure(folder: nil, icons: [:], originals: [])
        }
        AtelierIcons.shared.packChanged()
    }

    private func applySounds() {
        if let id = soundPackID, let installed = pack(id, kind: .sounds), case .sounds(let sounds) = installed.pack {
            SoundPackRuntime.configure(installed.bundle, sounds, typing: typingFromPack)
        } else {
            SoundPackRuntime.configure(nil, nil, typing: false)
        }
    }

    // MARK: Opening

    /// A pack opened from Finder or dropped on the Library: installed, never used until chosen.
    func handleOpen(_ url: URL) -> Bool {
        guard ModPackKind.of(extension: url.pathExtension) != nil else { return false }
        do { try install(from: url) } catch {
            problem = (error as? ModCatalogError)?.description ?? error.localizedDescription
        }
        return true
    }
}

// MARK: - Icons

/// The icon pack, read from any thread: Orbit draws icons in the background. A lock guards the
/// map and the decoded pictures.
enum IconPackRuntime {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var folder: URL?
        var icons: [String: String] = [:]
        var originals: Set<String> = []
        var images: [String: NSImage] = [:]
        var bundleIDs: [String: String] = [:]
    }

    private static let state = State()

    static func configure(folder: URL?, icons: [String: String], originals: Set<String>) {
        state.lock.lock()
        state.folder = folder
        state.icons = icons
        state.originals = originals
        state.images = [:]
        state.lock.unlock()
    }

    static var active: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.folder != nil
    }

    /// The bundle identifier of an app at a path, read once.
    static func bundleID(_ path: String) -> String? {
        guard path.hasSuffix(".app") else { return nil }
        state.lock.lock()
        if let known = state.bundleIDs[path] { state.lock.unlock(); return known.isEmpty ? nil : known }
        state.lock.unlock()
        let id = Bundle(path: path)?.bundleIdentifier ?? ""
        state.lock.lock()
        state.bundleIDs[path] = id
        state.lock.unlock()
        return id.isEmpty ? nil : id
    }

    /// The pack's picture for a key (a bundle id or a special key), unless the owner keeps the
    /// original for it.
    static func image(key: String) -> NSImage? {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let folder = state.folder, !state.originals.contains(key), let path = state.icons[key] else { return nil }
        if let image = state.images[key] { return image }
        guard let image = NSImage(contentsOf: folder.appendingPathComponent(path)) else { return nil }
        state.images[key] = image
        return image
    }

    /// The pack's picture for an app (or the Downloads folder, or any folder) at a path.
    static func image(forPath path: String) -> NSImage? {
        guard active else { return nil }
        if let id = bundleID(path) { return image(key: id) }
        return nil
    }

    static func folderImage(_ path: String) -> NSImage? {
        guard active else { return nil }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        if path == downloads, let image = image(key: "downloads") { return image }
        return image(key: "folder")
    }

    /// Whether the pack changes the icon of the app at `path` now.
    static func covers(_ path: String) -> Bool { image(forPath: path) != nil }
}

// MARK: - Sounds

@MainActor
enum SoundPackRuntime {
    private static var folder: URL?
    private static var pack: SoundPack?
    private static var typingOn = false
    private static var cache: [SoundSlot: NSSound] = [:]
    private static var bank: [[AVAudioPCMBuffer]]?
    private static var bankFormat: AVAudioFormat?

    static func configure(_ folder: URL?, _ pack: SoundPack?, typing: Bool) {
        self.folder = folder
        self.pack = pack
        typingOn = typing && pack?.hasTyping == true
        cache = [:]
        bank = nil
    }

    static var activeName: String? { pack?.header.name }

    static func sound(_ slot: SoundSlot) -> NSSound? {
        if let sound = cache[slot] { return sound }
        guard let folder, let path = pack?.sounds[slot],
              let sound = NSSound(contentsOf: folder.appendingPathComponent(path), byReference: true) else { return nil }
        cache[slot] = sound
        return sound
    }

    /// Plays the pack's sound for a slot. False when the pack has none, so the caller plays its own.
    @discardableResult
    static func play(_ slot: SoundSlot, volume: Float? = nil) -> Bool {
        guard let sound = sound(slot) else { return false }
        if let volume { sound.volume = volume }
        if sound.isPlaying { sound.stop() }
        sound.play()
        return true
    }

    /// The timers' chime: the pack's, or the one macOS ships.
    static func timerDone() {
        if !play(.timerDone) { NSSound(named: "Glass")?.play() }
    }

    /// Typing Sounds' variants for a key class, decoded into the player's format once.
    static func typingVariants(_ kind: TypingKeyClass, format: AVAudioFormat) -> [AVAudioPCMBuffer]? {
        guard typingOn, let pack, let folder else { return nil }
        if bank == nil || bankFormat != format {
            bankFormat = format
            bank = TypingKeyClass.allCases.map { keyClass in
                let slot = TypingSlot.allCases.first { $0.keyClass == keyClass } ?? .key
                return pack.variants(slot).compactMap { decode(folder.appendingPathComponent($0), into: format) }
            }
        }
        guard let bank, bank.indices.contains(kind.rawValue), !bank[kind.rawValue].isEmpty else { return nil }
        return bank[kind.rawValue]
    }

    /// Any CAF, M4A or WAV, converted to the engine's format (mono, 48 kHz, float).
    static func decode(_ url: URL, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024) else { return nil }
        nonisolated(unsafe) var given = false
        nonisolated(unsafe) let source = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return source
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Plays a file from an installed pack, for the preview's play buttons.
    static func preview(_ url: URL) {
        NSSound(contentsOf: url, byReference: true)?.play()
    }
}

// MARK: - Shaders

@MainActor
enum ShaderPackRuntime {
    /// The tuning a pack asks for, with its palette registered under the pack's id.
    static func tuning(_ pack: ShaderPack) -> LivingTuning {
        var tuning = LivingTuning()
        if pack.palette.count == 4 { tuning.palette = ThemePalettes.register(pack.palette, for: "pack." + pack.header.id) }
        tuning.speed = pack.speed
        tuning.intensity = pack.intensity
        tuning.grain = pack.grain
        tuning.scale = pack.scale
        tuning.dim = pack.dim
        tuning.pointer = pack.pointer
        tuning.cycle = DayCycle(rawValue: pack.cycle) ?? .clock
        return tuning
    }

    static func shader(_ pack: ShaderPack) -> LivingShader? { LivingShader(rawValue: pack.base) }

    /// The wallpaper as it was before the first shader pack was worn, so Stop puts it back.
    private struct Before: Codable {
        var enabled: Bool, scheduled: Bool, shader: String, tuning: LivingTuning?, living: String?
    }
    private static let beforeKey = "packs.shader.before"

    /// Wears a pack: its base shader with its tuning, live on the desktop.
    static func wear(_ pack: ShaderPack) {
        guard let shader = shader(pack) else { return }
        let live = LiveWallpaper.shared
        let store = UserDefaults.standard
        if store.data(forKey: beforeKey) == nil {
            let before = Before(enabled: live.enabled, scheduled: live.scheduled, shader: live.shader.rawValue,
                                tuning: live.tunings[shader], living: Effects.shared.living?.rawValue)
            if let data = try? JSONEncoder().encode(before) { store.set(data, forKey: beforeKey) }
        }
        live.setTuning(tuning(pack), for: shader)
        if Effects.shared.living != nil { Effects.shared.living = nil }
        if live.scheduled { live.scheduled = false }
        if live.shader != shader { live.shader = shader }
        if !live.enabled { live.enabled = true }
    }

    /// Takes the worn pack off: the wallpaper, shader, schedule, tuning and mesh go back to how
    /// they were before the first pack was worn.
    static func stop(_ pack: ShaderPack) {
        let store = UserDefaults.standard
        guard let data = store.data(forKey: beforeKey), let before = try? JSONDecoder().decode(Before.self, from: data) else { return }
        store.removeObject(forKey: beforeKey)
        let live = LiveWallpaper.shared
        if let worn = shader(pack) {
            if let tuning = before.tuning { live.setTuning(tuning, for: worn) } else { live.setTuning(LivingTuning(), for: worn) }
        }
        if let old = LivingShader(rawValue: before.shader), live.shader != old { live.shader = old }
        if live.scheduled != before.scheduled { live.scheduled = before.scheduled }
        if live.enabled != before.enabled { live.enabled = before.enabled }
        if let living = before.living, let hue = Hue(rawValue: living) { Effects.shared.living = hue }
    }

    /// One frame of a pack, for previews. Nil without Metal.
    static func still(_ pack: ShaderPack, width: Int, height: Int, time: Double) -> CGImage? {
        guard let shader = shader(pack), let engine = LivingEngine.shared else { return nil }
        let tuning = tuning(pack)
        return engine.snapshot(shader, width: width, height: height, hour: tuning.cycle.heldHour ?? DayLight.hourNow,
                               time: time, tuning: tuning)
    }
}

// MARK: - Layouts

@MainActor
enum LayoutPackRuntime {
    private static func layouts(_ pack: InstalledPack) -> [CustomLayout] {
        guard case .layouts(let layouts) = pack.pack else { return [] }
        return layouts.layouts
    }

    static func isAdded(_ pack: InstalledPack) -> Bool {
        let ids = Set(Tools.shared.layouts.map(\.id))
        let mine = layouts(pack)
        return !mine.isEmpty && mine.allSatisfy { ids.contains($0.id) }
    }

    /// Adds the pack's layouts to Window Engine's custom layouts, replacing earlier copies.
    static func add(_ pack: InstalledPack) {
        var list = Tools.shared.layouts
        for layout in layouts(pack) {
            if let index = list.firstIndex(where: { $0.id == layout.id }) { list[index] = layout } else { list.append(layout) }
        }
        Tools.shared.layouts = list
    }

    static func remove(_ pack: InstalledPack) {
        let ids = Set(layouts(pack).map(\.id))
        Tools.shared.layouts.removeAll { ids.contains($0.id) }
    }
}

// MARK: - Effects

extension MinimizeEffectSetting {
    static let packKey = "ownDock.minimizeEffectPack"

    /// The pack effect chosen in the picker, as pack id and effect id. Set, it is drawn in place
    /// of the built-in pick.
    static var packEffect: (pack: String, effect: String)? {
        get {
            guard let text = UserDefaults.standard.string(forKey: packKey) else { return nil }
            let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        set {
            UserDefaults.standard.set(newValue.map { $0.pack + "/" + $0.effect }, forKey: packKey)
            NotificationCenter.default.post(name: .atelierEffectPackChanged, object: nil)
        }
    }

    /// The pack effect to draw now. Nil with Reduce Motion on, or when its pack is gone.
    @MainActor static var activePack: PackMinimizeEffect? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let chosen = packEffect else { return nil }
        return effect(pack: chosen.pack, effect: chosen.effect)
    }

    @MainActor static func effect(pack: String, effect: String) -> PackMinimizeEffect? {
        guard let installed = ModPackStore.shared.pack(pack, kind: .effects), case .effects(let effects) = installed.pack else { return nil }
        return effects.effects.first { $0.id == effect }
    }
}

extension Notification.Name {
    static let atelierEffectPackChanged = Notification.Name("atelierEffectPackChanged")
}

// MARK: - Looks

/// Applies a Look: its theme first (through ThemeEngine, which keeps the setup from before), then
/// the wallpaper, the Dock settings and the packs. What the theme cannot record (packs, the
/// picture and the Dock's size and edge) is added to the same revert point, so Revert in Looks
/// puts all of it back.
@MainActor
enum LookApplier {
    static func themeID(_ pack: InstalledPack) -> String? {
        guard case .look(let look) = pack.pack else { return nil }
        return (try? ThemeEngine.load(pack.file(look.theme)))?.id
    }

    /// The parts of the Mac a Look changes beyond its theme, as they are now.
    static func snapshot() -> JSONValue {
        let store = ModPackStore.shared, dock = OwnDock.shared
        var packs: [String: JSONValue] = [
            "iconPack": store.iconPackID.map(JSONValue.string) ?? .null,
            "soundPack": store.soundPackID.map(JSONValue.string) ?? .null,
            "typingFromPack": .bool(store.typingFromPack),
            "shaderPack": store.shaderPackID.map(JSONValue.string) ?? .null,
            "dock": .object(["edge": .string(dock.edge.rawValue), "tile": .number(dock.tile), "large": .number(dock.large),
                             "magnify": .bool(dock.magnify), "autoHide": .bool(dock.autoHide)]),
        ]
        if let url = Wallpaper.url() { packs["image"] = .string(url.absoluteString) }
        return .object(packs)
    }

    /// Puts back what `snapshot()` saw. Called by ThemeEngine.revert().
    static func restore(_ value: JSONValue?) {
        guard let saved = value?.object else { return }
        let store = ModPackStore.shared, dock = OwnDock.shared
        store.iconPackID = saved["iconPack"]?.string
        store.soundPackID = saved["soundPack"]?.string
        store.typingFromPack = saved["typingFromPack"]?.bool ?? false
        store.shaderPackID = saved["shaderPack"]?.string
        if let d = saved["dock"]?.object {
            if let edge = d["edge"]?.string.flatMap(OwnDockEdge.init(rawValue:)), edge != dock.edge { dock.edge = edge }
            if let tile = d["tile"]?.number, tile != dock.tile { dock.tile = tile }
            if let large = d["large"]?.number, large != dock.large { dock.large = large }
            if let magnify = d["magnify"]?.bool, magnify != dock.magnify { dock.magnify = magnify }
            if let hide = d["autoHide"]?.bool, hide != dock.autoHide { dock.autoHide = hide }
        }
        if let image = saved["image"]?.string.flatMap(URL.init(string:)), image.isFileURL,
           FileManager.default.fileExists(atPath: image.path), Wallpaper.url() != image {
            ThemeWallpaper.set(image)
        }
    }

    static func apply(_ installed: InstalledPack) {
        guard case .look(let look) = installed.pack else { return }
        let store = ModPackStore.shared, engine = ThemeEngine.shared
        let theme: InstalledTheme
        do { theme = try ThemeEngine.load(installed.file(look.theme)) } catch {
            store.problem = "The Look’s theme could not be read: \(error.localizedDescription)"
            return
        }
        engine.keepRevertPoint(extra: snapshot())
        engine.apply(theme)

        if let path = look.wallpaperImage {
            let live = LiveWallpaper.shared
            if live.enabled { live.enabled = false }
            if Effects.shared.living != nil { Effects.shared.living = nil }
            ThemeWallpaper.set(installed.file(path))
            if let error = ThemeWallpaper.lastError { store.problem = error }
        } else if let shader = look.wallpaperShader, let pack = resolve(shader, kind: .shader, in: installed), case .shader(let s) = pack.pack {
            ShaderPackRuntime.wear(s)
            store.shaderPackID = pack.id
        }

        let dock = OwnDock.shared
        if let edge = look.dock.edge.flatMap(OwnDockEdge.init(rawValue:)), edge != dock.edge { dock.edge = edge }
        if let tile = look.dock.tileSize, tile != dock.tile { dock.tile = tile }
        if let large = look.dock.magnifiedSize, large != dock.large { dock.large = large }
        if let magnify = look.dock.magnification, magnify != dock.magnify { dock.magnify = magnify }
        if let hide = look.dock.autohide, hide != dock.autoHide { dock.autoHide = hide }

        if let ref = look.iconPack {
            if let pack = resolve(ref, kind: .icons, in: installed) { store.iconPackID = pack.id }
            else { store.problem = "The Look’s icon pack is not installed." }
        }
        if let ref = look.soundPack {
            if let pack = resolve(ref, kind: .sounds, in: installed) { store.soundPackID = pack.id }
            else { store.problem = "The Look’s sound pack is not installed." }
        }
        store.notice = "Wearing \(installed.name). Revert in Looks puts everything back."
    }

    /// A pack a Look names: installed by id, or inside the Look (installed from there first).
    static func resolve(_ ref: PackReference, kind: ModPackKind, in look: InstalledPack) -> InstalledPack? {
        let store = ModPackStore.shared
        switch ref {
        case .installed(let id): return store.pack(id, kind: kind)
        case .embedded(let path):
            // Installed once; wearing the Look again uses the copy already there.
            guard case .success(let (pack, _)) = ModPackDisk.load(look.file(path), kind: kind) else { return nil }
            if let have = store.pack(pack.header.id, kind: kind), have.pack.header.version == pack.header.version { return have }
            return try? store.install(from: look.file(path), expecting: kind)
        }
    }
}
