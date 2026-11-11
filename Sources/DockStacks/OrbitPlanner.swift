import CoreGraphics
import Foundation

// From apps, folders and options to pages of placed entries. Pure values, measured outside the app.

struct OrbitApp: Hashable, Sendable {
    var path: String
    var name: String
}

struct OrbitFolder: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var paths: [String]
}

/// Anything that can sit in orbit: one app, a folder of them, a settings pane or a file.
struct OrbitEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case app, folder, pane, file }
    var id: String
    var name: String
    var paths: [String]
    var folder: UUID?
    var kind = Kind.app
    /// For panes and files: what to open.
    var url: String?

    var isFolder: Bool { folder != nil }
    var path: String { paths.first ?? "" }

    static func app(_ app: OrbitApp) -> OrbitEntry {
        OrbitEntry(id: app.path, name: app.name, paths: [app.path], folder: nil)
    }
}

struct OrbitSlot: Identifiable, Equatable, Sendable {
    let key: String
    let entry: OrbitEntry
    let spot: OrbitSpot
    var id: String { key }
}

struct OrbitPage: Identifiable, Equatable, Sendable {
    let id: String
    let group: OrbitGroup
    let part: Int
    let slots: [OrbitSlot]
    let rings: [OrbitRing]
    /// Leading slots that are pinned favourites.
    let core: Int
    let titlePoint: CGPoint
    var title: String { part == 0 ? group.title : "\(group.title) \(part + 1)" }
    /// Items that belong to this page, favourites aside.
    var count: Int { slots.count - core }
}

/// What the system knows about each app, gathered off the main thread.
struct OrbitUsage: Sendable {
    var lastUsed: [String: Date] = [:]
    var counts: [String: Int] = [:]
    var hues: [String: OrbitRGB] = [:]
    var categories: [String: OrbitCategory] = [:]
}

enum OrbitPlanner {
    static let allGroup = OrbitGroup(id: "all", title: "All Apps", symbol: "square.grid.2x2.fill", rgb: OrbitRGB(0.55, 0.72, 1))
    static let resultsGroup = OrbitGroup(id: "results", title: "Results", symbol: "magnifyingglass", rgb: OrbitRGB(0.55, 0.72, 1))

    static func groupID(of path: String, options: OrbitOptions, usage: OrbitUsage) -> String {
        if let chosen = options.assigned[path],
           OrbitCategory(rawValue: chosen) != nil || options.customCategories.contains(where: { $0.id == chosen }) {
            return chosen
        }
        return (usage.categories[path] ?? .other).rawValue
    }

    static func pages(apps: [OrbitApp], folders: [OrbitFolder], options: OrbitOptions, usage: OrbitUsage,
                      size: CGSize) -> [OrbitPage] {
        let params = OrbitLayoutParams(options)
        let field = OrbitLayout.field(size, params)
        let hidden = Set(options.hidden)
        let visible = apps.filter { !hidden.contains($0.path) }
        let byPath = Dictionary(visible.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let foldered = Set(folders.flatMap(\.paths))

        // Favourites leave their constellation and hold the centre of every page.
        let ringStyle = params.style.centredTitle
        let favourites = options.favourites.compactMap { byPath[$0] }.filter { !foldered.contains($0.path) }
        let pinnedLimit = ringStyle ? 5 : max(OrbitLayout.capacity(params, field: field, core: 0) / 2, 1)
        let pinned = Array(favourites.prefix(pinnedLimit)).map(OrbitEntry.app)
        let pinnedPaths = Set(pinned.map(\.path))

        var groups: [String: [OrbitEntry]] = [:]
        let grouped = options.sort == .category
        for app in visible where !foldered.contains(app.path) && !pinnedPaths.contains(app.path) {
            groups[grouped ? groupID(of: app.path, options: options, usage: usage) : allGroup.id, default: []].append(.app(app))
        }
        for folder in folders {
            let members = folder.paths.compactMap { byPath[$0] }
            guard let first = members.first else { continue }
            let key = grouped ? groupID(of: first.path, options: options, usage: usage) : allGroup.id
            groups[key, default: []].append(OrbitEntry(id: "folder:\(folder.id.uuidString)", name: folder.name,
                                                       paths: members.map(\.path), folder: folder.id, kind: .folder))
        }

        let core = pinned.count
        let capacity = max(OrbitLayout.capacity(params, field: field, core: core) - core, 1)
        let order = grouped ? options.groups : [allGroup]
        var built: [OrbitPage] = []
        for group in order {
            guard let entries = groups[group.id], !entries.isEmpty else { continue }
            let ordered = sort(entries, by: options.sort, usage: usage)
            for start in stride(from: 0, to: ordered.count, by: capacity) {
                let chunk = Array(ordered[start..<min(start + capacity, ordered.count)])
                let part = start / capacity
                let id = "\(group.id)-\(part)"
                let all = pinned + chunk
                let placed = OrbitLayout.spots(count: all.count, core: core, params, field: field)
                let slots = zip(all.indices, placed.spots).map { index, spot in
                    OrbitSlot(key: index < core ? "fav:\(all[index].id)" : all[index].id, entry: all[index], spot: spot)
                }
                built.append(OrbitPage(id: id, group: group, part: part, slots: slots, rings: placed.rings, core: core,
                                       titlePoint: OrbitLayout.titlePoint(params, field: field, core: core > 0)))
            }
        }
        if built.isEmpty && !pinned.isEmpty {
            let placed = OrbitLayout.spots(count: pinned.count, core: core, params, field: field)
            let slots = zip(pinned, placed.spots).map { OrbitSlot(key: "fav:\($0.id)", entry: $0, spot: $1) }
            built = [OrbitPage(id: "fav-0", group: OrbitGroup(id: "fav", title: "Favourites", symbol: "star.fill",
                                                              rgb: OrbitRGB(1, 0.84, 0.3)),
                               part: 0, slots: slots, rings: placed.rings, core: core,
                               titlePoint: OrbitLayout.titlePoint(params, field: field, core: true))]
        }
        return built
    }

    static func recency(_ entry: OrbitEntry, _ usage: OrbitUsage) -> Date {
        entry.paths.compactMap { usage.lastUsed[$0] }.max() ?? .distantPast
    }

    static func sort(_ entries: [OrbitEntry], by sort: OrbitSort, usage: OrbitUsage) -> [OrbitEntry] {
        let byName: (OrbitEntry, OrbitEntry) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch sort {
        case .category, .recent:
            // What you use most recently stays closest to the centre.
            let keyed = entries.map { ($0, recency($0, usage)) }
            return keyed.sorted { $0.1 == $1.1 ? byName($0.0, $1.0) : $0.1 > $1.1 }.map(\.0)
        case .name:
            return entries.sorted(by: byName)
        case .mostUsed:
            let keyed = entries.map { entry in (entry, entry.paths.reduce(0) { $0 + (usage.counts[$1] ?? 0) }, recency(entry, usage)) }
            return keyed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.2 == $1.2 ? byName($0.0, $1.0) : $0.2 > $1.2) }.map(\.0)
        case .colour:
            // Greys gather at the end, the rest follow the spectrum.
            let keyed = entries.map { entry -> (OrbitEntry, Double) in
                guard let rgb = usage.hues[entry.path] else { return (entry, 3) }
                return (entry, rgb.saturation < 0.18 ? 2 + (1 - max(rgb.r, rgb.g, rgb.b)) : rgb.hue)
            }
            return keyed.sorted { $0.1 == $1.1 ? byName($0.0, $1.0) : $0.1 < $1.1 }.map(\.0)
        }
    }

    // MARK: Search

    /// Plain matching wants the letters together; fuzzy accepts them in order with gaps.
    static func score(_ query: String, in text: String, fuzzy: Bool) -> Int? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return 0 }
        let hay = text.lowercased()
        if !fuzzy {
            guard let range = hay.range(of: needle) else { return nil }
            let start = hay.distance(from: hay.startIndex, to: range.lowerBound)
            let wordStart = start == 0 || hay[hay.index(before: range.lowerBound)] == " "
            return 100 - start + (wordStart ? 40 : 0) - hay.count / 8
        }
        let letters = Array(needle.filter { !$0.isWhitespace }), chars = Array(hay)
        var score = 0, position = 0, last = -2
        for character in letters {
            guard position < chars.count, let found = chars[position...].firstIndex(of: character) else { return nil }
            score += found == last + 1 ? 8 : 1
            if found == 0 || chars[found - 1] == " " { score += 6 }
            last = found
            position = found + 1
        }
        return score - chars.count / 8
    }

    static func results(_ query: String, entries: [OrbitEntry], fuzzy: Bool, usage: OrbitUsage, limit: Int) -> [OrbitEntry] {
        let ranked = entries.compactMap { entry in score(query, in: entry.name, fuzzy: fuzzy).map { (entry, $0, recency(entry, usage)) } }
        return ranked.sorted { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
