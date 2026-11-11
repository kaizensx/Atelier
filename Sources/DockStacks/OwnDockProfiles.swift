import AppKit
import Carbon.HIToolbox
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profiles

/// Everything a dock profile puts back: what is on the bar and how it looks.
struct OwnDockSetup: Codable, Equatable, Sendable {
    var items: [OwnDockItem]
    var appearance: DockAppearance
    var edge: OwnDockEdge
    var tile: Double
    var large: Double
    var magnify: Bool
    var autoHide: Bool
    var showRunning: Bool
    var showVitals: Bool
    /// Missing in profiles saved before sections and tile options existed.
    var sections: [DockSection]?
    var options: [String: DockTileOptions]?
    var smart: [String: DockSmartStack]?
    /// Missing in profiles saved before designs existed.
    var design: DockDesignPrefs?
}

struct OwnDockProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var setup: OwnDockSetup
    var saved = Date()
}

/// The current Space, as SkyLight names it. Read only, a fraction of a millisecond.
enum SpaceProbe {
    struct Current: Equatable {
        /// `ManagedSpaceID`, stable for the life of the Space.
        var key: String
        var label: String
    }

    nonisolated(unsafe) private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private typealias Connection = @convention(c) () -> Int32
    /// A Copy function hands back an owned array, or NULL; taken as such, it is neither leaked
    /// nor dereferenced when the window server has nothing to say.
    private typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// Never asks dlsym with a NULL handle: that is not the default search on every release.
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let library else { return nil }
        return dlsym(library, name)
    }

    static var available: Bool { symbol("SLSCopyManagedDisplaySpaces") != nil }

    @MainActor static func current(on screen: NSScreen?) -> Current? {
        guard let connection = symbol("SLSMainConnectionID"),
              let copy = symbol("SLSCopyManagedDisplaySpaces") else { return nil }
        let id = unsafeBitCast(connection, to: Connection.self)()
        guard let array = unsafeBitCast(copy, to: Copy.self)(id)?.takeRetainedValue(),
              let displays = array as? [[String: Any]], !displays.isEmpty else { return nil }
        let uuid = screen.flatMap(Self.uuid(of:))
        let display = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays[0]
        guard let current = display["Current Space"] as? [String: Any],
              let spaceID = (current["ManagedSpaceID"] as? NSNumber)?.intValue else { return nil }
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let desktops = spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }
        let label: String
        if let index = desktops.firstIndex(where: { ($0["ManagedSpaceID"] as? NSNumber)?.intValue == spaceID }) {
            label = "Desktop \(index + 1)"
        } else {
            label = "Full Screen Space"
        }
        return Current(key: String(spaceID), label: label)
    }

    @MainActor private static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

/// Saved docks, and the rules that switch between them.
@MainActor
final class OwnDockProfiles: ObservableObject {
    static let shared = OwnDockProfiles()

    struct Rules: Codable, Equatable {
        var bySpace = false
        /// Space key to profile.
        var spaces: [String: UUID] = [:]
        /// Space key to the label it had when it was assigned.
        var spaceLabels: [String: String] = [:]
        var byTime = false
        var day: UUID?
        var night: UUID?
        var dayStarts = 7
        var nightStarts = 20
    }

    @Published private(set) var profiles: [OwnDockProfile] = []
    @Published var rules = Rules() { didSet { if rules != oldValue { save(); evaluate(force: true) } } }
    @Published private(set) var active: UUID?
    @Published private(set) var space: SpaceProbe.Current?

    private var timer: Timer?
    private var lastTimeChoice: UUID?
    private var started = false
    private var file: URL { Support.root.appendingPathComponent("dock-profiles.json") }

    private struct Stored: Codable {
        var profiles: [OwnDockProfile]
        var rules: Rules
        var active: UUID?
    }

    private init() {
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        profiles = stored.profiles
        rules = stored.rules
        active = stored.active
    }

    private func save() {
        let stored = Stored(profiles: profiles, rules: rules, active: active)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: Support.root, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OwnDockProfiles.shared.evaluate(force: false) }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { OwnDockProfiles.shared.evaluate(force: false) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate(force: false)
    }

    // MARK: Editing

    @discardableResult func saveCurrent(named name: String) -> OwnDockProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = OwnDockProfile(name: trimmed.isEmpty ? "Dock \(profiles.count + 1)" : trimmed, setup: OwnDock.shared.setup)
        profiles.append(profile)
        active = profile.id
        save()
        return profile
    }

    /// Writes what the dock has now into an existing profile.
    func update(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].setup = OwnDock.shared.setup
        profiles[index].saved = Date()
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        profiles[index].name = name
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        var rules = rules
        rules.spaces = rules.spaces.filter { $0.value != id }
        if rules.day == id { rules.day = nil }
        if rules.night == id { rules.night = nil }
        if active == id { active = nil }
        self.rules = rules
        save()
    }

    func apply(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        active = id
        save()
        OwnDock.shared.apply(profile.setup)
    }

    /// For the Profile 1, 2 and 3 shortcuts.
    func apply(index: Int) {
        guard profiles.indices.contains(index) else { NSSound.beep(); return }
        apply(profiles[index].id)
    }

    /// For the Next Profile shortcut: the one after the active one, round again at the end.
    func applyNext() {
        guard !profiles.isEmpty else { NSSound.beep(); return }
        let index = profiles.firstIndex { $0.id == active }.map { ($0 + 1) % profiles.count } ?? 0
        apply(profiles[index].id)
    }

    /// A profile's theme: its style and colour. The dock follows at once if it is the active one.
    func setLook(_ id: UUID, style: DockStyle? = nil, accent: DockAccent? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let style { profiles[index].setup.appearance.style = style }
        if let accent { profiles[index].setup.appearance.accent = accent }
        save()
        if active == id {
            var look = OwnDock.shared.appearance
            if let style { look.style = style }
            if let accent { look.accent = accent }
            OwnDock.shared.appearance = look
        }
    }

    /// A profile's design. The dock follows at once if it is the active one.
    func setDesign(_ id: UUID, _ design: DockDesign) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var prefs = profiles[index].setup.design ?? DockDesignPrefs()
        prefs.design = design
        profiles[index].setup.design = prefs
        save()
        if active == id { OwnDock.shared.selectDesign(design) }
    }

    /// Ties a profile to the Space in front now, or unties it.
    func assignCurrentSpace(_ id: UUID?) {
        guard let space = SpaceProbe.current(on: OwnDock.shared.currentScreen) else { return }
        var rules = rules
        rules.spaces[space.key] = id
        rules.spaceLabels[space.key] = id == nil ? nil : space.label
        rules.bySpace = rules.bySpace || id != nil
        self.rules = rules
    }

    func spaces(for id: UUID) -> [String] {
        rules.spaces.filter { $0.value == id }.keys.compactMap { rules.spaceLabels[$0] }.sorted()
    }

    // MARK: Switching

    /// Picks the profile the rules ask for. A Space rule wins over the time of day. The time
    /// rule only acts when the period changes, so a profile picked by hand stays until then.
    func evaluate(force: Bool) {
        guard OwnDock.shared.enabled else { return }
        if SpaceProbe.available {
            let now = SpaceProbe.current(on: OwnDock.shared.currentScreen)
            if now != space { space = now }
        }
        if rules.bySpace, let key = space?.key, let id = rules.spaces[key], profiles.contains(where: { $0.id == id }) {
            if id != active { apply(id) }
            return
        }
        guard rules.byTime else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let day = rules.dayStarts <= rules.nightStarts
            ? hour >= rules.dayStarts && hour < rules.nightStarts
            : hour >= rules.dayStarts || hour < rules.nightStarts
        guard let wanted = day ? rules.day : rules.night, profiles.contains(where: { $0.id == wanted }) else { return }
        if (force || wanted != lastTimeChoice), wanted != active { apply(wanted) }
        lastTimeChoice = wanted
    }
}

// MARK: - Custom icons and names

/// A name or a picture the user gave one tile.
struct DockCustom: Codable, Equatable, Sendable {
    var label: String?
    /// A file in `DockCustomStore.folder`.
    var icon: String?
}

@MainActor
enum DockCustomStore {
    static var folder: URL { Support.root.appendingPathComponent("DockIcons", isDirectory: true) }

    static func iconPath(_ custom: DockCustom?) -> String? {
        custom?.icon.map { folder.appendingPathComponent($0).path }
    }

    /// Asks for a picture, copies it into Application Support, and returns its file name.
    static func pickIcon(for title: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns, .applicationBundle]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for \(title). An app or a folder lends its own icon."
        panel.prompt = "Use Picture"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let image: NSImage?
        if url.pathExtension == "app" || url.hasDirectoryPath {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(contentsOf: url)
        }
        guard let image else { return nil }
        return store(image)
    }

    /// Copies a picture into Application Support as a 512 point PNG and returns its file name.
    static func store(_ image: NSImage) -> String? {
        guard let png = render(image) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        return name
    }

    /// A 512 point square PNG, so any picture draws as fast as an app icon.
    private static func render(_ image: NSImage) -> Data? {
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = image.size
        let scale = min(Double(side) / max(size.width, 1), Double(side) / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: NSRect(x: (Double(side) - drawn.width) / 2, y: (Double(side) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func remove(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// Asks for a new name. Empty puts back the file's own name.
    static func askName(current: String, original: String) -> String?? {
        let alert = NSAlert()
        alert.messageText = "Rename \(original)"
        alert.informativeText = "The new name shows in the dock only. Leave it empty to use the original name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = original
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return .none }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(text.isEmpty || text == original ? nil : text)
    }

    static func askSectionName(current: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = current.isEmpty ? "New Section" : "Rename Section"
        alert.informativeText = "A section keeps tiles together, like Work, Design or Media."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: current.isEmpty ? "Add" : "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func askProfileName(suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save This Dock"
        alert.informativeText = "Saves what is in the dock and how it looks, to switch back to later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = suggested
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

// MARK: - Keyboard

struct DockShortcut: Equatable, Sendable {
    let key: UInt32
    let modifiers: UInt32
    let label: String

    static let all = [
        DockShortcut(key: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥ D"),
        DockShortcut(key: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧ D"),
        DockShortcut(key: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧ D"),
        DockShortcut(key: UInt32(kVK_F5), modifiers: UInt32(controlKey), label: "⌃ F5"),
    ]
}
