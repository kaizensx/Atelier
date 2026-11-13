import Foundation

// The plugin engine's newer parts, kept apart from PluginBridge.swift so that file stays the
// core: interactive and richer views, more bridge calls, settings declared in the manifest,
// on-demand activation, messaging between plugins, localized strings, plugin assets, safe mode
// and the per-plugin resource meter. Everything here is plain data with strict validation.

// MARK: - Interactive and richer views

public struct PluginButton: Equatable, Sendable {
    public enum Style: String, Sendable, CaseIterable { case prominent, plain }
    public var title: String
    public var symbol: String?
    public var style: Style
    /// The id a tap calls back: one the plugin registered with `atelier.action`, or one the
    /// prelude made for an inline function.
    public var action: String
}

public struct PluginImage: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A file inside the plugin's own folder.
        case asset(String)
        /// An https image on a host in `network.hosts`, fetched by Atelier.
        case url(URL)
    }
    public enum Fit: String, Sendable, CaseIterable { case fit, fill }
    public var source: Source
    public var width: Double?
    public var height: Double?
    public var fit: Fit
    public var radius: Double
}

public struct PluginChart: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case bar, line, area }
    public struct Series: Equatable, Sendable {
        public var label: String
        public var values: [Double]
        public var color: PluginColor?
    }
    public var kind: Kind
    public var series: [Series]
    public var labels: [String]
    public var max: Double?

    public static let maxSeries = 8
    public static let maxValues = 120
}

public enum PluginTransition: String, Sendable, CaseIterable { case fade, slide, scale }

extension PluginNode {
    static let typeNames = "text, symbol, ring, bar, progress, list, sparkline, chart, image, button, toggle, grid, divider, vstack, hstack, zstack or spacer"

    /// Action ids: what `atelier.action` registered, or an inline function's id from the prelude.
    public static func isActionID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }
    }

    static func parseMore(type: String, _ object: [String: JSONValue], depth: Int, path: String,
                          budget: inout Int) throws(PluginFailure) -> PluginNode? {
        func action() throws(PluginFailure) -> String {
            guard let id = object["action"]?.string, isActionID(id) else {
                throw .invalid("\(path): a \(type) needs an action: a function, or an id registered with atelier.action.")
            }
            return id
        }
        switch type {
        case "button":
            let title = clip(text(object["title"] ?? object["label"]))
            let symbol = object["symbol"]?.string
            if let symbol, !isSymbolName(symbol) { throw .invalid("\(path): \"\(symbol)\" is not an SF Symbol name.") }
            guard !title.isEmpty || symbol != nil else { throw .invalid("\(path): a button needs a title or a symbol.") }
            let style = object["style"]?.string.flatMap(PluginButton.Style.init(rawValue:)) ?? .prominent
            return .button(PluginButton(title: title, symbol: symbol, style: style, action: try action()))
        case "toggle":
            return .toggle(label: clip(text(object["label"] ?? object["title"])), on: object["on"]?.bool ?? false, action: try action())
        case "image":
            let source: PluginImage.Source
            if let asset = object["asset"]?.string {
                guard PluginAssets.isValidPath(asset) else {
                    throw .invalid("\(path): \"\(asset)\" is not an image in the plugin's folder. Use a relative path to a \(PluginAssets.imageTypes.joined(separator: ", ")) file.")
                }
                source = .asset(asset)
            } else if let text = object["url"]?.string, let url = URL(string: text), url.scheme == "https", url.host() != nil {
                source = .url(url)
            } else {
                throw .invalid("\(path): an image needs an asset (a file in the plugin) or an https url.")
            }
            return .image(PluginImage(source: source, width: object["width"]?.number.map { clamp($0, 4...600) },
                                      height: object["height"]?.number.map { clamp($0, 4...600) },
                                      fit: object["fit"]?.string.flatMap(PluginImage.Fit.init(rawValue:)) ?? .fit,
                                      radius: clamp(object["radius"]?.number ?? 0, 0...60)))
        case "chart":
            let kind = object["kind"]?.string.flatMap(PluginChart.Kind.init(rawValue:)) ?? .bar
            func numbers(_ value: JSONValue?) -> [Double] {
                Array((value?.array ?? []).compactMap(\.number).filter(\.isFinite).suffix(PluginChart.maxValues))
            }
            var series: [PluginChart.Series] = []
            if let list = object["series"]?.array {
                guard list.count <= PluginChart.maxSeries else { throw .invalid("\(path): a chart shows at most \(PluginChart.maxSeries) series.") }
                series = list.map { item in
                    PluginChart.Series(label: String(text(item["label"]).prefix(40)), values: numbers(item["values"]), color: PluginColor(item["color"]))
                }
            } else {
                series = [PluginChart.Series(label: "", values: numbers(object["values"]), color: PluginColor(object["color"]))]
            }
            let labels = (object["labels"]?.array ?? []).prefix(PluginChart.maxValues).map { String(text($0).prefix(24)) }
            let max = object["max"]?.number.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return .chart(PluginChart(kind: kind, series: series, labels: Array(labels), max: max))
        case "grid":
            let columns = Int(clamp(object["columns"]?.number ?? 2, 1...6))
            return .grid(columns: columns, try children(object["children"]?.array ?? [], depth: depth, path: path, budget: &budget))
        case "progress":
            return .progress(value: unit(object["value"]), label: object["label"].map(text).map(clip), color: PluginColor(object["color"]))
        case "divider":
            return .divider
        default:
            return nil
        }
    }

    /// Every action id the tree calls, so a host can tell which taps are live.
    public var actions: [String] {
        switch self {
        case .button(let button): [button.action]
        case .toggle(_, _, let action): [action]
        case .stack(_, _, _, let children), .grid(_, let children): children.flatMap(\.actions)
        case .transition(_, let inner): inner.actions
        default: []
        }
    }

    /// Every image the tree shows.
    public var images: [PluginImage] {
        switch self {
        case .image(let image): [image]
        case .stack(_, _, _, let children), .grid(_, let children): children.flatMap(\.images)
        case .transition(_, let inner): inner.images
        default: []
        }
    }
}

/// Files a plugin ships with, such as images. Read only, inside the plugin's own folder.
public enum PluginAssets {
    public static let imageTypes = ["png", "jpg", "jpeg", "heic", "pdf"]
    public static let maxBytes = 2 * 1024 * 1024

    /// A relative path inside the plugin, to an image type Atelier draws.
    public static func isValidPath(_ path: String) -> Bool {
        ThemeIdentifier.isSafeRelativePath(path) && imageTypes.contains((path as NSString).pathExtension.lowercased())
    }

    /// Resolves `path` inside `folder`, refusing anything that leaves it (links included),
    /// is missing, or is larger than 2 MB.
    public static func resolve(_ path: String, in folder: URL) -> Result<URL, PluginFailure> {
        guard isValidPath(path) else { return .failure(.invalid("asset: \"\(path)\" is not a relative path to a \(imageTypes.joined(separator: ", ")) file.")) }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base) else { return .failure(.refused("asset: \"\(path)\" is outside the plugin.")) }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            return .failure(.invalid("asset: \"\(path)\" is not in the plugin."))
        }
        guard (values.fileSize ?? 0) <= maxBytes else { return .failure(.invalid("asset: \"\(path)\" is larger than 2 MB.")) }
        return .success(url)
    }
}

// MARK: - More bridge calls

extension PluginMessage {
    public static let maxMessageBytes = 64 * 1024
    public static let sendMethods = ["POST", "PUT", "PATCH", "DELETE"]

    /// Header rules for every request: plugins may say what they accept and who they are, not
    /// impersonate the browser.
    static func headers(_ value: JSONValue?) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, item) in value?.object ?? [:] {
            guard let text = item.string, headers.count < 16 else { continue }
            let lower = key.lowercased()
            guard !["cookie", "host", "origin", "referer", "content-length", "connection"].contains(lower),
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), text.count < 2048 else { continue }
            headers[key] = text
        }
        return headers
    }

    static func decodeEngine(kind: String, _ value: JSONValue) throws(PluginFailure) -> PluginMessage? {
        switch kind {
        case "httpSend":
            let method = (value["method"]?.string ?? "").uppercased()
            guard sendMethods.contains(method) else { throw .invalid("http: the method must be one of \(sendMethods.joined(separator: ", ")).") }
            guard let request = value["request"]?.number, let text = value["url"]?.string, let url = URL(string: text) else {
                throw .invalid("http.\(method.lowercased()): pass a URL string.")
            }
            var headers = headers(value["headers"])
            var body: String?
            if let json = value["json"], !json.isNull {
                body = json.text()
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "application/json" }
            } else if let text = value["body"]?.string {
                body = text
            } else if let other = value["body"], !other.isNull {
                throw .invalid("http.\(method.lowercased()): body must be a string. Pass objects as json.")
            }
            return .httpSend(request: Int(request), method: method, url: url, headers: headers, body: body)
        case "send":
            guard let to = value["to"]?.string, ThemeIdentifier.isValid(to) else {
                throw .invalid("send: the first argument is the other plugin's id, like com.example.timer.")
            }
            let payload = value["payload"] ?? .null
            guard payload.text().utf8.count <= maxMessageBytes else { throw .invalid("send: a message may be at most 64 KB of JSON.") }
            return .send(to: to, payload: payload)
        default:
            return nil
        }
    }
}

// MARK: - Settings declared in the manifest

/// One setting a plugin declares. Atelier draws it; values live in the plugin's storage under
/// `settings.<key>`, except secrets, which live in the Keychain.
public struct PluginSetting: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case text, secret, number, toggle, choice, color, hotkeyHint }
    public struct Option: Equatable, Sendable {
        public var value: String
        public var title: String
        public init(value: String, title: String) { self.value = value; self.title = title }
    }

    public var key: String
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var defaultValue: JSONValue?
    public var options: [Option]
    public var min: Double?
    public var max: Double?
    public var id: String { key }

    public static let maxCount = 24
    public static let maxText = 1000
    public static let maxSecret = 4096
    public static let storagePrefix = "settings."
    public var storageKey: String { Self.storagePrefix + key }

    public init(key: String, kind: Kind, title: String, detail: String? = nil, defaultValue: JSONValue? = nil,
                options: [Option] = [], min: Double? = nil, max: Double? = nil) {
        self.key = key; self.kind = kind; self.title = title; self.detail = detail; self.defaultValue = defaultValue
        self.options = options; self.min = min; self.max = max
    }

    public static func isValidKey(_ key: String) -> Bool {
        (1...64).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Checks a value for this setting strictly, and normalises it (a number into range, a
    /// shortcut into `cmd+shift+p` form). `null` clears the setting back to its default.
    public func check(_ value: JSONValue) -> Result<JSONValue, PluginFailure> {
        if value.isNull { return .success(.null) }
        let wrong = PluginFailure.invalid("settings: \"\(key)\" is a \(kind.rawValue) setting; \(value.shortDescription) does not fit.")
        switch kind {
        case .text:
            guard let text = value.string, text.count <= Self.maxText else { return .failure(wrong) }
            return .success(.string(text))
        case .secret:
            guard let text = value.string, text.count <= Self.maxSecret else { return .failure(wrong) }
            return .success(.string(text))
        case .number:
            guard let number = value.number, number.isFinite else { return .failure(wrong) }
            if let min, number < min { return .failure(.invalid("settings: \"\(key)\" is at least \(PluginNode.format(min)).")) }
            if let max, number > max { return .failure(.invalid("settings: \"\(key)\" is at most \(PluginNode.format(max)).")) }
            return .success(.number(number))
        case .toggle:
            guard let flag = value.bool else { return .failure(wrong) }
            return .success(.bool(flag))
        case .choice:
            guard let text = value.string, options.contains(where: { $0.value == text }) else {
                return .failure(.invalid("settings: \"\(key)\" is one of \(options.map(\.value).joined(separator: ", ")).")) }
            return .success(.string(text))
        case .color:
            guard let text = value.string, let color = ThemeColor(hex: text) else { return .failure(wrong) }
            return .success(.string(color.hex))
        case .hotkeyHint:
            guard let text = value.string else { return .failure(wrong) }
            if text.isEmpty { return .success(.null) }
            guard let normal = PluginShortcut.normalise(text) else {
                return .failure(.invalid("settings: \"\(text)\" is not a shortcut. Use something like \"cmd+shift+p\"."))
            }
            return .success(.string(normal))
        }
    }

    static func parseList(_ value: JSONValue?, into result: inout ThemeValidation) -> [PluginSetting] {
        guard let value else { return [] }
        guard let list = value.array else { result.error("settings", "Expected a list of settings."); return [] }
        if list.count > maxCount { result.error("settings", "At most \(maxCount) settings.") }
        var out: [PluginSetting] = [], seen = Set<String>()
        for (index, item) in list.prefix(maxCount).enumerated() {
            let path = "settings[\(index)]"
            guard let object = item.object else { result.error(path, "Expected an object."); continue }
            guard let key = object["key"]?.string, isValidKey(key) else {
                result.error(path + ".key", "A key of letters, digits, - _ or . is required, up to 64 characters."); continue
            }
            guard seen.insert(key).inserted else { result.error(path + ".key", "\"\(key)\" is used twice."); continue }
            guard let kind = object["type"]?.string.flatMap(Kind.init(rawValue:)) else {
                result.error(path + ".type", "Use one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))."); continue
            }
            guard let title = object["title"]?.string, (1...60).contains(title.count) else {
                result.error(path + ".title", "A title of 1 to 60 characters is required."); continue
            }
            let known: Set<String> = ["key", "type", "title", "detail", "default", "options", "min", "max"]
            for extra in object.keys.sorted() where !known.contains(extra) { result.warn(path + "." + extra, "Unknown key, ignored.") }
            var options: [Option] = []
            for (n, option) in (object["options"]?.array ?? []).prefix(40).enumerated() {
                if let text = option.string, !text.isEmpty { options.append(Option(value: text, title: text)) }
                else if let text = option["value"]?.string, !text.isEmpty {
                    options.append(Option(value: text, title: option["title"]?.string ?? text))
                } else { result.error("\(path).options[\(n)]", "An option is text, or { value, title }.") }
            }
            if kind == .choice, options.isEmpty { result.error(path + ".options", "A choice needs options."); continue }
            let min = object["min"]?.number, max = object["max"]?.number
            if let min, let max, min > max { result.error(path + ".min", "min is larger than max."); continue }
            var setting = PluginSetting(key: key, kind: kind, title: title,
                                        detail: object["detail"]?.string.map { String($0.prefix(200)) },
                                        options: options, min: min, max: max)
            if let given = object["default"], !given.isNull {
                if kind == .secret { result.error(path + ".default", "A secret cannot have a default."); continue }
                switch setting.check(given) {
                case .success(let value): setting.defaultValue = value.isNull ? nil : value
                case .failure(let failure): result.error(path + ".default", failure.description); continue
                }
            }
            out.append(setting)
        }
        return out
    }
}

// MARK: - On-demand activation

/// When a plugin's script first runs. Without `onStartup`, nothing runs until one of the
/// listed things happens; what it declares under `contributes` shows meanwhile.
public enum PluginActivation: Hashable, Sendable {
    case onStartup, onCommand, onWidgetVisible, onTileClick, onTimer, onCorner
    case onEvent(PluginEvent)

    public init?(_ text: String) {
        switch text {
        case "onStartup": self = .onStartup
        case "onCommand": self = .onCommand
        case "onWidgetVisible": self = .onWidgetVisible
        case "onTileClick": self = .onTileClick
        case "onTimer": self = .onTimer
        case "onCorner": self = .onCorner
        default:
            guard text.hasPrefix("onEvent:"), let event = PluginEvent(rawValue: String(text.dropFirst("onEvent:".count))) else { return nil }
            self = .onEvent(event)
        }
    }

    public var text: String {
        switch self {
        case .onStartup: "onStartup"
        case .onCommand: "onCommand"
        case .onWidgetVisible: "onWidgetVisible"
        case .onTileClick: "onTileClick"
        case .onTimer: "onTimer"
        case .onCorner: "onCorner"
        case .onEvent(let event): "onEvent:" + event.rawValue
        }
    }
}

/// What a plugin shows before its script runs: the manifest's `contributes` block.
public struct PluginContributions: Equatable, Sendable {
    public var widgets: [PluginWidgetSpec] = []
    public var tiles: [PluginTileSpec] = []
    public var commands: [PluginCommandSpec] = []
    public var corners: [PluginCornerSpec] = []
    /// With `onTimer`: how often a sleeping plugin is woken, in seconds.
    public var timer: Double?
    public init() {}
    public var isEmpty: Bool { widgets.isEmpty && tiles.isEmpty && commands.isEmpty && corners.isEmpty }

    static func parse(_ value: JSONValue?, into result: inout ThemeValidation) -> PluginContributions {
        var out = PluginContributions()
        guard let value else { return out }
        guard let object = value.object else { result.error("contributes", "Expected an object."); return out }
        let groups: [(String, String)] = [("widgets", "widget"), ("tiles", "tile"), ("commands", "command"), ("cornerActions", "corner")]
        for key in object.keys.sorted() where !groups.map(\.0).contains(key) && key != "timer" {
            result.warn("contributes." + key, "Unknown key, ignored.")
        }
        var count = 0
        for (key, kind) in groups {
            for (index, item) in (object[key]?.array ?? []).enumerated() {
                count += 1
                do {
                    switch try PluginMessage.decode(kind: kind, item) {
                    case .widget(let spec): out.widgets.append(spec)
                    case .tile(let spec): out.tiles.append(spec)
                    case .command(let spec): out.commands.append(spec)
                    case .corner(let spec): out.corners.append(spec)
                    default: break
                    }
                } catch {
                    result.error("contributes.\(key)[\(index)]", error.description)
                }
            }
        }
        if count > PluginMessage.maxRegistrations { result.error("contributes", "At most \(PluginMessage.maxRegistrations) registrations in all.") }
        if let timer = object["timer"] {
            guard let seconds = timer.number else { result.error("contributes.timer", "Seconds, 60 to 86400."); return out }
            out.timer = PluginNode.clamp(seconds, 60...86_400)
        }
        return out
    }
}

/// Messaging between plugins. Both sides must name each other.
public struct PluginMessaging: Equatable, Sendable {
    public var send: [String] = []
    public var receive: [String] = []
    public init(send: [String] = [], receive: [String] = []) { self.send = send; self.receive = receive }

    /// Whether `from` may send to `to`: `from` lists `to` under send, and `to` lists `from` under receive.
    public static func allows(from: PluginManifest, to: PluginManifest) -> Bool {
        from.id != to.id && from.messages.send.contains(to.id) && to.messages.receive.contains(from.id)
    }

    static func parse(_ value: JSONValue?, into result: inout ThemeValidation) -> PluginMessaging {
        guard let value else { return PluginMessaging() }
        guard let object = value.object else { result.error("messages", "Expected { send, receive }."); return PluginMessaging() }
        func ids(_ key: String) -> [String] {
            var out: [String] = []
            for (index, item) in (object[key]?.array ?? []).prefix(16).enumerated() {
                guard let id = item.string, ThemeIdentifier.isValid(id) else {
                    result.error("messages.\(key)[\(index)]", "A plugin id like com.example.timer."); continue
                }
                out.append(id)
            }
            return out
        }
        for key in object.keys.sorted() where key != "send" && key != "receive" { result.warn("messages." + key, "Unknown key, ignored.") }
        return PluginMessaging(send: ids("send"), receive: ids("receive"))
    }
}

// MARK: - Localized strings

public enum PluginStrings {
    public static let maxLanguages = 24
    public static let maxKeys = 400
    public static let maxLength = 1000

    static func parse(_ value: JSONValue?, into result: inout ThemeValidation) -> [String: [String: String]] {
        guard let value else { return [:] }
        guard let object = value.object else { result.error("strings", "Expected { \"en\": { … }, \"pt\": { … } }."); return [:] }
        if object.count > maxLanguages { result.error("strings", "At most \(maxLanguages) languages.") }
        var out: [String: [String: String]] = [:]
        for (language, table) in object.sorted(by: { $0.key < $1.key }).prefix(maxLanguages) {
            guard isLanguage(language) else { result.error("strings." + language, "Not a language code like en, pt or pt-BR."); continue }
            guard let entries = table.object else { result.error("strings." + language, "Expected an object of strings."); continue }
            if entries.count > maxKeys { result.error("strings." + language, "At most \(maxKeys) strings per language.") }
            var strings: [String: String] = [:]
            for (key, text) in entries.prefix(maxKeys) {
                guard (1...128).contains(key.count), let text = text.string, text.count <= maxLength else {
                    result.error("strings.\(language).\(key)", "Keys are 1 to 128 characters; values are text up to \(maxLength)."); continue
                }
                strings[key] = text
            }
            out[language] = strings
        }
        return out
    }

    static func isLanguage(_ code: String) -> Bool {
        (2...12).contains(code.count) && code.first?.isLetter == true && code.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "_") }
    }

    /// The strings for the first of the owner's preferred languages the plugin has, laid over
    /// its English ones. `pt-BR` matches `pt-BR`, then `pt`.
    public static func pick(_ tables: [String: [String: String]], preferred: [String]) -> [String: String] {
        let lower = Dictionary(tables.map { ($0.key.lowercased().replacingOccurrences(of: "_", with: "-"), $0.value) }, uniquingKeysWith: { a, _ in a })
        var base = lower["en"] ?? [:]
        for language in preferred {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            let candidates = [code, String(code.split(separator: "-").first ?? "")]
            if let table = candidates.lazy.compactMap({ lower[$0] }).first {
                base.merge(table) { _, mine in mine }
                return base
            }
        }
        return base
    }

    /// `"{n} sessions"` with `["n": 3]` becomes `"3 sessions"`.
    public static func format(_ template: String, _ vars: [String: JSONValue]) -> String {
        var text = template
        for (key, value) in vars { text = text.replacingOccurrences(of: "{\(key)}", with: PluginNode.text(value)) }
        return text
    }
}

// MARK: - Safe mode

/// After launches that crash while plugins run, Atelier starts once with every plugin off.
public enum PluginSafeMode {
    public static let threshold = 2

    /// The crash streak after this launch: up by one when the last run crashed with plugins
    /// running, back to zero otherwise.
    public static func streak(previous: Int, lastRunCrashed: Bool, pluginsWereRunning: Bool) -> Int {
        lastRunCrashed && pluginsWereRunning ? previous + 1 : 0
    }

    public static func isSafe(streak: Int) -> Bool { streak >= threshold }
}

// MARK: - Resource meter

/// One request a plugin made, as the owner sees it in the details.
public struct PluginNetworkEntry: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var method: String
    public var host: String
    public var path: String
    /// The HTTP status, or nil when the request failed before a response.
    public var status: Int?
    public var milliseconds: Int
    public var bytes: Int
    public init(date: Date, method: String, host: String, path: String, status: Int?, milliseconds: Int, bytes: Int) {
        self.date = date; self.method = method; self.host = host; self.path = path
        self.status = status; self.milliseconds = milliseconds; self.bytes = bytes
    }
}

/// Calls into a plugin over the last minute and the script time they took.
public struct PluginMeter: Equatable, Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var callsPerMinute: Int
        public var millisecondsPerMinute: Double
        public var lastCall: Date?
    }
    private var samples: [(date: Date, seconds: Double)] = []
    public private(set) var lastCall: Date?
    public init() {}

    public static func == (a: PluginMeter, b: PluginMeter) -> Bool { a.snapshot(at: Date()) == b.snapshot(at: Date()) }

    public mutating func record(at date: Date, seconds: Double) {
        samples.append((date, seconds))
        lastCall = date
        if samples.count > 4000 { prune(before: date.addingTimeInterval(-60)) }
    }

    public mutating func prune(before cutoff: Date) { samples.removeAll { $0.date < cutoff } }

    public func snapshot(at now: Date) -> Snapshot {
        let recent = samples.filter { $0.date >= now.addingTimeInterval(-60) }
        return Snapshot(callsPerMinute: recent.count, millisecondsPerMinute: recent.reduce(0) { $0 + $1.seconds } * 1000, lastCall: lastCall)
    }
}

/// Whether a plugin started on demand may go back to sleep.
public enum PluginIdle {
    public static let limit: TimeInterval = 600

    public static func canSleep(timers: Int, visibleWidgets: Int, pendingRequests: Int, lastCall: Date?, now: Date) -> Bool {
        guard timers == 0, visibleWidgets == 0, pendingRequests == 0 else { return false }
        guard let lastCall else { return true }
        return now.timeIntervalSince(lastCall) >= limit
    }
}
