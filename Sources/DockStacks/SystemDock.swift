import Foundation

// MARK: - Replacing the system Dock
//
// The macOS Dock is kept out of sight with three of its own preferences, then one restart:
//
//     autohide                 true     it hides
//     autohide-delay           1000     and waits 1000 s at the edge before it comes back
//     autohide-time-modifier   0        and does not slide while it hides
//
// Nothing else is touched: no code injection, no SIP, and never `static-only`. Every value
// is saved before the first write, present or absent, and put back exactly afterwards.
// This file only uses Foundation, so the plan can be checked outside the app.

/// One stored preference value, in a form that can be saved and written back unchanged.
enum DockPrefValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// Anything else, as a binary property list.
    case plist(Data)

    init?(_ object: Any?) {
        guard let object else { return nil }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
            else { self = .int(number.intValue) }
        } else if let text = object as? String {
            self = .string(text)
        } else if let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) {
            self = .plist(data)
        } else {
            return nil
        }
    }

    var object: Any? {
        switch self {
        case .bool(let value): value as NSNumber
        case .int(let value): value as NSNumber
        case .double(let value): value as NSNumber
        case .string(let value): value as NSString
        case .plist(let data): try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
    }

    /// The arguments `defaults write` takes for this value, or nil when it has no plain form.
    var defaultsArguments: [String]? {
        switch self {
        case .bool(let value): ["-bool", value ? "true" : "false"]
        case .int(let value): ["-int", String(value)]
        case .double(let value): ["-float", String(value)]
        case .string(let value): ["-string", value]
        case .plist: nil
        }
    }
}

/// What a key held before the first write. `value == nil` means the key was absent.
struct SystemDockBackup: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var key: String
        var value: DockPrefValue?
    }
    var entries: [Entry]
    var date = Date()

    func original(_ key: String) -> DockPrefValue? { entries.first { $0.key == key }?.value }
}

/// One change to a preference. `value == nil` deletes the key.
struct DockPrefWrite: Equatable, Sendable {
    var key: String
    var value: DockPrefValue?
}

/// The pure part: which keys, which values, and which writes get from one state to another.
enum SystemDockPlan {
    static let domain = "com.apple.dock"

    static let targets: [(key: String, value: DockPrefValue)] = [
        ("autohide", .bool(true)),
        ("autohide-delay", .double(1000)),
        ("autohide-time-modifier", .double(0)),
    ]

    static var keys: [String] { targets.map(\.key) }

    /// Never written by this plan, whatever else changes. Listed so a test can hold it to that.
    static let forbidden: Set<String> = ["static-only", "persistent-apps", "persistent-others", "autohide-immutable"]

    static func backup(_ current: (String) -> DockPrefValue?) -> SystemDockBackup {
        SystemDockBackup(entries: keys.map { SystemDockBackup.Entry(key: $0, value: current($0)) })
    }

    /// The writes that hide the Dock. Keys that already hold the target are left alone.
    static func engageWrites(_ current: (String) -> DockPrefValue?) -> [DockPrefWrite] {
        targets.compactMap { current($0.key) == $0.value ? nil : DockPrefWrite(key: $0.key, value: $0.value) }
    }

    /// The writes that put back what the backup holds, deleting keys that were absent.
    static func restoreWrites(_ backup: SystemDockBackup, _ current: (String) -> DockPrefValue?) -> [DockPrefWrite] {
        backup.entries.compactMap { entry in
            current(entry.key) == entry.value ? nil : DockPrefWrite(key: entry.key, value: entry.value)
        }
    }

    /// A shell script that waits on its standard input. The app writes `done` before it puts
    /// the Dock back itself. If the app dies first, the pipe closes with nothing written and
    /// the script restores the backup and restarts the Dock.
    static func guardianScript(_ backup: SystemDockBackup, domain: String = domain, restart: [String]) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["IFS= read -r line", "[ \"$line\" = done ] && exit 0"]
        for entry in backup.entries {
            if let value = entry.value {
                // A value with no plain form is left to the next launch, which restores everything.
                guard let arguments = value.defaultsArguments else { continue }
                lines.append((["/usr/bin/defaults", "write", domain, entry.key] + arguments).map(quote).joined(separator: " "))
            } else {
                lines.append((["/usr/bin/defaults", "delete", domain, entry.key]).map(quote).joined(separator: " ") + " 2>/dev/null")
            }
        }
        if !restart.isEmpty { lines.append(restart.map(quote).joined(separator: " ")) }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Injectable parts

protocol DockPreferenceStore: AnyObject {
    func value(for key: String) -> DockPrefValue?
    func set(_ value: DockPrefValue?, for key: String)
    /// False when the values could not be saved.
    @discardableResult func synchronize() -> Bool
}

protocol DockRestarting: AnyObject {
    func restart()
}

protocol DockBackupStore: AnyObject {
    func load() -> SystemDockBackup?
    func save(_ backup: SystemDockBackup)
    func clear()
}

protocol DockGuardian: AnyObject {
    func arm(_ backup: SystemDockBackup)
    func disarm()
}

/// A preferences domain through CFPreferences, the same store `defaults` uses.
final class CFDockPreferences: DockPreferenceStore {
    let domain: String
    init(domain: String = SystemDockPlan.domain) { self.domain = domain }

    func value(for key: String) -> DockPrefValue? {
        DockPrefValue(CFPreferencesCopyAppValue(key as CFString, domain as CFString))
    }

    func set(_ value: DockPrefValue?, for key: String) {
        CFPreferencesSetAppValue(key as CFString, value?.object as CFPropertyList?, domain as CFString)
    }

    @discardableResult func synchronize() -> Bool { CFPreferencesAppSynchronize(domain as CFString) }
}

/// `killall Dock`. launchd starts it again at once with the new values.
final class KillallRestarter: DockRestarting {
    let process: String
    init(process: String = "Dock") { self.process = process }

    func restart() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = [process]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        // killall returns in a few milliseconds. Waiting keeps a quitting app alive until it ran.
        kill.waitUntilExit()
    }
}

/// The backup and the "pending restore" flag, in the app's own defaults.
final class DefaultsBackupStore: DockBackupStore {
    static let backupKey = "ownDock.systemDock.backup"
    static let pendingKey = "ownDock.systemDock.pendingRestore"
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SystemDockBackup? {
        guard defaults.bool(forKey: Self.pendingKey), let data = defaults.data(forKey: Self.backupKey) else { return nil }
        return try? JSONDecoder().decode(SystemDockBackup.self, from: data)
    }

    func save(_ backup: SystemDockBackup) {
        guard let data = try? JSONEncoder().encode(backup) else { return }
        defaults.set(data, forKey: Self.backupKey)
        defaults.set(true, forKey: Self.pendingKey)
        defaults.synchronize()
    }

    func clear() {
        defaults.set(false, forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.backupKey)
        defaults.synchronize()
    }
}

/// A small `/bin/sh` child that puts the Dock back if the app dies without doing it. It sits
/// blocked on a pipe, so it costs nothing while it waits.
final class ShellGuardian: DockGuardian {
    let domain: String
    let restart: [String]
    private var process: Process?
    private var pipe: Pipe?

    init(domain: String = SystemDockPlan.domain, restart: [String] = ["/usr/bin/killall", "Dock"]) {
        self.domain = domain
        self.restart = restart
    }

    var armed: Bool { process?.isRunning ?? false }
    var processIdentifier: Int32? { process?.processIdentifier }

    func arm(_ backup: SystemDockBackup) {
        disarm()
        let pipe = Pipe()
        // Writing to a guardian that has gone away must not take the app down with SIGPIPE.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SystemDockPlan.guardianScript(backup, domain: domain, restart: restart)]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        // Only the write end stays here. The child has its own copy of the read end.
        try? pipe.fileHandleForReading.close()
        // The child dies with the app's launchd job, so the separate crash guard agent keeps
        // the same restore as a file. Its first two lines wait on the pipe; the file skips them.
        let script = SystemDockPlan.guardianScript(backup, domain: domain, restart: restart)
        CrashGuard.writeRestoreScript(script.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n"))
        self.process = process
        self.pipe = pipe
    }

    func disarm() {
        CrashGuard.removeRestoreScript()
        if let pipe {
            try? pipe.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        process?.waitUntilExit()
        process = nil
        pipe = nil
    }

    /// For tests: drop the pipe the way a crash would, with nothing written.
    func simulateCrash() {
        try? pipe?.fileHandleForWriting.close()
        process?.waitUntilExit()
        process = nil
        pipe = nil
    }
}

// MARK: - The controller

enum SystemDockError: Error, Equatable {
    case couldNotSave
}

/// Hides the system Dock and brings it back. Holds no state of its own beyond the stores, so
/// it can be made fresh at quit or at launch and still find what a previous run left.
@MainActor
final class SystemDockReplacer {
    let preferences: DockPreferenceStore
    let backups: DockBackupStore
    let restarter: DockRestarting
    let guardian: DockGuardian?

    init(preferences: DockPreferenceStore, backups: DockBackupStore, restarter: DockRestarting, guardian: DockGuardian?) {
        self.preferences = preferences
        self.backups = backups
        self.restarter = restarter
        self.guardian = guardian
    }

    /// True while a backup waits to be put back.
    var engaged: Bool { backups.load() != nil }

    /// Saves the current values unless a backup is already pending, then hides the Dock.
    /// A pending backup is never replaced: it holds the user's values, the current ones may be ours.
    func engage() throws {
        _ = preferences.synchronize()
        let backup: SystemDockBackup
        if let pending = backups.load() {
            backup = pending
        } else {
            backup = SystemDockPlan.backup(preferences.value(for:))
            backups.save(backup)
        }
        guardian?.arm(backup)
        let writes = SystemDockPlan.engageWrites(preferences.value(for:))
        guard !writes.isEmpty else { return }
        for write in writes { preferences.set(write.value, for: write.key) }
        guard preferences.synchronize() else {
            restore()
            throw SystemDockError.couldNotSave
        }
        restarter.restart()
    }

    /// Puts back exactly what the backup holds. Restarts the Dock only if something changed.
    /// Returns whether the Dock was restarted.
    @discardableResult func restore() -> Bool {
        guardian?.disarm()
        guard let backup = backups.load() else { return false }
        _ = preferences.synchronize()
        let writes = SystemDockPlan.restoreWrites(backup, preferences.value(for:))
        for write in writes { preferences.set(write.value, for: write.key) }
        guard preferences.synchronize() || writes.isEmpty else {
            // Keep the backup and the flag, so the next launch tries again.
            return false
        }
        backups.clear()
        guard !writes.isEmpty else { return false }
        restarter.restart()
        return true
    }

    static func live(defaults: UserDefaults = .standard) -> SystemDockReplacer {
        SystemDockReplacer(preferences: CFDockPreferences(), backups: DefaultsBackupStore(defaults),
                           restarter: KillallRestarter(), guardian: ShellGuardian())
    }
}

// MARK: - The right side of the Dock

/// What the system Dock keeps after its divider, as the Atelier Dock imports it.
enum DockOtherKind: String, Equatable, Sendable {
    case folder, stack, file
}

enum DockRightSide {
    static let stackExtension = "dockstack"

    /// Folders, stacks and files from `persistent-others`, in the Dock's order. Spacers, URLs
    /// and anything that no longer exists are left out, and each path comes once.
    static func others(_ tiles: [(type: String?, path: String?)], isFolder: (String) -> Bool?) -> [(kind: DockOtherKind, path: String)] {
        var seen = Set<String>()
        var found: [(kind: DockOtherKind, path: String)] = []
        for tile in tiles {
            guard let path = tile.path, tile.type == "directory-tile" || tile.type == "file-tile",
                  let folder = isFolder(path), seen.insert(path).inserted else { continue }
            if path.hasSuffix("." + stackExtension) { found.append((.stack, path)) }
            else if folder, !path.hasSuffix(".app") { found.append((.folder, path)) }
            else { found.append((.file, path)) }
        }
        return found
    }

    /// The bar from left to right, the way macOS lays it out: kept apps, open apps, then the
    /// right side (folders, stacks, files, then whatever must come last, like the Trash).
    /// `separator(0)` sits before the open apps, `separator(1)` before the right side.
    static func arrange<T>(kept: [T], open: [T], right: [T], separators: Bool, separator: (Int) -> T) -> [T] {
        var list = kept
        if separators, !kept.isEmpty, !open.isEmpty { list.append(separator(0)) }
        list += open
        if separators, !list.isEmpty, !right.isEmpty { list.append(separator(1)) }
        return list + right
    }

    /// Finder counts the Trash as full when it holds anything that is not hidden.
    static func trashHasItems(_ names: [String]) -> Bool {
        names.contains { !$0.hasPrefix(".") }
    }

    /// The newest `limit` paths, newest first, the order the Dock uses for a folder's stack.
    static func newest(_ entries: [(path: String, date: Date?)], limit: Int) -> [String] {
        entries.filter { !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".") }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(limit).map(\.path)
    }
}
