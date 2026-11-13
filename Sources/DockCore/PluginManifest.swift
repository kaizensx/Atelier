import Foundation

/// What a plugin may do beyond drawing and storing its own small settings. Each one is asked
/// for in the manifest and granted by the owner; nothing is granted by default.
public enum PluginPermission: String, CaseIterable, Codable, Sendable, Identifiable {
    /// `atelier.http.get`, to the hosts listed in `network.hosts` only.
    case network
    /// `atelier.notify`.
    case notifications
    /// `atelier.openURL`, for https and mailto links.
    case openURL
    /// `atelier.theme.apply`: change colours, wallpaper and other theme keys.
    case appearance
    // Hooks into Atelier (PluginHooksBridge.swift).
    /// `atelier.menuBarItem`: up to two items in the menu bar.
    case menuBar
    /// `atelier.liveActivity`: small live pills at the top of the screen.
    case liveActivities
    /// `atelier.scenes`: list the owner's Scenes and switch to one.
    case scenes
    /// `atelier.panel`: its own small windows, showing its HTML with no network.
    case panels

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .network: "Network"
        case .notifications: "Notifications"
        case .openURL: "Open Links"
        case .appearance: "Change Appearance"
        case .menuBar: "Menu Bar"
        case .liveActivities: "Live Activities"
        case .scenes: "Scenes"
        case .panels: "Windows"
        }
    }

    public var detail: String {
        switch self {
        case .network: "Exchange data over https with the sites listed below. Nothing else on the network."
        case .notifications: "Post notifications in Notification Center."
        case .openURL: "Open web and mail links in your default apps."
        case .appearance: "Change Atelier theme settings: colours, wallpaper, Dock and widget style. You can revert them."
        case .menuBar: "Show an item in the menu bar, with its own menu. At most two."
        case .liveActivities: "Show small live updates at the top of the screen, like a timer or a download. At most three."
        case .scenes: "See the names of your Scenes and switch to one, which changes your Dock."
        case .panels: "Open its own small windows. They show the plugin's page with no network and no access to your files."
        }
    }

    public var symbol: String {
        switch self {
        case .network: "network"
        case .notifications: "bell.badge"
        case .openURL: "safari"
        case .appearance: "paintpalette"
        case .menuBar: "menubar.rectangle"
        case .liveActivities: "capsule.inset.filled"
        case .scenes: "theatermasks"
        case .panels: "macwindow"
        }
    }
}

/// `manifest.json` inside a `.atelierplugin` folder.
public struct PluginManifest: Equatable, Sendable, Identifiable {
    public static let fileName = "manifest.json"
    public static let bundleExtension = "atelierplugin"
    public static let format = 1
    public static let maxScriptBytes = 512 * 1024
    public static let maxHosts = 8

    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var summary: String?
    public var entry: String
    public var symbol: String
    public var permissions: [PluginPermission]
    public var hosts: [String]
    public var homepage: String?
    // Declared in the manifest, all optional (see PluginEngine.swift).
    public var settings: [PluginSetting] = []
    public var strings: [String: [String: String]] = [:]
    /// Nil: the script runs at startup, as it always has.
    public var activation: [PluginActivation]?
    public var contributes = PluginContributions()
    public var messages = PluginMessaging()

    public init(id: String, name: String, version: String, author: String? = nil, summary: String? = nil,
                entry: String = "main.js", symbol: String = "puzzlepiece.extension", permissions: [PluginPermission] = [],
                hosts: [String] = [], homepage: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.author = author; self.summary = summary
        self.entry = entry; self.symbol = symbol; self.permissions = permissions; self.hosts = hosts; self.homepage = homepage
    }

    /// Whether the script waits for one of its `activation` triggers instead of running at startup.
    public var startsOnDemand: Bool { activation.map { !$0.contains(.onStartup) } ?? false }

    public func setting(_ key: String) -> PluginSetting? { settings.first { $0.key == key } }

    /// Keys validated by their own code rather than the field table.
    static let engineKeys = ["settings", "strings", "activation", "contributes", "messages"]

    public static let fields: [ThemeSchema.Field] = [
        .init("format", .integer(1...1), "Manifest format. Always 1.", required: true),
        .init("id", .string(maxLength: 120), "Reverse-DNS identifier: `com.example.pomodoro`.", required: true),
        .init("name", .string(maxLength: 60), "Name shown in Atelier.", required: true),
        .init("version", .string(maxLength: 20), "Semantic version: `1.0.0`.", required: true),
        .init("author", .string(maxLength: 80), "Who made it."),
        .init("description", .string(maxLength: 400), "What it does, in a sentence or two."),
        .init("entry", .file(["js"]), "The script Atelier runs. Default `main.js`."),
        .init("icon", .string(maxLength: 80), "An SF Symbol name for the plugin. Default `puzzlepiece.extension`."),
        .init("homepage", .url, "An https link to the plugin's page."),
        .init("permissions", .strings(maxCount: 16, maxLength: 24), "Permissions the plugin asks for."),
        .init("network", .object([
            .init("hosts", .strings(maxCount: maxHosts, maxLength: 120), "Hosts `atelier.http.get` may reach, like `api.github.com`."),
        ]), "Network access, with the network permission."),
    ]

    /// Parses and validates. `files` lists the paths in the plugin folder.
    public static func parse(_ data: Data, files: Set<String>? = nil) -> (PluginManifest?, ThemeValidation) {
        var result = ThemeValidation()
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch {
            result.error("", "\(fileName) is not valid JSON: \(ThemeValidator.describe(error)).")
            return (nil, result)
        }
        guard let root = value.object else {
            result.error("", "\(fileName) must be a JSON object.")
            return (nil, result)
        }
        var withEntry = root
        if withEntry["entry"] == nil { withEntry["entry"] = .string("main.js") }
        for key in engineKeys { withEntry[key] = nil }
        result.issues = ThemeValidator.validate(fields: fields, object: withEntry, files: files).issues
        let settings = PluginSetting.parseList(root["settings"], into: &result)
        let strings = PluginStrings.parse(root["strings"], into: &result)
        let contributes = PluginContributions.parse(root["contributes"], into: &result)
        let messages = PluginMessaging.parse(root["messages"], into: &result)
        var activation: [PluginActivation]?
        if let list = root["activation"] {
            activation = []
            for (index, item) in (list.array ?? []).enumerated() {
                if let text = item.string, let trigger = PluginActivation(text) {
                    if activation?.contains(trigger) == false { activation?.append(trigger) }
                } else {
                    result.error("activation[\(index)]", "Use onStartup, onCommand, onWidgetVisible, onTileClick, onTimer, onCorner or onEvent:<event>.")
                }
            }
            if list.array == nil { result.error("activation", "Expected a list, like [\"onCommand\"].") }
            else if activation?.isEmpty == true { result.error("activation", "List at least one trigger, or leave activation out.") }
            if activation?.contains(.onTimer) == true, contributes.timer == nil {
                result.error("contributes.timer", "onTimer needs contributes.timer: how often to wake, in seconds.")
            }
        }
        let id = root["id"]?.string ?? ""
        if !id.isEmpty, !ThemeIdentifier.isValid(id) { result.error("id", "\"\(id)\" is not a reverse-DNS identifier, like com.example.pomodoro.") }
        if let version = root["version"]?.string, SemVer(version) == nil { result.error("version", "\"\(version)\" is not a version like 1.0.0.") }
        var permissions: [PluginPermission] = []
        for (index, item) in (root["permissions"]?.array ?? []).enumerated() {
            guard let text = item.string else { continue }
            if let permission = PluginPermission(rawValue: text) {
                if !permissions.contains(permission) { permissions.append(permission) }
            } else {
                result.error("permissions[\(index)]", "\"\(text)\" is not a permission. Use \(PluginPermission.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
        }
        let hosts = root["network"]?["hosts"]?.array?.compactMap(\.string).map { $0.lowercased() } ?? []
        for (index, host) in hosts.enumerated() where !PluginNetwork.isValidHost(host) {
            result.error("network.hosts[\(index)]", "\"\(host)\" is not a public host name like api.github.com. No schemes, paths, ports or wildcards.")
        }
        if permissions.contains(.network), hosts.isEmpty {
            result.error("network.hosts", "The network permission needs at least one host.")
        }
        if !hosts.isEmpty, !permissions.contains(.network) {
            result.warn("network.hosts", "Hosts are listed but the network permission is not asked for, so they are unused.")
        }
        guard result.isValid else { return (nil, result) }
        let manifest = PluginManifest(
            id: id, name: root["name"]?.string ?? id, version: root["version"]?.string ?? "1.0.0",
            author: root["author"]?.string, summary: root["description"]?.string,
            entry: withEntry["entry"]?.string ?? "main.js", symbol: root["icon"]?.string ?? "puzzlepiece.extension",
            permissions: permissions, hosts: hosts, homepage: root["homepage"]?.string)
        var full = manifest
        full.settings = settings
        full.strings = strings
        full.activation = activation
        full.contributes = contributes
        full.messages = messages
        return (full, result)
    }
}

public enum PluginNetwork {
    public static func isValidHost(_ host: String) -> Bool {
        guard (3...120).contains(host.count), !host.contains("/"), !host.contains(":"), !host.contains("*"),
              host.contains("."), !ThemeLink.isPrivate(host) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Whether a plugin with these grants may fetch `url`: https, on a listed host, granted.
    public static func allows(_ url: URL, manifest: PluginManifest, granted: Set<PluginPermission>) -> Result<Void, PluginFailure> {
        guard manifest.permissions.contains(.network), granted.contains(.network) else {
            return .failure(.permission("network"))
        }
        guard url.scheme == "https" else { return .failure(.refused("Only https is allowed.")) }
        guard let host = url.host()?.lowercased(), manifest.hosts.contains(host) else {
            return .failure(.refused("\(url.host() ?? "That host") is not listed in network.hosts."))
        }
        if url.port != nil, url.port != 443 { return .failure(.refused("Only the standard https port is allowed.")) }
        if url.user() != nil || url.password() != nil { return .failure(.refused("Links with credentials are not allowed.")) }
        return .success(())
    }

    /// Links `atelier.openURL` may open.
    public static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "mailto": url.absoluteString.count < 2048
        case "atelier": url.host() == "studio"
        default: false
        }
    }
}

public enum PluginFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case permission(String)
    case refused(String)
    case invalid(String)
    case timeout
    case script(String)

    public var description: String {
        switch self {
        case .permission(let name): "This needs the \"\(name)\" permission, which is not granted."
        case .refused(let reason): reason
        case .invalid(let reason): reason
        case .timeout: "The plugin took too long and was stopped."
        case .script(let message): message
        }
    }
}
