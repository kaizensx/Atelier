import Foundation
import Testing
@testable import DockCore

private func folderTile(_ path: String) -> Tile {
    [
        "tile-type": "directory-tile",
        "tile-data": ["file-data": ["_CFURLString": URL(fileURLWithPath: path, isDirectory: true).absoluteString]],
    ]
}

@Test func pathDropsTrailingSlashAndDecodes() {
    #expect(Tiles.path(of: folderTile("/Users/a/Pastas da Dock")) == "/Users/a/Pastas da Dock")
}

@Test func detachThenAttachKeepsPosition() throws {
    var plist: DockPlist = ["persistent-others": [folderTile("/a"), folderTile("/b"), folderTile("/c")]]
    let index = Tiles.detach(path: "/b", from: &plist)
    #expect(index == 1)
    Tiles.attach(Tiles.stack(path: "/n.dockstack", label: "N"), to: &plist, at: index)
    #expect(Tiles.others(plist).compactMap(Tiles.path) == ["/a", "/n.dockstack", "/c"])
}

@Test func attachIgnoresDuplicate() {
    var plist: DockPlist = [:]
    let tile = Tiles.stack(path: "/n.dockstack", label: "N")
    Tiles.attach(tile, to: &plist, at: nil)
    Tiles.attach(tile, to: &plist, at: nil)
    #expect(Tiles.others(plist).count == 1)
}

@Test func fullWidthToggles() {
    var plist: DockPlist = ["persistent-others": [folderTile("/x")]]
    Tiles.setFullWidth(true, in: &plist)
    Tiles.setFullWidth(true, in: &plist)
    #expect(Tiles.others(plist).count == 2)
    #expect(Tiles.type(of: Tiles.others(plist)[0]) == "flex-spacer-tile")
    #expect(Tiles.isFullWidth(plist))
    Tiles.setFullWidth(false, in: &plist)
    #expect(!Tiles.isFullWidth(plist))
    #expect(Tiles.others(plist).count == 1)
}

@Test func removeSpacersKeepsRealTiles() {
    var plist: DockPlist = [
        "persistent-apps": [folderTile("/x"), Tiles.spacer(.small)],
        "persistent-others": [Tiles.spacer(.regular), folderTile("/y")],
    ]
    Tiles.removeSpacers(from: &plist)
    #expect(Tiles.apps(plist).count == 1)
    #expect(Tiles.others(plist).compactMap(Tiles.path) == ["/y"])
}

@Test func restoreDeletesAddedKeys() {
    #expect(Tiles.keysToDelete(current: ["a": 1, "no-bouncing": true], target: ["a": 2]) == ["no-bouncing"])
}

@Test func timelineNameRoundTrips() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let name = Timeline.fileName(date: date, label: "Antes de voltar atrás")
    let snapshot = try #require(Timeline.parse(name: name, in: URL(fileURLWithPath: "/tmp")))
    #expect(snapshot.label == "Antes de voltar atrás")
    #expect(snapshot.date == date)
}

@Test func stackRoundTripsNestedItems() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var document = StackDocument(title: "Criar")
    document.items = [.path("/Applications/Safari.app"),
                      StackItem(kind: .group, name: "Mais", children: [.path("/tmp/a.txt")])]
    let url = StackStore.url(forTitle: "Criar", in: folder)
    try StackStore.save(document, to: url)
    #expect(try StackStore.load(url) == document)
    #expect(StackStore.list(in: folder).map(\.path) == [url.path])
    #expect(document.items[0].kind == .app && document.items[0].name == "Safari")
}

@Test func titlesAreCleaned() throws {
    #expect(try StackStore.cleanTitle("  a/b:c ") == "a-b-c")
    #expect(throws: DockFailure.self) { try StackStore.cleanTitle("   ") }
}

@Test func fuzzyPrefersWordStarts() throws {
    #expect(Fuzzy.score("xyz", in: "Safari") == nil)
    let start = try #require(Fuzzy.score("ph", in: "Photoshop"))
    let middle = try #require(Fuzzy.score("ph", in: "Graphics"))
    #expect(start > middle)
}

@Test func smartTilesAddAndRemoveByLabel() {
    var plist: DockPlist = ["persistent-others": [folderTile("/a")]]
    Tiles.addSmart(label: "Imagens", query: "q", to: &plist)
    Tiles.addSmart(label: "Imagens", query: "q", to: &plist)
    #expect(Tiles.smartLabels(plist) == ["Imagens"])
    #expect((Tiles.others(plist)[1]["tile-data"] as? [String: Any])?["displayas"] as? Int == 1)
    Tiles.removeSmart(label: "Imagens", from: &plist)
    #expect(Tiles.others(plist).count == 1)
}
