import AppKit
import CoreServices
import DockCore
import SwiftUI

// What folders, stacks and smart stacks hold, read in the background and kept, so a tile can
// show its newest items or a count without the bar ever touching the disk while it draws.

@MainActor
final class DockHubContents {
    static let shared = DockHubContents()

    /// Newest item paths per tile id, front first, for fanned tiles.
    private(set) var newest: [String: [String]] = [:]
    /// Item counts per tile id, for badges.
    private(set) var counts: [String: Int] = [:]
    /// Menu commands per app, read when the pointer rests on its tile.
    private var commands: [pid_t: (list: [(ref: AXRef, title: String, keys: String)], at: Date)] = [:]
    private var reading = false
    private var again = false
    private var lastRead = Date.distantPast

    /// Called when something a tile shows has changed.
    var changed: (() -> Void)?

    struct Job: Sendable {
        var id: String
        var path: String
        var stack: Bool
        var sort: DockSort
        var fanned: Bool
        var counted: Bool
    }

    /// Reads what the fanned and counted tiles need. Throttled to once every few seconds;
    /// `force` reads at once, after a drop or a click.
    func refresh(_ items: [OwnDockItem], options: [String: DockTileOptions], force: Bool = false) {
        let jobs: [Job] = items.compactMap { item in
            guard item.kind == .folder || item.kind == .stack || item.kind == .downloads,
                  let option = options[item.id], option.folderLook == .stack || option.badge else { return nil }
            let path = item.kind == .downloads ? OwnDockFeed.downloadsFolder.path : item.path
            return Job(id: item.id, path: path, stack: item.kind == .stack, sort: option.sort,
                       fanned: option.folderLook == .stack, counted: option.badge)
        }
        let wanted = Set(jobs.map(\.id))
        if newest.keys.contains(where: { !wanted.contains($0) }) || counts.keys.contains(where: { !wanted.contains($0) }) {
            newest = newest.filter { wanted.contains($0.key) }
            counts = counts.filter { wanted.contains($0.key) }
            changed?()
        }
        guard !jobs.isEmpty else { return }
        guard !reading else { again = true; return }
        guard force || Date().timeIntervalSince(lastRead) > 5 else { return }
        reading = true
        lastRead = Date()
        Task.detached(priority: .utility) {
            var found: [String: (paths: [String], count: Int)] = [:]
            for job in jobs {
                if job.stack {
                    guard let document = try? StackStore.load(URL(fileURLWithPath: job.path)) else { continue }
                    let paths = document.items.filter { $0.kind == .app || $0.kind == .file }.map(\.value)
                    found[job.id] = (Array(paths.prefix(3)), document.items.count)
                } else if let listed = Self.list(job.path, sort: job.sort, limit: 400) {
                    found[job.id] = (Array(listed.prefix(3)), listed.count)
                }
            }
            let icons = Self.icons(for: found.values.flatMap(\.paths))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let contents = DockHubContents.shared
                    DockHubIcons.store(icons)
                    var newest: [String: [String]] = [:], counts: [String: Int] = [:]
                    for job in jobs {
                        guard let entry = found[job.id] else { continue }
                        if job.fanned { newest[job.id] = entry.paths }
                        if job.counted { counts[job.id] = entry.count }
                    }
                    contents.reading = false
                    if newest != contents.newest || counts != contents.counts {
                        contents.newest = newest
                        contents.counts = counts
                        contents.changed?()
                    }
                    if contents.again {
                        contents.again = false
                        contents.lastRead = .distantPast
                        OwnDock.shared.refreshContents()
                    }
                }
            }
        }
    }

    nonisolated private static func icons(for paths: [String]) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for path in paths where icons[path] == nil {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 64, height: 64)
            icons[path] = image
        }
        return icons
    }

    /// A folder's items, sorted. Hidden files are left out. Nil when it cannot be read.
    nonisolated static func list(_ path: String, sort: DockSort, limit: Int) -> [String]? {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey,
                                      .localizedNameKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        struct Row { var path: String; var date: Date; var name: String; var kind: String }
        let rows = entries.prefix(4000).map { entry -> Row in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let date: Date? = switch sort {
            case .added, .name, .kind: values?.addedToDirectoryDate ?? values?.contentModificationDate
            case .modified: values?.contentModificationDate
            case .created: values?.creationDate
            }
            return Row(path: entry.path, date: date ?? .distantPast, name: values?.localizedName ?? entry.lastPathComponent,
                       kind: values?.typeIdentifier ?? "")
        }
        let sorted: [Row] = switch sort {
        case .name: rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .kind: rows.sorted { $0.kind == $1.kind ? $0.date > $1.date : $0.kind < $1.kind }
        default: rows.sorted { $0.date > $1.date }
        }
        return sorted.prefix(limit).map(\.path)
    }

    // MARK: Smart stacks

    /// What a smart stack holds right now. Apps come from the catalogue Atelier keeps;
    /// folders and searches are read off the main thread.
    func items(for stack: DockSmartStack) async -> [StackItem] {
        let limit = stack.fetchLimit
        switch stack.source {
        case .recentApps:
            return Array(AppCatalog.shared.items(for: .recentlyUsed, fallback: []).prefix(limit))
        case .recentlyInstalled:
            return Array(AppCatalog.shared.items(for: .recentlyInstalled, fallback: []).prefix(limit))
        case .running:
            return Array(AppCatalog.shared.items(for: .running, fallback: []).prefix(limit))
        case .downloads, .folder:
            let path = stack.source == .downloads ? OwnDockFeed.downloadsFolder.path : stack.folder
            let sort = stack.folderSort
            guard !path.isEmpty else { return [] }
            let paths = await Task.detached(priority: .userInitiated) { Self.list(path, sort: sort, limit: limit) ?? [] }.value
            return paths.map(StackItem.path)
        case .spotlight:
            guard let query = DockSpotlightQuery.make(stack.query) else { return [] }
            let paths = await Task.detached(priority: .userInitiated) { Self.spotlight(query, limit: limit) }.value
            return paths.map(StackItem.path)
        }
    }

    /// A Spotlight search, newest first. Synchronous, so it runs off the main thread, and it
    /// stops after a second however much is left.
    nonisolated static func spotlight(_ text: String, limit: Int) -> [String] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil,
                                        [kMDItemContentModificationDate] as CFArray) else { return [] }
        MDQuerySetMaxCount(query, limit * 4)
        let started = Date()
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var rows: [(path: String, date: Date)] = []
        let count = MDQueryGetResultCount(query)
        for index in 0..<count {
            if Date().timeIntervalSince(started) > 1 { break }
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let date = MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date ?? .distantPast
            rows.append((path, date))
        }
        return rows.sorted { $0.date > $1.date }.prefix(limit).map(\.path)
    }

    // MARK: Menu commands

    func cachedCommands(_ pid: pid_t) -> [(ref: AXRef, title: String, keys: String)]? {
        guard let entry = commands[pid], Date().timeIntervalSince(entry.at) < 60 else { return nil }
        return entry.list
    }

    /// Reads an app's menu commands in the background, if they are not fresh.
    func prefetchCommands(_ pid: pid_t) {
        guard AXIsProcessTrusted(), cachedCommands(pid) == nil else { return }
        commands[pid] = ([], Date().addingTimeInterval(-55))
        Task.detached(priority: .utility) {
            let list = DockAX.menuCommands(pid)
            let box = CommandBox(list: list)
            await MainActor.run { DockHubContents.shared.commands[pid] = (box.list, Date()) }
        }
    }
}

private struct CommandBox: @unchecked Sendable {
    let list: [(ref: AXRef, title: String, keys: String)]
}

/// Icons for the items fanned on a tile, made off the main thread.
@MainActor
enum DockHubIcons {
    private static var images: [String: NSImage] = [:]

    static func store(_ found: [String: NSImage]) {
        if images.count > 300 { images.removeAll() }
        images.merge(found) { _, new in new }
    }

    static func image(_ path: String) -> NSImage? { images[path] }
}
