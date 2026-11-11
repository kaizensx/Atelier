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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .network: "Network"
        case .notifications: "Notifications"
        case .openURL: "Open Links"
        case .appearance: "Change Appearance"
        }
    }

    public var detail: String {
        switch self {
        case .network: "Download data over https from the sites listed below. Nothing else on the network."
        case .notifications: "Post notifications in Notification Center."
        case .openURL: "Open web and mail links in your default apps."
        case .appearance: "Change Atelier theme settings: colours, wallpaper, Dock and widget style. You can revert them."
        }
    }

    public var symbol: String {
        switch self {
        case .network: "network"
        case .notifications: "bell.badge"
        case .openURL: "safari"
        case .appearance: "paintpalette"
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

    public init(id: String, name: String, version: String, author: String? = nil, summary: String? = nil,
                entry: String = "main.js", symbol: String = "puzzlepiece.extension", permissions: [PluginPermission] = [],
                hosts: [String] = [], homepage: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.author = author; self.summary = summary
        self.entry = entry; self.symbol = symbol; self.permissions = permissions; self.hosts = hosts; self.homepage = homepage
    }

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
        .init("permissions", .strings(maxCount: 8, maxLength: 24), "Permissions the plugin asks for."),
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
        result.issues = ThemeValidator.validate(fields: fields, object: withEntry, files: files).issues
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
        return (manifest, result)
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
