import Foundation

public struct StackItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case app, file, url, shortcut, group }

    public var id = UUID()
    public var kind: Kind
    public var name: String
    public var value: String
    public var children: [StackItem] = []

    public init(kind: Kind, name: String, value: String = "", children: [StackItem] = []) {
        self.kind = kind
        self.name = name
        self.value = value
        self.children = children
    }

    public static func path(_ path: String) -> StackItem {
        let url = URL(fileURLWithPath: path)
        let isApp = url.pathExtension == "app"
        return StackItem(kind: isApp ? .app : .file,
                         name: isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                         value: path)
    }
}

/// How a stack's bubble lays its items out. `arc` was the curved column of the first
/// builds; documents saved then are read as `fan`, which is what that look is called now.
public enum StackLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid, fan, list, carousel, arc, spiral, honeycomb
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// The legacy content rule of a `.dockstack`. New documents keep `StackDocument.smart`.
public enum SmartRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, running, recentlyUsed, recentlyInstalled
    public var id: String { rawValue }
}

/// Where a Smart Stack's items come from. One list for both docks: the macOS Dock (a
/// `.dockstack`, or a native Spotlight folder) and the Atelier Dock.
public enum StackSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case recentApps, recentlyInstalled, running, downloads, folder, spotlight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recentApps: "Recent Apps"
        case .recentlyInstalled: "Recently Installed"
        case .running: "Running Apps"
        case .downloads: "Downloads"
        case .folder: "A Folder"
        case .spotlight: "Spotlight Search"
        }
    }
    public var symbol: String {
        switch self {
        case .recentApps: "clock.arrow.circlepath"
        case .recentlyInstalled: "sparkles"
        case .running: "play.circle"
        case .downloads: "arrow.down.circle"
        case .folder: "folder"
        case .spotlight: "magnifyingglass"
        }
    }
    /// The legacy rule this source came from, when there is one.
    public init?(rule: SmartRule) {
        switch rule {
        case .none: return nil
        case .running: self = .running
        case .recentlyUsed: self = .recentApps
        case .recentlyInstalled: self = .recentlyInstalled
        }
    }
    public var rule: SmartRule {
        switch self {
        case .running: .running
        case .recentApps: .recentlyUsed
        case .recentlyInstalled: .recentlyInstalled
        default: .none
        }
    }
}

/// What makes a stack smart: it fills itself from `source` each time it opens.
public struct StackSmart: Codable, Hashable, Sendable {
    public var source: StackSource
    /// For `.folder`.
    public var folder = ""
    /// For `.spotlight`: friendly words (`kind:image modified this week`) or a raw query.
    public var query = ""
    public init(source: StackSource) { self.source = source }

    private enum CodingKeys: String, CodingKey { case source, folder, query }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(StackSource.self, forKey: .source)) ?? .recentApps
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? ""
    }
}

public enum IconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case apps, text, symbol, image
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .apps: "Apps"
        case .text: "Text"
        case .symbol: "Symbol"
        case .image: "Image"
        }
    }
}

public struct IconSpec: Codable, Hashable, Sendable {
    public var style = IconStyle.apps
    public var text = ""
    public var symbol = "sparkles"
    public var color = 1
    /// For `.image`: a picture file, from the icon library or the user's own.
    public var image = ""
    public init() {}

    private enum CodingKeys: String, CodingKey { case style, text, symbol, color, image }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IconSpec()
        style = (try? c.decodeIfPresent(IconStyle.self, forKey: .style)) ?? d.style
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? d.text
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? d.symbol
        color = (try? c.decodeIfPresent(Int.self, forKey: .color)) ?? d.color
        image = (try? c.decodeIfPresent(String.self, forKey: .image)) ?? d.image
    }
}

public struct StackDocument: Codable, Hashable, Sendable {
    public var title: String
    public var items: [StackItem] = []
    /// Legacy: read from old documents into `style.layout`. Kept in step for old builds.
    public var layout = StackLayout.grid
    /// Legacy: read from old documents into `smart`. Kept in step for old builds.
    public var rule = SmartRule.none
    public var icon = IconSpec()
    /// Everything about how the bubble looks and behaves.
    public var style = StackStyle()
    /// Set when the stack fills itself.
    public var smart: StackSmart?
    public init(title: String) { self.title = title }

    /// The source in effect: `smart`, or the legacy rule.
    public var source: StackSource? { smart?.source ?? StackSource(rule: rule) }

    private enum CodingKeys: String, CodingKey { case title, items, layout, rule, icon, style, smart }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Stack"
        items = (try? c.decodeIfPresent([StackItem].self, forKey: .items)) ?? []
        layout = (try? c.decodeIfPresent(StackLayout.self, forKey: .layout)) ?? .grid
        rule = (try? c.decodeIfPresent(SmartRule.self, forKey: .rule)) ?? .none
        icon = (try? c.decodeIfPresent(IconSpec.self, forKey: .icon)) ?? IconSpec()
        smart = try? c.decodeIfPresent(StackSmart.self, forKey: .smart)
        if let style = try? c.decodeIfPresent(StackStyle.self, forKey: .style) {
            self.style = style
        } else {
            // A document from before styles: its layout moves in, and the old curved
            // column, saved as "arc", is what is now called Fan.
            style.layout = layout == .arc ? .fan : layout
        }
        if smart == nil, let source = StackSource(rule: rule) { smart = StackSmart(source: source) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(items, forKey: .items)
        // Old builds only know grid, arc and list.
        let legacy: StackLayout = switch style.layout {
        case .grid, .list: style.layout
        case .fan: .arc
        default: .grid
        }
        try c.encode(legacy, forKey: .layout)
        try c.encode(smart?.source.rule ?? rule, forKey: .rule)
        try c.encode(icon, forKey: .icon)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(smart, forKey: .smart)
    }
}

/// Stacks are `.dockstack` packages: the Dock shows a package's custom icon, not a plain file's.
public enum StackStore {
    public static let fileExtension = "dockstack"
    public static let manifest = "stack.json"

    public static var folder: URL {
        Support.root.appendingPathComponent("Stacks", isDirectory: true)
    }

    public static func url(forTitle title: String, in folder: URL = StackStore.folder) -> URL {
        folder.appendingPathComponent(title).appendingPathExtension(fileExtension)
    }

    public static func cleanTitle(_ title: String) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else {
            throw DockFailure("Choose a name for the stack.")
        }
        return clean
    }

    public static func load(_ url: URL) throws -> StackDocument {
        let data = try Data(contentsOf: url.appendingPathComponent(manifest))
        return try JSONDecoder().decode(StackDocument.self, from: data)
    }

    public static func save(_ document: StackDocument, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url.appendingPathComponent(manifest), options: .atomic)
        var values = URLResourceValues()
        values.hasHiddenExtension = true
        var target = url
        try? target.setResourceValues(values)
    }

    public static func list(in folder: URL = StackStore.folder) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix("." + fileExtension) }.sorted()
            .map { folder.appendingPathComponent($0) }
    }
}

/// Subsequence match: higher is better, nil is no match.
public enum Fuzzy {
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let hay = Array(text.lowercased())
        guard !needle.isEmpty else { return 0 }
        var score = 0, position = 0, last = -2
        for character in needle {
            guard let found = hay[position...].firstIndex(of: character) else { return nil }
            score += found == last + 1 ? 8 : 1
            if found == 0 || hay[found - 1] == " " { score += 6 }
            last = found
            position = found + 1
            if position > hay.count { return nil }
        }
        return score - hay.count / 8
    }
}
