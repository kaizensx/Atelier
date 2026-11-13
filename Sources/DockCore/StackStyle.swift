import Foundation

// A stack's look and behaviour, shared by the macOS Dock's `.dockstack` bubbles and the
// Atelier Dock's stack tiles. Plain values only: it is saved in the document, compared
// cheaply, and every field reads with a fallback so documents from other builds still load.

public enum StackMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Liquid Glass, as the rest of the system draws it.
    case glass
    /// Liquid Glass with less frost.
    case clear
    /// A blurred material you can set the strength of.
    case frosted
    /// An opaque, tinted card.
    case solid
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum StackOpenAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case bloom, unfold, slide, zoom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bloom: "Spring Bloom"
        case .unfold: "Unfold"
        case .slide: "Slide"
        case .zoom: "Zoom from Tile"
        }
    }
}

public enum StackSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, name, added, kind, used
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .added: "Date Added"
        case .kind: "Kind"
        case .used: "Last Used"
        }
    }
}

public enum StackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apps, documents, images, media, folders, links
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "webp", "bmp", "svg", "raw", "dng", "psd"]
    static let mediaTypes: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"]

    /// What an item is, from its kind and its file extension alone, so it costs nothing.
    public static func of(_ item: StackItem, isFolder: Bool = false) -> StackKind {
        switch item.kind {
        case .app: return .apps
        case .url, .shortcut, .plugin: return .links
        case .group: return .folders
        case .file:
            let ext = (item.value as NSString).pathExtension.lowercased()
            if ext == "app" { return .apps }
            if imageTypes.contains(ext) { return .images }
            if mediaTypes.contains(ext) { return .media }
            if isFolder || ext.isEmpty { return .folders }
            return .documents
        }
    }
}

public enum StackAge: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, day, week, month, year
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: "Any Time"
        case .day: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        }
    }
    public var seconds: TimeInterval? {
        switch self {
        case .any: nil
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 31 * 86_400
        case .year: 366 * 86_400
        }
    }
}

public struct StackStyle: Codable, Hashable, Sendable {
    // Layout
    public var layout = StackLayout.grid
    /// Icon edge in points.
    public var iconSize = 62.0
    /// Grid and Honeycomb columns. 0 picks from the item count.
    public var columns = 0
    /// The whole bubble's scale.
    public var scale = 1.0

    // Bubble
    public var material = StackMaterial.glass
    /// -1 follows the dock or the wallpaper, -2 is no tint, 0 and up is a palette colour.
    public var tint = -1
    /// Frost for `.frosted`, and the blur over a background picture. 0 to 1.
    public var blur = 0.5
    public var radius = 36.0
    /// A picture behind the items. Empty is none.
    public var background = ""
    public var backgroundOpacity = 0.45
    public var animation = StackOpenAnimation.bloom

    // Opening
    public var hoverOpen = false
    /// Seconds the pointer rests on the tile before it opens.
    public var hoverDelay = 0.35

    // Content
    public var sort = StackSort.manual
    /// Empty shows every kind.
    public var kinds: [StackKind] = []
    public var age = StackAge.any
    /// 0 shows everything.
    public var limit = 0
    public var groupByKind = false

    // Items
    public var labels = true
    /// A count on groups and folders, a dot on running apps.
    public var badges = true
    /// Folders inside open in the bubble instead of in Finder.
    public var nested = true
    public var search = true
    public var keyboard = true
    /// Open With, Show in Finder and Copy Path on a secondary click.
    public var quickActions = true

    public init() {}

    public static let iconSizes: ClosedRange<Double> = 32...128
    public static let scales: ClosedRange<Double> = 0.7...1.4
    public static let radii: ClosedRange<Double> = 8...48
    public static let delays: ClosedRange<Double> = 0.1...1.5

    private enum CodingKeys: String, CodingKey {
        case layout, iconSize, columns, scale, material, tint, blur, radius, background, backgroundOpacity, animation,
             hoverOpen, hoverDelay, sort, kinds, age, limit, groupByKind, labels, badges, nested, search, keyboard,
             quickActions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StackStyle()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        layout = read(.layout, d.layout)
        iconSize = clamp(read(.iconSize, d.iconSize), Self.iconSizes)
        columns = min(max(read(.columns, d.columns), 0), 8)
        scale = clamp(read(.scale, d.scale), Self.scales)
        material = read(.material, d.material)
        tint = max(read(.tint, d.tint), -2)
        blur = clamp(read(.blur, d.blur), 0...1)
        radius = clamp(read(.radius, d.radius), Self.radii)
        background = read(.background, d.background)
        backgroundOpacity = clamp(read(.backgroundOpacity, d.backgroundOpacity), 0...1)
        animation = read(.animation, d.animation)
        hoverOpen = read(.hoverOpen, d.hoverOpen)
        hoverDelay = clamp(read(.hoverDelay, d.hoverDelay), Self.delays)
        sort = read(.sort, d.sort)
        // An unknown kind from a newer build is dropped, not the whole list.
        kinds = ((try? c.decodeIfPresent([String].self, forKey: .kinds)) ?? []).compactMap(StackKind.init(rawValue:))
        age = read(.age, d.age)
        limit = max(read(.limit, d.limit), 0)
        groupByKind = read(.groupByKind, d.groupByKind)
        labels = read(.labels, d.labels)
        badges = read(.badges, d.badges)
        nested = read(.nested, d.nested)
        search = read(.search, d.search)
        keyboard = read(.keyboard, d.keyboard)
        quickActions = read(.quickActions, d.quickActions)
    }
}

// MARK: - Content

/// What is known about one item without touching the disk again.
public struct StackFacts: Sendable {
    public var added: Date?
    public var used: Date?
    public var modified: Date?
    public var folder = false
    public init(added: Date? = nil, used: Date? = nil, modified: Date? = nil, folder: Bool = false) {
        self.added = added
        self.used = used
        self.modified = modified
        self.folder = folder
    }
}

/// One heading's worth of items. The title is empty when the stack is not grouped.
public struct StackGroup: Sendable, Equatable {
    public var title: String
    public var items: [StackItem]
    public init(title: String, items: [StackItem]) {
        self.title = title
        self.items = items
    }
}

public enum StackQuery {
    /// Filters, sorts, limits and groups, in that order. Pure, so the bubble can run it on
    /// every keystroke and the tests can run it at all.
    public static func apply(_ items: [StackItem], style: StackStyle, now: Date = Date(),
                             facts: (StackItem) -> StackFacts = { _ in StackFacts() }) -> [StackGroup] {
        let known = items.map { (item: $0, facts: facts($0)) }
        var kept = known
        if !style.kinds.isEmpty {
            let allowed = Set(style.kinds)
            kept = kept.filter { allowed.contains(StackKind.of($0.item, isFolder: $0.facts.folder)) }
        }
        if let span = style.age.seconds {
            let since = now.addingTimeInterval(-span)
            // Items with no date at all (links, Shortcuts) stay: there is nothing to judge.
            kept = kept.filter { row in
                guard let date = row.facts.modified ?? row.facts.added ?? row.facts.used else { return true }
                return date >= since
            }
        }
        // Every sort breaks ties by the original order, so items with no date stay put.
        var indexed = kept.enumerated().map { (index: $0.offset, item: $0.element.item, facts: $0.element.facts) }
        func byName(_ a: StackItem, _ b: StackItem) -> ComparisonResult { a.name.localizedStandardCompare(b.name) }
        func newer(_ a: Date?, _ b: Date?) -> ComparisonResult {
            let x = a ?? .distantPast, y = b ?? .distantPast
            return x == y ? .orderedSame : x > y ? .orderedAscending : .orderedDescending
        }
        let compare: ((index: Int, item: StackItem, facts: StackFacts), (index: Int, item: StackItem, facts: StackFacts)) -> ComparisonResult
        switch style.sort {
        case .manual: compare = { _, _ in .orderedSame }
        case .name: compare = { byName($0.item, $1.item) }
        case .added: compare = { newer($0.facts.added ?? $0.facts.modified, $1.facts.added ?? $1.facts.modified) }
        case .used: compare = { newer($0.facts.used, $1.facts.used) }
        case .kind:
            compare = { a, b in
                let ka = order(StackKind.of(a.item, isFolder: a.facts.folder)), kb = order(StackKind.of(b.item, isFolder: b.facts.folder))
                return ka == kb ? byName(a.item, b.item) : ka < kb ? .orderedAscending : .orderedDescending
            }
        }
        if style.sort != .manual {
            indexed.sort { a, b in
                let result = compare(a, b)
                return result == .orderedSame ? a.index < b.index : result == .orderedAscending
            }
        }
        kept = indexed.map { (item: $0.item, facts: $0.facts) }
        if style.limit > 0, kept.count > style.limit { kept = Array(kept.prefix(style.limit)) }
        guard style.groupByKind else { return [StackGroup(title: "", items: kept.map(\.item))] }
        var groups: [StackKind: [StackItem]] = [:]
        for row in kept { groups[StackKind.of(row.item, isFolder: row.facts.folder), default: []].append(row.item) }
        return StackKind.allCases.compactMap { kind in groups[kind].map { StackGroup(title: kind.title, items: $0) } }
    }

    private static func order(_ kind: StackKind) -> Int { StackKind.allCases.firstIndex(of: kind) ?? 0 }
}

// MARK: - Geometry

/// Where each item sits in the free-form layouts, in points from the bubble's top-left.
public struct StackPlacement: Sendable, Equatable {
    public var points: [CGPoint]
    public var size: CGSize
    /// Degrees, for layouts that lean their items.
    public var angles: [Double]
}

public enum StackGeometry {
    /// Columns for a grid of `count` items when the style leaves it to the count.
    public static func columns(_ count: Int, style: StackStyle) -> Int {
        if style.columns > 0 { return style.columns }
        return min(max(Int(Double(max(count, 1)).squareRoot().rounded(.up)), 2), 6)
    }

    /// `cell` is one item's footprint, icon and label. Arc, Spiral and Honeycomb only.
    public static func place(_ layout: StackLayout, count: Int, cell: CGSize, columns: Int) -> StackPlacement {
        guard count > 0 else { return StackPlacement(points: [], size: cell, angles: []) }
        var points: [CGPoint] = []
        var angles: [Double] = []
        points.reserveCapacity(count)
        switch layout {
        case .arc:
            // A half circle over the tile, outer rows for larger stacks.
            let perRow = 7
            for index in 0..<count {
                let row = index / perRow, inRow = min(count - row * perRow, perRow)
                let slot = index % perRow
                let radius = Double(cell.width) * (1.9 + Double(row) * 1.05)
                let t = inRow > 1 ? Double(slot) / Double(inRow - 1) : 0.5
                let angle = Double.pi * (0.92 - 0.84 * t)
                points.append(CGPoint(x: cos(angle) * radius, y: -sin(angle) * radius))
                angles.append((t - 0.5) * 50)
            }
        case .spiral:
            // A golden-angle spiral: even spacing, no rows to read.
            let golden = Double.pi * (3 - 5.0.squareRoot())
            let step = Double(max(cell.width, cell.height)) * 0.62
            for index in 0..<count {
                let r = step * (Double(index) + 0.6).squareRoot() * 1.25
                let a = Double(index) * golden
                points.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
                angles.append(0)
            }
        case .honeycomb:
            let cols = max(columns, 2)
            let w = Double(cell.width), h = Double(cell.height) * 0.86
            for index in 0..<count {
                let row = index / cols, col = index % cols
                let shift = row % 2 == 1 ? w / 2 : 0
                points.append(CGPoint(x: Double(col) * w + shift, y: Double(row) * h))
                angles.append(0)
            }
        default:
            let cols = max(columns, 1)
            for index in 0..<count {
                points.append(CGPoint(x: Double(index % cols) * Double(cell.width), y: Double(index / cols) * Double(cell.height)))
                angles.append(0)
            }
        }
        // Moved so the top-left item's frame starts at zero.
        let minX = points.map(\.x).min() ?? 0, minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0, maxY = points.map(\.y).max() ?? 0
        let shifted = points.map { CGPoint(x: $0.x - minX + cell.width / 2, y: $0.y - minY + cell.height / 2) }
        return StackPlacement(points: shifted, size: CGSize(width: maxX - minX + cell.width, height: maxY - minY + cell.height),
                              angles: angles)
    }
}

// MARK: - Section labels

/// Where a dock section's name goes: over its own tiles, not over its separator, and
/// beyond the tallest icon so it rides up and down with the magnification.
public enum SectionLabelLayout {
    public enum Edge: Sendable { case bottom, top, left, right }

    public struct Tile: Sendable {
        /// Starts a section (its separator), or ends one (a divider), or is a tile.
        public enum Role: Sendable { case section, divider, tile }
        public var role: Role
        /// Along the bar.
        public var span: ClosedRange<Double>
        /// How far the drawn icon reaches from the bar's screen edge, across the bar.
        public var reach: Double
        public init(role: Role, span: ClosedRange<Double>, reach: Double) {
            self.role = role
            self.span = span
            self.reach = reach
        }
    }

    public struct Label: Sendable, Equatable {
        /// Index of the section tile it belongs to.
        public var section: Int
        /// Centre along the bar, and the width it may take.
        public var along: Double
        public var width: Double
        /// Distance from the screen edge to the label's near side.
        public var cross: Double
    }

    /// One pass over the tiles: O(n), no allocation beyond the result.
    public static func place(_ tiles: [Tile], gap: Double = 7) -> [Label] {
        var result: [Label] = []
        var open: (index: Int, low: Double, high: Double, reach: Double, count: Int)?
        func close() {
            guard let section = open else { return }
            if section.count > 0 {
                result.append(Label(section: section.index, along: (section.low + section.high) / 2,
                                    width: section.high - section.low, cross: section.reach + gap))
            }
            open = nil
        }
        for (index, tile) in tiles.enumerated() {
            switch tile.role {
            case .section:
                close()
                open = (index, .infinity, -.infinity, 0, 0)
            case .divider:
                close()
            case .tile:
                guard var section = open else { continue }
                section.low = min(section.low, tile.span.lowerBound)
                section.high = max(section.high, tile.span.upperBound)
                section.reach = max(section.reach, tile.reach)
                section.count += 1
                open = section
            }
        }
        close()
        return result
    }
}
