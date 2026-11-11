import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private let visible = CGRect(x: 0, y: 30, width: 1200, height: 800)

@Test func touchingZonesLeaveOneGap() {
    let left = ToolsGeometry.frame(of: ZoneRect(x: 0, y: 0, width: 0.5, height: 1), in: visible, gap: 8)
    let right = ToolsGeometry.frame(of: ZoneRect(x: 0.5, y: 0, width: 0.5, height: 1), in: visible, gap: 8)
    #expect(left.minX == 8)
    #expect(left.minY == 38)
    #expect(right.maxX == 1192)
    #expect(right.minX - left.maxX == 8)
}

@Test func drawnZonesSnapOutwardToTheGrid() throws {
    let zone = try #require(ToolsGeometry.zone(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.4, y: 0.6), columns: 12, rows: 8))
    #expect(abs(zone.x - 1.0 / 12) < 1e-9 && zone.y == 0)
    #expect(abs(zone.width - 4.0 / 12) < 1e-9 && abs(zone.height - 5.0 / 8) < 1e-9)
    // A click without a drag still makes one cell.
    let tap = ToolsGeometry.zone(from: CGPoint(x: 0.99, y: 0.99), to: CGPoint(x: 0.99, y: 0.99), columns: 4, rows: 4)
    #expect(tap == ZoneRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25))
}

@Test func smallestZoneWins() {
    let zones = [ZoneRect(x: 0, y: 0, width: 1, height: 1), ZoneRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)]
    #expect(ToolsGeometry.zoneIndex(containing: CGPoint(x: 0.7, y: 0.7), in: zones) == 1)
    #expect(ToolsGeometry.zoneIndex(containing: CGPoint(x: 0.2, y: 0.2), in: zones) == 0)
    #expect(ToolsGeometry.zoneIndex(containing: CGPoint(x: 0.2, y: 0.2), in: []) == nil)
}

@Test func percentFrameIsCentred() {
    let frame = ToolsGeometry.percentFrame(0.5, in: visible)
    #expect(frame == CGRect(x: 300, y: 230, width: 600, height: 400))
    // Clamped to a sane minimum.
    #expect(ToolsGeometry.percentFrame(0.01, in: visible).width == 240)
}

@Test func cyclesWrap() {
    #expect(ToolsGeometry.nextIndex(after: nil, count: 3) == 0)
    #expect(ToolsGeometry.nextIndex(after: 2, count: 3) == 0)
    #expect(ToolsGeometry.nextIndex(after: 0, count: 0) == nil)
}

@Test func rulesAndDisplays() throws {
    let off = AppRule(bundleID: "com.a", appName: "A", placement: .percent(0.8), enabled: false)
    let on = AppRule(bundleID: "com.a", appName: "A", placement: .layout("leftHalf"), display: 1)
    #expect(ToolsGeometry.rule(for: "com.a", in: [off, on]) == on)
    #expect(ToolsGeometry.rule(for: "com.b", in: [off, on]) == nil)
    #expect(ToolsGeometry.displayIndex(preferred: 1, count: 2, fallback: 0) == 1)
    #expect(ToolsGeometry.displayIndex(preferred: 3, count: 2, fallback: 0) == 0)
    // Rules survive a round trip, placement and all.
    let data = try JSONEncoder().encode([on, AppRule(bundleID: "x", appName: "X", placement: .zone(layout: UUID(), index: 2))])
    let back = try JSONDecoder().decode([AppRule].self, from: data)
    #expect(back.first == on)
    #expect(back.count == 2)
}

@Test func presetsFillTheScreen() {
    for preset in CustomLayout.presets {
        let total = preset.zones.reduce(0) { $0 + $1.area }
        #expect(abs(total - 1) < 0.0001, "\(preset.name)")
    }
}
