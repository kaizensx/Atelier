import Foundation

// Hooks: places where a plugin plugs into Atelier's own features — the Command palette, the
// menu bar, its Dock tile's menu and drops, Stacks, live activities, Scenes and small HTML
// panels. Like the rest of the bridge, everything a script sends here is plain JSON, decoded
// and bounded before Atelier acts on it. Functions never cross: the prelude swaps each one for
// an action key, and Atelier calls the key back.

// MARK: - Menus

/// A menu a plugin describes: for its menu bar item or its Dock tile.
public indirect enum PluginMenuEntry: Equatable, Sendable {
    case item(PluginMenuItem)
    case separator
    case submenu(title: String, symbol: String?, items: [PluginMenuEntry])

    public static let maxItems = 40
    /// A menu and one level of submenus.
    public static let maxDepth = 2
    public static let maxTitle = 80

    public static func parse(_ value: JSONValue?, path: String) throws(PluginFailure) -> [PluginMenuEntry] {
        guard let value, !value.isNull else { return [] }
        guard let list = value.array else { throw .invalid("\(path): a menu is a list of items.") }
        var budget = maxItems
        return try parse(list, depth: 1, path: path, budget: &budget)
    }

    private static func parse(_ list: [JSONValue], depth: Int, path: String, budget: inout Int) throws(PluginFailure) -> [PluginMenuEntry] {
        var out: [PluginMenuEntry] = []
        for (index, entry) in list.enumerated() {
            budget -= 1
            guard budget >= 0 else { throw .invalid("\(path): a menu may hold at most \(maxItems) items in all.") }
            let here = "\(path)[\(index)]"
            if entry.string == "separator" || entry.string == "-" { out.append(.separator); continue }
            guard let object = entry.object else { throw .invalid("\(here): a menu item is an object or \"separator\".") }
            let title = String(PluginNode.text(object["title"]).prefix(maxTitle))
            guard !title.isEmpty else { throw .invalid("\(here): a menu item needs a title.") }
            let symbol = try PluginHookCheck.symbol(object["symbol"], here)
            if let children = object["submenu"] {
                guard depth < maxDepth else { throw .invalid("\(here): menus nest at most \(maxDepth) deep.") }
                guard let items = children.array else { throw .invalid("\(here): submenu is a list of items.") }
                out.append(.submenu(title: title, symbol: symbol,
                                    items: try parse(items, depth: depth + 1, path: here + ".submenu", budget: &budget)))
            } else {
                out.append(.item(PluginMenuItem(title: title, symbol: symbol, action: try PluginHookCheck.action(object["action"], here),
                                                checked: object["checked"]?.bool ?? false, enabled: object["enabled"]?.bool ?? true)))
            }
        }
        return out
    }

    /// Every entry, submenus included.
    public static func count(_ entries: [PluginMenuEntry]) -> Int {
        entries.reduce(0) { total, entry in
            if case .submenu(_, _, let items) = entry { return total + 1 + count(items) }
            return total + 1
        }
    }
}

public struct PluginMenuItem: Equatable, Sendable {
    public var title: String
    public var symbol: String?
    /// The key Atelier calls back when the item is chosen. Nil for an item that only shows.
    public var action: String?
    public var checked: Bool
    public var enabled: Bool
}

// MARK: - Results (palette rows and stack items)

public struct PluginResultItem: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    /// A PNG or JPEG inside the plugin's own folder, by relative path.
    public var image: String?
    public var action: String?

    public init(title: String, subtitle: String? = nil, symbol: String? = nil, image: String? = nil, action: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.image = image; self.action = action
    }

    /// Rows a plugin answered with. Rows without a title are skipped, never the whole answer.
    public static func parse(_ value: JSONValue?, limit: Int) -> [PluginResultItem] {
        guard let list = value?.array else { return [] }
        var out: [PluginResultItem] = []
        for entry in list where out.count < limit {
            guard let object = entry.object else {
                if let text = entry.string, !text.isEmpty { out.append(PluginResultItem(title: String(text.prefix(120)))) }
                continue
            }
            let title = PluginNode.text(object["title"])
            guard !title.isEmpty else { continue }
            let image = object["image"]?.string.flatMap { path -> String? in
                let lower = path.lowercased()
                guard ThemeIdentifier.isSafeRelativePath(path), lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { return nil }
                return path
            }
            out.append(PluginResultItem(
                title: String(title.prefix(120)),
                subtitle: object["subtitle"].map(PluginNode.text).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
                symbol: object["symbol"]?.string.flatMap { PluginNode.isSymbolName($0) ? $0 : nil },
                image: image,
                action: (try? PluginHookCheck.action(object["action"], "")) ?? nil))
        }
        return out
    }
}

// MARK: - Registrations

public struct PluginPaletteSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    /// Lowercase, without spaces. With one, the provider is asked only when the query starts
    /// with it and a space (`gh atelier`), and gets the rest (`atelier`).
    public var prefix: String?

    public static let maxResults = 20

    /// What this provider is asked for `query`, or nil when it is not asked at all.
    public func query(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let prefix else { return trimmed.isEmpty ? nil : trimmed }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix(prefix + " ") else { return nil }
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

public struct PluginMenuBarSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    /// Shown beside the symbol in the menu bar.
    public var text: String?
    public var menu: [PluginMenuEntry]

    public static let maxPerPlugin = 2
    public static let maxText = 16
}

public enum PluginDropKind: String, Sendable, CaseIterable {
    case url, text
}

/// The extras a Dock tile may have beyond what it draws: a menu, and what can be dropped on it.
public struct PluginTileHooks: Equatable, Sendable {
    public var id: String
    public var menu: [PluginMenuEntry]
    public var accepts: Set<PluginDropKind>

    /// A dropped URL or text is handed over up to this size. Files never are.
    public static let maxDropBytes = 8 * 1024
}

public struct PluginStackSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    /// Seconds a fetched list stays fresh. 0 asks again every time the stack opens.
    public var refresh: Double

    public static let maxItems = 60
    public static let maxPerPlugin = 4
}

public struct PluginActivitySpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var text: String
    public var progress: Double?
    public var tint: PluginColor?
    /// When it ends by itself.
    public var until: Date?

    public static let maxShown = 3
    public static let maxText = 60
}

public struct PluginPanelSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var width: Double
    public var height: Double
    public var html: String
    public var resizable: Bool

    public static let maxHTMLBytes = 512 * 1024
    public static let maxMessageBytes = 64 * 1024
    public static let maxPerPlugin = 4
    public static let widths: ClosedRange<Double> = 200...1200
    public static let heights: ClosedRange<Double> = 120...900
}

// MARK: - Messages

public enum PluginHookMessage: Equatable, Sendable {
    case palette(PluginPaletteSpec)
    case menuBar(PluginMenuBarSpec)
    case menuBarRemove(id: String)
    case tileHooks(PluginTileHooks)
    case stack(PluginStackSpec)
    /// `refresh()` on a stack provider: the next opening asks again.
    case stackChanged(id: String)
    case activity(PluginActivitySpec)
    case activityEnd(id: String)
    case panel(PluginPanelSpec)
    case panelShow(id: String)
    case panelHide(id: String)
    case panelPost(id: String, message: JSONValue)
    case scenesList(request: Int)
    case scenesApply(request: Int, name: String)
    /// A plugin's answer to `__atelier.ask`: palette rows or stack items.
    case reply(request: Int, ok: Bool, value: JSONValue, error: String?)

    public static let kinds: Set<String> = [
        "palette", "menuBar", "menuBarRemove", "tileHooks", "stack", "stackChanged", "activity", "activityEnd",
        "panel", "panelShow", "panelHide", "panelPost", "scenes.list", "scenes.apply", "hooks.reply",
    ]

    public static func handles(_ kind: String) -> Bool { kinds.contains(kind) }

    /// The permission a call needs, beyond the plugin being on.
    public var permission: PluginPermission? {
        switch self {
        case .menuBar, .menuBarRemove: .menuBar
        case .activity, .activityEnd: .liveActivities
        case .panel, .panelShow, .panelHide, .panelPost: .panels
        case .scenesList, .scenesApply: .scenes
        case .palette, .tileHooks, .stack, .stackChanged, .reply: nil
        }
    }

    public static func decode(kind: String, payload: String) throws(PluginFailure) -> PluginHookMessage {
        // A panel carries its page, so it may be larger than other calls; its html is checked below.
        let limit = kind == "panel" ? 3 * PluginPanelSpec.maxHTMLBytes : 256 * 1024
        guard payload.utf8.count <= limit else { throw .invalid("\(kind): the message was larger than \(limit / 1024) KB.") }
        let value: JSONValue
        do { value = try JSONValue.parse(payload) } catch { throw .invalid("\(kind): the message was not valid JSON.") }
        return try decode(kind: kind, value)
    }

    public static func decode(kind: String, _ value: JSONValue) throws(PluginFailure) -> PluginHookMessage {
        func id() throws(PluginFailure) -> String { try PluginHookCheck.id(value["id"], kind) }
        func title(_ fallback: String) -> String {
            let text = PluginNode.text(value["title"])
            return String((text.isEmpty ? fallback : text).prefix(60))
        }
        func request() throws(PluginFailure) -> Int {
            guard let number = value["request"]?.number, number.isFinite, number >= 0, number < 1e12 else {
                throw .invalid("\(kind): bad arguments.")
            }
            return Int(number)
        }
        switch kind {
        case "palette":
            let id = try id()
            var prefix: String?
            if let text = value["prefix"]?.string, !text.isEmpty {
                let lower = text.lowercased()
                guard (1...12).contains(lower.count), lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/!?#@".contains($0)) }) else {
                    throw .invalid("paletteProvider: a prefix is 1 to 12 letters or digits, like \"gh\".")
                }
                prefix = lower
            }
            return .palette(PluginPaletteSpec(id: id, title: title(id), prefix: prefix))
        case "menuBar":
            let id = try id()
            let symbol = try PluginHookCheck.symbol(value["symbol"], "menuBarItem")
            let text = value["text"].map(PluginNode.text).flatMap { $0.isEmpty ? nil : String($0.prefix(PluginMenuBarSpec.maxText)) }
            guard symbol != nil || text != nil else { throw .invalid("menuBarItem: give it a symbol, a text or both.") }
            return .menuBar(PluginMenuBarSpec(id: id, title: title(id), symbol: symbol, text: text,
                                              menu: try PluginMenuEntry.parse(value["menu"], path: "menuBarItem.menu")))
        case "menuBarRemove": return .menuBarRemove(id: try id())
        case "tileHooks":
            let id = try id()
            var accepts = Set<PluginDropKind>()
            for item in value["accepts"]?.array ?? [] {
                guard let name = item.string, let kind = PluginDropKind(rawValue: name) else {
                    throw .invalid("dockTile: accepts is a list of \"url\" and \"text\". Files are never handed to plugins.")
                }
                accepts.insert(kind)
            }
            return .tileHooks(PluginTileHooks(id: id, menu: try PluginMenuEntry.parse(value["menu"], path: "dockTile.menu"), accepts: accepts))
        case "stack":
            let id = try id()
            return .stack(PluginStackSpec(id: id, title: title(id), symbol: try PluginHookCheck.symbol(value["symbol"], "stackProvider") ?? "square.stack.3d.up",
                                          refresh: PluginNode.clamp(value["refresh"]?.number ?? 0, 0...86_400)))
        case "stackChanged": return .stackChanged(id: try id())
        case "activity":
            let id = try id()
            var until: Date?
            if let ms = value["until"]?.number, ms.isFinite { until = Date(timeIntervalSince1970: ms / 1000) }
            else if let text = value["until"]?.string { until = ISO8601DateFormatter().date(from: text) ?? PluginHookCheck.fractional(text) }
            return .activity(PluginActivitySpec(
                id: id, title: title(id), symbol: try PluginHookCheck.symbol(value["symbol"], "liveActivity") ?? "bolt.fill",
                text: String(PluginNode.text(value["text"]).prefix(PluginActivitySpec.maxText)),
                progress: value["progress"]?.number.map { PluginNode.clamp($0, 0...1) }, tint: PluginColor(value["tint"]), until: until))
        case "activityEnd": return .activityEnd(id: try id())
        case "panel":
            let id = try id()
            guard let html = value["html"]?.string else { throw .invalid("panel: html is required, as a string.") }
            guard html.utf8.count <= PluginPanelSpec.maxHTMLBytes else { throw .invalid("panel: html may be at most 512 KB.") }
            return .panel(PluginPanelSpec(id: id, title: title(id),
                                          width: PluginNode.clamp(value["width"]?.number ?? 420, PluginPanelSpec.widths),
                                          height: PluginNode.clamp(value["height"]?.number ?? 320, PluginPanelSpec.heights),
                                          html: html, resizable: value["resizable"]?.bool ?? false))
        case "panelShow": return .panelShow(id: try id())
        case "panelHide": return .panelHide(id: try id())
        case "panelPost":
            let id = try id()
            let message = value["message"] ?? .null
            guard message.text().utf8.count <= PluginPanelSpec.maxMessageBytes else { throw .invalid("panel.post: a message may be at most 64 KB of JSON.") }
            return .panelPost(id: id, message: message)
        case "scenes.list": return .scenesList(request: try request())
        case "scenes.apply":
            let request = try request()
            guard let name = value["name"]?.string, (1...120).contains(name.count) else { throw .invalid("scenes.apply: pass a Scene's name.") }
            return .scenesApply(request: request, name: name)
        case "hooks.reply":
            return .reply(request: try request(), ok: value["ok"]?.bool ?? false, value: value["value"] ?? .null,
                          error: value["error"]?.string.map { String($0.prefix(300)) })
        default:
            throw .invalid("Unknown call \"\(kind)\".")
        }
    }
}

/// Per-plugin counts, kept by the runtime, so a plugin hears "too many" at the call that
/// asked for one more.
public struct PluginHookLimits: Sendable {
    public static let maxPalettes = 4
    private var palettes = Set<String>(), menuBars = Set<String>(), stacks = Set<String>()
    private var panels = Set<String>()

    public init() {}

    /// Nil when the call may go ahead, or the reason it may not.
    public mutating func admit(_ message: PluginHookMessage) -> String? {
        func add(_ id: String, to set: inout Set<String>, max: Int, _ what: String) -> String? {
            if set.contains(id) { return nil }
            guard set.count < max else { return "A plugin may have at most \(max) \(what)." }
            set.insert(id)
            return nil
        }
        switch message {
        case .palette(let spec): return add(spec.id, to: &palettes, max: Self.maxPalettes, "palette providers")
        case .menuBar(let spec): return add(spec.id, to: &menuBars, max: PluginMenuBarSpec.maxPerPlugin, "menu bar items")
        case .menuBarRemove(let id): menuBars.remove(id)
        case .stack(let spec): return add(spec.id, to: &stacks, max: PluginStackSpec.maxPerPlugin, "stack providers")
        // Live activities can end by themselves, so Atelier counts those where it shows them.
        case .panel(let spec): return add(spec.id, to: &panels, max: PluginPanelSpec.maxPerPlugin, "panels")
        default: break
        }
        return nil
    }
}

/// Small checks shared by the hook decoders.
public enum PluginHookCheck {
    static func id(_ value: JSONValue?, _ kind: String) throws(PluginFailure) -> String {
        guard let id = value?.string, (1...64).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw .invalid("\(kind): an id of letters, digits, - _ or . is required, up to 64 characters.")
        }
        return id
    }

    static func symbol(_ value: JSONValue?, _ path: String) throws(PluginFailure) -> String? {
        guard let value, !value.isNull else { return nil }
        guard let name = value.string, PluginNode.isSymbolName(name) else {
            throw .invalid("\(path): \"\(PluginNode.text(value))\" is not an SF Symbol name.")
        }
        return name
    }

    /// Action keys are made by the prelude: `action:<owner>:<n>`.
    static func action(_ value: JSONValue?, _ path: String) throws(PluginFailure) -> String? {
        guard let value, !value.isNull else { return nil }
        guard let key = value.string, isActionKey(key) else { throw .invalid("\(path): action must be a function.") }
        return key
    }

    public static func isActionKey(_ key: String) -> Bool {
        key.hasPrefix("action:") && (8...200).contains(key.count)
            && key.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "\"" && $0 != "\\" }
    }

    static func fractional(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// What a drop hands to a plugin: a web link or a line of text, never a file. Nil when the
    /// tile does not take it.
    public static func dropValue(url: String?, text: String?, fileCount: Int, accepts: Set<PluginDropKind>) -> (PluginDropKind, String)? {
        guard fileCount == 0 else { return nil }
        if accepts.contains(.url), let url, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme), url.utf8.count <= PluginTileHooks.maxDropBytes {
            return (.url, url)
        }
        if accepts.contains(.text), let text = text ?? url, !text.isEmpty, text.utf8.count <= PluginTileHooks.maxDropBytes,
           !text.lowercased().hasPrefix("file:") {
            return (.text, text)
        }
        return nil
    }
}

/// What a plugin's stack item carries inside a `StackItem` while its stack is open: the plugin,
/// the action to call back, and how to draw it. Fields are joined by the unit separator, which
/// none of them may contain.
public struct PluginStackValue: Equatable, Sendable {
    public var plugin: String
    public var action: String?
    public var symbol: String?
    /// An absolute path inside the plugin's folder, already checked.
    public var imagePath: String?

    public init(plugin: String, action: String?, symbol: String?, imagePath: String?) {
        self.plugin = plugin; self.action = action; self.symbol = symbol; self.imagePath = imagePath
    }

    static let separator: Character = "\u{1F}"

    public var encoded: String {
        [plugin, action ?? "", symbol ?? "", imagePath ?? ""].map { $0.filter { $0 != Self.separator } }
            .joined(separator: String(Self.separator))
    }

    public init?(_ text: String) {
        let parts = text.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !parts[0].isEmpty else { return nil }
        plugin = parts[0]
        action = parts[1].isEmpty ? nil : parts[1]
        symbol = parts[2].isEmpty ? nil : parts[2]
        imagePath = parts[3].isEmpty ? nil : parts[3]
    }
}

/// The Atelier Dock keeps a plugin's tile or stack as a tile whose path names it:
/// `atelier:plugin:tile:<plugin>/<id>` or `atelier:plugin:stack:<plugin>/<id>`.
public enum PluginDockPath {
    public enum Role: String, Sendable { case tile, stack }
    public static let prefix = "atelier:plugin:"

    public static func make(_ role: Role, key: String) -> String { prefix + role.rawValue + ":" + key }

    /// The role and the `plugin/id` key, from a tile's path.
    public static func parse(_ path: String) -> (role: Role, key: String)? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), let role = Role(rawValue: String(rest[..<colon])) else { return nil }
        let key = String(rest[rest.index(after: colon)...])
        guard key.contains("/"), !key.hasPrefix("/"), !key.hasSuffix("/") else { return nil }
        return (role, key)
    }
}
