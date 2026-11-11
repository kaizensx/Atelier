import DockCore
import Foundation

// The settings behind the unified Dock chapter: sections, per-tile options, smart stacks and
// the dock-wide preferences that the Atelier Dock gained with it. Plain values only, so they
// can be saved, put in a profile and compared cheaply.

// MARK: - Sections

/// A group of tiles the user named, like Work, Design or Media.
struct DockSection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
}

// MARK: - Tile options

/// Folders and stacks share one set of layouts. The old four (grid, fan, list, carousel)
/// keep their saved names.
typealias DockStackLayout = StackLayout

enum DockSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case added, modified, created, name, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: "Date Added"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .name: "Name"
        case .kind: "Kind"
        }
    }
}

enum DockTileSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, regular, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: Double {
        switch self {
        case .small: 0.78
        case .regular: 1
        case .large: 1.22
        }
    }
}

enum DockTileLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, glass, accent, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var face: DockFace.Style {
        switch self {
        case .standard: .standard
        case .glass: .glass
        case .accent: .accent
        case .dark: .dark
        }
    }
}

enum DockClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// What the tile does on its own.
    case standard
    /// Opens a web address or any URL.
    case url
    /// Opens another app.
    case app
    /// Shows the item in Finder.
    case finder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .url: "Open a URL"
        case .app: "Open an App"
        case .finder: "Show in Finder"
        }
    }
}

enum DockClockHours: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, twelve, twentyFour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .twelve: "12-hour"
        case .twentyFour: "24-hour"
        }
    }
}

enum DockBatteryShows: String, Codable, CaseIterable, Identifiable, Sendable {
    case percent, time, ring
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: "Percent"
        case .time: "Time Left"
        case .ring: "Ring"
        }
    }
}

enum DockFolderLook: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The folder's own icon.
    case folder
    /// Its newest items, fanned, like the macOS Dock's Stack display.
    case stack
    var id: String { rawValue }
    var title: String { self == .folder ? "Folder" : "Stack" }
}

/// Everything one tile can be set to. Only the fields that fit the tile's kind are shown.
struct DockTileOptions: Codable, Equatable, Sendable {
    var size = DockTileSize.regular
    var look = DockTileLook.standard
    /// The name in small type under the icon.
    var caption = false
    var click = DockClickAction.standard
    /// The URL or app path for `click`.
    var target = ""

    // Clock
    var hours = DockClockHours.system
    var seconds = false
    var date = true
    var analog = false

    // Battery
    var battery = DockBatteryShows.percent

    // Folders, Downloads and stacks
    var sort = DockSort.added
    /// Nil: a stack's own layout, Grid for a folder.
    var layout: DockStackLayout?
    var folderLook = DockFolderLook.folder
    var openOnHover = false
    /// A stack's or a folder's item count, as a badge.
    var badge = false

    // Downloads
    var ring = true
    var count = true

    // Apps
    /// Launch arguments, used when the app is opened from the dock.
    var arguments = ""
    /// A URL the app opens when its tile is clicked.
    var url = ""
    /// The app's own menu commands in its right-click menu.
    var quickActions = true

    init() {}

    var isDefault: Bool { self == DockTileOptions() }

    var face: DockFace {
        var face = DockFace()
        face.style = look.face
        face.caption = caption
        face.clock = switch hours {
        case .system: .system
        case .twelve: .twelve
        case .twentyFour: .twentyFour
        }
        face.seconds = seconds
        face.date = date
        face.analog = analog
        face.battery = switch battery {
        case .percent: .percent
        case .time: .time
        case .ring: .ring
        }
        face.ring = ring
        face.count = count
        face.fanned = folderLook == .stack
        return face
    }

    private enum CodingKeys: String, CodingKey {
        case size, look, caption, click, target, hours, seconds, date, analog, battery, sort, layout, folderLook,
             openOnHover, badge, ring, count, arguments, url, quickActions
    }

    // Every field is optional when reading, so options saved by another build still load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockTileOptions()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        size = read(.size, d.size)
        look = read(.look, d.look)
        caption = read(.caption, d.caption)
        click = read(.click, d.click)
        target = read(.target, d.target)
        hours = read(.hours, d.hours)
        seconds = read(.seconds, d.seconds)
        date = read(.date, d.date)
        analog = read(.analog, d.analog)
        battery = read(.battery, d.battery)
        sort = read(.sort, d.sort)
        layout = read(.layout, nil as DockStackLayout?)
        folderLook = read(.folderLook, d.folderLook)
        openOnHover = read(.openOnHover, d.openOnHover)
        badge = read(.badge, d.badge)
        ring = read(.ring, d.ring)
        count = read(.count, d.count)
        arguments = read(.arguments, d.arguments)
        url = read(.url, d.url)
        quickActions = read(.quickActions, d.quickActions)
    }
}

// MARK: - Smart stacks

/// One list of sources for every Smart Stack, in either dock.
typealias DockSmartSource = StackSource

/// An Atelier Dock Smart Stack: it fills itself each time it opens. A `.dockstack` in the
/// macOS Dock keeps the same three things (source, style, icon) in its document.
struct DockSmartStack: Codable, Equatable, Sendable {
    var name: String
    var source: DockSmartSource
    /// For `.folder`.
    var folder = ""
    /// For `.spotlight`: words, `kind:image`, `modified:week` and the like, or a raw query.
    var query = ""
    var style = StackStyle()
    /// Nil draws the source's symbol.
    var icon: IconSpec?

    init(name: String, source: DockSmartSource) {
        self.name = name
        self.source = source
    }

    var smart: StackSmart {
        var smart = StackSmart(source: source)
        smart.folder = folder
        smart.query = query
        return smart
    }

    /// How many items to read. A style with no limit still stops somewhere.
    var fetchLimit: Int { style.limit > 0 ? style.limit : 60 }

    /// How a folder is read from disk, from the style's sort.
    var folderSort: DockSort {
        switch style.sort {
        case .name: .name
        case .kind: .kind
        default: .added
        }
    }

    private enum CodingKeys: String, CodingKey { case name, source, folder, query, style, icon, limit, sort }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Smart Stack"
        source = (try? c.decode(DockSmartSource.self, forKey: .source)) ?? .recentApps
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? ""
        icon = try? c.decodeIfPresent(IconSpec.self, forKey: .icon)
        if let style = try? c.decodeIfPresent(StackStyle.self, forKey: .style) {
            self.style = style
        } else {
            // Saved before styles: the old limit and sort move in.
            style.limit = min(max((try? c.decodeIfPresent(Int.self, forKey: .limit)) ?? 24, 4), 60)
            style.sort = switch (try? c.decodeIfPresent(DockSort.self, forKey: .sort)) ?? .added {
            case .name: .name
            case .kind: .kind
            default: .added
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(folder, forKey: .folder)
        try c.encode(query, forKey: .query)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(icon, forKey: .icon)
    }
}

/// Spotlight queries from a few friendly words. `kind:image modified:week trip` becomes
/// images changed this week whose name has "trip" in it. Anything with `==`, `<` or `>` is
/// taken as a raw Spotlight query and passed on as it is.
enum DockSpotlightQuery {
    static func make(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("==") || trimmed.contains(">") || trimmed.contains("<") { return trimmed }
        var parts: [String] = []
        let words = trimmed.lowercased().split(separator: " ").map(String.init)
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("kind:"), let type = kinds[String(word.dropFirst(5))] {
                parts.append("kMDItemContentTypeTree == \"\(type)\"")
            } else if word.hasPrefix("modified:") || word.hasPrefix("created:"),
                      let span = spans[String(word.drop { $0 != ":" }.dropFirst())] {
                let key = word.hasPrefix("modified:") ? "kMDItemContentModificationDate" : "kMDItemContentCreationDate"
                parts.append("\(key) >= $time.\(span)")
            } else if word == "modified" || word == "created", index + 1 < words.count {
                // "modified this week", "modified today"
                var phrase = words[index + 1]
                if phrase == "this", index + 2 < words.count { phrase = words[index + 2]; index += 1 }
                if let span = spans[phrase] {
                    let key = word == "modified" ? "kMDItemContentModificationDate" : "kMDItemContentCreationDate"
                    parts.append("\(key) >= $time.\(span)")
                    index += 1
                } else {
                    parts.append(name(word))
                }
            } else if !word.isEmpty {
                parts.append(name(word))
            }
            index += 1
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    private static func name(_ word: String) -> String {
        let safe = word.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
        return "kMDItemDisplayName == \"*\(safe)*\"cd"
    }

    static let kinds: [String: String] = [
        "image": "public.image", "images": "public.image", "photo": "public.image",
        "movie": "public.movie", "video": "public.movie", "audio": "public.audio", "music": "public.audio",
        "pdf": "com.adobe.pdf", "text": "public.text", "document": "public.content", "app": "com.apple.application",
        "folder": "public.folder", "archive": "public.archive", "presentation": "public.presentation",
        "spreadsheet": "public.spreadsheet", "code": "public.source-code",
    ]

    static let spans: [String: String] = [
        "today": "today", "day": "today", "yesterday": "yesterday", "week": "this_week",
        "month": "this_month", "year": "this_year",
    ]
}

// MARK: - Dock-wide preferences

enum DockHideSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
    case slow, normal, fast, instant
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var stiffness: Double {
        switch self {
        case .slow: 70
        case .normal: 170
        case .fast: 360
        case .instant: 0
        }
    }
}

/// What a dock shortcut does.
enum DockHubAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case focusDock, toggleDock, showOrbit, arrange, autoHide, magnify, focusMode, nextProfile, profile1, profile2, profile3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .focusDock: "Focus the Dock"
        case .toggleDock: "Show or Hide the Dock"
        case .showOrbit: "Open Orbit"
        case .arrange: "Arrange Dock"
        case .autoHide: "Turn Auto-hide On or Off"
        case .magnify: "Turn Magnification On or Off"
        case .focusMode: "Turn Focus Mode On or Off"
        case .nextProfile: "Next Profile"
        case .profile1: "Profile 1"
        case .profile2: "Profile 2"
        case .profile3: "Profile 3"
        }
    }
    var detail: String? {
        switch self {
        case .focusDock: "Arrows move, typing finds an app, Return opens it, Esc lets go."
        case .toggleDock: "Works while the dock is off, too."
        case .nextProfile: "Goes through your saved profiles in order."
        default: nil
        }
    }
}

struct DockHubPrefs: Codable, Equatable, Sendable {
    /// Live Peek shows a still picture of each window. Needs Screen Recording.
    var windowPreviews = true
    var sectionStyle = DockSectionStyle.label
    /// Apps other than the one in front fade back.
    var focusMode = false
    var focusDim = 0.55
    /// Seconds the pointer rests on the edge before a hidden dock comes back.
    var revealDelay = 0.08
    /// Seconds after the pointer leaves before the dock hides again.
    var hideDelay = 0.4
    var hideSpeed = DockHideSpeed.normal
    var allSpaces = true
    var fullScreen = false
    var shortcuts: [String: DockKeyCombo] = [:]
    /// The old one-of-four shortcut has been carried over.
    var shortcutsSeeded = false

    init() {}

    func shortcut(_ action: DockHubAction) -> DockKeyCombo? { shortcuts[action.rawValue] }

    private enum CodingKeys: String, CodingKey {
        case windowPreviews, sectionStyle, focusMode, focusDim, revealDelay, hideDelay, hideSpeed, allSpaces, fullScreen,
             shortcuts, shortcutsSeeded
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockHubPrefs()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        windowPreviews = read(.windowPreviews, d.windowPreviews)
        sectionStyle = read(.sectionStyle, d.sectionStyle)
        focusMode = read(.focusMode, d.focusMode)
        focusDim = min(max(read(.focusDim, d.focusDim), 0.15), 0.85)
        revealDelay = min(max(read(.revealDelay, d.revealDelay), 0), 2)
        hideDelay = min(max(read(.hideDelay, d.hideDelay), 0), 3)
        hideSpeed = read(.hideSpeed, d.hideSpeed)
        allSpaces = read(.allSpaces, d.allSpaces)
        fullScreen = read(.fullScreen, d.fullScreen)
        shortcuts = read(.shortcuts, d.shortcuts)
        shortcutsSeeded = read(.shortcutsSeeded, d.shortcutsSeeded)
    }
}
