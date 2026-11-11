import Foundation

public typealias Tile = [String: Any]
public typealias DockPlist = [String: Any]

public struct DockFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Pure operations on Dock tiles, so they can be tested without touching real preferences.
public enum Tiles {
    public enum Spacer: String, CaseIterable, Sendable {
        case small = "small-spacer-tile"
        case regular = "spacer-tile"
        case flexible = "flex-spacer-tile"
    }

    public static func path(of tile: Tile) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String,
              let url = URL(string: string) else { return nil }
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public static func type(of tile: Tile) -> String? { tile["tile-type"] as? String }

    public static func isSpacer(_ tile: Tile) -> Bool {
        guard let type = type(of: tile) else { return false }
        return Spacer(rawValue: type) != nil
    }

    public static func stack(path: String, label: String) -> Tile {
        [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": URL(fileURLWithPath: path).absoluteString,
                    "_CFURLStringType": 15,
                ] as [String: Any],
                "file-label": label,
            ] as [String: Any],
        ]
    }

    public static func spacer(_ kind: Spacer) -> Tile {
        ["tile-type": kind.rawValue, "tile-data": [String: Any]()]
    }

    public static func others(_ plist: DockPlist) -> [Tile] {
        plist["persistent-others"] as? [Tile] ?? []
    }

    public static func apps(_ plist: DockPlist) -> [Tile] {
        plist["persistent-apps"] as? [Tile] ?? []
    }

    /// Inserts a tile for `path`, unless one is already there.
    public static func attach(_ tile: Tile, to plist: inout DockPlist, at index: Int?) {
        guard let path = path(of: tile) else { return }
        var list = others(plist)
        guard !list.contains(where: { Self.path(of: $0) == path }) else { return }
        list.insert(tile, at: min(max(index ?? list.count, 0), list.count))
        plist["persistent-others"] = list
    }

    /// Removes the tile for `path` and returns where it was.
    @discardableResult
    public static func detach(path: String, from plist: inout DockPlist) -> Int? {
        var list = others(plist)
        let index = list.firstIndex { Self.path(of: $0) == path }
        list.removeAll { Self.path(of: $0) == path }
        plist["persistent-others"] = list
        return index
    }

    /// Full width comes from one flexible spacer at the start of the right-hand zone.
    /// The Dock silently drops flexible spacers from `persistent-apps`.
    public static func isFullWidth(_ plist: DockPlist) -> Bool {
        others(plist).contains { type(of: $0) == Spacer.flexible.rawValue }
    }

    public static func setFullWidth(_ enabled: Bool, in plist: inout DockPlist) {
        var list = others(plist)
        list.removeAll { type(of: $0) == Spacer.flexible.rawValue }
        if enabled { list.insert(spacer(.flexible), at: 0) }
        plist["persistent-others"] = list
    }

    /// A native Spotlight tile. `displayas` must be 1: as a stack it draws nothing.
    public static func smart(label: String, query: String) -> Tile {
        [
            "tile-type": "smartfolder-tile",
            "tile-data": [
                "label": label,
                "RawQuery": query,
                "RawQueryDict": [
                    "FinderFilesOnly": true,
                    "UserFilesOnly": true,
                    "SearchScopes": ["~"],
                ] as [String: Any],
                "displayas": 1,
                "showas": 2,
                "arrangement": 2,
            ] as [String: Any],
        ]
    }

    public static func smartLabels(_ plist: DockPlist) -> [String] {
        others(plist).filter { type(of: $0) == "smartfolder-tile" }
            .compactMap { ($0["tile-data"] as? [String: Any])?["label"] as? String }
    }

    public static func addSmart(label: String, query: String, to plist: inout DockPlist) {
        guard !smartLabels(plist).contains(label) else { return }
        plist["persistent-others"] = others(plist) + [smart(label: label, query: query)]
    }

    public static func removeSmart(label: String, from plist: inout DockPlist) {
        plist["persistent-others"] = others(plist).filter {
            !(type(of: $0) == "smartfolder-tile"
                && ($0["tile-data"] as? [String: Any])?["label"] as? String == label)
        }
    }

    public static func addSpacer(_ kind: Spacer, to plist: inout DockPlist) {
        plist["persistent-others"] = others(plist) + [spacer(kind)]
    }

    public static func removeSpacers(from plist: inout DockPlist) {
        plist["persistent-apps"] = apps(plist).filter { !isSpacer($0) }
        plist["persistent-others"] = others(plist).filter { !isSpacer($0) }
    }

    /// `defaults import` merges, so keys gone from `target` must be deleted separately.
    public static func keysToDelete(current: DockPlist, target: DockPlist) -> [String] {
        current.keys.filter { target[$0] == nil }.sorted()
    }
}

/// The real Dock. Every call blocks, so call from a background task.
public enum DockStore {
    private static let domain = "com.apple.dock"
    private static let settle: TimeInterval = 1.5

    @discardableResult
    private static func run(_ tool: String, _ args: [String], input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        // Nothing reads the errors: a full pipe would block the tool, and this call with it.
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DockFailure("Failed: \(URL(fileURLWithPath: tool).lastPathComponent) \(args.joined(separator: " "))")
        }
        return data
    }

    public static func plist(at url: URL) throws -> DockPlist {
        try parse(Data(contentsOf: url))
    }

    public static func read() throws -> DockPlist {
        try parse(run("/usr/bin/defaults", ["export", domain, "-"]))
    }

    private static func parse(_ data: Data) throws -> DockPlist {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? DockPlist else { throw DockFailure("Could not read the Dock preferences.") }
        return plist
    }

    private static func write(_ plist: DockPlist) throws {
        let current = try read()
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try run("/usr/bin/defaults", ["import", domain, "-"], input: data)
        for key in Tiles.keysToDelete(current: current, target: plist) {
            try run("/usr/bin/defaults", ["delete", domain, key])
        }
        restart()
    }

    public static func restart() {
        _ = try? run("/usr/bin/killall", ["Dock"])
        Thread.sleep(forTimeInterval: settle)
    }

    /// Records a snapshot, applies `change`, restarts the Dock.
    public static func update(_ label: String, change: (inout DockPlist) throws -> Void) throws {
        var plist = try read()
        try Timeline.record(plist, label: label)
        try change(&plist)
        try write(plist)
    }

    /// A snapshot may come from an older macOS: the Dock's own bookkeeping stays as it is now.
    public static func restore(_ snapshot: Snapshot) throws {
        let target = try parse(Data(contentsOf: snapshot.url))
        try update("Before going back") { $0 = DockCompat.carryingBookkeeping(current: $0, target: target) }
    }

    public static func apply(snapshotAt url: URL, label: String) throws {
        let target = try parse(Data(contentsOf: url))
        try update(label) { $0 = DockCompat.carryingBookkeeping(current: $0, target: target) }
    }

    public static func exportData() throws -> Data {
        try run("/usr/bin/defaults", ["export", domain, "-"])
    }
}

public struct Snapshot: Identifiable, Hashable, Sendable {
    public let url: URL
    public let date: Date
    public let label: String
    public var id: URL { url }
}

/// Every Dock change leaves a snapshot here.
public enum Timeline {
    private static let limit = 200

    public static var folder: URL {
        Support.root.appendingPathComponent("Timeline", isDirectory: true)
    }

    public static func record(_ plist: DockPlist, label: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let name = fileName(date: Date(), label: label)
        try data.write(to: folder.appendingPathComponent(name))
        for old in list().dropFirst(limit) { try? FileManager.default.removeItem(at: old.url) }
    }

    public static func list() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { parse(name: $0, in: folder) }.sorted { $0.date > $1.date }
    }

    static func fileName(date: Date, label: String) -> String {
        let safe = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "change"
        return "\(Int(date.timeIntervalSince1970 * 1000))-\(safe).plist"
    }

    static func parse(name: String, in folder: URL) -> Snapshot? {
        guard name.hasSuffix(".plist"), let dash = name.firstIndex(of: "-"),
              let millis = Double(name[..<dash]) else { return nil }
        let label = name[name.index(after: dash)...].dropLast(".plist".count)
        return Snapshot(url: folder.appendingPathComponent(name),
                        date: Date(timeIntervalSince1970: millis / 1000),
                        label: String(label).removingPercentEncoding ?? String(label))
    }
}

/// Plain preferences in any domain, for tweaks outside the Dock.
public enum Prefs {
    public static func isSet(_ key: String, domain: String) -> Bool {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) != nil
    }

    /// Whether the stored value is this one, not just any value.
    public static func matches(_ key: String, value: String, domain: String) -> Bool {
        guard let stored = current(key, domain: domain) else { return false }
        return same(stored, value)
    }

    /// `1`, `YES` and `true` are one value to the apps that read them; so are numbers written two ways.
    public static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            switch s.lowercased() {
            case "1", "yes", "true": return "true"
            case "0", "no", "false": return "false"
            default: return Double(s).map { String($0) } ?? s
            }
        }
        return a == b || norm(a) == norm(b)
    }

    /// The stored value in the same text form `defaults write` takes.
    public static func current(_ key: String, domain: String) -> String? {
        CFPreferencesAppSynchronize(domain as CFString)
        let stored: CFPropertyList? = domain == "NSGlobalDomain"
            ? CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            : CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        switch stored {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default: return nil
        }
    }

    public static func write(_ key: String, type: String, value: String, domain: String) throws {
        try run(["write", domain, key, "-\(type)", value])
        CFPreferencesAppSynchronize(domain as CFString)
    }

    public static func delete(_ key: String, domain: String) throws {
        try run(["delete", domain, key])
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private static func run(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DockFailure("Failed: defaults \(args.joined(separator: " "))")
        }
    }

    public static func restart(_ process: String) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = [process]
        try? kill.run()
        kill.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)
    }
}

public enum Support {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockStacks", isDirectory: true)
    }
}
