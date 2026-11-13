import CryptoKit
import Foundation
import Testing
@testable import DockCore

// Author signatures, the "changed hands" check, permission diffs on updates, rollback.

private let author = Curve25519.Signing.PrivateKey()
private let stranger = Curve25519.Signing.PrivateKey()
private func pub(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }
private func priv(_ k: Curve25519.Signing.PrivateKey) -> String { k.rawRepresentation.base64EncodedString() }
private let hex = String(repeating: "cd", count: 32)

private func file(_ version: String) -> ModFile {
    ModFile(url: URL(string: "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/\(version).zip")!, sha256: hex, size: 100)
}

private func entry(version: String = "2.0.0", permissions: [String] = ["notifications"], hosts: [String] = [],
                   key: String? = nil, versions: [ModVersion] = []) -> ModEntry {
    var e = ModEntry(id: "com.example.focus", name: "Focus", author: "Ana", github: "ana", kind: .plugin, version: version,
                     summary: "Focus.", permissions: permissions, hosts: hosts, package: file(version), versions: versions)
    e.authorKey = key
    e.packageSignature = key == nil ? nil : Data(repeating: 1, count: 64).base64EncodedString()
    return e
}

@Test func authorSignatureVerifiesThePackageBytes() throws {
    let zip = Data("PK\u{3}\u{4} a package".utf8)
    let signature = try #require(ModSignature.sign(zip, privateKey: priv(author)))
    #expect(ModAuthorSignature.isKey(pub(author)))
    #expect(!ModAuthorSignature.isKey("AAAA"))
    #expect(ModAuthorSignature.isSignature(signature))
    #expect(ModAuthorSignature.verify(package: zip, signature: signature, authorKey: pub(author)))
    #expect(ModAuthorSignature.verify(package: zip, signature: signature + "\n", authorKey: pub(author)))     // as package.sig is written
    #expect(!ModAuthorSignature.verify(package: zip + Data([0]), signature: signature, authorKey: pub(author)))
    #expect(!ModAuthorSignature.verify(package: zip, signature: signature, authorKey: pub(stranger)))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).zip")
    try zip.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect((try? ModAuthorSignature.check(fileAt: url, key: pub(author), signature: signature).get()) != nil)
    #expect((try? ModAuthorSignature.check(fileAt: url, key: pub(stranger), signature: signature).get()) == nil)
    #expect((try? ModAuthorSignature.check(fileAt: url, key: pub(author), signature: nil).get()) == nil)     // key without signature fails
    #expect((try? ModAuthorSignature.check(fileAt: url, key: nil, signature: nil).get()) != nil)             // unsigned mods keep working
}

@Test func authorSignaturesFromNodeVerify() throws {
    // Made with the catalog's scripts/lib.mjs ed25519Sign (what sign-package.mjs uses: Node's
    // crypto.sign) and a throwaway key, so both sides agree on the format.
    let key = "kP7I4eefIr9ALGtFI8BLZHSi5yCaJ7AOsjSV8Alge5Y="
    let message = Data("atelier package bytes\n".utf8)
    let signature = "mlcu/DE1snwD+seqt39BIwO8/Gpsh8DIMvCYfVzuoXs1es4F41IP7uBV91u+2PG7cmwTh8Uey2e2PJZ04riaAA==\n"
    #expect(ModAuthorSignature.verify(package: message, signature: signature, authorKey: key))
}

@Test func keyChangesThatNeedTheOwner() {
    #expect(ModKeyChange.compare(installed: nil, candidate: nil) == .same)
    #expect(ModKeyChange.compare(installed: "a", candidate: "a") == .same)
    #expect(ModKeyChange.compare(installed: nil, candidate: "a") == .adopted)
    #expect(ModKeyChange.compare(installed: "a", candidate: nil) == .dropped)
    #expect(ModKeyChange.compare(installed: "a", candidate: "b") == .changed)
    #expect(!ModKeyChange.adopted.needsConfirmation)
    #expect(ModKeyChange.dropped.needsConfirmation && ModKeyChange.changed.needsConfirmation)
    #expect(ModAuthorSignature.fingerprint(pub(author)).split(separator: " ").count == 4)
}

@Test func updatesWithNewPermissionsOrHostsWaitForReview() {
    let installed = InstalledModInfo(id: "com.example.focus", kind: .plugin, version: "1.0.0", permissions: ["notifications"], hosts: [])
    // Same permissions: Update All may install it.
    let plain = ModInstallReview(entry: entry(), installed: installed, installedKey: nil)
    #expect(!plain.needsReview && plain.canInstallUnattended)
    // A new permission.
    let more = ModInstallReview(entry: entry(permissions: ["notifications", "network"], hosts: ["api.example.com"]), installed: installed, installedKey: nil)
    #expect(more.diff.added == ["network"] && more.diff.addedHosts == ["api.example.com"])
    #expect(more.needsReview && !more.canInstallUnattended)
    // A new host only.
    let host = ModInstallReview(entry: entry(permissions: ["notifications"], hosts: ["api.example.com"]),
                                installed: InstalledModInfo(id: "com.example.focus", kind: .plugin, version: "1.0.0", permissions: ["notifications"]),
                                installedKey: nil)
    #expect(!host.canInstallUnattended)
    // Asking for less is fine.
    let less = ModInstallReview(entry: entry(permissions: []), installed: installed, installedKey: nil)
    #expect(less.canInstallUnattended && less.diff.removed == ["notifications"])
    // A first install asks on the permission sheet after installing, not here.
    let fresh = ModInstallReview(entry: entry(permissions: ["network"]), installed: nil, installedKey: nil)
    #expect(!fresh.needsReview && fresh.keyChange == .same)
}

@Test func aChangedAuthorKeyNeedsTheOwner() {
    let installed = InstalledModInfo(id: "com.example.focus", kind: .plugin, version: "1.0.0", permissions: ["notifications"])
    let same = ModInstallReview(entry: entry(key: pub(author)), installed: installed, installedKey: pub(author))
    #expect(same.canInstallUnattended)
    let adopted = ModInstallReview(entry: entry(key: pub(author)), installed: installed, installedKey: nil)
    #expect(adopted.keyChange == .adopted && adopted.canInstallUnattended)
    let changed = ModInstallReview(entry: entry(key: pub(stranger)), installed: installed, installedKey: pub(author))
    #expect(changed.keyChange == .changed && changed.needsReview && !changed.canInstallUnattended)
    let dropped = ModInstallReview(entry: entry(key: nil), installed: installed, installedKey: pub(author))
    #expect(dropped.keyChange == .dropped && !dropped.canInstallUnattended)
}

@Test func olderVersionsInstallFromHistoryWithAWarning() throws {
    let history = [
        ModVersion(version: "2.0.0", package: file("2.0.0"), authorKey: pub(author), packageSignature: Data(repeating: 2, count: 64).base64EncodedString(),
                   permissions: ["notifications", "network"], hosts: ["api.example.com"]),
        ModVersion(version: "1.5.0", package: file("1.5.0"), permissions: ["notifications"], hosts: []),
        ModVersion(version: "1.0.0", package: file("1.0.0")),
    ]
    let latest = entry(permissions: ["notifications", "network"], hosts: ["api.example.com"], key: pub(author), versions: history)
    let old = try #require(latest.at(version: "1.5.0"))
    #expect(old.version == "1.5.0" && old.package == file("1.5.0"))
    #expect(old.permissions == ["notifications"] && old.hosts.isEmpty)       // what that version asked for
    #expect(old.authorKey == nil && !old.signedByAuthor)
    #expect(latest.at(version: "9.9.9") == nil)
    #expect(latest.at(version: "2.0.0") == latest)
    #expect(latest.recordsPermissions(of: "1.5.0"))
    #expect(!latest.recordsPermissions(of: "1.0.0"))

    let installed = InstalledModInfo(id: latest.id, kind: .plugin, version: "2.0.0", permissions: ["notifications", "network"], hosts: ["api.example.com"])
    let back = ModInstallReview(entry: old, installed: installed, installedKey: nil)
    #expect(back.isOlder && back.needsReview && !back.canInstallUnattended)
    // Rolling back past the point the author started signing is not "changed hands"...
    let unsignedPast = ModInstallReview(entry: old, installed: installed, installedKey: pub(author))
    #expect(unsignedPast.keyChange == .same && unsignedPast.isOlder)
    // ...but an older version signed by someone else is.
    var foreign = old; foreign.authorKey = pub(stranger)
    #expect(ModInstallReview(entry: foreign, installed: installed, installedKey: pub(author)).keyChange == .changed)
}

@Test func rollbackGoesToThePreviousVersion() {
    let history = [ModVersion(version: "2.0.0", package: file("2.0.0")), ModVersion(version: "1.5.0", package: file("1.5.0")),
                   ModVersion(version: "1.0.0", package: file("1.0.0"))]
    #expect(ModRollback.target(installed: "2.0.0", remembered: "1.0.0", versions: history)?.version == "1.0.0")
    #expect(ModRollback.target(installed: "2.0.0", remembered: nil, versions: history)?.version == "1.5.0")
    #expect(ModRollback.target(installed: "2.0.0", remembered: "0.9.0", versions: history)?.version == "1.5.0")   // delisted: next older
    #expect(ModRollback.target(installed: "1.0.0", remembered: nil, versions: history) == nil)
    // After a rollback the remembered version is the newer one; "Roll Back" never goes forward.
    #expect(ModRollback.target(installed: "1.5.0", remembered: "2.0.0", versions: history)?.version == "1.0.0")
}
