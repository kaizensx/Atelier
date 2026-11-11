import Foundation
import Testing
@testable import DockCore

private func v(_ s: String) -> AppVersion { AppVersion(s)! }

private func release(_ tag: String, pre: Bool = false, draft: Bool = false, assets: Bool = true) -> ReleaseInfo {
    let version = AppVersion(tag)!.description
    let base = URL(string: "https://example.com/")!
    return ReleaseInfo(tag: tag, version: AppVersionBox(AppVersion(tag)!), prerelease: pre, draft: draft, title: tag, notes: "",
                       published: nil, page: nil,
                       assets: assets ? [ReleaseAsset(name: "Atelier-\(version).zip", url: base, size: 5_000_000),
                                         ReleaseAsset(name: "Atelier-\(version).zip.sig", url: base, size: 88)] : [])
}

@Test func semverOrdersLikeSemver() {
    let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                   "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"].map(v)
    for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
    #expect(v("v1.2.3") == v("1.2.3"))
    #expect(v("1.2") == v("1.2.0"))
    #expect(v("1.2.3+build.9") == v("1.2.3"))
    #expect(AppVersion("one.two") == nil)
    #expect(AppVersion("1.0.0-") == nil)
    #expect(v("1.0.0-beta.1").description == "1.0.0-beta.1")
}

@Test func stableNeverSeesBetas() {
    let all = [release("1.0.0"), release("1.1.0-beta.1", pre: true), release("1.0.1")]
    #expect(UpdatePolicy.pick(all, current: v("1.0.0"), channel: .stable)?.tag == "1.0.1")
    #expect(UpdatePolicy.pick(all, current: v("1.0.0"), channel: .beta)?.tag == "1.1.0-beta.1")
    // a beta tagged without GitHub's pre-release flag is still a beta
    let unflagged = [release("1.2.0-beta.1")]
    let parsedLike = unflagged.map { r -> ReleaseInfo in var r = r; r.prerelease = r.version.value.isPrerelease; return r }
    #expect(UpdatePolicy.pick(parsedLike, current: v("1.0.0"), channel: .stable) == nil)
}

@Test func betaUsersMoveOnToTheFinalRelease() {
    // on 1.1.0-beta.2: the promoted 1.1.0 is newer and is offered on both channels
    let all = [release("1.1.0-beta.2", pre: true), release("1.1.0")]
    #expect(UpdatePolicy.pick(all, current: v("1.1.0-beta.2"), channel: .beta)?.tag == "1.1.0")
    #expect(UpdatePolicy.pick(all, current: v("1.1.0-beta.2"), channel: .stable)?.tag == "1.1.0")
}

@Test func nothingOlderDraftOrIncompleteIsOffered() {
    let all = [release("0.9.0"), release("2.0.0", draft: true), release("1.5.0", assets: false)]
    #expect(UpdatePolicy.pick(all, current: v("1.0.0"), channel: .beta) == nil)
    #expect(UpdatePolicy.pick([release("1.0.0")], current: v("1.0.0"), channel: .beta) == nil)
    #expect(UpdatePolicy.pick([release("1.2.0")], current: v("1.0.0"), channel: .stable, skipped: ["1.2.0"]) == nil)
}

@Test func readsGitHubsReleaseList() throws {
    let json = """
    [{"tag_name":"v1.0.0-beta.1","name":"Atelier 1.0 beta 1","body":"First","draft":false,"prerelease":true,
      "published_at":"2026-11-11T10:00:00Z","html_url":"https://github.com/o/r/releases/tag/v1.0.0-beta.1",
      "assets":[{"name":"Atelier-1.0.0-beta.1.zip","browser_download_url":"https://github.com/o/r/a.zip","size":12345678},
                {"name":"Atelier-1.0.0-beta.1.zip.sig","browser_download_url":"https://github.com/o/r/a.sig","size":88}]},
     {"tag_name":"nightly","name":null,"body":null,"draft":false,"prerelease":true,"published_at":null,"html_url":null,"assets":[]}]
    """
    let releases = try UpdatePolicy.parseReleases(Data(json.utf8))
    #expect(releases.count == 1)
    #expect(releases[0].version.value == v("1.0.0-beta.1"))
    #expect(releases[0].installable)
    #expect(releases[0].published != nil)
}

@Test func checksAndArchivesAreSane() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(UpdatePolicy.checkDue(last: nil, now: now))
    #expect(!UpdatePolicy.checkDue(last: now.addingTimeInterval(-60), now: now))
    #expect(UpdatePolicy.checkDue(last: now.addingTimeInterval(-7 * 3600), now: now))
    #expect(UpdatePolicy.checkDue(last: now.addingTimeInterval(3600), now: now))   // clock went back
    #expect(UpdatePolicy.plausibleArchive(bytes: 20_000_000, announced: 20_000_000))
    #expect(!UpdatePolicy.plausibleArchive(bytes: 20_000_000, announced: 20_000_001))
    #expect(!UpdatePolicy.plausibleArchive(bytes: 500, announced: 500))
}
