import Foundation

// MARK: - Updates: which release to offer, as plain functions
//
// Atelier updates itself from its GitHub Releases. Every release is published twice over: first
// as a pre-release ("beta"), which only Macs on the Beta channel see, then, once it has been
// tried, promoted to a normal release, which everyone sees. A release ships two assets:
// `Atelier-<version>.zip` (the app) and `Atelier-<version>.zip.sig` (an Ed25519 signature of the
// zip, made with a key that never leaves the maintainer's Mac). The app refuses any download
// whose signature does not match the public key built into it.

/// A semantic version: 1.4.0, 1.4.0-beta.2. Ordering follows semver: a pre-release sorts before
/// its release, numeric identifiers compare as numbers.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var prerelease: [String]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }   // build metadata is ignored
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let core = parts[0].split(separator: ".").map(String.init)
        guard (1...3).contains(core.count), let ma = Int(core[0]) else { return nil }
        let mi = core.count > 1 ? Int(core[1]) : 0, pa = core.count > 2 ? Int(core[2]) : 0
        guard let mi, let pa, ma >= 0, mi >= 0, pa >= 0 else { return nil }
        major = ma; minor = mi; patch = pa
        prerelease = parts.count > 1 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        if prerelease.contains(where: \.isEmpty) { return nil }
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false          // 1.0.0 > 1.0.0-beta
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (.some, nil): return true        // numeric identifiers sort first
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public enum UpdateChannel: String, CaseIterable, Sendable, Codable {
    /// Finished releases only.
    case stable
    /// Pre-releases too: every build is here first, before it is promoted.
    case beta
}

/// One downloadable file of a release.
public struct ReleaseAsset: Equatable, Sendable, Codable {
    public var name: String
    public var url: URL
    public var size: Int
    public init(name: String, url: URL, size: Int) { self.name = name; self.url = url; self.size = size }
}

/// A release as GitHub describes it, reduced to what the updater needs.
public struct ReleaseInfo: Equatable, Sendable, Codable {
    public var tag: String
    public var version: AppVersionBox
    public var prerelease: Bool
    public var draft: Bool
    public var title: String
    public var notes: String
    public var published: Date?
    public var page: URL?
    public var assets: [ReleaseAsset]

    /// The app archive and its signature, by Atelier's naming.
    public var archive: ReleaseAsset? { assets.first { $0.name == "Atelier-\(version.value).zip" } }
    public var signature: ReleaseAsset? { assets.first { $0.name == "Atelier-\(version.value).zip.sig" } }
    public var installable: Bool { archive != nil && signature != nil }
}

/// AppVersion stored as text, so ReleaseInfo stays Codable.
public struct AppVersionBox: Equatable, Sendable, Codable {
    public var value: AppVersion
    public init(_ value: AppVersion) { self.value = value }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let v = AppVersion(text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad version \(text)")) }
        value = v
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value.description) }
}

public enum UpdatePolicy {
    /// Reads GitHub's `GET /repos/{owner}/{repo}/releases` answer. Releases whose tag is not a
    /// version are skipped.
    public static func parseReleases(_ data: Data) throws -> [ReleaseInfo] {
        struct GHAsset: Decodable { let name: String; let browser_download_url: URL; let size: Int }
        struct GHRelease: Decodable {
            let tag_name: String; let name: String?; let body: String?; let draft: Bool; let prerelease: Bool
            let published_at: String?; let html_url: URL?; let assets: [GHAsset]
        }
        let raw = try JSONDecoder().decode([GHRelease].self, from: data)
        let iso = ISO8601DateFormatter()
        return raw.compactMap { r in
            guard let v = AppVersion(r.tag_name) else { return nil }
            return ReleaseInfo(tag: r.tag_name, version: AppVersionBox(v), prerelease: r.prerelease || v.isPrerelease,
                               draft: r.draft, title: r.name ?? r.tag_name, notes: r.body ?? "",
                               published: r.published_at.flatMap { iso.date(from: $0) }, page: r.html_url,
                               assets: r.assets.map { ReleaseAsset(name: $0.name, url: $0.browser_download_url, size: $0.size) })
        }
    }

    /// The release to offer: the newest installable one above the running version that the
    /// channel allows. Stable never sees pre-releases; Beta sees both and takes the newest.
    public static func pick(_ releases: [ReleaseInfo], current: AppVersion, channel: UpdateChannel, skipped: Set<String> = []) -> ReleaseInfo? {
        releases
            .filter { !$0.draft && $0.installable && !skipped.contains($0.version.value.description) }
            .filter { channel == .beta || !$0.prerelease }
            .filter { $0.version.value > current }
            .max { $0.version.value < $1.version.value }
    }

    /// Whether an automatic check is due.
    public static func checkDue(last: Date?, now: Date, interval: TimeInterval = 6 * 3600) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }

    /// The archive must be the size GitHub announced and sensibly sized for an app.
    public static func plausibleArchive(bytes: Int, announced: Int) -> Bool {
        bytes == announced && bytes > 1_000_000 && bytes < 600_000_000
    }
}
