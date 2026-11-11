import Foundation
import Testing
@testable import DockCore

// MARK: - Migration

@Test func oldDocumentWithArcBecomesFanAndRuleBecomesSmart() throws {
    let json = #"{"title":"Work","items":[],"layout":"arc","rule":"recentlyUsed","icon":{"style":"text","text":"W","symbol":"x","color":2}}"#
    let document = try JSONDecoder().decode(StackDocument.self, from: Data(json.utf8))
    #expect(document.style.layout == .fan)
    #expect(document.smart?.source == .recentApps)
    #expect(document.icon.style == .text)
    #expect(document.icon.image.isEmpty)
}

@Test func plainOldDocumentStaysPlain() throws {
    let json = #"{"title":"Tools","items":[],"layout":"list","rule":"none","icon":{"style":"apps","text":"","symbol":"sparkles","color":1}}"#
    let document = try JSONDecoder().decode(StackDocument.self, from: Data(json.utf8))
    #expect(document.smart == nil)
    #expect(document.style.layout == .list)
    #expect(document.style == {
        var style = StackStyle()
        style.layout = .list
        return style
    }())
}

@Test func documentRoundTripsAndStaysReadableByOldBuilds() throws {
    var document = StackDocument(title: "Mix")
    document.style.layout = .honeycomb
    document.style.material = .frosted
    document.style.kinds = [.images, .media]
    document.smart = StackSmart(source: .running)
    let data = try JSONEncoder().encode(document)
    let back = try JSONDecoder().decode(StackDocument.self, from: data)
    #expect(back.style == document.style)
    #expect(back.smart == document.smart)
    // The legacy fields an old build reads.
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(raw["layout"] as? String == "grid")
    #expect(raw["rule"] as? String == "running")
}

@Test func styleClampsAndDropsUnknownKinds() throws {
    let json = #"{"iconSize":900,"scale":0.1,"radius":2,"columns":40,"kinds":["images","holograms"],"layout":"spiral"}"#
    let style = try JSONDecoder().decode(StackStyle.self, from: Data(json.utf8))
    #expect(style.iconSize == StackStyle.iconSizes.upperBound)
    #expect(style.scale == StackStyle.scales.lowerBound)
    #expect(style.radius == StackStyle.radii.lowerBound)
    #expect(style.columns == 8)
    #expect(style.kinds == [.images])
    #expect(style.layout == .spiral)
}

// MARK: - Content

private let items = [
    StackItem.path("/Applications/Safari.app"),
    StackItem.path("/Users/a/b.png"),
    StackItem.path("/Users/a/a.pdf"),
    StackItem(kind: .url, name: "Apple", value: "https://apple.com"),
    StackItem.path("/Users/a/c.mov"),
]

@Test func filterByKindAndLimit() {
    var style = StackStyle()
    style.kinds = [.images, .documents]
    let groups = StackQuery.apply(items, style: style)
    #expect(groups.count == 1)
    #expect(groups[0].items.map(\.name) == ["b.png", "a.pdf"])
    style.limit = 1
    #expect(StackQuery.apply(items, style: style)[0].items.count == 1)
}

@Test func sortByNameAndManualKeepsOrder() {
    var style = StackStyle()
    #expect(StackQuery.apply(items, style: style)[0].items == items)
    style.sort = .name
    #expect(StackQuery.apply(items, style: style)[0].items.map(\.name) == ["a.pdf", "Apple", "b.png", "c.mov", "Safari"])
}

@Test func sortByAddedIsStableForUndated() {
    var style = StackStyle()
    style.sort = .added
    let now = Date()
    let result = StackQuery.apply(items, style: style) { item in
        item.name == "c.mov" ? StackFacts(added: now) : StackFacts()
    }
    #expect(result[0].items.map(\.name) == ["c.mov", "Safari", "b.png", "a.pdf", "Apple"])
}

@Test func ageFilterKeepsUndatedItems() {
    var style = StackStyle()
    style.age = .week
    let now = Date()
    let result = StackQuery.apply(items, style: style, now: now) { item in
        item.name == "b.png" ? StackFacts(modified: now.addingTimeInterval(-30 * 86_400)) : StackFacts()
    }
    #expect(!result[0].items.contains { $0.name == "b.png" })
    #expect(result[0].items.count == 4)
}

@Test func groupByKindMakesHeadings() {
    var style = StackStyle()
    style.groupByKind = true
    let groups = StackQuery.apply(items, style: style)
    #expect(groups.map(\.title) == ["Apps", "Documents", "Images", "Media", "Links"])
}

// MARK: - Geometry

@Test func freeLayoutsFitTheirFrame() {
    let cell = CGSize(width: 88, height: 92)
    for layout in [StackLayout.arc, .spiral, .honeycomb] {
        let placement = StackGeometry.place(layout, count: 23, cell: cell, columns: 5)
        #expect(placement.points.count == 23)
        #expect(placement.angles.count == 23)
        for point in placement.points {
            #expect(point.x >= cell.width / 2 - 0.001 && point.x <= placement.size.width - cell.width / 2 + 0.001)
            #expect(point.y >= cell.height / 2 - 0.001 && point.y <= placement.size.height - cell.height / 2 + 0.001)
        }
    }
    #expect(StackGeometry.place(.spiral, count: 0, cell: cell, columns: 3).points.isEmpty)
}

@Test func automaticColumns() {
    #expect(StackGeometry.columns(1, style: StackStyle()) == 2)
    #expect(StackGeometry.columns(9, style: StackStyle()) == 3)
    #expect(StackGeometry.columns(100, style: StackStyle()) == 6)
    var style = StackStyle()
    style.columns = 4
    #expect(StackGeometry.columns(100, style: style) == 4)
}

// MARK: - Section labels

private func row() -> [SectionLabelLayout.Tile] {
    // Apps, then section "AI" with two tiles, a divider, then an empty section.
    [
        .init(role: .tile, span: 0...56, reach: 70),
        .init(role: .section, span: 56...80, reach: 40),
        .init(role: .tile, span: 80...136, reach: 70),
        .init(role: .tile, span: 136...240, reach: 130),
        .init(role: .divider, span: 240...260, reach: 40),
        .init(role: .section, span: 260...280, reach: 40),
    ]
}

@Test func labelSitsOverItsOwnTilesAndClearsTheTallestIcon() {
    let labels = SectionLabelLayout.place(row(), gap: 5)
    #expect(labels.count == 1)
    #expect(labels[0].section == 1)
    #expect(labels[0].along == (80 + 240) / 2)
    #expect(labels[0].width == 160)
    #expect(labels[0].cross == 135)
}

@Test func sectionLabelsCostLittlePerFrame() {
    // 40 tiles in 6 sections, 120 frames a second: the budget is 8.3 ms a frame.
    var tiles: [SectionLabelLayout.Tile] = []
    for index in 0..<40 {
        let role: SectionLabelLayout.Tile.Role = index % 7 == 0 ? .section : .tile
        tiles.append(.init(role: role, span: Double(index) * 56...Double(index + 1) * 56, reach: 60 + Double(index % 5)))
    }
    let runs = 10_000
    let start = Date()
    var total = 0
    for _ in 0..<runs { total += SectionLabelLayout.place(tiles).count }
    let perFrame = Date().timeIntervalSince(start) / Double(runs)
    print("SectionLabelLayout.place, 40 tiles: \(String(format: "%.2f", perFrame * 1_000_000)) µs per frame")
    #expect(total == runs * 6)
    #expect(perFrame < 0.0005)
}
