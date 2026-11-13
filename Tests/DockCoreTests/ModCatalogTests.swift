import CryptoKit
import Foundation
import Testing
@testable import DockCore

// A throwaway key for the tests; the real catalog key never appears in the repository.
private let testKey = Curve25519.Signing.PrivateKey()
private var testPrivate: String { testKey.rawRepresentation.base64EncodedString() }
private var testPublic: String { testKey.publicKey.rawRepresentation.base64EncodedString() }

private let digest = String(repeating: "ab", count: 32)

private func failure(_ result: Result<Void, ModCatalogError>) -> ModCatalogError? {
    if case .failure(let error) = result { return error }
    return nil
}

private func entryJSON(id: String = "com.example.pomodoro", kind: String = "plugin", version: String = "1.2.0",
                       url: String = "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/packages/x/1.2.0.zip",
                       sha: String = digest, size: Int = 4096, minAtelier: String = "1.0.0") -> String {
    """
    {"id":"\(id)","name":"Pomodoro","author":"Atelier Examples","github":"kaizensx","kind":"\(kind)","version":"\(version)",
     "summary":"A focus timer.","description":"# Hi\\n\\nText.","permissions":["notifications"],"hosts":[],
     "minAtelier":"\(minAtelier)","license":"MIT","tags":["focus"],"added":"2026-11-01T10:00:00Z","updated":"2026-11-10T10:00:00Z",
     "screenshots":[{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/s/1.png","sha256":"\(digest)","size":1000,"width":1280,"height":800}],
     "package":{"url":"\(url)","sha256":"\(sha)","size":\(size)},
     "versions":[{"version":"1.0.0","date":"2026-11-01T10:00:00Z","package":{"url":"\(url)","sha256":"\(sha)","size":\(size)}},
                 {"version":"1.2.0","date":"2026-11-10T10:00:00Z","notes":"Faster.","package":{"url":"\(url)","sha256":"\(sha)","size":\(size)}}]}
    """
}

private func indexJSON(_ entries: [String], featured: [String] = ["com.example.pomodoro"], format: Int = 1,
                       generated: String = "2026-11-11T12:00:00Z") -> Data {
    let featuredList = featured.map { "\"\($0)\"" }.joined(separator: ",")
    return Data("""
    {"format":\(format),"generated":"\(generated)","catalog":"kaizensx/atelier-mods","featured":[\(featuredList)],"mods":[\(entries.joined(separator: ","))]}
    """.utf8)
}

// MARK: Parsing

@Test func indexParsesEntriesVersionsAndScreenshots() throws {
    let index = try ModIndexParser.parse(indexJSON([entryJSON()]))
    #expect(index.format == 1)
    #expect(index.mods.count == 1)
    let mod = try #require(index.mod("com.example.pomodoro"))
    #expect(mod.kind == .plugin)
    #expect(mod.pluginPermissions == [.notifications])
    #expect(mod.screenshots.count == 1)
    #expect(mod.versions.map(\.version) == ["1.2.0", "1.0.0"])    // newest first, whatever the order in the file
    #expect(mod.versions.first?.notes == "Faster.")
    #expect(index.featuredMods.map(\.id) == ["com.example.pomodoro"])
    #expect(mod.added == ModDates.parse("2026-11-01T10:00:00Z"))
}

@Test func indexSkipsBadEntriesInsteadOfFailing() throws {
    let entries = [
        entryJSON(),
        entryJSON(id: "not an id"),
        entryJSON(id: "com.example.http", url: "http://example.com/x.zip"),           // not https
        entryJSON(id: "com.example.local", url: "https://192.168.1.2/x.zip"),         // private address
        entryJSON(id: "com.example.sha", sha: "1234"),                                // not a digest
        entryJSON(id: "com.example.big", size: 3 * 1024 * 1024),                      // over the plugin limit
        entryJSON(id: "com.example.kind", kind: "virus"),
        entryJSON(id: "com.example.version", version: "one"),
        entryJSON(),                                                                  // duplicate id
        #"{"id":"com.example.broken"}"#,
    ]
    let index = try ModIndexParser.parse(indexJSON(entries, featured: ["com.example.pomodoro", "com.example.gone"]))
    #expect(index.mods.map(\.id) == ["com.example.pomodoro"])
    #expect(index.featured == ["com.example.pomodoro"])
    // A big theme is fine: themes may be 40 MB.
    let theme = try ModIndexParser.parse(indexJSON([entryJSON(id: "com.example.theme", kind: "theme", size: 30 * 1024 * 1024)]))
    #expect(theme.mods.count == 1)
}

@Test func indexRefusesNewerFormatsAndJunk() {
    #expect(throws: ModCatalogError.newerFormat(2)) { try ModIndexParser.parse(indexJSON([entryJSON()], format: 2)) }
    #expect(throws: ModCatalogError.self) { try ModIndexParser.parse(Data("[]".utf8)) }
    #expect(throws: ModCatalogError.self) { try ModIndexParser.parse(Data(#"{"format":1}"#.utf8)) }
}

@Test func loopbackIsOnlyForTestCatalogs() throws {
    let local = entryJSON(url: "http://127.0.0.1:8765/packages/x/1.2.0.zip")
    #expect(try ModIndexParser.parse(indexJSON([local])).mods.isEmpty)
    #expect(try ModIndexParser.parse(indexJSON([local]), allowLoopback: true).mods.count == 1)
    #expect(ModURLPolicy.isAllowed(URL(string: "https://raw.githubusercontent.com/a")!, allowLoopback: false))
    #expect(!ModURLPolicy.isAllowed(URL(string: "https://raw.githubusercontent.com:8443/a")!, allowLoopback: false))
    #expect(!ModURLPolicy.isAllowed(URL(string: "https://user:pw@example.com/a")!, allowLoopback: false))
    #expect(!ModURLPolicy.isAllowed(URL(string: "http://localhost/a")!, allowLoopback: false))
    #expect(ModURLPolicy.isAllowed(URL(string: "http://localhost:9000/a")!, allowLoopback: true))
    #expect(!ModURLPolicy.isAllowed(URL(string: "http://example.com/a")!, allowLoopback: true))
}

@Test func indexRoundTripsThroughTheEncoder() throws {
    let index = try ModIndexParser.parse(indexJSON([entryJSON()]))
    let data = try ModIndexParser.encoder.encode(index)
    #expect(try ModIndexParser.parse(data) == index)
}

// MARK: Signatures

@Test func signatureVerifiesExactBytesOnly() throws {
    let data = indexJSON([entryJSON()])
    let signature = try #require(ModSignature.sign(data, privateKey: testPrivate))
    // Published as base64 text with a trailing newline.
    let published = Data((signature + "\n").utf8)
    #expect(ModSignature.verify(index: data, signature: published, publicKey: testPublic))
    #expect(ModSignature.verify(index: data, signature: Data(base64Encoded: signature)!, publicKey: testPublic))
    // One byte changed in the index.
    var tampered = data
    tampered[tampered.count - 3] ^= 0x01
    #expect(!ModSignature.verify(index: tampered, signature: published, publicKey: testPublic))
    // Another key.
    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(!ModSignature.verify(index: data, signature: published, publicKey: other))
    // Garbage.
    #expect(!ModSignature.verify(index: data, signature: Data("nope".utf8), publicKey: testPublic))
    #expect(!ModSignature.verify(index: data, signature: published, publicKey: "short"))
}

@Test func openVerifiesBeforeParsing() throws {
    let data = indexJSON([entryJSON()])
    let signature = Data(ModSignature.sign(data, privateKey: testPrivate)!.utf8)
    #expect(try ModSignature.open(index: data, signature: signature, publicKey: testPublic).mods.count == 1)
    var tampered = data
    tampered.append(contentsOf: Array(" ".utf8))
    #expect(throws: ModCatalogError.signature) { try ModSignature.open(index: tampered, signature: signature, publicKey: testPublic) }
}

@Test func theBuiltInKeyIsAValidEd25519Key() throws {
    // The same value as ModsConfig.publicKey in the app and catalog.json in the catalog.
    let key = try #require(Data(base64Encoded: "SATwJOjY3lMsJm4Ak8pOlyv54/DlSPynY0qz71XiGSY="))
    #expect(key.count == 32)
    #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil)
}

@Test func signaturesFromNodeVerify() throws {
    // Made with the catalog's scripts/sign-index.mjs (Node's crypto.sign) with a throwaway key,
    // so the two implementations are known to agree on the format.
    let publicKey = "CyvMGEKX47/mqj6axII3u5cMWZfBxFqacvU5G6JIrU0="
    let message = Data("{\"format\":1}\n".utf8)
    let signature = Data("04/deZ3Z3p/XTp5SWcBh6TwjCrJ0UaltCPVh2cp+sFiS0Ls+6dC5e2yFNqoICa1QkXy5CqUDAbHTKJlAPbLbBQ==\n".utf8)
    #expect(ModSignature.verify(index: message, signature: signature, publicKey: publicKey))
}

@Test func catalogNeverGoesBackInTime() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(ModIndexFreshness.accept(now, over: nil))
    #expect(ModIndexFreshness.accept(now, over: now))
    #expect(ModIndexFreshness.accept(now.addingTimeInterval(60), over: now))
    #expect(!ModIndexFreshness.accept(now.addingTimeInterval(-60), over: now))
}

// MARK: Checksums

@Test func sha256MatchesKnownVectorsAndSizes() throws {
    #expect(ModIntegrity.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let data = Data("abc".utf8)
    let file = ModFile(url: URL(string: "https://example.com/a.zip")!, sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", size: 3)
    #expect(failure(ModIntegrity.check(data, against: file)) == nil)
    #expect(failure(ModIntegrity.check(Data("abd".utf8), against: file)) == .checksum)
    #expect(failure(ModIntegrity.check(Data("abcd".utf8), against: file)) == .size(expected: 3, got: 4))
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mod-\(UUID().uuidString).bin")
    try Data((0..<3_000_000).map { UInt8($0 % 251) }).write(to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }
    let whole = ModIntegrity.sha256Hex(try Data(contentsOf: temp))
    #expect(try ModIntegrity.sha256Hex(fileAt: temp) == whole)
    #expect(failure(ModIntegrity.check(fileAt: temp, against: ModFile(url: file.url, sha256: whole, size: 3_000_000))) == nil)
    #expect(failure(ModIntegrity.check(fileAt: temp, against: ModFile(url: file.url, sha256: digest, size: 3_000_000))) == .checksum)
    #expect(ModIntegrity.isDigest(digest))
    #expect(!ModIntegrity.isDigest("zz" + String(digest.dropFirst(2))))
}

// MARK: Versions

@Test func versionComparison() {
    #expect(ModVersions.isNewer("1.2.0", than: "1.1.9"))
    #expect(ModVersions.isNewer("1.10.0", than: "1.9.0"))
    #expect(ModVersions.isNewer("2.0.0", than: "2.0.0-beta.3"))
    #expect(ModVersions.isNewer("2.0.0-beta.10", than: "2.0.0-beta.9"))
    #expect(!ModVersions.isNewer("1.0.0", than: "1.0.0"))
    #expect(!ModVersions.isNewer("1.0.0", than: "1.0.1"))
    #expect(!ModVersions.isNewer("junk", than: "1.0.0"))
    #expect(ModVersions.isNewer("1.0.1", than: "junk"))       // a broken install can be repaired
}

@Test func compatibilityIgnoresPrereleaseOfTheSameVersion() {
    #expect(ModVersions.isCompatible(minAtelier: "1.0.0", running: "1.0.0-beta.1"))
    #expect(ModVersions.isCompatible(minAtelier: "1.0", running: "1.0.0"))
    #expect(!ModVersions.isCompatible(minAtelier: "1.1.0", running: "1.0.9"))
    #expect(ModVersions.isCompatible(minAtelier: nil, running: "1.0.0"))
    #expect(ModVersions.isCompatible(minAtelier: "9.0.0", running: "dev"))
}

// MARK: Permissions and updates

@Test func permissionDiff() {
    let same = ModPermissionDiff(old: ["network"], new: ["network"], oldHosts: ["api.github.com"], newHosts: ["API.github.com"])
    #expect(same.isEmpty && !same.needsConsent)
    let more = ModPermissionDiff(old: ["notifications"], new: ["notifications", "network"], oldHosts: [], newHosts: ["api.example.com"])
    #expect(more.added == ["network"])
    #expect(more.addedHosts == ["api.example.com"])
    #expect(more.needsConsent)
    let less = ModPermissionDiff(old: ["network", "openURL"], new: ["network"])
    #expect(less.removed == ["openURL"])
    #expect(!less.needsConsent)
    let host = ModPermissionDiff(old: ["network"], new: ["network"], oldHosts: ["a.example.com"], newHosts: ["a.example.com", "b.example.com"])
    #expect(host.needsConsent && host.added.isEmpty)
}

@Test func updatesComeFromNewerCatalogVersions() throws {
    let index = try ModIndexParser.parse(indexJSON([
        entryJSON(),
        entryJSON(id: "com.example.midnight", kind: "theme", version: "1.0.0"),
        entryJSON(id: "com.example.later", version: "3.0.0", minAtelier: "5.0.0"),
    ]))
    let installed = [
        InstalledModInfo(id: "com.example.pomodoro", kind: .plugin, version: "1.0.0", permissions: []),
        InstalledModInfo(id: "com.example.midnight", kind: .theme, version: "1.0.0"),
        InstalledModInfo(id: "com.example.later", kind: .plugin, version: "2.0.0", permissions: ["notifications"]),
        InstalledModInfo(id: "com.example.mine", kind: .plugin, version: "0.1.0"),
        // Same id, different kind: never offered as an update.
    ]
    let updates = ModUpdates.available(installed: installed, index: index, atelier: "1.0.0-beta.1")
    #expect(updates.count == 2)
    let pomodoro = try #require(updates.first { $0.id == "com.example.pomodoro" })
    #expect(pomodoro.from == "1.0.0" && pomodoro.to == "1.2.0")
    #expect(pomodoro.diff.added == ["notifications"])
    #expect(pomodoro.compatible)
    let later = try #require(updates.first { $0.id == "com.example.later" })
    #expect(!later.compatible)
    #expect(!later.diff.needsConsent)
    let wrongKind = ModUpdates.available(installed: [InstalledModInfo(id: "com.example.pomodoro", kind: .theme, version: "0.1.0")],
                                         index: index, atelier: "1.0.0")
    #expect(wrongKind.isEmpty)
}

@Test func dailyCheck() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(ModUpdates.checkDue(last: nil, now: now))
    #expect(!ModUpdates.checkDue(last: now.addingTimeInterval(-3600), now: now))
    #expect(ModUpdates.checkDue(last: now.addingTimeInterval(-86_400), now: now))
    #expect(ModUpdates.checkDue(last: now.addingTimeInterval(3600), now: now))      // clock went back
}

// MARK: Browsing

@Test func searchAndKindFilters() throws {
    let index = try ModIndexParser.parse(indexJSON([
        entryJSON(),
        entryJSON(id: "com.example.midnight", kind: "theme"),
        entryJSON(id: "com.example.dockfx", kind: "native", size: 1000),
    ]))
    #expect(ModQuery.filter(index.mods, kind: nil, text: "", includeNative: false).count == 2)
    #expect(ModQuery.filter(index.mods, kind: nil, text: "", includeNative: true).count == 3)
    #expect(ModQuery.filter(index.mods, kind: .theme, text: "", includeNative: true).map(\.id) == ["com.example.midnight"])
    #expect(ModQuery.filter(index.mods, kind: nil, text: "midnight", includeNative: false).map(\.id) == ["com.example.midnight"])
    #expect(ModQuery.filter(index.mods, kind: nil, text: "focus KAIZENSX", includeNative: false).count == 2)
    #expect(ModQuery.filter(index.mods, kind: .native, text: "", includeNative: false).isEmpty)
    #expect(ModQuery.newest(index.mods, count: 1).count == 1)
}

// MARK: Package checks

@Test func packageMustBeTheModTheIndexNames() throws {
    let entry = try #require(try ModIndexParser.parse(indexJSON([entryJSON()])).mods.first)
    #expect(ModPackageCheck.matches(entry: entry, packageID: entry.id, packageVersion: "1.2.0") == nil)
    #expect(ModPackageCheck.matches(entry: entry, packageID: "com.evil.other", packageVersion: "1.2.0") != nil)
    #expect(ModPackageCheck.matches(entry: entry, packageID: entry.id, packageVersion: "1.1.0") != nil)
    let ok = PluginManifest(id: entry.id, name: "Pomodoro", version: "1.2.0", permissions: [.notifications])
    #expect(ModPackageCheck.permissionsMatch(entry: entry, manifest: ok) == nil)
    let sneaky = PluginManifest(id: entry.id, name: "Pomodoro", version: "1.2.0", permissions: [.notifications, .network], hosts: ["evil.example.com"])
    #expect(ModPackageCheck.permissionsMatch(entry: entry, manifest: sneaky) != nil)
}

@Test func permissionScanFindsWhatTheScriptCalls() {
    let pomodoro = """
    // atelier.http.get is mentioned in a comment only
    const s = "atelier.theme.apply in a string";
    atelier.notify("Done", "Take five.");
    atelier . openURL("https://example.com");
    /* atelier.http.get("https://x") */
    """
    let result = ModScan.scan(pomodoro)
    #expect(result.used.contains(.notifications))
    #expect(result.used.contains(.openURL))
    #expect(!result.used.contains(.network))
    // Strings are code to the scan: a mention in a string counts. Over-reporting is the safe side.
    #expect(result.used.contains(.appearance))
    #expect(!result.dynamicAccess)
    #expect(ModScan.scan("atelier.http.get(u)").used == [.network])
    #expect(ModScan.scan("const a = atelier; a.http.get(u)").dynamicAccess)
    #expect(ModScan.scan("atelier[\"ht\" + \"tp\"].get(u)").dynamicAccess)
    #expect(ModScan.scan("atelier.widget({})").used.isEmpty)
}

@Test func nativeManifest() {
    let good = Data(#"{"format":1,"id":"com.example.dockfx","name":"Dock FX","version":"1.0.0","architectures":["arm64e","x86_64"],"payload":"payload.dylib","bridge":"1.0"}"#.utf8)
    if case .success(let m) = NativeModManifest.parse(good, files: ["payload.dylib", "atelier-mod.json"]) {
        #expect(m.id == "com.example.dockfx" && m.architectures == ["arm64e", "x86_64"])
    } else {
        Issue.record("a good native manifest was refused")
    }
    #expect((try? NativeModManifest.parse(good, files: ["atelier-mod.json"]).get()) == nil)       // payload missing
    let escape = Data(#"{"format":1,"id":"com.example.x","version":"1.0.0","architectures":["arm64e"],"payload":"../x.dylib"}"#.utf8)
    #expect((try? NativeModManifest.parse(escape, files: ["../x.dylib"]).get()) == nil)
    let arch = Data(#"{"format":1,"id":"com.example.x","version":"1.0.0","architectures":["ppc"],"payload":"p.dylib"}"#.utf8)
    #expect((try? NativeModManifest.parse(arch, files: ["p.dylib"]).get()) == nil)
}

@Test func packageExtensions() {
    #expect(ModKind.plugin.packageExtension == "atelierplugin")
    #expect(ModKind.theme.packageExtension == "ateliertheme")
    #expect(ModKind.native.packageExtension == "ateliermod")
}

// MARK: Community fields: authors, collections, installs, likes, discussion, release assets

private let communityKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
private let communitySig = Data(repeating: 7, count: 64).base64EncodedString()

private func communityEntryJSON(id: String = "com.example.pomodoro", github: String = "kaizensx",
                                key: String = communityKey, discussion: String = "https://github.com/kaizensx/atelier-mods/discussions/12",
                                release: String = "https://github.com/kaizensx/atelier-mods/releases/download/com.example.pomodoro%401.2.0/1.2.0.zip",
                                authorURL: String = "https://example.com", downloads: Int = 1234) -> String {
    """
    {"id":"\(id)","name":"Pomodoro","author":"Ana","github":"\(github)","kind":"plugin","version":"1.2.0",
     "summary":"A focus timer.","permissions":["notifications"],"hosts":[],"tags":["focus"],
     "updated":"2026-11-10T10:00:00Z","screenshots":[],
     "authorKey":"\(key)","packageSignature":"\(communitySig)","authorURL":"\(authorURL)",
     "downloads":\(downloads),"likes":9,"discussion":"\(discussion)",
     "package":{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/1.2.0.zip","sha256":"\(digest)","size":4096,"release":"\(release)"},
     "versions":[{"version":"1.2.0","authorKey":"\(key)","packageSignature":"\(communitySig)","permissions":["notifications"],"hosts":[],
                  "package":{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/1.2.0.zip","sha256":"\(digest)","size":4096,"release":"\(release)"}},
                 {"version":"1.0.0","package":{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/1.0.0.zip","sha256":"\(digest)","size":4000}}]}
    """
}

private func communityIndex(_ entries: [String], extra: String) -> Data {
    Data("""
    {"format":1,"generated":"2026-11-11T12:00:00Z","featured":["com.example.pomodoro"],"mods":[\(entries.joined(separator: ","))],\(extra)}
    """.utf8)
}

@Test func indexCarriesAuthorKeysCountsAndReleaseAssets() throws {
    let index = try ModIndexParser.parse(communityIndex([communityEntryJSON()], extra: #""featuredNote":"Focus week.""#))
    let mod = try #require(index.mod("com.example.pomodoro"))
    #expect(mod.authorKey == communityKey)
    #expect(mod.packageSignature == communitySig)
    #expect(mod.signedByAuthor)
    #expect(mod.downloads == 1234 && mod.likes == 9)
    #expect(mod.discussion?.absoluteString == "https://github.com/kaizensx/atelier-mods/discussions/12")
    #expect(mod.authorURL?.host() == "example.com")
    #expect(mod.package.release?.host() == "github.com")
    #expect(mod.package.sources.first == mod.package.release)                 // release asset first, counted
    #expect(mod.package.sources.last == mod.package.url)                      // dist copy as the fallback
    #expect(mod.versions.first?.permissions == ["notifications"])
    #expect(mod.versions.last?.authorKey == nil)                              // an old unsigned version
    #expect(index.featuredNote == "Focus week.")
    // Round trip keeps every new field.
    #expect(try ModIndexParser.parse(ModIndexParser.encoder.encode(index)) == index)
}

@Test func indexDropsUnsafeCommunityFields() throws {
    let entry = communityEntryJSON(key: "not a key", discussion: "https://evil.example/discussions/1",
                                   release: "http://github.com/x.zip", authorURL: "http://example.com", downloads: -5)
    let mod = try #require(try ModIndexParser.parse(communityIndex([entry], extra: #""collections":[]"#)).mods.first)
    #expect(mod.authorKey == nil && mod.packageSignature == nil)              // no key, no signature to check
    #expect(!mod.signedByAuthor)
    #expect(mod.signingLabel == "Signed by the catalog")
    #expect(mod.discussion == nil)                                            // only github.com
    #expect(mod.package.release == nil)                                       // only https
    #expect(mod.authorURL == nil)
    #expect(mod.downloads == nil)
    #expect(mod.package.sources == [mod.package.url])
}

@Test func collectionsAndAuthorsAreCheckedAgainstTheCatalog() throws {
    let extra = """
    "collections":[{"id":"focus","title":"Focus","description":"Stay on task.","mods":["com.example.pomodoro","com.example.gone","com.example.pomodoro"]},
                   {"id":"empty","title":"Nothing here","mods":["com.example.gone"]},
                   {"id":"focus","title":"Duplicate","mods":["com.example.pomodoro"]},
                   {"id":"untitled","title":" ","mods":["com.example.pomodoro"]}],
    "authors":[{"github":"kaizensx","name":"Kaizen","url":"https://example.com","mods":["com.example.pomodoro","com.example.gone"]},
               {"github":"-bad-","name":"Bad"},
               {"github":"KAIZENSX","name":"Again"}]
    """
    let index = try ModIndexParser.parse(communityIndex([communityEntryJSON(), communityEntryJSON(id: "com.example.other", github: "someone")], extra: extra))
    #expect(index.collections.map(\.id) == ["focus"])
    #expect(index.collections.first?.mods == ["com.example.pomodoro"])       // unknown and repeated ids dropped
    #expect(index.mods(in: index.collections[0]).map(\.id) == ["com.example.pomodoro"])
    #expect(index.authors.map(\.github) == ["kaizensx"])
    #expect(index.authors.first?.mods == ["com.example.pomodoro"])
    // Author pages work for everyone, listed or not.
    #expect(index.allAuthors.map(\.github) == ["kaizensx", "someone"])
    #expect(index.author("SOMEONE")?.mods == ["com.example.other"])
    #expect(index.mods(by: "kaizensx").map(\.id) == ["com.example.pomodoro"])
    #expect(index.author("kaizensx")?.profile?.absoluteString == "https://github.com/kaizensx")
}

@Test func searchMatchesAuthorAndTags() throws {
    let index = try ModIndexParser.parse(communityIndex([communityEntryJSON()], extra: #""authors":[]"#))
    #expect(ModQuery.filter(index.mods, kind: nil, text: "ana", includeNative: false).count == 1)
    #expect(ModQuery.filter(index.mods, kind: nil, text: "kaizensx", includeNative: false).count == 1)
    #expect(ModQuery.filter(index.mods, kind: nil, text: "focus", includeNative: false).count == 1)
    #expect(ModQuery.filter(index.mods, kind: nil, text: "nobody", includeNative: false).isEmpty)
}

@Test func installCountsReadShort() {
    #expect(ModCounts.short(0) == "0")
    #expect(ModCounts.short(950) == "950")
    #expect(ModCounts.short(1000) == "1k")
    #expect(ModCounts.short(1234) == "1.2k")
    #expect(ModCounts.short(1299) == "1.2k")                                  // never rounds up past the real count
    #expect(ModCounts.short(12_345) == "12k")
    #expect(ModCounts.short(1_250_000) == "1.2M")
    #expect(ModCounts.installs(1) == "1 install")
    #expect(ModCounts.installs(1234) == "1.2k installs")
    #expect(ModCounts.likes(3) == "3 likes")
}
