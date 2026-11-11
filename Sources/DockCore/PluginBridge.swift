import Foundation

// MARK: - Declarative views

/// A colour a plugin names: a hex string, or one of Atelier's semantic inks, which follow the
/// widget style and the theme.
public enum PluginColor: Equatable, Sendable {
    case hex(ThemeColor)
    case named(String)

    public static let names = ["primary", "secondary", "tertiary", "accent", "red", "orange", "yellow", "green", "mint", "teal", "blue", "indigo", "purple", "pink", "gray"]

    public init?(_ value: JSONValue?) {
        guard let text = value?.string else { return nil }
        if let color = ThemeColor(hex: text) { self = .hex(color) }
        else if Self.names.contains(text) { self = .named(text) }
        else { return nil }
    }
}

public struct PluginTextStyle: Equatable, Sendable {
    public enum Weight: String, Sendable, CaseIterable { case regular, medium, semibold, bold, heavy, light }
    public enum Design: String, Sendable, CaseIterable { case `default`, rounded, serif, mono }
    public var size: Double = 13
    public var weight: Weight = .regular
    public var design: Design = .default
    public var color: PluginColor?
    public var lines: Int = 2
    public init() {}
}

/// What a plugin widget shows. Plugins send plain objects; Atelier draws them natively, so a
/// plugin can never run code in the render path or draw outside its widget.
public indirect enum PluginNode: Equatable, Sendable {
    case text(String, PluginTextStyle)
    case symbol(String, PluginTextStyle)
    /// 0...1, with an optional label in the middle.
    case ring(value: Double, label: String?, color: PluginColor?, width: Double)
    case bar(value: Double, label: String?, color: PluginColor?)
    case list([Row])
    case sparkline([Double], color: PluginColor?, fill: Bool)
    case stack(Axis, spacing: Double, alignment: Alignment, [PluginNode])
    case spacer

    public enum Axis: String, Sendable { case vertical, horizontal, overlay }
    public enum Alignment: String, Sendable { case leading, center, trailing, top, bottom }

    public struct Row: Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var symbol: String?
        public var color: PluginColor?
    }

    public static let maxDepth = 8
    public static let maxNodes = 160
    public static let maxText = 400
    public static let maxPoints = 240
    public static let maxRows = 20

    /// Parses a view description. Strings and numbers on their own become text, so
    /// `view: () => "Hello"` works.
    public static func parse(_ value: JSONValue) throws(PluginFailure) -> PluginNode {
        var budget = maxNodes
        return try parse(value, depth: 0, path: "view", budget: &budget)
    }

    private static func parse(_ value: JSONValue, depth: Int, path: String, budget: inout Int) throws(PluginFailure) -> PluginNode {
        budget -= 1
        guard budget >= 0 else { throw .invalid("\(path): more than \(maxNodes) views. Show less at once.") }
        guard depth <= maxDepth else { throw .invalid("\(path): views nest more than \(maxDepth) deep.") }
        switch value {
        case .string(let text): return .text(clip(text), PluginTextStyle())
        case .number(let number): return .text(format(number), PluginTextStyle())
        case .array(let items):
            return .stack(.vertical, spacing: 6, alignment: .leading,
                          try children(items, depth: depth, path: path, budget: &budget))
        case .object(let object):
            let type = object["type"]?.string ?? "text"
            switch type {
            case "text":
                return .text(clip(text(object["text"] ?? object["value"])), style(object))
            case "symbol":
                guard let name = object["name"]?.string ?? object["symbol"]?.string, isSymbolName(name) else {
                    throw .invalid("\(path): a symbol needs a name, like \"timer\".")
                }
                var s = style(object)
                if object["size"] == nil { s.size = 18 }
                return .symbol(name, s)
            case "ring":
                return .ring(value: unit(object["value"]), label: object["label"].map(text).map(clip),
                             color: PluginColor(object["color"]), width: clamp(object["width"]?.number ?? 6, 2...14))
            case "bar":
                return .bar(value: unit(object["value"]), label: object["label"].map(text).map(clip), color: PluginColor(object["color"]))
            case "sparkline":
                let points = (object["values"]?.array ?? object["points"]?.array ?? []).compactMap(\.number).filter(\.isFinite)
                return .sparkline(Array(points.suffix(maxPoints)), color: PluginColor(object["color"]), fill: object["fill"]?.bool ?? true)
            case "list":
                let rows = (object["items"]?.array ?? []).prefix(maxRows).map { item -> Row in
                    if let title = item.string { return Row(title: clip(title)) }
                    return Row(title: clip(text(item["title"])), detail: item["detail"].map(text).map(clip),
                               symbol: item["symbol"]?.string.flatMap { isSymbolName($0) ? $0 : nil },
                               color: PluginColor(item["color"]))
                }
                return .list(Array(rows))
            case "vstack", "hstack", "zstack", "stack":
                let axis: Axis = type == "hstack" ? .horizontal : type == "zstack" ? .overlay : .vertical
                let alignment = object["align"]?.string.flatMap(Alignment.init(rawValue:)) ?? (axis == .horizontal ? .center : .leading)
                return .stack(axis, spacing: clamp(object["spacing"]?.number ?? 6, 0...40), alignment: alignment,
                              try children(object["children"]?.array ?? [], depth: depth, path: path, budget: &budget))
            case "spacer":
                return .spacer
            default:
                throw .invalid("\(path): unknown view type \"\(type)\". Use text, symbol, ring, bar, list, sparkline, vstack, hstack, zstack or spacer.")
            }
        case .bool(let flag): return .text(flag ? "true" : "false", PluginTextStyle())
        case .null: return .spacer
        }
    }

    private static func children(_ items: [JSONValue], depth: Int, path: String, budget: inout Int) throws(PluginFailure) -> [PluginNode] {
        var out: [PluginNode] = []
        for (index, item) in items.enumerated() {
            out.append(try parse(item, depth: depth + 1, path: "\(path).children[\(index)]", budget: &budget))
        }
        return out
    }

    private static func style(_ object: [String: JSONValue]) -> PluginTextStyle {
        var style = PluginTextStyle()
        if let size = object["size"]?.number { style.size = clamp(size, 8...64) }
        if let weight = object["weight"]?.string.flatMap(PluginTextStyle.Weight.init(rawValue:)) { style.weight = weight }
        if let design = object["design"]?.string.flatMap(PluginTextStyle.Design.init(rawValue:)) { style.design = design }
        style.color = PluginColor(object["color"])
        if let lines = object["lines"]?.number { style.lines = Int(clamp(lines, 1...8)) }
        return style
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .number(let number)?: format(number)
        case .bool(let flag)?: flag ? "true" : "false"
        default: ""
        }
    }

    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "–" }
        return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(format: "%.2f", number)
    }

    static func clip(_ text: String) -> String { text.count > maxText ? String(text.prefix(maxText)) + "…" : text }
    static func unit(_ value: JSONValue?) -> Double { clamp(value?.number ?? 0, 0...1) }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// SF Symbol names are lowercase words joined by dots.
    public static func isSymbolName(_ name: String) -> Bool {
        (1...80).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }
    }
}

// MARK: - Registrations

public enum PluginWidgetSize: String, Sendable, CaseIterable { case small, medium, large }

public struct PluginWidgetSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var size: PluginWidgetSize
    /// Seconds between refreshes. At least 5.
    public var refresh: Double
}

public struct PluginTileSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var text: String?
    public var badge: String?
    public var tint: PluginColor?
    public var progress: Double?
}

public struct PluginCommandSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// `cmd+shift+p` style, normalised. Nil for none.
    public var shortcut: String?
}

public struct PluginCornerSpec: Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
}

public enum PluginEvent: String, CaseIterable, Sendable {
    case appActivated, spaceChanged, wallpaperChanged, themeChanged, timer
}

/// One call from a plugin's script into Atelier, decoded and checked. Everything a script
/// sends goes through here, so the shape of the bridge is plain data that tests can cover.
public enum PluginMessage: Equatable, Sendable {
    case widget(PluginWidgetSpec)
    case widgetView(id: String, view: PluginNode)
    case widgetError(id: String, message: String)
    case tile(PluginTileSpec)
    case command(PluginCommandSpec)
    case corner(PluginCornerSpec)
    case subscribe(PluginEvent, interval: Double?)
    case notify(title: String, body: String?)
    case openURL(URL)
    case log(level: String, message: String)
    case themeApply([String: JSONValue])
    case timer(id: Int, milliseconds: Double, repeats: Bool)
    case clearTimer(id: Int)
    case http(request: Int, url: URL, headers: [String: String])
    /// Ask the owner for a line of text. Answered through `__atelier.settle`.
    case prompt(request: Int, title: String, message: String?, placeholder: String?, secure: Bool)

    public static let maxRegistrations = 24

    public static func decode(kind: String, payload: String) throws(PluginFailure) -> PluginMessage {
        guard payload.utf8.count <= 256 * 1024 else { throw .invalid("A message from the plugin was larger than 256 KB.") }
        let value: JSONValue
        do { value = try JSONValue.parse(payload) } catch { throw .invalid("A message from the plugin was not valid JSON.") }
        return try decode(kind: kind, value)
    }

    public static func decode(kind: String, _ value: JSONValue) throws(PluginFailure) -> PluginMessage {
        func id() throws(PluginFailure) -> String {
            guard let id = value["id"]?.string, (1...64).contains(id.count),
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
                throw .invalid("\(kind): an id of letters, digits, - _ or . is required, up to 64 characters.")
            }
            return id
        }
        func title(_ fallback: String) -> String {
            String((value["title"]?.string ?? fallback).prefix(60))
        }
        switch kind {
        case "widget":
            let size = value["size"]?.string.flatMap(PluginWidgetSize.init(rawValue:)) ?? .small
            let refresh = PluginNode.clamp(value["refresh"]?.number ?? 60, 5...86_400)
            let id = try id()
            return .widget(PluginWidgetSpec(id: id, title: title(id), size: size, refresh: refresh))
        case "widgetView":
            let id = try id()
            return .widgetView(id: id, view: try PluginNode.parse(value["view"] ?? .null))
        case "widgetError":
            return .widgetError(id: try id(), message: String((value["message"]?.string ?? "Unknown error").prefix(300)))
        case "tile":
            let id = try id()
            let symbol = value["symbol"]?.string ?? value["icon"]?.string
            if let symbol, !PluginNode.isSymbolName(symbol) { throw .invalid("tile: \"\(symbol)\" is not an SF Symbol name.") }
            return .tile(PluginTileSpec(
                id: id, title: title(id), symbol: symbol,
                text: value["text"].map(PluginNode.text).map { String($0.prefix(12)) },
                badge: value["badge"].flatMap { $0.isNull ? nil : PluginNode.text($0) }.map { String($0.prefix(4)) },
                tint: PluginColor(value["tint"]),
                progress: value["progress"]?.number.map { PluginNode.clamp($0, 0...1) }))
        case "command":
            let id = try id()
            guard let text = value["title"]?.string, !text.isEmpty else { throw .invalid("command: a title is required.") }
            let shortcut = try value["shortcut"]?.string.map { text throws(PluginFailure) in
                guard let normal = PluginShortcut.normalise(text) else {
                    throw .invalid("command: \"\(text)\" is not a shortcut. Use something like \"cmd+shift+p\".")
                }
                return normal
            }
            return .command(PluginCommandSpec(id: id, title: String(text.prefix(60)),
                                              subtitle: value["subtitle"]?.string.map { String($0.prefix(40)) }, shortcut: shortcut))
        case "corner":
            let id = try id()
            guard let text = value["title"]?.string, !text.isEmpty else { throw .invalid("cornerAction: a title is required.") }
            let symbol = value["symbol"]?.string.flatMap { PluginNode.isSymbolName($0) ? $0 : nil } ?? "puzzlepiece.extension"
            return .corner(PluginCornerSpec(id: id, title: String(text.prefix(40)), symbol: symbol))
        case "on":
            guard let name = value["event"]?.string, let event = PluginEvent(rawValue: name) else {
                throw .invalid("on: unknown event. Use \(PluginEvent.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let interval = event == .timer ? PluginNode.clamp(value["interval"]?.number ?? 60, 5...86_400) : nil
            return .subscribe(event, interval: interval)
        case "notify":
            guard let text = value["title"]?.string, !text.isEmpty else { throw .invalid("notify: a title is required.") }
            return .notify(title: String(text.prefix(80)), body: value["body"]?.string.map { String($0.prefix(240)) })
        case "openURL":
            guard let text = value["url"]?.string, let url = URL(string: text), PluginNetwork.canOpen(url) else {
                throw .invalid("openURL: only https, mailto and atelier://studio links can be opened.")
            }
            return .openURL(url)
        case "log":
            let level = ["log", "info", "warn", "error", "debug"].contains(value["level"]?.string ?? "") ? value["level"]!.string! : "log"
            return .log(level: level, message: String((value["message"]?.string ?? "").prefix(2000)))
        case "theme":
            guard let patch = value["patch"]?.object else { throw .invalid("theme.apply: pass an object of theme keys.") }
            return .themeApply(patch)
        case "timer":
            guard let id = value["id"]?.number, let ms = value["ms"]?.number else { throw .invalid("timer: bad arguments.") }
            return .timer(id: Int(id), milliseconds: PluginNode.clamp(ms, 0...86_400_000), repeats: value["repeat"]?.bool ?? false)
        case "clearTimer":
            guard let id = value["id"]?.number else { throw .invalid("clearTimer: bad arguments.") }
            return .clearTimer(id: Int(id))
        case "http":
            guard let request = value["request"]?.number, let text = value["url"]?.string, let url = URL(string: text) else {
                throw .invalid("http.get: pass a URL string.")
            }
            var headers: [String: String] = [:]
            for (key, item) in value["headers"]?.object ?? [:] {
                guard let text = item.string, headers.count < 16 else { continue }
                let lower = key.lowercased()
                // Plugins may say what they accept and who they are, not impersonate the browser.
                guard !["cookie", "host", "origin", "referer", "content-length", "connection"].contains(lower),
                      key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), text.count < 2048 else { continue }
                headers[key] = text
            }
            return .http(request: Int(request), url: url, headers: headers)
        case "prompt":
            guard let request = value["request"]?.number, let text = value["title"]?.string, !text.isEmpty else {
                throw .invalid("prompt: a title is required.")
            }
            return .prompt(request: Int(request), title: String(text.prefix(80)),
                           message: value["message"]?.string.map { String($0.prefix(300)) },
                           placeholder: value["placeholder"]?.string.map { String($0.prefix(80)) },
                           secure: value["secure"]?.bool ?? false)
        default:
            throw .invalid("Unknown call \"\(kind)\".")
        }
    }
}

public enum PluginShortcut {
    static let modifiers = ["cmd", "ctrl", "opt", "shift"]
    static let aliases = ["command": "cmd", "⌘": "cmd", "control": "ctrl", "⌃": "ctrl", "option": "opt", "alt": "opt", "⌥": "opt", "⇧": "shift"]

    /// `Shift+Cmd+P` becomes `cmd+shift+p`. Needs at least one of cmd, ctrl or opt.
    public static func normalise(_ text: String) -> String? {
        let parts = text.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last, key.count == 1 || ["space", "return", "tab", "escape"].contains(key) ||
              (key.hasPrefix("f") && Int(key.dropFirst()).map { (1...20).contains($0) } == true) else { return nil }
        let mods = Set(parts.dropLast().map { aliases[$0] ?? $0 })
        guard mods.isSubset(of: Set(modifiers)), !mods.intersection(["cmd", "ctrl", "opt"]).isEmpty else { return nil }
        return (modifiers.filter(mods.contains) + [key]).joined(separator: "+")
    }

    /// For menus: `⌘⇧P`.
    public static func symbols(_ normal: String) -> String {
        let map = ["ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘"]
        let parts = normal.split(separator: "+").map(String.init)
        let order = ["ctrl", "opt", "shift", "cmd"]
        return order.filter(parts.contains).compactMap { map[$0] }.joined() + (parts.last?.uppercased() ?? "")
    }
}

/// A plugin's own key-value store. JSON values only, and small: plugins keep settings here,
/// not data sets.
public struct PluginStorage: Equatable, Sendable {
    public static let maxBytes = 256 * 1024
    public static let maxKeyLength = 128
    public private(set) var values: [String: JSONValue]

    public init(values: [String: JSONValue] = [:]) { self.values = values }

    public init(data: Data) {
        values = (try? JSONValue.parse(data))?.object ?? [:]
    }

    public var data: Data { (try? JSONValue.object(values).data(pretty: false)) ?? Data("{}".utf8) }

    public mutating func set(_ key: String, _ value: JSONValue?) throws(PluginFailure) {
        guard (1...Self.maxKeyLength).contains(key.count) else { throw .invalid("storage: keys are 1 to \(Self.maxKeyLength) characters.") }
        var next = values
        next[key] = value.flatMap { $0.isNull ? nil : $0 }
        let size = (try? JSONValue.object(next).data(pretty: false).count) ?? 0
        guard size <= Self.maxBytes else { throw .invalid("storage: a plugin may keep at most \(Self.maxBytes / 1024) KB.") }
        values = next
    }
}
