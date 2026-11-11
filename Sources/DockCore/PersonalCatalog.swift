import CoreFoundation
import Foundation

// MARK: - Values

/// A preference value in one of the four plain types `defaults` understands.
public enum PersonalValue: Sendable, Equatable, Hashable, Codable {
    case bool(Bool), int(Int), float(Double), string(String)

    public var plist: CFPropertyList {
        switch self {
        case let .bool(value): (value ? kCFBooleanTrue : kCFBooleanFalse)!
        case let .int(value): value as NSNumber
        case let .float(value): value as NSNumber
        case let .string(value): value as CFString
        }
    }

    /// Reads a stored value back in the kind the setting expects, so `1` and `true` compare equal.
    public init?(_ raw: CFPropertyList?, as kind: PersonalKind) {
        guard let raw else { return nil }
        switch (kind, raw) {
        case let (.bool, number as NSNumber): self = .bool(number.boolValue)
        case let (.bool, text as String): self = .bool(["1", "true", "yes"].contains(text.lowercased()))
        case let (.int, number as NSNumber): self = .int(number.intValue)
        case let (.int, text as String): guard let value = Int(text) else { return nil }; self = .int(value)
        case let (.float, number as NSNumber): self = .float(number.doubleValue)
        case let (.float, text as String): guard let value = Double(text) else { return nil }; self = .float(value)
        case let (.string, text as String): self = .string(text)
        case let (.string, number as NSNumber): self = .string(number.stringValue)
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case let .bool(value): value ? "On" : "Off"
        case let .int(value): String(value)
        case let .float(value): value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        case let .string(value): value.isEmpty ? "Empty" : value
        }
    }

    public var number: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .float(value): value
        default: nil
        }
    }
}

public enum PersonalKind: String, Sendable, Codable { case bool, int, float, string }

// MARK: - Settings

/// The chapters the new settings live in. Raw values match the `Chapter` cases they map to.
public enum PersonalArea: String, Sendable, CaseIterable, Codable {
    case finder, folders, input, sounds, animations, apps, capture, windows, corners
    case controlCenter, spotlight, missionControl, lockScreen, accessibility, appKit, quickLook
}

/// When a change shows up. Shown under every control so nobody waits for nothing.
public enum PersonalEffect: Sendable, Equatable {
    case immediate
    /// Atelier restarts this process for you.
    case restart(String)
    /// An app of the user's that reads it at launch. Atelier offers a Relaunch button
    /// while it is open, and never quits it on its own.
    case relaunch(String)
    /// Apps read it when they open.
    case relaunchApps
    /// Only a new login session reads it.
    case logout
    /// The next screenshot or recording reads it.
    case nextUse

    public var label: String {
        switch self {
        case .immediate: "Takes effect at once"
        case let .restart(process): "Restarts \(process)"
        case let .relaunch(app): "Read when \(app) opens"
        case .relaunchApps: "Apps pick it up when reopened"
        case .logout: "Needs you to log out and back in"
        case .nextUse: "Used from the next capture"
        }
    }

    /// The app a Relaunch button should offer, if any.
    public var relaunchTarget: String? {
        switch self {
        case let .relaunch(app): app
        case let .restart(process) where !["Finder", "Dock", "SystemUIServer", "ControlCenter"].contains(process): process
        default: nil
        }
    }
}

/// Where a setting's preference file lives, and whether macOS guards it.
public enum PersonalStorage: Sendable, Equatable, Hashable {
    /// ~/Library/Preferences, open to any unsandboxed app.
    case standard
    /// A sandboxed app's own container (~/Library/Containers/<bundle id>). macOS only lets
    /// another app in with Full Disk Access.
    case container(String)
    /// ~/Library/Preferences, but the file is guarded by privacy protection (Messages, Contacts).
    case guarded

    public var needsFullDiskAccess: Bool { self != .standard }
}

public struct PersonalOption: Sendable, Equatable, Hashable {
    public let value: PersonalValue
    public let label: String
    public init(_ value: PersonalValue, _ label: String) { self.value = value; self.label = label }
}

public enum PersonalControl: Sendable, Equatable {
    case toggle(on: PersonalValue, off: PersonalValue)
    case choice([PersonalOption])
    case number(ClosedRange<Double>, step: Double, unit: String)
    case text(placeholder: String)
    case folder
    /// The alert sounds in /System/Library/Sounds.
    case sound
}

/// One preference Atelier can change and put back.
public struct PersonalSetting: Sendable, Identifiable, Equatable {
    public let area: PersonalArea
    public let section: String
    public let domain: String
    public let key: String
    public let kind: PersonalKind
    public let currentHost: Bool
    public let control: PersonalControl
    public let title: String
    public let detail: String
    public let effect: PersonalEffect
    /// What macOS uses when the key is absent, if known.
    public let fallback: PersonalValue?
    /// Where the key was found. Shown in the help tag.
    public let evidence: String
    /// What the hover preview should show. Wired by the stage after merge.
    public let preview: String
    /// Other domains that hold the same key (built-in and Bluetooth trackpads).
    public let mirrors: [String]
    /// A sentence of warning when the write can be refused or has side effects.
    public let caution: String?
    /// Where the preference file lives. `.standard` for everything written before the app catalogue.
    public let storage: PersonalStorage
    /// Found in the app's code but not in its settings. Shown with a warning.
    public let experimental: Bool

    public var id: String { domain + (currentHost ? "@host" : "") + "." + key }

    public init(_ area: PersonalArea, _ section: String, domain: String, key: String, kind: PersonalKind,
                currentHost: Bool = false, control: PersonalControl, title: String, detail: String,
                effect: PersonalEffect, fallback: PersonalValue? = nil, evidence: String, preview: String,
                mirrors: [String] = [], caution: String? = nil, storage: PersonalStorage = .standard,
                experimental: Bool = false) {
        self.area = area; self.section = section; self.domain = domain; self.key = key; self.kind = kind
        self.currentHost = currentHost; self.control = control; self.title = title; self.detail = detail
        self.effect = effect; self.fallback = fallback; self.evidence = evidence; self.preview = preview
        self.mirrors = mirrors; self.caution = caution; self.storage = storage; self.experimental = experimental
    }
}

// MARK: - Reading and writing

/// Any preference domain, through cfprefsd. Atelier is not sandboxed, so this reaches the
/// same store `defaults` does. A protected domain refuses the write, and that is reported.
public struct PersonalPrefs: Sendable {
    /// The folder that holds sandboxed apps' containers. Tests pass a scratch folder.
    public let containers: String

    public init(containers: String = NSHomeDirectory() + "/Library/Containers") { self.containers = containers }

    /// The Preferences folder a container keeps its plists in.
    public func preferencesFolder(container bundleID: String) -> String {
        containers + "/" + bundleID + "/Data/Library/Preferences"
    }

    /// The name cfprefsd knows the setting's file by. A container plist is addressed by its
    /// full path, the same way `defaults` does it.
    public func storeDomain(_ setting: PersonalSetting) -> String { storeDomain(setting.domain, storage: setting.storage) }

    public func storeDomain(_ domain: String, storage: PersonalStorage) -> String {
        if case let .container(bundleID) = storage { return preferencesFolder(container: bundleID) + "/" + domain }
        return domain
    }

    /// Why Atelier cannot reach a setting's file right now, or nil when it can. Checked with
    /// access(2), which honours privacy protection without opening anything. Without Full Disk
    /// Access a guarded file reads as absent and a write is refused, so nothing is attempted.
    public func blocker(_ setting: PersonalSetting) -> String? {
        let fileManager = FileManager.default
        switch setting.storage {
        case .standard: return nil
        case let .container(bundleID):
            let folder = preferencesFolder(container: bundleID)
            // A container is macOS's to create. Writing into a missing one would make a folder
            // the app's sandbox does not own.
            guard fileManager.fileExists(atPath: (containers as NSString).appendingPathComponent(bundleID)) else {
                return "Open \(setting.section) once first, so macOS creates its settings."
            }
            if !fileManager.fileExists(atPath: folder) {
                return fileManager.isReadableFile(atPath: (folder as NSString).deletingLastPathComponent)
                    ? nil : Self.privateNotice(setting)
            }
            return fileManager.isReadableFile(atPath: folder) ? nil : Self.privateNotice(setting)
        case .guarded:
            let file = NSHomeDirectory() + "/Library/Preferences/" + setting.domain + ".plist"
            return !fileManager.fileExists(atPath: file) || fileManager.isReadableFile(atPath: file) ? nil : Self.privateNotice(setting)
        }
    }

    public func isReachable(_ setting: PersonalSetting) -> Bool { blocker(setting) == nil }

    /// Domains in ~/Library/Preferences that any app may read but, from macOS 13, only an app
    /// with Full Disk Access may change.
    public static let writeGuardedDomains: Set<String> = ["com.apple.universalaccess"]

    /// Why a change would be refused, or nil. Adds the write-only guard to `blocker`: the file
    /// reads fine, so rows keep showing the real value, but cfprefsd refuses the write.
    public func writeBlocker(_ setting: PersonalSetting) -> String? {
        if let reason = blocker(setting) { return reason }
        guard setting.storage == .standard, Self.writeGuardedDomains.contains(setting.domain) else { return nil }
        let file = (preferencesRoot as NSString).appendingPathComponent(setting.domain + ".plist")
        return PersonalWriteGate.isWritable(file) ? nil : Self.writeNotice
    }

    public static let writeNotice = "Needs Full Disk Access. macOS lets Atelier read these settings but not change them."

    /// ~/Library/Preferences. Tests point `containers` elsewhere; this stays the real one.
    var preferencesRoot: String { NSHomeDirectory() + "/Library/Preferences" }

    private static func privateNotice(_ setting: PersonalSetting) -> String {
        "macOS keeps \(setting.section)'s settings private. Give Atelier Full Disk Access to change them."
    }

    private static func application(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
    }

    private static func host(_ current: Bool) -> CFString { current ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }

    public func raw(_ key: String, domain: String, currentHost: Bool = false) -> CFPropertyList? {
        let app = Self.application(domain), host = Self.host(currentHost)
        // Synchronising asks cfprefsd over IPC. A chapter reads dozens of keys from one domain in
        // one frame, so each domain is synchronised at most once a second; writes force it.
        if PersonalSyncGate.shouldSync("\(domain)|\(currentHost)") {
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, host)
        }
        return CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, host)
    }

    public func read(_ setting: PersonalSetting) -> PersonalValue? {
        guard isReachable(setting) else { return nil }
        if let value = stored(setting) { return value }
        // A menu bar module nobody chose for yet: AppKit's visibility flag says what shows now.
        if Self.isMenuModule(setting), let visible = PersonalValue(raw(Self.visibleKey(setting), domain: setting.domain), as: .bool) {
            return .int(visible == .bool(true) ? 18 : 8)
        }
        return nil
    }

    /// The value stored under the key itself, without `read`'s menu bar fallback.
    public func stored(_ setting: PersonalSetting) -> PersonalValue? {
        guard isReachable(setting) else { return nil }
        return PersonalValue(raw(setting.key, domain: storeDomain(setting), currentHost: setting.currentHost), as: setting.kind)
    }

    static func isMenuModule(_ setting: PersonalSetting) -> Bool {
        setting.domain == "com.apple.controlcenter" && setting.currentHost && setting.kind == .int && setting.section == "Menu Bar Items"
    }

    static func visibleKey(_ setting: PersonalSetting) -> String { "NSStatusItem VisibleCC " + setting.key }

    /// Writes, or removes with `nil`. Throws when cfprefsd does not accept it.
    public func set(_ raw: CFPropertyList?, key: String, domain: String, currentHost: Bool = false) throws {
        let app = Self.application(domain), host = Self.host(currentHost)
        PersonalSyncGate.invalidate("\(domain)|\(currentHost)")
        CFPreferencesSetValue(key as CFString, raw, app, kCFPreferencesCurrentUser, host)
        guard CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, host) else {
            throw DockFailure("macOS refused to change \(key) in \(domain).")
        }
    }

    public func write(_ value: PersonalValue?, for setting: PersonalSetting) throws {
        if let reason = writeBlocker(setting) { throw DockFailure(reason) }
        for domain in [setting.domain] + setting.mirrors {
            try set(value?.plist, key: setting.key, domain: storeDomain(domain, storage: setting.storage),
                    currentHost: setting.currentHost)
        }
        // Keep AppKit's flag in step, or ControlCenter restores the old visibility from it.
        if Self.isMenuModule(setting), let value, value == .int(18) || value == .int(8) {
            try set((value == .int(18) ? kCFBooleanTrue : kCFBooleanFalse)!, key: Self.visibleKey(setting), domain: setting.domain)
        }
    }
}

/// Remembers what each setting held before Atelier first touched it, so Revert is exact,
/// including "there was no value at all".
public struct PersonalLedger: Sendable {
    private struct Entry: Codable { var original: PersonalValue? }
    private let suite: String?
    private let storeKey = "personal.originals"

    /// `suite` nil is Atelier's own defaults. Tests pass a scratch suite.
    public init(suite: String? = nil) { self.suite = suite }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: storeKey)
    }

    public func isTracked(_ id: String) -> Bool { load()[id] != nil }

    /// The value before Atelier's first change. `.some(nil)` means the key was absent.
    public func original(_ id: String) -> PersonalValue?? { load()[id].map { $0.original } }

    /// Keeps only the first original: changing a setting twice must not forget the real one.
    public func remember(_ id: String, original: PersonalValue?) {
        var entries = load()
        guard entries[id] == nil else { return }
        entries[id] = Entry(original: original)
        save(entries)
    }

    public func forget(_ id: String) {
        var entries = load()
        entries[id] = nil
        save(entries)
    }

    public var trackedIDs: [String] { load().keys.sorted() }

    /// After `plist` replaced the whole of `domain` outside the rows (a Dock scene or Timeline
    /// restore), forgets each tracked setting that is back at its original, absent included.
    /// One left at another value stays tracked, so Revert still puts the original back.
    /// Returns the ids forgotten.
    @discardableResult
    public func reconcile(domain: String, with plist: [String: Any],
                          settings: [PersonalSetting] = PersonalCatalog.all) -> [String] {
        var entries = load()
        var forgotten: [String] = []
        for setting in settings where setting.domain == domain && !setting.currentHost && setting.storage == .standard {
            guard let entry = entries[setting.id] else { continue }
            let now = PersonalValue(plist[setting.key] as CFPropertyList?, as: setting.kind)
            if now == entry.original {
                entries[setting.id] = nil
                forgotten.append(setting.id)
            }
        }
        if !forgotten.isEmpty { save(entries) }
        return forgotten
    }
}

/// Change and revert, against any `PersonalPrefs` store. The app and the tests share it.
public struct PersonalEngine: Sendable {
    public let prefs: PersonalPrefs
    public let ledger: PersonalLedger

    public init(prefs: PersonalPrefs = PersonalPrefs(), ledger: PersonalLedger = PersonalLedger()) {
        self.prefs = prefs; self.ledger = ledger
    }

    /// Writes `value`, or removes the key with nil, remembering the original first.
    public func apply(_ value: PersonalValue?, to setting: PersonalSetting) throws {
        let fresh = !ledger.isTracked(setting.id)
        // What is stored, not what `read` shows: a menu bar module with no key of its own reads
        // as AppKit's visibility flag, and Revert must delete the key again, not write that.
        let original = prefs.stored(setting)
        ledger.remember(setting.id, original: original)
        let visibleID = Self.visibleID(setting)
        if fresh, PersonalPrefs.isMenuModule(setting) {
            ledger.remember(visibleID, original: PersonalValue(prefs.raw(PersonalPrefs.visibleKey(setting), domain: setting.domain), as: .bool))
        }
        do { try prefs.write(value, for: setting) } catch {
            // A refused write leaves nothing to revert.
            if fresh { try? prefs.write(original, for: setting); ledger.forget(setting.id); ledger.forget(visibleID) }
            throw error
        }
    }

    /// Puts back the original. A key that was absent is removed again.
    public func revert(_ setting: PersonalSetting) throws {
        guard let original = ledger.original(setting.id) else { return }
        try prefs.write(original, for: setting)
        let visibleID = Self.visibleID(setting)
        if let visible = ledger.original(visibleID) {
            try prefs.set(visible?.plist, key: PersonalPrefs.visibleKey(setting), domain: setting.domain)
            ledger.forget(visibleID)
        }
        ledger.forget(setting.id)
    }

    /// The ledger entry for a menu bar module's AppKit visibility flag, which a write also changes.
    static func visibleID(_ setting: PersonalSetting) -> String { setting.id + "|visible" }
}

// MARK: - Catalogue

/// Every key here was found as a literal in the binary that reads it, with REA, or in the
/// dyld shared cache when the reader lives there. `evidence` says which.
public enum PersonalCatalog {
    private static let finderProc = PersonalEffect.restart("Finder")
    private static let dockProc = PersonalEffect.restart("Dock")
    private static let reaFinder = "REA: Finder binary string"
    private static let reaDock = "REA: Dock binary string"
    private static let cache = "dyld shared cache string"

    private static func onOff(_ on: Bool = true) -> PersonalControl { .toggle(on: .bool(on), off: .bool(!on)) }

    private static func finder(_ section: String, _ key: String, _ title: String, _ detail: String, preview: String,
                               on: Bool = true, fallback: Bool? = nil) -> PersonalSetting {
        PersonalSetting(.finder, section, domain: "com.apple.finder", key: key, kind: .bool, control: onOff(on),
                        title: title, detail: detail, effect: finderProc, fallback: fallback.map(PersonalValue.bool),
                        evidence: reaFinder, preview: preview)
    }

    private static func global(_ area: PersonalArea, _ section: String, _ key: String, kind: PersonalKind = .bool,
                               control: PersonalControl? = nil, _ title: String, _ detail: String,
                               effect: PersonalEffect = .relaunchApps, fallback: PersonalValue? = nil,
                               evidence: String = cache, preview: String, caution: String? = nil) -> PersonalSetting {
        PersonalSetting(area, section, domain: "NSGlobalDomain", key: key, kind: kind, control: control ?? onOff(),
                        title: title, detail: detail, effect: effect, fallback: fallback, evidence: evidence,
                        preview: preview, caution: caution)
    }

    private static func dock(_ area: PersonalArea, _ section: String, _ key: String, kind: PersonalKind = .bool,
                             control: PersonalControl? = nil, _ title: String, _ detail: String,
                             fallback: PersonalValue? = nil, preview: String) -> PersonalSetting {
        PersonalSetting(area, section, domain: "com.apple.dock", key: key, kind: kind, control: control ?? onOff(),
                        title: title, detail: detail, effect: dockProc, fallback: fallback, evidence: reaDock, preview: preview)
    }

    private static let trackpad = "com.apple.AppleMultitouchTrackpad"
    private static let bluetoothTrackpad = ["com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    private static func pad(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                            _ title: String, _ detail: String, fallback: PersonalValue?, preview: String) -> PersonalSetting {
        PersonalSetting(.input, "Trackpad", domain: trackpad, key: key, kind: kind, control: control ?? onOff(),
                        title: title, detail: detail, effect: .logout, fallback: fallback, evidence: cache,
                        preview: preview, mirrors: bluetoothTrackpad,
                        caution: "The trackpad driver reads this at login. System Settings may show the old value until then.")
    }

    public static let all: [PersonalSetting] = finderSettings + finderExtraSettings + inputSettings + soundSettings
        + animationSettings + appSettings + appCatalogue + captureSettings + windowSettings + cornerSettings + systemSettings

    // Finder: window defaults, view options, sidebar, desktop.
    static let finderSettings: [PersonalSetting] = [
        PersonalSetting(.finder, "New Windows", domain: "com.apple.finder", key: "NewWindowTarget", kind: .string,
                        control: .choice([.init(.string("PfHm"), "Home"), .init(.string("PfDe"), "Desktop"),
                                          .init(.string("PfDo"), "Documents"), .init(.string("PfAF"), "Recents"),
                                          .init(.string("PfCm"), "Computer"), .init(.string("PfID"), "iCloud Drive")]),
                        title: "New Window Opens", detail: "Where ⌘N lands.", effect: finderProc,
                        evidence: reaFinder + " NewWindowTarget; PfAF read from this Mac's defaults",
                        preview: "A new Finder window opening on the chosen folder"),
        PersonalSetting(.finder, "New Windows", domain: "com.apple.finder", key: "FXPreferredViewStyle", kind: .string,
                        control: .choice([.init(.string("icnv"), "Icons"), .init(.string("Nlsv"), "List"),
                                          .init(.string("clmv"), "Columns"), .init(.string("glyv"), "Gallery")]),
                        title: "Default View", detail: "For folders that have no view of their own yet.", effect: finderProc,
                        evidence: reaFinder + " FXPreferredViewStyle; Nlsv read from this Mac",
                        preview: "A Finder window switching between icon, list, column and gallery view"),
        PersonalSetting(.finder, "New Windows", domain: "com.apple.finder", key: "FXDefaultSearchScope", kind: .string,
                        control: .choice([.init(.string("SCev"), "This Mac"), .init(.string("SCcf"), "Current Folder"),
                                          .init(.string("SCsp"), "Previous Scope")]),
                        title: "Search In", detail: "Where a Finder search starts looking.", effect: finderProc,
                        fallback: .string("SCev"), evidence: reaFinder + " FXDefaultSearchScope",
                        preview: "The Finder search bar with its scope chip highlighted"),
        finder("New Windows", "FinderSpawnTab", "Open Folders in Tabs", "⌘-double-click opens a tab instead of a window.",
               preview: "A folder opening as a new tab in the same window", fallback: true),
        finder("Window Chrome", "ShowSidebar", "Sidebar", "Show the sidebar in new windows.",
               preview: "A Finder window with and without its sidebar", fallback: true),
        finder("Window Chrome", "ShowTabView", "Always Show Tab Bar", "The tab bar stays even with one tab.",
               preview: "A Finder window with a single-tab bar"),
        finder("Window Chrome", "PathBarRootAtHome", "Path Bar Starts at Home", "The path bar begins at your home folder, not the disk.",
               preview: "The path bar shortening to start at the house icon"),
        PersonalSetting(.finder, "Window Chrome", domain: "com.apple.finder", key: "SidebarWidth", kind: .int,
                        control: .number(130...360, step: 10, unit: "pt"), title: "Sidebar Width",
                        detail: "Width of the sidebar in new windows.", effect: finderProc, evidence: reaFinder + " SidebarWidth",
                        preview: "The sidebar growing and shrinking"),
        global(.finder, "Window Chrome", "NSTableViewDefaultSizeMode", kind: .int,
               control: .choice([.init(.int(1), "Small"), .init(.int(2), "Medium"), .init(.int(3), "Large")]),
               "Sidebar Icon Size", "Row size in Finder and every app's sidebar.", fallback: .int(2),
               preview: "Sidebar rows at three sizes"),
        finder("Files", "_FXEnableColumnAutoSizing", "Auto-size Columns", "Column view widens to fit long names.",
               preview: "Column view columns stretching to fit names"),
        global(.finder, "Files", "AppleShowAllExtensions", "Show All Extensions", "Every file name shows its extension.",
               effect: finderProc, evidence: reaFinder + " AppleShowAllExtensions (read from the global domain)",
               preview: "File names gaining .pdf, .png and .txt"),
        finder("Files", "FXEnableRemoveFromICloudDriveWarning", "iCloud Removal Warning",
               "Ask before moving a file out of iCloud Drive.", preview: "The iCloud warning sheet", fallback: true),
        finder("Trash", "WarnOnEmptyTrash", "Confirm Empty Trash", "Ask before emptying the Trash.",
               preview: "The Empty Trash confirmation", fallback: true),
        finder("Trash", "FXRemoveOldTrashItems", "Empty Trash After 30 Days", "Items in the Trash go after a month.",
               preview: "A calendar page tearing off over the Trash"),
        finder("Desktop", "ShowHardDrivesOnDesktop", "Internal Disks on Desktop", "Show this Mac's disks on the desktop.",
               preview: "A disk icon appearing in the desktop's top right"),
        finder("Desktop", "ShowExternalHardDrivesOnDesktop", "External Disks on Desktop", "Show plugged-in disks.",
               preview: "An external disk icon on the desktop", fallback: true),
        finder("Desktop", "ShowRemovableMediaOnDesktop", "Removable Media on Desktop", "Cards and discs.",
               preview: "An SD card icon on the desktop", fallback: true),
        finder("Desktop", "ShowMountedServersOnDesktop", "Servers on Desktop", "Connected network shares.",
               preview: "A server icon on the desktop"),
    ]

    // Cursor & Input: pointer, keyboard, trackpad, text.
    static let inputSettings: [PersonalSetting] = [
        PersonalSetting(.input, "Pointer", domain: "com.apple.universalaccess", key: "mouseDriverCursorSize", kind: .float,
                        control: .number(1...4, step: 0.25, unit: "×"), title: "Pointer Size",
                        detail: "The same setting as Accessibility › Display › Pointer size.", effect: .logout,
                        fallback: .float(1), evidence: cache + " mouseDriverCursorSize; com.apple.universalaccess readable here",
                        preview: "The arrow pointer growing on the stage",
                        caution: "macOS protects this domain. If the write is refused, use the button to open Accessibility settings."),
        global(.input, "Pointer", "com.apple.mouse.scaling", kind: .float, control: .number(0...3, step: 0.125, unit: ""),
               "Mouse Speed", "Tracking speed for a mouse, beyond the slider's notches.", effect: .logout,
               preview: "A pointer trail at the chosen speed"),
        global(.input, "Pointer", "com.apple.springing.enabled", "Spring-loaded Folders",
               "Hovering a drag over a folder opens it.", effect: .relaunchApps, fallback: .bool(true),
               preview: "A dragged file opening a folder by hovering"),
        global(.input, "Pointer", "com.apple.springing.delay", kind: .float, control: .number(0...2, step: 0.1, unit: "s"),
               "Spring-loading Delay", "How long the hover waits.", fallback: .float(0.5),
               preview: "A folder springing open after the delay"),
        global(.input, "Keyboard", "KeyRepeat", kind: .int,
               control: .choice([.init(.int(1), "Extreme"), .init(.int(2), "Fastest"), .init(.int(6), "Fast"),
                                 .init(.int(30), "Slow"), .init(.int(120), "Very Slow")]),
               "Key Repeat Rate", "\"Extreme\" is faster than Settings allows.", effect: .logout, fallback: .int(6),
               preview: "A held key repeating at the chosen rate"),
        global(.input, "Keyboard", "InitialKeyRepeat", kind: .int,
               control: .choice([.init(.int(10), "Instant"), .init(.int(15), "Short"), .init(.int(25), "Medium"),
                                 .init(.int(68), "Long"), .init(.int(120), "Longest")]),
               "Delay Until Repeat", "How long a key is held before it repeats.", effect: .logout, fallback: .int(25),
               preview: "A pause, then repeating letters"),
        global(.input, "Keyboard", "ApplePressAndHoldEnabled", "Press and Hold for Accents",
               "Off makes held keys repeat instead of showing accents.", fallback: .bool(true),
               preview: "The accent popover over a held e"),
        global(.input, "Keyboard", "AppleKeyboardUIMode", kind: .int,
               control: .toggle(on: .int(2), off: .int(0)), "Keyboard Navigation",
               "Tab moves through every control, not just text fields.", fallback: .int(0),
               preview: "A focus ring hopping between buttons"),
        global(.input, "Keyboard", "com.apple.keyboard.fnState", "F-keys as Standard Keys",
               "F1, F2… act as function keys. Hold fn for brightness and volume.", effect: .logout,
               preview: "The top row labels switching to F1-F12"),
        pad("Clicking", "Tap to Click", "A light tap clicks.", fallback: .bool(false), preview: "A finger tapping the trackpad"),
        pad("TrackpadThreeFingerDrag", "Three-finger Drag", "Drag windows with three fingers, no click.",
            fallback: .bool(false), preview: "Three fingers carrying a window"),
        pad("FirstClickThreshold", kind: .int,
            control: .choice([.init(.int(0), "Light"), .init(.int(1), "Medium"), .init(.int(2), "Firm")]),
            "Click Firmness", "How hard a click needs to be.", fallback: .int(1), preview: "A click pulse at three strengths"),
        pad("ForceSuppressed", "Turn Off Force Click", "A deep press stays an ordinary click.", fallback: .bool(false),
            preview: "A force-click ripple crossed out"),
        global(.input, "Trackpad", "com.apple.trackpad.scaling", kind: .float, control: .number(0...3, step: 0.125, unit: ""),
               "Trackpad Speed", "Beyond the slider's fastest notch.", effect: .logout, preview: "A pointer trail at the chosen speed"),
        global(.input, "Trackpad", "com.apple.swipescrolldirection", "Natural Scrolling", "Content follows your fingers.",
               effect: .logout, fallback: .bool(true), preview: "A page scrolling with and against the fingers"),
        global(.input, "Trackpad", "AppleEnableSwipeNavigateWithScrolls", "Swipe Between Pages",
               "Two-finger swipe goes back and forward.", fallback: .bool(true), preview: "A page sliding back"),
        global(.input, "Text", "NSAutomaticQuoteSubstitutionEnabled", "Smart Quotes", "\"Straight\" quotes become “curly”.",
               fallback: .bool(true), preview: "Straight quotes curling as you type"),
        global(.input, "Text", "NSAutomaticDashSubstitutionEnabled", "Smart Dashes", "Two hyphens become a dash.",
               fallback: .bool(true), preview: "-- turning into —"),
        global(.input, "Text", "NSAutomaticSpellingCorrectionEnabled", "Autocorrect", "Fix spelling as you type.",
               fallback: .bool(true), preview: "teh correcting to the"),
        global(.input, "Text", "WebAutomaticSpellingCorrectionEnabled", "Autocorrect in Web Views",
               "The same, inside apps that show web pages.", fallback: .bool(true), preview: "A web text field correcting a word"),
        global(.input, "Text", "NSAutomaticCapitalizationEnabled", "Auto-capitalise", "Capitalise the start of sentences.",
               fallback: .bool(true), preview: "A lowercase sentence start becoming capital"),
        global(.input, "Text", "NSAutomaticPeriodSubstitutionEnabled", "Double-space Full Stop", "Two spaces type a full stop.",
               fallback: .bool(true), preview: "Two spaces turning into “. ”"),
        global(.input, "Text", "NSAutomaticInlinePredictionEnabled", "Inline Predictions", "Grey completions ahead of the cursor.",
               fallback: .bool(true), preview: "Grey predicted text after the cursor"),
    ]

    // Sounds. The startup chime lives in NVRAM and is left alone.
    static let soundSettings: [PersonalSetting] = [
        global(.sounds, "Alerts", "com.apple.sound.beep.sound", kind: .string, control: .sound, "Alert Sound",
               "The sound for alerts and errors.", effect: .relaunchApps, fallback: .string("/System/Library/Sounds/Tink.aiff"),
               preview: "The alert bell icon pulsing with the chosen sound"),
        global(.sounds, "Alerts", "com.apple.sound.beep.volume", kind: .float, control: .number(0...1, step: 0.05, unit: ""),
               "Alert Volume", "Relative to the main volume.", effect: .relaunchApps, fallback: .float(1),
               preview: "A speaker with waves at the chosen level"),
        global(.sounds, "Alerts", "com.apple.sound.beep.flash", kind: .int, control: .toggle(on: .int(1), off: .int(0)),
               "Flash the Screen", "The screen flashes with every alert.", effect: .relaunchApps, fallback: .int(0),
               preview: "The stage screen flashing white once"),
        global(.sounds, "Feedback", "com.apple.sound.beep.feedback", kind: .int, control: .toggle(on: .int(1), off: .int(0)),
               "Volume Change Sound", "A pop when you change the volume.", effect: .logout,
               evidence: cache + " and the Sound settings extension", preview: "The volume HUD with a pop"),
    ]

    // Animations, beyond the ones in the tweak catalogue (moved here, not repeated).
    static let animationSettings: [PersonalSetting] = [
        global(.animations, "Apps", "NSBrowserColumnAnimationSpeedMultiplier", kind: .float,
               control: .choice([.init(.float(0), "Instant"), .init(.float(0.5), "Quick"), .init(.float(1), "Normal")]),
               "Column Slide", "The slide when a column view moves.", fallback: .float(1),
               preview: "Finder columns sliding in"),
        // Both keys name the feature itself, so On writes true. Writing false switches it off.
        global(.animations, "Apps", "NSDocumentRevisionsWindowTransformAnimation", "Version Browser Zoom",
               "The zoom into Browse All Versions.", fallback: .bool(true),
               preview: "A document flying into the version timeline"),
        global(.animations, "Apps", "NSScrollViewRubberbanding", "Rubber-band Scrolling",
               "Lists stretch past their ends.", fallback: .bool(true), preview: "A list bouncing at the top"),
        global(.animations, "Apps", "NSInitialToolTipDelay", kind: .int,
               control: .choice([.init(.int(50), "Instant"), .init(.int(400), "Quick"), .init(.int(1000), "Normal")]),
               "Tooltip Delay", "How long the pointer rests before a tooltip shows, in milliseconds.",
               preview: "A tooltip appearing over a button"),
        // Opening Bounce (launchanim) lives in the Dock chapter with the Dock's other bounces
        // (DockStacks Catalog.swift), so it has one home.
        dock(.animations, "Dock", "mineffect", kind: .string,
             control: .choice([.init(.string("genie"), "Genie"), .init(.string("scale"), "Scale"), .init(.string("suck"), "Suck")]),
             "Minimise Effect", "\"Suck\" is hidden from Settings.", fallback: .string("genie"),
             preview: "A window minimising with the chosen effect"),
    ]

    // Apps. More per-app settings, including sandboxed apps behind Full Disk Access, are in PersonalCatalogApps.swift.
    static let appSettings: [PersonalSetting] = [
        PersonalSetting(.apps, "Activity Monitor", domain: "com.apple.ActivityMonitor", key: "IconType", kind: .int,
                        control: .choice([.init(.int(0), "App Icon"), .init(.int(5), "CPU Usage"), .init(.int(6), "CPU History"),
                                          .init(.int(2), "Network"), .init(.int(3), "Disk")]),
                        title: "Dock Icon", detail: "Activity Monitor's Dock icon becomes a live graph while it runs.",
                        effect: .relaunch("Activity Monitor"), fallback: .int(0),
                        evidence: "REA: Activity Monitor binary string IconType; values from Activity Monitor's View menu",
                        preview: "The Activity Monitor tile turning into a CPU graph"),
        PersonalSetting(.apps, "Activity Monitor", domain: "com.apple.ActivityMonitor", key: "UpdatePeriod", kind: .int,
                        control: .choice([.init(.int(1), "1 s"), .init(.int(2), "2 s"), .init(.int(5), "5 s")]),
                        title: "Update Every", detail: "How often its numbers refresh.", effect: .relaunch("Activity Monitor"),
                        fallback: .int(5), evidence: "REA: Activity Monitor binary string UpdatePeriod",
                        preview: "A graph ticking at the chosen rate"),
        PersonalSetting(.apps, "Music", domain: "com.apple.Music", key: "userWantsPlaybackNotifications", kind: .bool,
                        control: onOff(), title: "Song Notifications", detail: "A notification when the track changes.",
                        effect: .relaunch("Music"), evidence: "Music binary string (strings; REA timed out on this binary)",
                        preview: "A song banner sliding in"),
        PersonalSetting(.apps, "Disk Utility", domain: "com.apple.DiskUtility", key: "SidebarShowAllDevices", kind: .bool,
                        control: onOff(), title: "Show All Devices", detail: "List physical disks, not just volumes.",
                        effect: .relaunch("Disk Utility"), evidence: "Disk Utility binary string (strings)",
                        preview: "The Disk Utility sidebar expanding to devices"),
        PersonalSetting(.apps, "Terminal", domain: "com.apple.Terminal", key: "SecureKeyboardEntry", kind: .bool,
                        control: onOff(), title: "Secure Keyboard Entry", detail: "Other apps cannot read what you type in Terminal.",
                        effect: .relaunch("Terminal"), evidence: "Terminal binary string (strings; REA timed out)",
                        preview: "A padlock over the Terminal window"),
        PersonalSetting(.apps, "Terminal", domain: "com.apple.Terminal", key: "FocusFollowsMouse", kind: .bool,
                        control: onOff(), title: "Focus Follows Pointer", detail: "The Terminal window under the pointer takes your typing.",
                        effect: .relaunch("Terminal"), evidence: "Terminal binary string (strings)",
                        preview: "Two Terminal windows, focus moving with the pointer"),
        global(.apps, "All Apps", "NSQuitAlwaysKeepsWindows", "Reopen Windows",
               "Apps bring back their windows when reopened.", preview: "An app reopening with its windows"),
        global(.apps, "All Apps", "NSCloseAlwaysConfirmsChanges", "Ask to Keep Changes",
               "Closing a document asks whether to save.", preview: "The save sheet on closing a document"),
    ]

    // Capture: the keys screencaptureui reads on this macOS.
    static let captureSettings: [PersonalSetting] = [
        PersonalSetting(.capture, "Screenshots", domain: "com.apple.screencapture", key: "location-screenshot", kind: .string,
                        control: .folder, title: "Save Screenshots To", detail: "The folder new screenshots go to.",
                        effect: .nextUse, evidence: "REA: screencaptureui and screencapture strings location-screenshot",
                        preview: "A screenshot thumbnail flying into the chosen folder"),
        PersonalSetting(.capture, "Screenshots", domain: "com.apple.screencapture", key: "type", kind: .string,
                        control: .choice([.init(.string("png"), "PNG"), .init(.string("jpg"), "JPEG"), .init(.string("heic"), "HEIC"),
                                          .init(.string("pdf"), "PDF"), .init(.string("tiff"), "TIFF")]),
                        title: "Format", detail: "The file type of new screenshots.", effect: .nextUse, fallback: .string("png"),
                        evidence: "REA: screencaptureui string type", preview: "The screenshot file badge changing type"),
        PersonalSetting(.capture, "Screenshots", domain: "com.apple.screencapture", key: "name", kind: .string,
                        control: .text(placeholder: "Screenshot"), title: "File Name", detail: "The word new screenshots start with.",
                        effect: .nextUse, evidence: "REA: screencaptureui and screencapture string name",
                        preview: "A file name changing under a screenshot"),
        PersonalSetting(.capture, "Recordings", domain: "com.apple.screencapture", key: "location-screenrecording", kind: .string,
                        control: .folder, title: "Save Recordings To", detail: "The folder new screen recordings go to.",
                        effect: .nextUse, evidence: "REA: screencaptureui string location-screenrecording",
                        preview: "A recording flying into the chosen folder"),
        // Sonoma and Sequoia keep one folder for both, under the plain "location" key. Only one
        // of this row and the two above is shown, by `PersonalAvailability`.
        PersonalSetting(.capture, "Screenshots", domain: "com.apple.screencapture", key: "location", kind: .string,
                        control: .folder, title: "Save Captures To",
                        detail: "The folder new screenshots and screen recordings go to.", effect: .nextUse,
                        evidence: "macos-defaults.com: com.apple.screencapture location, tested on Sonoma and earlier",
                        preview: "A screenshot thumbnail flying into the chosen folder"),
    ]

    // Mission Control and Spaces. mru-spaces was not found in Dock or the shared cache, so it is left out.
    // In the Mission Control area with the rest, so Windows & Spaces shows one Mission Control section.
    static let windowSettings: [PersonalSetting] = [
        dock(.missionControl, "Mission Control", "expose-group-apps", "Group Windows by App",
             "Mission Control stacks each app's windows together.", fallback: .bool(false),
             preview: "Mission Control tiles clustering by app"),
        dock(.missionControl, "Mission Control", "workspaces-auto-swoosh", "Jump to an App's Space",
             "Switching to an app moves to the Space with its window.", fallback: .bool(true), preview: "The screen sliding to another Space"),
        dock(.missionControl, "Mission Control", "showAppExposeGestureEnabled", "App Exposé Gesture",
             "Swipe down with three fingers to see an app's windows.", fallback: .bool(false), preview: "App Exposé spreading windows"),
        dock(.missionControl, "Mission Control", "appswitcher-all-displays", "App Switcher on Every Display",
             "⌘-Tab shows on all screens, not just the main one.", fallback: .bool(false), preview: "Two screens, each with the switcher"),
        dock(.missionControl, "Mission Control", "minimize-to-application", "Minimise into App Icon",
             "Minimised windows go into their app's Dock icon.", fallback: .bool(false), preview: "A window shrinking into its app icon"),
        dock(.missionControl, "Mission Control", "workspaces-edge-delay", kind: .float, control: .number(0...1.5, step: 0.05, unit: "s"),
             "Edge Space Switch Delay", "How long a dragged window waits at the edge before changing Space.",
             fallback: .float(0.75), preview: "A window held at the screen edge, then switching Space"),
    ]

    static let cornerSettings: [PersonalSetting] = [
        dock(.corners, "Hot Corners", "wvous-corner-action-delay", kind: .float, control: .number(0...2, step: 0.05, unit: "s"),
             "Hot Corner Delay", "How long the pointer waits in a corner before macOS acts.",
             preview: "A ring filling in a screen corner"),
    ]

    public static func settings(in area: PersonalArea) -> [PersonalSetting] { all.filter { $0.area == area } }

    /// Section titles in the order they first appear.
    public static func sections(in area: PersonalArea) -> [String] {
        var seen: [String] = []
        for setting in settings(in: area) where !seen.contains(setting.section) { seen.append(setting.section) }
        return seen
    }
}

// MARK: - Desktop icon grid

/// Finder's desktop view options live in a nested dictionary, so they get their own reader.
public struct DesktopIconOptions: Sendable, Equatable, Codable {
    public var iconSize: Double
    public var gridSpacing: Double
    public var textSize: Double
    public var labelOnBottom: Bool
    public var showItemInfo: Bool
    public var showIconPreview: Bool
    public var arrangeBy: String

    public static let arrangements: [(String, String)] = [
        ("none", "None"), ("grid", "Snap to Grid"), ("name", "Name"), ("kind", "Kind"), ("dateAdded", "Date Added"),
        ("dateModified", "Date Modified"), ("dateCreated", "Date Created"), ("size", "Size"), ("label", "Tags"),
    ]

    public init(iconSize: Double = 64, gridSpacing: Double = 54, textSize: Double = 12, labelOnBottom: Bool = true,
                showItemInfo: Bool = false, showIconPreview: Bool = true, arrangeBy: String = "none") {
        self.iconSize = iconSize; self.gridSpacing = gridSpacing; self.textSize = textSize
        self.labelOnBottom = labelOnBottom; self.showItemInfo = showItemInfo
        self.showIconPreview = showIconPreview; self.arrangeBy = arrangeBy
    }

    public init(desktopViewSettings: [String: Any]?) {
        self.init()
        guard let icon = desktopViewSettings?["IconViewSettings"] as? [String: Any] else { return }
        func number(_ key: String) -> Double? { (icon[key] as? NSNumber)?.doubleValue }
        iconSize = number("iconSize") ?? iconSize
        gridSpacing = number("gridSpacing") ?? gridSpacing
        textSize = number("textSize") ?? textSize
        labelOnBottom = (icon["labelOnBottom"] as? NSNumber)?.boolValue ?? labelOnBottom
        showItemInfo = (icon["showItemInfo"] as? NSNumber)?.boolValue ?? showItemInfo
        showIconPreview = (icon["showIconPreview"] as? NSNumber)?.boolValue ?? showIconPreview
        arrangeBy = icon["arrangeBy"] as? String ?? arrangeBy
    }

    /// Merges into the existing dictionary so the keys Atelier does not know survive.
    public func merged(into desktopViewSettings: [String: Any]?) -> [String: Any] {
        var outer = desktopViewSettings ?? [:]
        var icon = outer["IconViewSettings"] as? [String: Any] ?? [:]
        icon["iconSize"] = min(max(iconSize, 16), 128)
        icon["gridSpacing"] = min(max(gridSpacing, 1), 100)
        icon["textSize"] = min(max(textSize, 10), 16)
        icon["labelOnBottom"] = labelOnBottom
        icon["showItemInfo"] = showItemInfo
        icon["showIconPreview"] = showIconPreview
        icon["arrangeBy"] = arrangeBy
        outer["IconViewSettings"] = icon
        return outer
    }
}


/// Remembers when each preferences domain was last synchronised.
enum PersonalSyncGate {
    nonisolated(unsafe) private static var last: [String: Date] = [:]
    private static let lock = NSLock()

    static func shouldSync(_ key: String, every interval: TimeInterval = 1) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let at = last[key], now.timeIntervalSince(at) < interval { return false }
        last[key] = now
        return true
    }

    static func invalidate(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        last[key] = nil
    }
}

/// Whether this process may write a privacy-guarded file, asked with access(2). Nothing is
/// opened or written: on macOS 13 and later access(W_OK) already answers no for a guarded file
/// without Full Disk Access, even though its mode says the owner may write. A missing file is
/// writable (cfprefsd creates it). The answer is kept for two seconds, so rows can ask on every
/// redraw and still notice within moments when Full Disk Access is granted.
public enum PersonalWriteGate {
    nonisolated(unsafe) private static var cache: [String: (writable: Bool, at: Date)] = [:]
    private static let lock = NSLock()

    public static func isWritable(_ path: String, maxAge: TimeInterval = 2,
                                  probe: (String) -> Bool = PersonalWriteGate.probe) -> Bool {
        lock.lock()
        if let hit = cache[path], Date().timeIntervalSince(hit.at) < maxAge { lock.unlock(); return hit.writable }
        lock.unlock()
        let writable = probe(path)
        lock.lock(); cache[path] = (writable, Date()); lock.unlock()
        return writable
    }

    public static func probe(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return access((path as NSString).deletingLastPathComponent, W_OK) == 0
        }
        return access(path, W_OK) == 0
    }

    public static func forget() { lock.lock(); cache = [:]; lock.unlock() }
}

// MARK: - Which macOS reads a key

/// The macOS releases that honour a preference key, and how sure the catalogue is of that.
/// Majors are marketing numbers: 14 Sonoma, 15 Sequoia, 26 Tahoe, 27.
public struct PersonalOSRange: Sendable, Equatable, Hashable {
    public enum Confidence: String, Sendable {
        /// Documented outside this Mac for the releases in range (macos-defaults.com, Apple's
        /// own Support pages, long-running dotfiles), or a key AppKit has read for many releases.
        case documented
        /// Tied to a feature that shipped in `min` (Apple's release notes), so earlier releases
        /// cannot read it.
        case feature
        /// Found only in this Mac's macOS 27 binaries. Assumed for the rest of the range.
        case thisMacOnly
    }

    public let min: Int
    /// The last release that reads it, or nil while current releases still do.
    public let max: Int?
    public let confidence: Confidence
    /// Why the range is what it is, in one sentence, for the help tag and the audit.
    public let reason: String

    public init(_ min: Int, max: Int? = nil, _ confidence: Confidence, _ reason: String) {
        self.min = min; self.max = max; self.confidence = confidence; self.reason = reason
    }

    public func contains(major: Int) -> Bool { major >= min && (max.map { major <= $0 } ?? true) }

    /// What the "Not on this macOS" group says about the row.
    public func requirement(onMajor major: Int) -> String {
        if let max, major > max { return "Replaced after macOS \(max)" }
        if let max, max != min { return "macOS \(min) to \(max)" }
        return "Needs macOS \(min) or later"
    }

    /// The note a row shows when it is in range but was only ever checked on macOS 27.
    public func verificationNote(onMajor major: Int) -> String? {
        confidence == .thisMacOnly && major != PersonalAvailability.verifiedMajor
            ? "Found in macOS \(PersonalAvailability.verifiedMajor); not yet checked on macOS \(major)." : nil
    }
}

/// Which releases read each catalogued key. Pure data and pure functions, so the decisions are
/// tested without the OS they describe.
public enum PersonalAvailability {
    /// The release every "evidence" string in the catalogue was taken from.
    public static let verifiedMajor = 27

    /// The running release. A binary linked against an SDK older than macOS 26 is told "16"
    /// by the compatibility shim (SYSTEM_VERSION_COMPAT); that is Tahoe, so it reads as 26.
    public static func normalizedMajor(_ reported: Int) -> Int { reported == 16 ? 26 : reported }

    public static var runningMajor: Int {
        normalizedMajor(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    private static func id(_ domain: String, _ key: String) -> String { domain + "|" + key }

    /// Long-standing keys: read by every release from 14 on.
    static let longStanding = PersonalOSRange(14, .documented,
        "Read by macOS for many releases; documented for Sonoma and Sequoia.")

    /// Keys of Apple's own apps. They follow the app, which ships with the OS; every one was
    /// found in this Mac's copy and none is tied to a feature newer than macOS 14.
    static let appKey = PersonalOSRange(14, .thisMacOnly,
        "Found in this Mac's copy of the app; the app reads it when it opens.")

    /// The domains of `PersonalCatalog.apps`, audited as a group under `appKey`.
    public static let appDomains: Set<String> = Set(PersonalCatalog.apps.map(\.bundleID))

    /// Every key that is not simply "14 and later". Anything absent here and outside
    /// `appDomains` must be in `auditedLongStanding`, which the tests enforce.
    public static let ranges: [String: PersonalOSRange] = {
        var table: [String: PersonalOSRange] = [:]
        func put(_ domain: String, _ keys: [String], _ range: PersonalOSRange) {
            for key in keys { table[id(domain, key)] = range }
        }
        let thisMac = { (min: Int, why: String) in PersonalOSRange(min, .thisMacOnly, why) }

        // Capture. macOS 27's screencaptureui and screencapture carry only the split keys,
        // and no plain "location" literal; Sonoma and Sequoia read "location" (macos-defaults.com).
        put("com.apple.screencapture", ["location-screenshot", "location-screenrecording"],
            thisMac(26, "Separate screenshot and recording folders; only the macOS 27 screenshot tools were checked."))
        put("com.apple.screencapture", ["location"],
            PersonalOSRange(14, max: 15, .documented, "The single save folder of Sonoma and Sequoia (macos-defaults.com)."))

        // Text. Inline predictions shipped with Sonoma.
        put("NSGlobalDomain", ["NSAutomaticInlinePredictionEnabled"],
            PersonalOSRange(14, .feature, "Inline predictive text arrived in macOS 14."))

        // Spotlight. These switches live in SpotlightUIShared and SpotlightUIInternal, the
        // frameworks of Tahoe's redesigned Spotlight (browse buttons, Apps, Files and Actions).
        put("com.apple.Spotlight", ["SUIDisableInvocationAnimation", "SUIDisableExpansionAnimation",
                                    "SUIDisableBrowseButtonAnimation", "SUIWindowSizeAnimationSpeed",
                                    "SUIWiderFilesBrowseViewEnabled", "SearchFieldClearTimeoutSeconds",
                                    "trackpadAppBrowseEnabled", "singleScreenClamp", "shouldShowTopResultAboveFilterBar"],
            PersonalOSRange(26, .feature, "Part of the Spotlight redesign in macOS 26; earlier Spotlight has no such switches."))

        // Window tiling by dragging shipped with Sequoia (Apple: "Tile windows on Mac", macOS 15).
        put("com.apple.WindowManager", ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag",
                                        "EnableTilingOptionAccelerator", "EnableTiledWindowMargins"],
            PersonalOSRange(15, .feature, "Window tiling arrived in macOS 15."))
        put("com.apple.WindowManager", ["TiledWindowSpacing"],
            thisMac(15, "A hidden spacing value for macOS 15's tiling; seen only in macOS 27."))
        // Desktop widgets, and hiding them, arrived with Sonoma.
        put("com.apple.WindowManager", ["StageManagerHideWidgets", "StandardHideWidgets", "EnableStandardClickToShowDesktop"],
            PersonalOSRange(14, .feature, "Desktop widgets and click-to-reveal arrived in macOS 14."))
        put("com.apple.WindowManager", ["EnableStageManagerHotKey", "HiddenStripPeekWidth", "AnimationSpeed"],
            thisMac(14, "Hidden Stage Manager values; seen only in macOS 27."))

        // Liquid Glass and the Tahoe icon styles.
        put("com.apple.dock", ["adaptive-glass"], PersonalOSRange(26, .feature, "Liquid Glass arrived in macOS 26."))
        put("NSGlobalDomain", ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor", "AppleIconAppearanceCustomTintColor"],
            PersonalOSRange(26, .feature, "Clear and tinted icon styles arrived in macOS 26."))

        // Lock screen. LoginUIKit's adjustable clock is Tahoe's.
        put("com.apple.loginwindow", ["ClockFontWeight", "HideUserAvatarAndName"],
            thisMac(26, "Tahoe's lock screen clock keys, found in macOS 27's LoginUIKit."))

        // Hidden Dock values decoded from DockGlobals, the Swift Dock of recent releases.
        put("com.apple.dock", ["clip-windows", "allow-display-switching", "appswitcher-dock-display",
                               "bounce-duration", "bounce-secondary-duration", "bounce-secondary-interval",
                               "workspaces-maximize-to-current-space"],
            thisMac(26, "Read by the Dock's DockGlobals in macOS 27; older Docks were not checked."))
        put("com.apple.dock", ["expose-sticky-time", "popup-delay", "wvous-corner-action-delay"],
            thisMac(14, "A Dock timing found as a literal in macOS 27; older Docks were not checked."))

        // Hidden AppKit, Quick Look and Control Center values seen only here.
        put("NSGlobalDomain", ["NSSplitViewItemFullscreenEdgeRevealDelay", "NSSwitchDefaultAnimationDuration",
                               "NSOverlayScrollerHideDelay", "NSToolTipAutoWrappingDisabled",
                               "NSFullScreenTransitionDuration",
                               "QLEnableSelectionCycling", "QLPreviewKeepConstantWidth", "QLPanelMaxSizeMargin",
                               "QLPreviewPanelAutoResetLocationDelay", "userMenuExtraStyle"],
            thisMac(14, "A hidden default found in macOS 27's frameworks; older releases were not checked."))
        put("com.apple.controlcenter", ["BatteryShowEnergyMode"],
            thisMac(14, "Energy Mode in the battery menu; seen in macOS 27's ControlCenter."))

        // App keys tied to features newer than 14.
        put("com.apple.Preview", ["PVDisableHDRBackgroundAppDimming", "PVStayHDRWhenAnnotating"],
            thisMac(26, "Preview's HDR editing keys; seen only in macOS 27's Preview."))
        return table
    }()

    /// The non-app keys audited as long-standing, by "domain|key". New catalogue entries fail
    /// the coverage test until they are added here or to `ranges`.
    public static let auditedLongStanding: Set<String> = {
        var set = Set<String>()
        func add(_ domain: String, _ keys: [String]) { for key in keys { set.insert(id(domain, key)) } }
        add("com.apple.finder", ["NewWindowTarget", "FXPreferredViewStyle", "FXDefaultSearchScope", "FinderSpawnTab",
                                 "ShowSidebar", "ShowTabView", "PathBarRootAtHome", "SidebarWidth", "_FXEnableColumnAutoSizing",
                                 "FXEnableRemoveFromICloudDriveWarning", "WarnOnEmptyTrash", "FXRemoveOldTrashItems",
                                 "ShowHardDrivesOnDesktop", "ShowExternalHardDrivesOnDesktop", "ShowRemovableMediaOnDesktop",
                                 "ShowMountedServersOnDesktop", "_FXSortFoldersFirstOnDesktop", "AnimateInfoPanes",
                                 "AnimateWindowZoom", "FXEnableSlowAnimation",
                                 // Tweaks.
                                 "ShowStatusBar", "ShowPathbar", "ShowPreviewPane", "_FXShowPosixPathInTitle",
                                 "_FXSortFoldersFirst", "FXEnableExtensionChangeWarning", "AppleShowAllFiles",
                                 "QuitMenuItem", "DisableAllAnimations", "ShowRecentTags"])
        add("NSGlobalDomain", ["NSTableViewDefaultSizeMode", "AppleShowAllExtensions", "com.apple.mouse.scaling",
                               "com.apple.springing.enabled", "com.apple.springing.delay", "KeyRepeat", "InitialKeyRepeat",
                               "ApplePressAndHoldEnabled", "AppleKeyboardUIMode", "com.apple.keyboard.fnState",
                               "com.apple.trackpad.scaling", "com.apple.swipescrolldirection",
                               "AppleEnableSwipeNavigateWithScrolls", "NSAutomaticQuoteSubstitutionEnabled",
                               "NSAutomaticDashSubstitutionEnabled", "NSAutomaticSpellingCorrectionEnabled",
                               "WebAutomaticSpellingCorrectionEnabled", "NSAutomaticCapitalizationEnabled",
                               "NSAutomaticPeriodSubstitutionEnabled", "com.apple.sound.beep.sound",
                               "com.apple.sound.beep.volume", "com.apple.sound.beep.flash", "com.apple.sound.beep.feedback",
                               "NSBrowserColumnAnimationSpeedMultiplier", "NSDocumentRevisionsWindowTransformAnimation",
                               "NSScrollViewRubberbanding", "NSInitialToolTipDelay", "NSQuitAlwaysKeepsWindows",
                               "NSCloseAlwaysConfirmsChanges", "AppleICUForce24HourTime", "_HIHideMenuBar",
                               "AppleMenuBarVisibleInFullscreen", "CGDisableCursorLocationMagnification",
                               "NSTextInsertionPointBlinkPeriodOn", "NSTextInsertionPointBlinkPeriodOff",
                               "NSDragAndDropTextDelay", "NSAutomaticTextCompletionEnabled",
                               "NSSpellCheckerAutomaticallyIdentifiesLanguages", "NSTextShowsControlCharacters",
                               "NSTextKillRingSize", "AppleScrollerPagingBehavior", "NSRecentDocumentsLimit",
                               "NSDisableAutomaticTermination", "NSAppSleepDisabled", "AppleHighlightColor",
                               "AppleFontSmoothing", "QLHidePanelOnDeactivate", "QLEnableSwipeWithScroll", "QLMarkupEnabled",
                               "com.apple.trackpad.forceClick",
                               // Tweaks.
                               "AppleEdgeResizeExteriorSize", "AppleEdgeResizeCornerSize", "NSWindowShouldDragOnGesture",
                               "NSWindowResizeTime", "NSAutomaticWindowAnimationsEnabled", "AppleSpacesSwitchOnActivate",
                               "NSStatusItemSpacing", "NSStatusItemSelectionPadding", "NSScrollAnimationEnabled",
                               "NSUseAnimatedFocusRing", "NSToolbarTitleViewRolloverDelay", "QLPanelAnimationDuration",
                               "NSNavPanelExpandedStateForSaveMode", "NSDocumentSaveNewDocumentsToCloud",
                               "AppleReduceDesktopTinting", "AppleShowScrollBars", "AppleWindowTabbingMode",
                               "AppleActionOnDoubleClick"])
        add("com.apple.universalaccess", ["mouseDriverCursorSize", "reduceMotion", "reduceTransparency", "increaseContrast",
                                          "differentiateWithoutColor", "showWindowTitlebarIcons", "showToolbarButtonShapes",
                                          "closeViewScrollWheelToggle", "closeViewSmoothImages", "closeViewZoomFollowsFocus",
                                          "hoverTextEnabled", "hoverTypingEnabled", "keyboardAccessLargeFocusRingEnabled",
                                          "keyboardAccessFocusRingHighContrastEnabled"])
        add("com.apple.AppleMultitouchTrackpad", ["Clicking", "TrackpadThreeFingerDrag", "FirstClickThreshold",
                                                  "ForceSuppressed", "ActuationStrength", "ActuateDetents", "SecondClickThreshold"])
        add("com.apple.dock", ["launchanim", "mineffect", "expose-group-apps", "workspaces-auto-swoosh",
                               "showAppExposeGestureEnabled", "appswitcher-all-displays", "minimize-to-application",
                               "workspaces-edge-delay", "mcx-expose-disabled", "showMissionControlGestureEnabled",
                               "showDesktopGestureEnabled",
                               // Tweaks.
                               "genie-speed", "slow-motion-allowed", "autohide-delay", "autohide-time-modifier",
                               "no-bouncing", "show-process-indicators", "scroll-to-open", "show-recent-count",
                               "mouse-over-hilite-stack", "enable-spring-load-actions-on-all-items", "spring-to-expose",
                               "hilite-windows-in-expose", "show-space-bindings"])
        add("com.apple.screencapture", ["type", "name", "disable-shadow", "show-thumbnail", "include-date"])
        // Menu bar modules: ByHost ints in com.apple.controlcenter since Big Sur, documented for
        // Sonoma and Sequoia, and still read by macOS 27's ControlCenter (values seen here).
        add("com.apple.controlcenter", ["Battery", "WiFi", "Bluetooth", "Sound", "NowPlaying", "FocusModes", "Display",
                                        "ScreenMirroring", "AirDrop", "KeyboardBrightness", "Hearing",
                                        "AccessibilityShortcuts", "MusicRecognition", "UserSwitcher", "BatteryShowPercentage"])
        add("com.apple.Spotlight", ["NSStatusItem VisibleCC Item-0"])
        add("com.apple.Siri", ["StatusMenuVisible"])
        add("com.apple.airplay", ["showInMenuBarIfPresent"])
        add("com.apple.menuextra.clock", ["ShowDate", "ShowDayOfWeek", "ShowAMPM", "ShowSeconds", "IsAnalog", "FlashDateSeparators"])
        add("com.apple.spaces", ["spans-displays"])
        add("com.apple.WindowManager", ["GloballyEnabled", "AppWindowGroupingBehavior", "HideDesktop",
                                        "StandardHideDesktopIcons", "AutoHide"])
        add("com.apple.screensaver", ["idleTime", "showClock", "mainScreenOnly"])
        add("com.apple.loginwindow", ["TALLogoutSavesState"])
        return set
    }()

    /// The range for a key. Unknown keys are long-standing: the brief's default, and a key
    /// a release does not read is ignored by it, never misread.
    public static func range(domain: String, key: String) -> PersonalOSRange {
        if let range = ranges[id(domain, key)] { return range }
        if appDomains.contains(domain) { return appKey }
        return longStanding
    }

    /// Whether the catalogue has made a decision about this key, rather than defaulting.
    public static func isAudited(domain: String, key: String) -> Bool {
        ranges[id(domain, key)] != nil || appDomains.contains(domain) || auditedLongStanding.contains(id(domain, key))
    }

    /// Splits settings into those the running release reads and those it does not, keeping order.
    public static func partition(_ settings: [PersonalSetting], major: Int = runningMajor)
        -> (supported: [PersonalSetting], unsupported: [PersonalSetting]) {
        var supported: [PersonalSetting] = [], unsupported: [PersonalSetting] = []
        for setting in settings { setting.isAvailable(onMajor: major) ? supported.append(setting) : unsupported.append(setting) }
        return (supported, unsupported)
    }

    /// Icon styles a theme may ask for: "dark" and "tinted" and "clear" all write
    /// AppleIconAppearanceTheme, which only Tahoe and later read.
    public static func themeIconStyleSupported(_ style: String, major: Int = runningMajor) -> Bool {
        style == "default" || range(domain: "NSGlobalDomain", key: "AppleIconAppearanceTheme").contains(major: major)
    }
}

extension PersonalSetting {
    /// The releases that read this setting's key.
    public var availability: PersonalOSRange { PersonalAvailability.range(domain: domain, key: key) }

    public func isAvailable(onMajor major: Int = PersonalAvailability.runningMajor) -> Bool {
        availability.contains(major: major)
    }
}
