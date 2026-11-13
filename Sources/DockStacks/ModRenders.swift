#if DEBUG
import AppKit
import CryptoKit
import DockCore
import SwiftUI

/// `DockStacks --render-mods <folder>` (debug builds): the Mods community pieces as PNGs, light and
/// dark, from a made-up catalog: cards with installs and likes, a collection shelf, an author
/// page, the review sheet (changed hands, new permissions, rollback) and the import sheet.
/// Reads no catalog, downloads nothing, installs nothing.
@MainActor
enum ModRenders {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sha = String(repeating: "ab", count: 32)
        let file = { (v: String) in ModFile(url: URL(string: "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/\(v).zip")!, sha256: sha, size: 4096) }
        let keyA = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let keyB = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        func mod(_ id: String, _ name: String, kind: ModKind, downloads: Int?, likes: Int?, permissions: [String] = [], key: String? = nil) -> ModEntry {
            var e = ModEntry(id: id, name: name, author: "Ana Lima", github: "analima", kind: kind, version: "2.0.0",
                             summary: "A short summary of what \(name) does, in one or two sentences.",
                             permissions: permissions, package: file("2.0.0"),
                             versions: [ModVersion(version: "2.0.0", package: file("2.0.0")), ModVersion(version: "1.4.0", package: file("1.4.0"))])
            e.downloads = downloads; e.likes = likes; e.authorKey = key
            e.packageSignature = key.map { _ in Data(repeating: 1, count: 64).base64EncodedString() }
            e.discussion = URL(string: "https://github.com/kaizensx/atelier-mods/discussions/1")
            return e
        }
        let focus = mod("com.example.focus", "Focus Ring", kind: .plugin, downloads: 1234, likes: 48, permissions: ["notifications"], key: keyA)
        let glass = mod("com.example.glass", "Midnight Glass", kind: .theme, downloads: 87, likes: 3)
        let fresh = mod("com.example.fresh", "Fresh", kind: .plugin, downloads: nil, likes: nil)
        let author = ModAuthor(github: "analima", name: "Ana Lima", url: URL(string: "https://example.com"), mods: [focus.id, glass.id])

        let installed = InstalledModInfo(id: focus.id, kind: .plugin, version: "1.4.0", permissions: ["notifications"])
        var wider = focus; wider.permissions = ["notifications", "network"]; wider.hosts = ["api.example.com"]
        var otherKey = focus; otherKey.authorKey = keyB
        let older = ModInstallReview(entry: focus.at(version: "1.4.0")!,
                                     installed: InstalledModInfo(id: focus.id, kind: .plugin, version: "2.0.0", permissions: ["notifications"]),
                                     installedKey: keyA)
        let setup = AtelierSetup(created: Date(timeIntervalSinceReferenceDate: 800_000_000), atelier: "1.0.0",
                                 mods: [.init(id: focus.id, kind: "plugin", version: "2.0.0", catalog: true),
                                        .init(id: "com.example.mine", kind: "plugin", version: "1.0.0", catalog: false)],
                                 plugins: [.init(id: focus.id, enabled: true, data: ["city": .string("Lisbon")])])
        let panel = { (v: AnyView, w: CGFloat) in AnyView(v.frame(width: w).padding(20).background(Color(nsColor: .windowBackgroundColor))) }
        let states: [(String, AnyView)] = [
            ("cards", panel(AnyView(HStack(alignment: .top, spacing: 16) {
                ModCard(entry: focus, featured: true) {}.frame(width: 260)
                ModCard(entry: glass) {}.frame(width: 260)
                ModCard(entry: fresh) {}.frame(width: 260)
            }), 820)),
            ("shelf", panel(AnyView(ModShelf(title: "Stay focused", detail: "A timer on the Dock and the notifications that matter.",
                                             mods: [focus, glass, fresh], open: { _ in })), 820)),
            ("author", panel(AnyView(ModAuthorPage(author: author, mods: [focus, glass], back: {}, open: { _ in })), 820)),
            ("review-permissions", panel(AnyView(ModReviewSheet(review: ModInstallReview(entry: wider, installed: installed, installedKey: keyA)) { _ in }), 480)),
            ("review-changed-hands", panel(AnyView(ModReviewSheet(review: ModInstallReview(entry: otherKey, installed: installed, installedKey: keyA)) { _ in }), 480)),
            ("review-rollback", panel(AnyView(ModReviewSheet(review: older) { _ in }), 480)),
            ("import", panel(AnyView(ModImportSheet(setup: setup) { _ in }), 480)),
        ]
        for (name, view) in states {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("failed: \(name)"); continue
                }
                let url = folder.appendingPathComponent("mods-\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
#endif
