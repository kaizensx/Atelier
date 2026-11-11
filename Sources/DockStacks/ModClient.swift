import DockCore
import Foundation

// MARK: - Atelier Mods: the network and disk half
//
// Downloads the signed catalog, keeps a verified copy for offline use, downloads packages and
// screenshots, and checks every byte against the signed index before anything is unpacked.
// Nothing here knows about the UI or the app's singletons, so a standalone harness can drive
// the whole path against a local catalog (see ModStore for the app side).
//
// Requests carry a generic User-Agent, no cookies and no cache: nothing about the person.

final class ModClient: @unchecked Sendable {
    struct Config: Sendable {
        var indexURL: URL
        var publicKey: String
        /// Where the verified catalog and screenshots are kept.
        var cacheFolder: URL
        /// Plain http on 127.0.0.1, for a test catalog served locally.
        var allowLoopback: Bool
        var signatureURL: URL { indexURL.deletingLastPathComponent().appendingPathComponent(indexURL.lastPathComponent + ".sig") }
    }

    let config: Config
    let session: URLSession

    init(config: Config) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 120
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "Atelier-Mods/1"]
        session = URLSession(configuration: c)
    }

    private var indexCache: URL { config.cacheFolder.appendingPathComponent("index.json") }
    private var signatureCache: URL { config.cacheFolder.appendingPathComponent("index.json.sig") }
    private var shotsFolder: URL { config.cacheFolder.appendingPathComponent("Screenshots", isDirectory: true) }

    // MARK: Catalog

    /// The last catalog that verified, from disk. Verified again: the cache is not trusted either.
    func cached() -> ModIndex? {
        guard let data = try? Data(contentsOf: indexCache), let sig = try? Data(contentsOf: signatureCache) else { return nil }
        return try? ModSignature.open(index: data, signature: sig, publicKey: config.publicKey, allowLoopback: config.allowLoopback)
    }

    /// Downloads, verifies and caches the catalog. `accepted` is the newest catalog date already
    /// accepted: an older one is refused (no rollback).
    func refresh(accepted: Date?) async throws -> ModIndex {
        guard ModURLPolicy.isAllowed(config.indexURL, allowLoopback: config.allowLoopback) else {
            throw ModCatalogError.network("The catalog address is not allowed.")
        }
        async let indexData = get(config.indexURL, limit: ModLimits.maxIndexBytes)
        async let sigData = get(config.signatureURL, limit: 4096)
        let (data, sig) = try await (indexData, sigData)
        let index = try ModSignature.open(index: data, signature: sig, publicKey: config.publicKey, allowLoopback: config.allowLoopback)
        guard ModIndexFreshness.accept(index.generated, over: accepted) else { throw ModCatalogError.stale }
        let manager = FileManager.default
        try? manager.createDirectory(at: config.cacheFolder, withIntermediateDirectories: true)
        try? data.write(to: indexCache, options: .atomic)
        try? sig.write(to: signatureCache, options: .atomic)
        return index
    }

    private func get(_ url: URL, limit: Int) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: url) } catch {
            throw ModCatalogError.network(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw ModCatalogError.network("No answer from the catalog.") }
        guard (200..<300).contains(http.statusCode) else { throw ModCatalogError.network("The catalog answered \(http.statusCode).") }
        guard data.count <= limit else { throw ModCatalogError.tooLarge(data.count) }
        return data
    }

    static func describe(_ error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "You are offline."
        case .timedOut: return "The catalog took too long to answer."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "The catalog cannot be reached."
        default: return error.localizedDescription
        }
    }

    // MARK: Packages

    /// A package downloaded, verified and unpacked into a private work folder. The caller installs
    /// `folder` and then calls `discard()`.
    struct Prepared: Sendable {
        let entry: ModEntry
        let folder: URL
        let work: URL
        let plugin: PluginManifest?
        func discard() { try? FileManager.default.removeItem(at: work) }
    }

    func prepare(_ entry: ModEntry, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Prepared {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("atelier-mod-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let zip = try await download(entry.package, kind: entry.kind, into: work, progress: progress)
            let out = work.appendingPathComponent("out", isDirectory: true)
            try Self.unzip(zip, to: out)
            let (folder, plugin) = try Self.check(unpacked: out, entry: entry)
            return Prepared(entry: entry, folder: folder, work: work, plugin: plugin)
        } catch {
            try? manager.removeItem(at: work)
            throw error
        }
    }

    /// Downloads a file the index vouches for: size and SHA-256 must match before it is used.
    func download(_ file: ModFile, kind: ModKind, into folder: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard ModURLPolicy.isAllowed(file.url, allowLoopback: config.allowLoopback) else {
            throw ModCatalogError.network("The download address is not allowed.")
        }
        guard file.size <= kind.maxPackageBytes else { throw ModCatalogError.tooLarge(file.size) }
        let temp: URL, response: URLResponse
        do { (temp, response) = try await session.download(from: file.url) } catch {
            throw ModCatalogError.network(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModCatalogError.network("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        progress?(1)
        let target = folder.appendingPathComponent("package.zip")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        if case .failure(let failure) = ModIntegrity.check(fileAt: target, against: file) { throw failure }
        return target
    }

    /// `ditto` refuses paths that escape the destination; hidden AppleDouble files are not kept.
    static func unzip(_ zip: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--noqtn", "--norsrc", "--noextattr", zip.path, destination.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModCatalogError.package("The download is not a zip archive.") }
    }

    /// Everything in an unpacked package: regular files only, within the size limit.
    static func inventory(_ folder: URL) throws -> (files: Set<String>, bytes: Int) {
        var files = Set<String>(), bytes = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw ModCatalogError.package("The package contains a link, which is not allowed.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw ModCatalogError.package("The package contains something that is not a file.") }
            bytes += values.fileSize ?? 0
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { throw ModCatalogError.package("The package reaches outside its folder.") }
            let relative = String(path.dropFirst(base.count))
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            files.insert(relative)
        }
        return (files, bytes)
    }

    /// Finds the one package folder in what was unpacked and checks it is exactly the mod the
    /// signed index describes: same id, same version, and for a plugin the same permissions.
    static func check(unpacked out: URL, entry: ModEntry) throws -> (URL, PluginManifest?) {
        let manager = FileManager.default
        let top = (try? manager.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" } ?? []
        let packages = top.filter { $0.pathExtension == entry.kind.packageExtension }
        guard packages.count == 1, let folder = packages.first else {
            throw ModCatalogError.package("The download does not hold one \(entry.kind.packageExtension) package.")
        }
        let (files, bytes) = try inventory(folder)
        guard bytes <= ModLimits.maxUnpackedBytes(entry.kind) else { throw ModCatalogError.tooLarge(bytes) }
        switch entry.kind {
        case .plugin:
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(PluginManifest.fileName)) else {
                throw ModCatalogError.package("The plugin has no manifest.json.")
            }
            let (manifest, validation) = PluginManifest.parse(data, files: files)
            guard let manifest else {
                throw ModCatalogError.package(validation.errors.map(\.description).joined(separator: " "))
            }
            if let problem = ModPackageCheck.matches(entry: entry, packageID: manifest.id, packageVersion: manifest.version)
                ?? ModPackageCheck.permissionsMatch(entry: entry, manifest: manifest) {
                throw ModCatalogError.package(problem)
            }
            return (folder, manifest)
        case .theme:
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(ThemeSchema.fileName)) else {
                throw ModCatalogError.package("The theme has no \(ThemeSchema.fileName).")
            }
            let (value, validation) = ThemeValidator.validate(data: data, files: files)
            guard let root = value?.object, validation.isValid else {
                throw ModCatalogError.package(validation.errors.map(\.description).joined(separator: " "))
            }
            let document = ThemeDocument(root: root)
            if let problem = ModPackageCheck.matches(entry: entry, packageID: document.id, packageVersion: document.version) {
                throw ModCatalogError.package(problem)
            }
            return (folder, nil)
        case .native:
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(NativeModManifest.fileName)) else {
                throw ModCatalogError.package("The native mod has no \(NativeModManifest.fileName).")
            }
            switch NativeModManifest.parse(data, files: files) {
            case .failure(let failure): throw failure
            case .success(let manifest):
                if let problem = ModPackageCheck.matches(entry: entry, packageID: manifest.id, packageVersion: manifest.version) {
                    throw ModCatalogError.package(problem)
                }
            }
            return (folder, nil)
        }
    }

    // MARK: Screenshots

    /// A screenshot's bytes, from the cache or the network, only if they match the signed hash.
    func screenshot(_ shot: ModScreenshot) async -> Data? {
        let manager = FileManager.default
        let digest = shot.sha256.lowercased()
        guard ModIntegrity.isDigest(digest) else { return nil }
        let file = shotsFolder.appendingPathComponent(digest)
        if let data = try? Data(contentsOf: file), ModIntegrity.sha256Hex(data) == digest { return data }
        guard ModURLPolicy.isAllowed(shot.url, allowLoopback: config.allowLoopback),
              let (data, response) = try? await session.data(from: shot.url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              data.count <= ModLimits.maxScreenshotBytes,
              case .success = ModIntegrity.check(data, against: ModFile(url: shot.url, sha256: digest, size: data.count)) else { return nil }
        try? manager.createDirectory(at: shotsFolder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Keeps the screenshot cache small: only pictures the current catalog still names.
    func pruneScreenshots(keeping index: ModIndex) {
        let keep = Set(index.mods.flatMap { $0.screenshots.map { $0.sha256.lowercased() } })
        for url in (try? FileManager.default.contentsOfDirectory(at: shotsFolder, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
