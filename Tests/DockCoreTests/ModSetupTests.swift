import Foundation
import Testing
@testable import DockCore

// `.ateliersetup`: export, import, secrets never leave the Mac.

private let sha = String(repeating: "ef", count: 32)

private func catalogEntry(_ id: String, kind: ModKind = .plugin, version: String = "1.2.0", older: [String] = []) -> ModEntry {
    let pkg = { (v: String) in ModFile(url: URL(string: "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/\(id)/\(v).zip")!, sha256: sha, size: 10) }
    return ModEntry(id: id, name: id.split(separator: ".").last.map(String.init) ?? id, author: "A", github: "a", kind: kind, version: version,
                    summary: "S", package: pkg(version), versions: ([version] + older).map { ModVersion(version: $0, package: pkg($0)) })
}

@Test func secretKeysAreRecognised() {
    for key in ["token", "githubToken", "GITHUB_TOKEN", "api_key", "apiKey", "apikey", "password", "userPassword", "secret",
                "clientSecret", "authHeader", "auth", "sessionCookie", "bearer", "privateKey", "key", "pat", "refresh-token"] {
        #expect(AtelierSetup.isSecretKey(key), "\(key) should count as a secret")
    }
    for key in ["author", "pattern", "spinner", "monkey", "keyboardLayout", "theme", "lastRun", "count", "city", "keynote"] {
        #expect(!AtelierSetup.isSecretKey(key), "\(key) should not count as a secret")
    }
}

@Test func setupRoundTripsWithoutSecrets() throws {
    let data: [String: JSONValue] = ["city": .string("Lisbon"), "githubToken": .string("ghp_secret"), "count": .number(3), "api_key": .string("k")]
    let setup = AtelierSetup(created: Date(timeIntervalSince1970: 1_800_000_000), atelier: "1.0.0",
                             mods: [.init(id: "com.example.focus", kind: "plugin", version: "1.2.0", catalog: true),
                                    .init(id: "com.example.glass", kind: "theme", version: "2.0.0", catalog: true)],
                             plugins: [.init(id: "com.example.focus", enabled: true, data: data),
                                       .init(id: "com.example.clock", enabled: false)],
                             theme: "atelier.look.midnight-glass", packs: ["com.example.icons"])
    let bytes = setup.data()
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("ghp_secret") && !text.contains("githubToken") && !text.contains("api_key"))
    let back = try AtelierSetup.parse(bytes).get()
    #expect(back.mods == setup.mods)
    #expect(back.plugins.first?.data == ["city": .string("Lisbon"), "count": .number(3)])
    #expect(back.plugins.last?.data == nil)
    #expect(back.plugins.map(\.enabled) == [true, false])
    #expect(back.theme == "atelier.look.midnight-glass")
    #expect(back.packs == ["com.example.icons"])
    #expect(back.created == setup.created)
    #expect(back.includesData)
}

@Test func setupWithoutDataHasNone() throws {
    let setup = AtelierSetup(atelier: "1.0.0", mods: [], plugins: [.init(id: "com.example.focus", enabled: true)])
    let back = try AtelierSetup.parse(setup.data()).get()
    #expect(!back.includesData)
    #expect(!String(decoding: setup.data(), as: UTF8.self).contains("\"data\""))
}

@Test func setupParsingIsStrict() throws {
    #expect(throws: AtelierSetup.Failure.notASetup) { try AtelierSetup.parse(Data("[]".utf8)).get() }
    #expect(throws: AtelierSetup.Failure.notASetup) { try AtelierSetup.parse(Data(#"{"format":1,"mods":[]}"#.utf8)).get() }
    #expect(throws: AtelierSetup.Failure.newerFormat(2)) { try AtelierSetup.parse(Data(#"{"format":2,"kind":"atelier-setup"}"#.utf8)).get() }
    #expect(throws: AtelierSetup.Failure.tooLarge) { try AtelierSetup.parse(Data(count: AtelierSetup.maxBytes + 1)).get() }
    let messy = Data("""
    {"format":1,"kind":"atelier-setup","mods":[
      {"id":"com.example.ok","kind":"plugin","version":"1.0.0"},
      {"id":"not an id","kind":"plugin","version":"1.0.0"},
      {"id":"com.example.badversion","kind":"plugin","version":"one"},
      {"id":"com.example.badkind","kind":"../plugin","version":"1.0.0"},
      {"id":"com.example.ok","kind":"plugin","version":"2.0.0"},
      {"id":"com.example.future","kind":"shader","version":"1.0.0","catalog":false}],
     "plugins":[{"id":"com.example.ok","enabled":true,"data":{"password":"x","note":"hi"}},{"id":"bad id"}],
     "theme":"../../etc","packs":["com.example.icons","nope"]}
    """.utf8)
    let setup = try AtelierSetup.parse(messy).get()
    #expect(setup.mods.map(\.id) == ["com.example.ok", "com.example.future"])
    #expect(setup.mods.last?.kind == "shader" && setup.mods.last?.catalog == false)   // an unknown kind survives
    #expect(setup.plugins.count == 1)
    #expect(setup.plugins.first?.data == ["note": .string("hi")])                    // secrets dropped on the way in too
    #expect(setup.theme == nil)
    #expect(setup.packs == ["com.example.icons"])
}

@Test func importPlanComparesWithCatalogAndThisMac() throws {
    var index = ModIndex(generated: Date(), mods: [catalogEntry("com.example.focus", older: ["1.0.0"]),
                                                   catalogEntry("com.example.glass", kind: .theme, version: "2.0.0"),
                                                   catalogEntry("com.example.clock", version: "3.0.0")])
    index.featured = []
    let setup = AtelierSetup(atelier: "1.0.0", mods: [
        .init(id: "com.example.focus", kind: "plugin", version: "1.0.0", catalog: true),   // an older version the catalog still has
        .init(id: "com.example.glass", kind: "theme", version: "1.0.0", catalog: true),    // gone from history: latest
        .init(id: "com.example.clock", kind: "plugin", version: "3.0.0", catalog: true),   // already here
        .init(id: "com.example.mine", kind: "plugin", version: "1.0.0", catalog: false),   // hand-made on the other Mac
        .init(id: "com.example.focus2", kind: "theme", version: "1.0.0", catalog: true),
    ], plugins: [])
    let installed = [InstalledModInfo(id: "com.example.clock", kind: .plugin, version: "3.0.0"),
                     InstalledModInfo(id: "com.example.glass", kind: .theme, version: "1.5.0")]
    let plan = setup.plan(index: index, installed: installed)
    #expect(plan.map(\.action) == [.install("1.0.0"), .change(from: "1.5.0", to: "2.0.0"), .alreadyInstalled, .unavailable, .unavailable])
    #expect(plan.first?.name == "focus")
    // No catalog at all: nothing can be installed.
    #expect(setup.plan(index: nil, installed: []).allSatisfy { $0.action == .unavailable })
}
