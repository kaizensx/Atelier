import CryptoKit
import Foundation

// MARK: - Atelier Mods: the community catalog, as plain rules
//
// The catalog is a public GitHub repository (kaizensx/atelier-mods). Every mod is a folder there
// with a `mod.json` and its package. When a pull request is merged, the repository's workflow
// zips every package, records its SHA-256 and size in `index.json`, and signs the exact bytes of
// `index.json` with an Ed25519 key that only the repository's secrets hold. The signature is
// published beside it as `index.json.sig` (base64).
//
// Atelier trusts nothing it downloads until:
//   1. `index.json.sig` verifies against the public key built into the app (`ModSignature`),
//   2. the index is not older than one it already accepted (`ModIndexFreshness`, no rollback),
//   3. each package's bytes match the size and SHA-256 the signed index announced (`ModIntegrity`).
// Screenshots carry their own SHA-256 in the index too, so even a picture cannot be swapped.
//
// Plugins still run in their sandbox and still ask for each permission; signing only proves the
// package is the one the catalog reviewed.

/// What a mod is. Plugins and themes are the community tier; native mods run inside the Dock
/// through the Dock Bridge and live in their own, separately reviewed tier.
public enum ModKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case plugin, theme, native
    /// Data-only packs (ModPacks.swift): no code runs, every file is checked before use.
    case icons, sounds, shader, layouts, effects, look

    public var id: String { rawValue }

    /// The package folder's extension.
    public var packageExtension: String {
        switch self {
        case .plugin: PluginManifest.bundleExtension
        case .theme: ThemeSchema.bundleExtension
        case .native: "ateliermod"
        default: pack?.bundleExtension ?? rawValue
        }
    }

    public var title: String {
        switch self {
        case .plugin: "Plugin"
        case .theme: "Theme"
        case .native: "Native"
        default: pack?.title ?? rawValue
        }
    }

    public var plural: String {
        switch self {
        case .plugin: "Plugins"
        case .theme: "Themes"
        case .native: "Native"
        default: pack?.plural ?? rawValue
        }
    }

    public var symbol: String {
        switch self {
        case .plugin: "puzzlepiece.extension"
        case .theme: "paintpalette"
        case .native: "cpu"
        default: pack?.symbol ?? "shippingbox"
        }
    }

    /// The largest zipped package the catalog accepts, and Atelier downloads.
    public var maxPackageBytes: Int {
        switch self {
        case .plugin: 2 * 1024 * 1024
        case .theme: 40 * 1024 * 1024
        case .native: 20 * 1024 * 1024
        default: pack?.maxPackageBytes ?? 1024 * 1024
        }
    }
}

/// A downloadable file the signed index vouches for.
public struct ModFile: Codable, Equatable, Hashable, Sendable {
    public var url: URL
    public var sha256: String
    public var size: Int

    public init(url: URL, sha256: String, size: Int) { self.url = url; self.sha256 = sha256; self.size = size }
}

public struct ModScreenshot: Codable, Equatable, Hashable, Sendable {
    public var url: URL
    public var sha256: String
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var caption: String?

    public init(url: URL, sha256: String, size: Int, width: Int? = nil, height: Int? = nil, caption: String? = nil) {
        self.url = url; self.sha256 = sha256; self.size = size; self.width = width; self.height = height; self.caption = caption
    }
}

/// One published version of a mod. Old versions stay downloadable, so history can show them.
public struct ModVersion: Codable, Equatable, Sendable {
    public var version: String
    public var date: Date?
    public var notes: String?
    public var package: ModFile

    public init(version: String, date: Date? = nil, notes: String? = nil, package: ModFile) {
        self.version = version; self.date = date; self.notes = notes; self.package = package
    }
}

/// One mod in the catalog, at its newest version.
public struct ModEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    /// The GitHub account that submitted it. Only that account (or a maintainer) may update it.
    public var github: String
    public var kind: ModKind
    public var version: String
    public var summary: String
    /// Markdown.
    public var description: String
    public var permissions: [String]
    public var hosts: [String]
    public var minAtelier: String?
    public var homepage: URL?
    public var license: String?
    public var tags: [String]
    public var added: Date?
    public var updated: Date?
    public var screenshots: [ModScreenshot]
    public var package: ModFile
    /// Newest first.
    public var versions: [ModVersion]

    public init(id: String, name: String, author: String, github: String, kind: ModKind, version: String,
                summary: String, description: String = "", permissions: [String] = [], hosts: [String] = [],
                minAtelier: String? = nil, homepage: URL? = nil, license: String? = nil, tags: [String] = [],
                added: Date? = nil, updated: Date? = nil, screenshots: [ModScreenshot] = [], package: ModFile,
                versions: [ModVersion] = []) {
        self.id = id; self.name = name; self.author = author; self.github = github; self.kind = kind
        self.version = version; self.summary = summary; self.description = description
        self.permissions = permissions; self.hosts = hosts; self.minAtelier = minAtelier; self.homepage = homepage
        self.license = license; self.tags = tags; self.added = added; self.updated = updated
        self.screenshots = screenshots; self.package = package; self.versions = versions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, author, github, kind, version, summary, description, permissions, hosts, minAtelier
        case homepage, license, tags, added, updated, screenshots, package, versions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        github = try c.decodeIfPresent(String.self, forKey: .github) ?? ""
        kind = try c.decode(ModKind.self, forKey: .kind)
        version = try c.decode(String.self, forKey: .version)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        minAtelier = try c.decodeIfPresent(String.self, forKey: .minAtelier)
        homepage = try? c.decodeIfPresent(URL.self, forKey: .homepage)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        added = try? c.decodeIfPresent(Date.self, forKey: .added)
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
        screenshots = (try? c.decodeIfPresent([ModScreenshot].self, forKey: .screenshots)) ?? []
        package = try c.decode(ModFile.self, forKey: .package)
        versions = (try? c.decodeIfPresent([ModVersion].self, forKey: .versions)) ?? []
    }

    /// Plugin permissions this mod asks for that Atelier knows.
    public var pluginPermissions: [PluginPermission] { permissions.compactMap(PluginPermission.init(rawValue:)) }
}

/// The whole catalog, as `index.json` holds it.
public struct ModIndex: Codable, Equatable, Sendable {
    public static let format = 1

    public var format: Int
    public var generated: Date
    public var catalog: String?
    /// Ids shown under Featured, in order.
    public var featured: [String]
    public var mods: [ModEntry]

    public init(format: Int = ModIndex.format, generated: Date, catalog: String? = nil, featured: [String] = [], mods: [ModEntry]) {
        self.format = format; self.generated = generated; self.catalog = catalog; self.featured = featured; self.mods = mods
    }

    public func mod(_ id: String) -> ModEntry? { mods.first { $0.id == id } }

    public var featuredMods: [ModEntry] { featured.compactMap(mod) }
}

public enum ModCatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    case signature
    case malformed(String)
    case newerFormat(Int)
    case stale
    case size(expected: Int, got: Int)
    case checksum
    case tooLarge(Int)
    case package(String)
    case network(String)

    public var description: String {
        switch self {
        case .signature: "The catalog’s signature does not match. Atelier only trusts the official catalog."
        case .malformed(let why): "The catalog could not be read: \(why)"
        case .newerFormat(let f): "The catalog uses format \(f), which needs a newer Atelier."
        case .stale: "The catalog is older than the one Atelier already has, so it was ignored."
        case .size(let expected, let got): "The download is \(got) bytes, but the catalog says \(expected)."
        case .checksum: "The download does not match the catalog’s checksum, so it was not installed."
        case .tooLarge(let bytes): "The download is too large (\(bytes / 1024) KB)."
        case .package(let why): why
        case .network(let why): why
        }
    }
}

// MARK: - Parsing

public enum ModIndexParser {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ModDates.parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ModDates.format(date))
        }
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    /// Parses `index.json`. A bad entry is skipped, not fatal, so one broken mod never hides the
    /// catalog. `allowLoopback` lets a test catalog on 127.0.0.1 serve plain http.
    public static func parse(_ data: Data, allowLoopback: Bool = false) throws -> ModIndex {
        struct Header: Decodable { let format: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw ModCatalogError.malformed("index.json has no format.")
        }
        guard header.format <= ModIndex.format else { throw ModCatalogError.newerFormat(header.format) }
        guard header.format == ModIndex.format else { throw ModCatalogError.malformed("Unknown format \(header.format).") }

        struct Lenient<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        }
        struct Raw: Decodable {
            let format: Int
            let generated: Date
            let catalog: String?
            let featured: [String]?
            let mods: [Lenient<ModEntry>]
        }
        let raw: Raw
        do { raw = try decoder.decode(Raw.self, from: data) } catch {
            throw ModCatalogError.malformed("index.json is not a catalog (\(error.localizedDescription)).")
        }
        var seen = Set<String>(), mods: [ModEntry] = []
        for case let entry? in raw.mods.map(\.value) where !seen.contains(entry.id) {
            guard let clean = sanitize(entry, allowLoopback: allowLoopback) else { continue }
            seen.insert(clean.id)
            mods.append(clean)
        }
        let featured = (raw.featured ?? []).filter(seen.contains)
        return ModIndex(format: raw.format, generated: raw.generated, catalog: raw.catalog, featured: featured, mods: mods)
    }

    /// Keeps an entry only when everything Atelier will act on is sound.
    static func sanitize(_ entry: ModEntry, allowLoopback: Bool) -> ModEntry? {
        guard ThemeIdentifier.isValid(entry.id), AppVersion(entry.version) != nil,
              !entry.name.trimmingCharacters(in: .whitespaces).isEmpty,
              ModURLPolicy.isAllowed(entry.package.url, allowLoopback: allowLoopback),
              ModIntegrity.isDigest(entry.package.sha256),
              entry.package.size > 0, entry.package.size <= entry.kind.maxPackageBytes else { return nil }
        var e = entry
        e.name = String(e.name.prefix(60))
        e.summary = String(e.summary.prefix(400))
        e.description = String(e.description.prefix(20_000))
        e.screenshots = e.screenshots.filter {
            ModURLPolicy.isAllowed($0.url, allowLoopback: allowLoopback) && ModIntegrity.isDigest($0.sha256)
                && $0.size > 0 && $0.size <= ModLimits.maxScreenshotBytes
        }.prefix(ModLimits.maxScreenshots).map { $0 }
        e.versions = e.versions.filter {
            AppVersion($0.version) != nil && ModURLPolicy.isAllowed($0.package.url, allowLoopback: allowLoopback)
                && ModIntegrity.isDigest($0.package.sha256)
        }.sorted { (AppVersion($0.version) ?? AppVersion("0")!) > (AppVersion($1.version) ?? AppVersion("0")!) }
        if e.homepage.map({ $0.scheme != "https" }) == true { e.homepage = nil }
        return e
    }
}

public enum ModLimits {
    public static let maxScreenshots = 6
    public static let maxScreenshotBytes = 1_500_000
    public static let maxIndexBytes = 8 * 1024 * 1024
    /// An unpacked package may be at most this many times its zip, and never above the kind's
    /// limit times four: a zip bomb stops here.
    public static func maxUnpackedBytes(_ kind: ModKind) -> Int { kind.maxPackageBytes * 4 }
}

public enum ModDates {
    public static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: text)
    }

    public static func format(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

/// Where Atelier downloads catalog files from: https anywhere public, or plain http on the
/// loopback address when a test catalog is being served locally.
public enum ModURLPolicy {
    public static func isAllowed(_ url: URL, allowLoopback: Bool) -> Bool {
        guard let host = url.host()?.lowercased(), url.user() == nil, url.password() == nil else { return false }
        if allowLoopback, isLoopback(host) { return url.scheme == "http" || url.scheme == "https" }
        guard url.scheme == "https", !ThemeLink.isPrivate(host) else { return false }
        return url.port == nil || url.port == 443
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}

// MARK: - Trust

public enum ModSignature {
    /// Whether `signature` (raw bytes, or base64 text as published in `index.json.sig`) is a valid
    /// Ed25519 signature of exactly `index` by the key `publicKey` (base64, 32 raw bytes).
    public static func verify(index: Data, signature: Data, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        let raw: Data
        if signature.count == 64 {
            raw = signature
        } else if let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let decoded = Data(base64Encoded: text), decoded.count == 64 {
            raw = decoded
        } else {
            return false
        }
        return key.isValidSignature(raw, for: index)
    }

    /// For tests and the catalog's tooling: signs with a base64 raw private key.
    public static func sign(_ index: Data, privateKey: String) -> String? {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
              let signature = try? key.signature(for: index) else { return nil }
        return signature.base64EncodedString()
    }

    /// Verifies, then parses. The only way the app should turn downloaded bytes into a catalog.
    public static func open(index: Data, signature: Data, publicKey: String, allowLoopback: Bool = false) throws -> ModIndex {
        guard index.count <= ModLimits.maxIndexBytes else { throw ModCatalogError.tooLarge(index.count) }
        guard verify(index: index, signature: signature, publicKey: publicKey) else { throw ModCatalogError.signature }
        return try ModIndexParser.parse(index, allowLoopback: allowLoopback)
    }
}

/// A catalog never goes back in time: an index older than one already accepted is refused, so
/// a stale copy (or a replayed old one with a known-bad version) cannot be pushed back.
public enum ModIndexFreshness {
    public static func accept(_ candidate: Date, over current: Date?) -> Bool {
        guard let current else { return true }
        return candidate >= current
    }
}

public enum ModIntegrity {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a file through SHA-256 without loading it whole.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }

    /// Size first, then the hash: both must match what the signed index announced.
    public static func check(_ data: Data, against file: ModFile) -> Result<Void, ModCatalogError> {
        guard data.count == file.size else { return .failure(.size(expected: file.size, got: data.count)) }
        guard sha256Hex(data) == file.sha256.lowercased() else { return .failure(.checksum) }
        return .success(())
    }

    public static func check(fileAt url: URL, against file: ModFile) -> Result<Void, ModCatalogError> {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        guard size == file.size else { return .failure(.size(expected: file.size, got: max(size, 0))) }
        guard let hash = try? sha256Hex(fileAt: url), hash == file.sha256.lowercased() else { return .failure(.checksum) }
        return .success(())
    }
}

// MARK: - Versions, compatibility, updates

public enum ModVersions {
    /// Whether `candidate` is newer than `installed`. An installed version that is not a version
    /// at all counts as older, so it can be repaired by an update.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let c = AppVersion(candidate) else { return false }
        guard let i = AppVersion(installed) else { return true }
        return c > i
    }

    /// Whether this Atelier is new enough. Pre-releases of a version count as that version, so a
    /// beta of 1.0.0 can install mods that ask for 1.0.0. A development build ("dev") runs anything.
    public static func isCompatible(minAtelier: String?, running: String) -> Bool {
        guard let minAtelier, let need = AppVersion(minAtelier) else { return true }
        guard let have = AppVersion(running) else { return true }
        return (have.major, have.minor, have.patch) >= (need.major, need.minor, need.patch)
    }
}

/// What an update asks for beyond what the installed version had.
public struct ModPermissionDiff: Equatable, Sendable {
    public var added: [String]
    public var removed: [String]
    public var addedHosts: [String]
    public var removedHosts: [String]

    public init(old: [String], new: [String], oldHosts: [String] = [], newHosts: [String] = []) {
        let o = Set(old), n = Set(new), oh = Set(oldHosts.map { $0.lowercased() }), nh = Set(newHosts.map { $0.lowercased() })
        added = new.filter { !o.contains($0) }.uniqued()
        removed = old.filter { !n.contains($0) }.uniqued()
        addedHosts = newHosts.map { $0.lowercased() }.filter { !oh.contains($0) }.uniqued()
        removedHosts = oldHosts.map { $0.lowercased() }.filter { !nh.contains($0) }.uniqued()
    }

    /// An update that reaches further (a new permission, or new hosts for the network) must be
    /// allowed again before it runs.
    public var needsConsent: Bool { !added.isEmpty || !addedHosts.isEmpty }
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && addedHosts.isEmpty && removedHosts.isEmpty }
}

/// A mod as it is installed on this Mac, whatever put it there.
public struct InstalledModInfo: Equatable, Sendable {
    public var id: String
    public var kind: ModKind
    public var version: String
    public var permissions: [String]
    public var hosts: [String]

    public init(id: String, kind: ModKind, version: String, permissions: [String] = [], hosts: [String] = []) {
        self.id = id; self.kind = kind; self.version = version; self.permissions = permissions; self.hosts = hosts
    }
}

public struct ModUpdate: Equatable, Sendable, Identifiable {
    public var entry: ModEntry
    public var from: String
    public var diff: ModPermissionDiff
    public var compatible: Bool
    public var id: String { entry.id }
    public var to: String { entry.version }
}

public enum ModUpdates {
    /// The catalog entries newer than what is installed, by name.
    public static func available(installed: [InstalledModInfo], index: ModIndex, atelier: String) -> [ModUpdate] {
        installed.compactMap { mine in
            guard let entry = index.mod(mine.id), entry.kind == mine.kind, ModVersions.isNewer(entry.version, than: mine.version) else { return nil }
            return ModUpdate(entry: entry, from: mine.version,
                             diff: ModPermissionDiff(old: mine.permissions, new: entry.permissions, oldHosts: mine.hosts, newHosts: entry.hosts),
                             compatible: ModVersions.isCompatible(minAtelier: entry.minAtelier, running: atelier))
        }
        .sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }

    /// Once a day is enough: the catalog changes when a pull request is merged.
    public static func checkDue(last: Date?, now: Date, interval: TimeInterval = 24 * 3600) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }
}

// MARK: - Browsing

public enum ModQuery {
    /// Mods of `kind` (all kinds when nil) whose name, summary, author, handle or tags contain
    /// every word of `text`. Native mods are left out unless `includeNative`.
    public static func filter(_ mods: [ModEntry], kind: ModKind?, text: String, includeNative: Bool) -> [ModEntry] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return mods.filter { mod in
            if mod.kind == .native, !includeNative { return false }
            if let kind, mod.kind != kind { return false }
            guard !words.isEmpty else { return true }
            let hay = ([mod.name, mod.summary, mod.author, mod.github, mod.id, mod.kind.title] + mod.tags).joined(separator: " ").lowercased()
            return words.allSatisfy(hay.contains)
        }
    }

    /// The newest additions first.
    public static func newest(_ mods: [ModEntry], count: Int = 6) -> [ModEntry] {
        Array(mods.sorted { ($0.added ?? .distantPast, $0.name) > ($1.added ?? .distantPast, $1.name) }.prefix(count))
    }
}

// MARK: - Package checks

public enum ModPackageCheck {
    /// The package inside the zip must be the mod the index describes, at the version it names.
    public static func matches(entry: ModEntry, packageID: String, packageVersion: String) -> String? {
        if packageID != entry.id { return "The package is \(packageID), not \(entry.id)." }
        if packageVersion != entry.version { return "The package is version \(packageVersion), not \(entry.version)." }
        return nil
    }

    /// For a plugin: the permissions in its manifest must be exactly the ones the catalog shows,
    /// so what the card promised is what the permission sheet asks.
    public static func permissionsMatch(entry: ModEntry, manifest: PluginManifest) -> String? {
        let declared = Set(entry.permissions), asked = Set(manifest.permissions.map(\.rawValue))
        if declared != asked { return "The plugin asks for \(asked.sorted().joined(separator: ", ")), but the catalog lists \(declared.sorted().joined(separator: ", "))." }
        if Set(entry.hosts.map { $0.lowercased() }) != Set(manifest.hosts) { return "The plugin’s network hosts differ from the catalog’s." }
        return nil
    }
}

/// A lint over a plugin's JavaScript: which permissioned `atelier.*` APIs it calls. The catalog's
/// review runs the same scan (scripts/validate.mjs) to catch a manifest that asks for less than
/// the code uses, or more than it needs. The runtime enforces permissions anyway; this is so the
/// permission chips on a card tell the truth.
public enum ModScan {
    public struct Result: Equatable, Sendable {
        public var used: Set<PluginPermission>
        /// `atelier[...]` or `atelier` passed around: the scan cannot follow it.
        public var dynamicAccess: Bool
    }

    static let patterns: [(PluginPermission, String)] = [
        (.network, #"\batelier\s*\.\s*http\b"#),
        (.notifications, #"\batelier\s*\.\s*notify\b"#),
        (.openURL, #"\batelier\s*\.\s*openURL\b"#),
        (.appearance, #"\batelier\s*\.\s*theme\b"#),
    ]

    public static func scan(_ source: String) -> Result {
        let code = stripComments(source)
        var used = Set<PluginPermission>()
        for (permission, pattern) in patterns where code.range(of: pattern, options: .regularExpression) != nil {
            used.insert(permission)
        }
        let dynamic = code.range(of: #"\batelier\s*\["#, options: .regularExpression) != nil
            || code.range(of: #"(?m)(=|\(|,|:)\s*atelier\s*(;|\)|,|$)"#, options: .regularExpression) != nil
        return Result(used: used, dynamicAccess: dynamic)
    }

    /// Removes // and /* */ comments, leaving strings alone.
    public static func stripComments(_ source: String) -> String {
        var out = "", i = source.startIndex
        var quote: Character?
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i) < source.endIndex ? source[source.index(after: i)] : nil
            if let q = quote {
                out.append(c)
                if c == "\\", let next { out.append(next); i = source.index(i, offsetBy: 2); continue }
                if c == q { quote = nil }
                i = source.index(after: i); continue
            }
            if c == "\"" || c == "'" || c == "`" { quote = c; out.append(c); i = source.index(after: i); continue }
            if c == "/", next == "/" {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            if c == "/", next == "*" {
                i = source.index(i, offsetBy: 2)
                while i < source.endIndex {
                    if source[i] == "*", source.index(after: i) < source.endIndex, source[source.index(after: i)] == "/" {
                        i = source.index(i, offsetBy: 2); break
                    }
                    i = source.index(after: i)
                }
                out.append(" ")
                continue
            }
            out.append(c)
            i = source.index(after: i)
        }
        return out
    }
}

/// `atelier-mod.json` inside a native `.ateliermod` package.
public struct NativeModManifest: Equatable, Sendable {
    public static let fileName = "atelier-mod.json"
    public var id: String
    public var name: String
    public var version: String
    /// The oldest Dock Bridge that can load it.
    public var bridge: String?
    public var architectures: [String]
    public var payload: String

    public static func parse(_ data: Data, files: Set<String>) -> Result<NativeModManifest, ModCatalogError> {
        guard let root = (try? JSONValue.parse(data))?.object else { return .failure(.package("\(fileName) is not a JSON object.")) }
        guard root["format"]?.number == 1 else { return .failure(.package("\(fileName) needs \"format\": 1.")) }
        guard let id = root["id"]?.string, ThemeIdentifier.isValid(id) else { return .failure(.package("\(fileName) needs a reverse-DNS id.")) }
        guard let version = root["version"]?.string, AppVersion(version) != nil else { return .failure(.package("\(fileName) needs a version like 1.0.0.")) }
        let payload = root["payload"]?.string ?? "payload.dylib"
        guard ThemeIdentifier.isSafeRelativePath(payload), files.contains(payload) else { return .failure(.package("The payload \(payload) is not in the package.")) }
        let archs = root["architectures"]?.array?.compactMap(\.string) ?? []
        guard !archs.isEmpty, archs.allSatisfy(["arm64e", "x86_64"].contains) else {
            return .failure(.package("\(fileName) must list its architectures: arm64e, x86_64."))
        }
        return .success(NativeModManifest(id: id, name: root["name"]?.string ?? id, version: version,
                                          bridge: root["bridge"]?.string, architectures: archs, payload: payload))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
