import Foundation

// MARK: - A setup to carry to another Mac: `.ateliersetup`
//
// A small JSON file: which mods are installed (id, kind, version), which plugins are on, the
// applied theme or Look, and the active packs. It never holds secrets. A plugin's stored data
// (its `atelier.storage`) is left out unless the owner ticks "Include plugin data", and even
// then any key that looks like a secret (token, password, key…) is dropped.
//
// Importing never grants anything: mods install from the signed catalog as usual, and a plugin
// with permissions still asks for them on its own sheet before it runs.
//
//   {"format":1,"kind":"atelier-setup","created":"…","atelier":"1.0.0",
//    "mods":[{"id":"…","kind":"plugin","version":"1.2.0","catalog":true}],
//    "plugins":[{"id":"…","enabled":true,"data":{…}}],
//    "theme":"atelier.look.midnight-glass","packs":["…"]}

public struct AtelierSetup: Equatable, Sendable {
    public static let fileExtension = "ateliersetup"
    public static let format = 1
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxMods = 500

    public struct Mod: Equatable, Sendable {
        public var id: String
        /// The raw kind, so a kind this Atelier does not know survives a round trip.
        public var kind: String
        public var version: String
        /// Installed from the catalog (and so installable from it on another Mac).
        public var catalog: Bool

        public init(id: String, kind: String, version: String, catalog: Bool) {
            self.id = id; self.kind = kind; self.version = version; self.catalog = catalog
        }
    }

    public struct Plugin: Equatable, Sendable {
        public var id: String
        public var enabled: Bool
        /// The plugin's stored data, without secrets. Only with "Include plugin data".
        public var data: [String: JSONValue]?

        public init(id: String, enabled: Bool, data: [String: JSONValue]? = nil) {
            self.id = id; self.enabled = enabled; self.data = data
        }
    }

    public var created: Date
    public var atelier: String
    public var mods: [Mod]
    public var plugins: [Plugin]
    /// The applied theme or Look.
    public var theme: String?
    /// The active packs.
    public var packs: [String]

    public init(created: Date = Date(), atelier: String, mods: [Mod], plugins: [Plugin], theme: String? = nil, packs: [String] = []) {
        self.created = created; self.atelier = atelier; self.mods = mods; self.plugins = plugins; self.theme = theme; self.packs = packs
    }

    public var includesData: Bool { plugins.contains { $0.data != nil } }

    // MARK: Secrets

    /// Whole words that mark a secret, matched against the parts of camelCase, snake_case and
    /// kebab-case keys: "githubToken", "api_key" and "authHeader" go; "author" and "pattern" stay.
    static let secretParts: Set<String> = ["token", "tokens", "secret", "secrets", "password", "passwd", "passphrase",
                                           "apikey", "auth", "authorization", "credential", "credentials", "cookie",
                                           "cookies", "session", "bearer", "private", "pat", "otp", "pin", "key", "keys"]
    /// Substrings that mark a secret wherever they appear.
    static let secretFragments = ["token", "secret", "password", "passwd", "credential", "apikey", "bearer"]

    /// Whether a storage key looks like it holds a secret.
    public static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return words(key).contains(where: secretParts.contains) || secretFragments.contains(where: lower.contains)
    }

    /// camelCase, snake_case and kebab-case split into lowercased words.
    static func words(_ key: String) -> [String] {
        var out: [String] = [], current = ""
        for c in key {
            if c == "_" || c == "-" || c == "." || c == " " {
                if !current.isEmpty { out.append(current) }; current = ""
            } else if c.isUppercase, !current.isEmpty, current.last?.isLowercase == true {
                out.append(current); current = String(c)
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.lowercased() }
    }

    public static func stripSecrets(_ values: [String: JSONValue]) -> [String: JSONValue] {
        values.filter { !isSecretKey($0.key) }
    }

    // MARK: Writing

    public func data() -> Data {
        var root: [String: JSONValue] = [
            "format": .number(Double(Self.format)),
            "kind": .string("atelier-setup"),
            "created": .string(ModDates.format(created)),
            "atelier": .string(atelier),
            "mods": .array(mods.map { .object(["id": .string($0.id), "kind": .string($0.kind), "version": .string($0.version), "catalog": .bool($0.catalog)]) }),
            "plugins": .array(plugins.map { p in
                var o: [String: JSONValue] = ["id": .string(p.id), "enabled": .bool(p.enabled)]
                if let data = p.data { o["data"] = .object(Self.stripSecrets(data)) }
                return .object(o)
            }),
            "packs": .array(packs.map(JSONValue.string)),
        ]
        if let theme { root["theme"] = .string(theme) }
        return (try? JSONValue.object(root).data(pretty: true)) ?? Data("{}".utf8)
    }

    // MARK: Reading

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge, notASetup, newerFormat(Int), invalid(String)

        public var description: String {
            switch self {
            case .tooLarge: "The setup file is too large."
            case .notASetup: "This is not an Atelier setup file."
            case .newerFormat(let f): "The setup file uses format \(f), which needs a newer Atelier."
            case .invalid(let why): "The setup file could not be read: \(why)"
            }
        }
    }

    /// Reads a setup file strictly: bad entries are skipped, secrets are dropped, sizes capped.
    public static func parse(_ data: Data) -> Result<AtelierSetup, Failure> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let root = (try? JSONValue.parse(data))?.object else { return .failure(.notASetup) }
        guard root["kind"]?.string == "atelier-setup" else { return .failure(.notASetup) }
        guard let format = root["format"]?.number else { return .failure(.invalid("it has no format.")) }
        guard Int(format) <= Self.format else { return .failure(.newerFormat(Int(format))) }
        guard Int(format) == Self.format else { return .failure(.invalid("unknown format \(Int(format)).")) }

        var seen = Set<String>(), mods: [Mod] = []
        for item in root["mods"]?.array ?? [] {
            guard let o = item.object, let id = o["id"]?.string, ThemeIdentifier.isValid(id), !seen.contains(id),
                  let kind = o["kind"]?.string, !kind.isEmpty, kind.count <= 24, kind.allSatisfy({ $0.isASCII && $0.isLetter }),
                  let version = o["version"]?.string, AppVersion(version) != nil else { continue }
            seen.insert(id)
            mods.append(Mod(id: id, kind: kind, version: version, catalog: o["catalog"]?.bool ?? true))
            if mods.count >= maxMods { break }
        }
        var pluginIDs = Set<String>(), plugins: [Plugin] = []
        for item in root["plugins"]?.array ?? [] {
            guard let o = item.object, let id = o["id"]?.string, ThemeIdentifier.isValid(id), pluginIDs.insert(id).inserted else { continue }
            var stored = o["data"]?.object.map(stripSecrets)
            if let s = stored, ((try? JSONValue.object(s).data(pretty: false).count) ?? .max) > PluginStorage.maxBytes { stored = nil }
            if let s = stored, s.keys.contains(where: { !(1...PluginStorage.maxKeyLength).contains($0.count) }) { stored = nil }
            plugins.append(Plugin(id: id, enabled: o["enabled"]?.bool ?? false, data: stored))
            if plugins.count >= maxMods { break }
        }
        let theme = root["theme"]?.string.flatMap { ThemeIdentifier.isValid($0) ? $0 : nil }
        let packs = (root["packs"]?.array ?? []).compactMap(\.string).filter(ThemeIdentifier.isValid).prefix(maxMods).map { $0 }
        let created = root["created"]?.string.flatMap(ModDates.parse) ?? Date(timeIntervalSince1970: 0)
        let atelier = root["atelier"]?.string.map { String($0.prefix(40)) } ?? ""
        return .success(AtelierSetup(created: created, atelier: atelier, mods: mods, plugins: plugins, theme: theme, packs: Array(packs)))
    }

    // MARK: Planning an import

    public struct Step: Equatable, Sendable, Identifiable {
        public enum Action: Equatable, Sendable {
            /// Install this version from the catalog (the file's, when the catalog still lists it).
            case install(String)
            /// Installed already at a different version; the catalog's copy of the file's version.
            case change(from: String, to: String)
            case alreadyInstalled
            /// Not in the catalog (added by hand on the other Mac, or delisted).
            case unavailable
        }
        public var id: String
        public var name: String
        public var kind: String
        public var action: Action
    }

    /// What importing would do, mod by mod, against the catalog and what is installed here.
    public func plan(index: ModIndex?, installed: [InstalledModInfo]) -> [Step] {
        mods.map { mod in
            let entry = index?.mod(mod.id)
            let name = entry?.name ?? mod.id
            let mine = installed.first { $0.id == mod.id }
            guard let entry, entry.kind.rawValue == mod.kind else {
                return Step(id: mod.id, name: name, kind: mod.kind, action: mine?.version == mod.version ? .alreadyInstalled : .unavailable)
            }
            let version = entry.at(version: mod.version) != nil ? mod.version : entry.version
            if let mine {
                return Step(id: mod.id, name: name, kind: mod.kind, action: mine.version == version ? .alreadyInstalled : .change(from: mine.version, to: version))
            }
            return Step(id: mod.id, name: name, kind: mod.kind, action: .install(version))
        }
    }
}
