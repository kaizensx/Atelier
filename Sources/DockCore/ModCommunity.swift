import CryptoKit
import Foundation

// MARK: - Atelier Mods: authors, collections, counts and trust beyond the catalog key
//
// Everything here is read from the signed index, so it is as trustworthy as the index itself.
//
// Author keys. An author may sign their own packages: mod.json carries `author.key` (an Ed25519
// public key, base64) and the pull request carries `package.sig`, the author's signature over the
// exact zip the catalog publishes. The index repeats both per version (`authorKey`,
// `packageSignature`). Atelier checks the catalog's signature on the index first, then, when a
// version has an author signature, that it verifies against that version's author key. If a mod
// that was signed by one key arrives signed by another (or not at all), it "changed hands", and
// Atelier asks before installing it. Mods without author keys keep working, signed by the catalog.
//
// Installs are counted without tracking: the catalog publishes every package as a GitHub Release
// asset too, Atelier downloads from there, and the publish workflow reads the release assets'
// download counts into the index. Likes are the thumbs-up on each mod's GitHub Discussion.

/// A shelf of mods chosen by the maintainers.
public struct ModCollection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var mods: [String]

    public init(id: String, title: String, description: String? = nil, mods: [String]) {
        self.id = id; self.title = title; self.description = description; self.mods = mods
    }
}

/// Someone with mods in the catalog.
public struct ModAuthor: Codable, Equatable, Sendable, Identifiable {
    public var github: String
    public var name: String
    public var url: URL?
    public var mods: [String]
    public var id: String { github.lowercased() }

    public init(github: String, name: String, url: URL? = nil, mods: [String] = []) {
        self.github = github; self.name = name; self.url = url; self.mods = mods
    }

    public var profile: URL? { URL(string: "https://github.com/\(github)") }
}

public enum ModCommunity {
    public static let maxCollections = 24
    public static let maxCollectionSize = 48

    /// A GitHub handle: letters, digits and single hyphens, up to 39 characters.
    public static func isHandle(_ text: String) -> Bool {
        (1...39).contains(text.count) && !text.hasPrefix("-") && !text.hasSuffix("-")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Drops what Atelier should not act on: unknown key formats, links that are not https, a
    /// discussion that is not on github.com, release assets the download policy refuses.
    static func sanitize(_ e: inout ModEntry, allowLoopback: Bool) {
        if let key = e.authorKey, !ModAuthorSignature.isKey(key) { e.authorKey = nil }
        if let sig = e.packageSignature, !ModAuthorSignature.isSignature(sig) { e.packageSignature = nil }
        if e.authorKey == nil { e.packageSignature = nil }
        if e.authorURL.map({ $0.scheme != "https" || $0.host() == nil }) == true { e.authorURL = nil }
        if let d = e.discussion, !isGitHubPage(d) { e.discussion = nil }
        if let n = e.downloads, n < 0 { e.downloads = nil }
        if let n = e.likes, n < 0 { e.likes = nil }
        if let r = e.package.release, !ModURLPolicy.isAllowed(r, allowLoopback: allowLoopback) { e.package.release = nil }
        e.versions = e.versions.map { v in
            var v = v
            if let r = v.package.release, !ModURLPolicy.isAllowed(r, allowLoopback: allowLoopback) { v.package.release = nil }
            if let key = v.authorKey, !ModAuthorSignature.isKey(key) { v.authorKey = nil }
            if let sig = v.packageSignature, !ModAuthorSignature.isSignature(sig) { v.packageSignature = nil }
            if v.authorKey == nil { v.packageSignature = nil }
            return v
        }
    }

    static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host()?.lowercased() == "github.com" && url.user() == nil
    }

    static func sanitize(collections: [ModCollection], known: Set<String>) -> [ModCollection] {
        var seen = Set<String>()
        return collections.compactMap { c -> ModCollection? in
            guard !c.id.isEmpty, c.id.count <= 60, !seen.contains(c.id),
                  !c.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var ids = Set<String>()
            let mods = c.mods.filter { known.contains($0) && ids.insert($0).inserted }.prefix(maxCollectionSize)
            guard !mods.isEmpty else { return nil }
            seen.insert(c.id)
            return ModCollection(id: c.id, title: String(c.title.prefix(60)),
                                 description: c.description.map { String($0.prefix(300)) }, mods: Array(mods))
        }
        .prefix(maxCollections).map { $0 }
    }

    static func sanitize(authors: [ModAuthor], known: Set<String>) -> [ModAuthor] {
        var seen = Set<String>()
        return authors.compactMap { a -> ModAuthor? in
            guard isHandle(a.github), seen.insert(a.github.lowercased()).inserted else { return nil }
            var a = a
            a.name = String((a.name.isEmpty ? a.github : a.name).prefix(80))
            if a.url.map({ $0.scheme != "https" || $0.host() == nil }) == true { a.url = nil }
            a.mods = a.mods.filter(known.contains)
            return a
        }
    }
}

extension ModIndex {
    public func mods(in collection: ModCollection) -> [ModEntry] { collection.mods.compactMap(mod) }

    /// Everyone with a mod here: the index's `authors`, completed from the mods themselves so an
    /// index without that list still has author pages.
    public var allAuthors: [ModAuthor] {
        var byHandle: [String: ModAuthor] = [:], order: [String] = []
        for a in authors { byHandle[a.id] = a; order.append(a.id) }
        for m in mods where ModCommunity.isHandle(m.github) {
            let key = m.github.lowercased()
            if byHandle[key] == nil {
                byHandle[key] = ModAuthor(github: m.github, name: m.author.isEmpty ? m.github : m.author, url: m.authorURL)
                order.append(key)
            }
            if !(byHandle[key]?.mods.contains(m.id) ?? true) { byHandle[key]?.mods.append(m.id) }
        }
        return order.compactMap { byHandle[$0] }
    }

    public func author(_ handle: String) -> ModAuthor? {
        allAuthors.first { $0.id == handle.lowercased() }
    }

    /// An author's mods, newest first.
    public func mods(by handle: String) -> [ModEntry] {
        mods.filter { $0.github.lowercased() == handle.lowercased() }
            .sorted { ($0.updated ?? .distantPast, $0.name) > ($1.updated ?? .distantPast, $1.name) }
    }
}

// MARK: Author signatures

public enum ModAuthorSignature {
    public static func isKey(_ base64: String) -> Bool {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
    }

    public static func isSignature(_ base64: String) -> Bool {
        Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 64
    }

    /// Whether `signature` (base64, as in `package.sig`) is the author's signature of exactly
    /// these package bytes.
    public static func verify(package data: Data, signature: String, authorKey: String) -> Bool {
        ModSignature.verify(index: data, signature: Data(signature.utf8), publicKey: authorKey)
    }

    public static func verify(fileAt url: URL, signature: String, authorKey: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return verify(package: data, signature: signature, authorKey: authorKey)
    }

    /// The check Atelier runs on a downloaded zip whose size and hash already matched: when the
    /// index names an author key, the author's signature must verify too.
    public static func check(fileAt url: URL, key: String?, signature: String?) -> Result<Void, ModCatalogError> {
        guard let key else { return .success(()) }
        guard let signature, verify(fileAt: url, signature: signature, authorKey: key) else {
            return .failure(.package("The author’s signature on this package does not verify, so it was not installed."))
        }
        return .success(())
    }

    /// A short, readable fingerprint of a key for the "changed hands" sheet: 4 groups of 4 hex.
    public static func fingerprint(_ base64: String) -> String {
        guard let raw = Data(base64Encoded: base64) else { return base64 }
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: min(i + 4, hex.count))])
        }.joined(separator: " ")
    }
}

/// How an update's author key compares with the key of what is installed.
public enum ModKeyChange: Equatable, Sendable {
    /// Same key, or neither is signed.
    case same
    /// The installed version was unsigned and this one is signed: fine.
    case adopted
    /// The installed version was signed and this one is not.
    case dropped
    /// Signed by a different key.
    case changed

    public static func compare(installed: String?, candidate: String?) -> ModKeyChange {
        switch (installed, candidate) {
        case (nil, nil): .same
        case (nil, _?): .adopted
        case (_?, nil): .dropped
        case let (a?, b?): a == b ? .same : .changed
        }
    }

    /// Installing needs the owner's yes on the "This mod changed hands" sheet.
    public var needsConfirmation: Bool { self == .dropped || self == .changed }
}

extension ModEntry {
    /// Signed by the author as well as the catalog.
    public var signedByAuthor: Bool { authorKey != nil && packageSignature != nil }

    /// "Signed by the author and the catalog" or "Signed by the catalog".
    public var signingLabel: String { signedByAuthor ? "Signed by the author and the catalog" : "Signed by the catalog" }

    /// This mod as it was at an older (or the current) version, ready to install: that version's
    /// package, author key and signature, and the permissions it recorded. Nil when the catalog
    /// does not list the version.
    public func at(version: String) -> ModEntry? {
        if version == self.version { return self }
        guard let v = versions.first(where: { $0.version == version }) else { return nil }
        var e = self
        e.version = v.version
        e.package = v.package
        e.authorKey = v.authorKey
        e.packageSignature = v.packageSignature
        if let p = v.permissions { e.permissions = p }
        if let h = v.hosts { e.hosts = h }
        e.updated = v.date ?? e.updated
        return e
    }

    /// Whether the index recorded what this version asks for, so the package can be held to it.
    public func recordsPermissions(of version: String) -> Bool {
        version == self.version || versions.first { $0.version == version }?.permissions != nil
    }
}

extension ModFile {
    /// Where to download from, in order: the release asset (counted), then the dist copy.
    public var sources: [URL] { [release, url].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
}

// MARK: Counts

public enum ModCounts {
    /// 950, 1.2k, 12k, 1.2M.
    public static func short(_ n: Int) -> String {
        let n = max(0, n)
        func trim(_ v: Double) -> String {
            let text = String(format: "%.1f", v)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return trim((Double(n) / 100).rounded(.down) / 10) + "k"
        case ..<1_000_000: return "\(n / 1000)k"
        default: return trim((Double(n) / 100_000).rounded(.down) / 10) + "M"
        }
    }

    public static func installs(_ n: Int) -> String { n == 1 ? "1 install" : "\(short(n)) installs" }
    public static func likes(_ n: Int) -> String { n == 1 ? "1 like" : "\(short(n)) likes" }
}

// MARK: Updates that need a person

/// What installing a given version would change, for the review sheet: new permissions or hosts,
/// a different author key, an older version.
public struct ModInstallReview: Equatable, Sendable, Identifiable {
    public var entry: ModEntry
    public var from: String?
    public var diff: ModPermissionDiff
    public var keyChange: ModKeyChange
    public var installedKey: String?
    public var id: String { entry.id + "@" + entry.version }

    public init(entry: ModEntry, installed: InstalledModInfo?, installedKey: String?) {
        self.entry = entry
        from = installed?.version
        diff = installed.map { ModPermissionDiff(old: $0.permissions, new: entry.permissions, oldHosts: $0.hosts, newHosts: entry.hosts) }
            ?? ModPermissionDiff(old: [], new: [])
        let older = installed.map { ModVersions.isNewer($0.version, than: entry.version) } ?? false
        if installed == nil || (older && entry.authorKey == nil) {
            // Going back to a version from before the author started signing is the same mod's
            // own history in the signed index, not a new publisher.
            keyChange = .same
        } else {
            keyChange = ModKeyChange.compare(installed: installedKey, candidate: entry.authorKey)
        }
        self.installedKey = installedKey
    }

    /// Going back to an older version than the one installed.
    public var isOlder: Bool { from.map { ModVersions.isNewer($0, than: entry.version) } ?? false }

    /// Something the owner must see before it installs. A first install asks for permissions on
    /// its own sheet afterwards, so it needs no review here unless the key matters.
    public var needsReview: Bool { (from != nil && diff.needsConsent) || keyChange.needsConfirmation || isOlder }

    /// Whether Update All (or any unattended path) may install it. Never with new permissions,
    /// new hosts or a changed key.
    public var canInstallUnattended: Bool { !diff.needsConsent && !keyChange.needsConfirmation && !isOlder }
}

// MARK: Rollback

public enum ModRollback {
    /// The version to roll back to: the one remembered from before the last update when it is
    /// older and the catalog still lists it, otherwise the newest listed version older than the
    /// installed one. Never forward.
    public static func target(installed: String, remembered: String?, versions: [ModVersion]) -> ModVersion? {
        if let remembered, ModVersions.isNewer(installed, than: remembered), let v = versions.first(where: { $0.version == remembered }) { return v }
        return versions
            .filter { ModVersions.isNewer(installed, than: $0.version) }
            .sorted { (AppVersion($0.version) ?? AppVersion("0")!) > (AppVersion($1.version) ?? AppVersion("0")!) }
            .first
    }
}
