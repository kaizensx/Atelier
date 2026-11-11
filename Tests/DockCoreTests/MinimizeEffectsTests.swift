import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private let bottom = MinimizeGeometry(window: CGRect(x: 300, y: 400, width: 800, height: 500),
                                      tile: CGRect(x: 1200, y: 10, width: 60, height: 60), edge: .bottom)
private let leftDock = MinimizeGeometry(window: CGRect(x: 400, y: 300, width: 700, height: 500),
                                        tile: CGRect(x: 10, y: 500, width: 60, height: 60), edge: .left)
private let rightDock = MinimizeGeometry(window: CGRect(x: 200, y: 300, width: 700, height: 500),
                                         tile: CGRect(x: 1650, y: 200, width: 60, height: 60), edge: .right)
private let topDock = MinimizeGeometry(window: CGRect(x: 200, y: 200, width: 700, height: 500),
                                       tile: CGRect(x: 900, y: 1040, width: 60, height: 60), edge: .top)
private let drawn = MinimizeEffect.allCases.filter { $0 != .system }

private func expected(_ v: MinimizeVertex, _ g: MinimizeGeometry) -> CGPoint {
    CGPoint(x: g.window.minX + Double(v.u) * g.window.width, y: g.window.maxY - Double(v.v) * g.window.height)
}

@Test func minimizeFollowMacOSReadsTheDockSetting() {
    #expect(MinimizeEffect.system.resolved(systemEffect: "genie") == .genie)
    #expect(MinimizeEffect.system.resolved(systemEffect: "scale") == .scale)
    #expect(MinimizeEffect.system.resolved(systemEffect: "suck") == .suck)
    #expect(MinimizeEffect.system.resolved(systemEffect: nil) == .genie)
    #expect(MinimizeEffect.system.resolved(systemEffect: "Scale") == .scale)
    #expect(MinimizeEffect.fold.resolved(systemEffect: "scale") == .fold)
    #expect(MinimizeEffect.shatter.reduced(true) == .scale)
    #expect(MinimizeEffect.shatter.reduced(false) == .shatter)
}

@Test func minimizeEffectNamesAreUnique() {
    let titles = MinimizeEffect.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(MinimizeEffect(rawValue: "system") == .system)
}

@Test func minimizeCanonicalRoundTrips() {
    for edge in MinimizeEdge.allCases {
        let p = CGPoint(x: 123, y: -45)
        let back = MinimizeEffects.real(MinimizeEffects.canonical(p, edge), edge)
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
    }
    // Toward the dock is +y in canonical coordinates, whatever the edge.
    #expect(MinimizeEffects.canonical(CGPoint(x: 0, y: 0), .bottom).y > MinimizeEffects.canonical(CGPoint(x: 0, y: 100), .bottom).y)
    #expect(MinimizeEffects.canonical(CGPoint(x: 0, y: 0), .left).y > MinimizeEffects.canonical(CGPoint(x: 100, y: 0), .left).y)
    #expect(MinimizeEffects.canonical(CGPoint(x: 100, y: 0), .right).y > MinimizeEffects.canonical(CGPoint(x: 0, y: 0), .right).y)
    #expect(MinimizeEffects.canonical(CGPoint(x: 0, y: 100), .top).y > MinimizeEffects.canonical(CGPoint(x: 0, y: 0), .top).y)
}

@Test func minimizeEveryEffectStartsAsTheWindow() {
    for g in [bottom, leftDock, rightDock, topDock] {
        for effect in drawn {
            let mesh = MinimizeEffects.mesh(effect, progress: 0, geometry: g)
            #expect(!mesh.vertices.isEmpty)
            for v in mesh.vertices {
                let p = expected(v, g)
                #expect(abs(Double(v.x) - p.x) < 0.5 && abs(Double(v.y) - p.y) < 0.5, "\(effect) \(g.edge) at 0 moved a vertex")
                #expect(v.alpha > 0.99, "\(effect) at 0 is not opaque")
            }
        }
    }
}

@Test func minimizeEveryEffectEndsInTheTile() {
    for g in [bottom, leftDock, rightDock, topDock] {
        for effect in drawn {
            let mesh = MinimizeEffects.mesh(effect, progress: 1, geometry: g)
            let room = g.tile.insetBy(dx: -g.tile.width * 0.6, dy: -g.tile.height * 0.6)
            for v in mesh.vertices {
                let inside = room.contains(CGPoint(x: Double(v.x), y: Double(v.y)))
                #expect(inside || v.alpha < 0.001, "\(effect) at 1 left a visible vertex outside the tile (\(g.edge))")
            }
            #expect(mesh.vertices.allSatisfy { $0.alpha < 0.05 }, "\(effect) is still visible at 1")
        }
    }
}

@Test func minimizeMeshIndicesAreValid() {
    for effect in drawn {
        let mesh = MinimizeEffects.mesh(effect, progress: 0.5, geometry: bottom)
        #expect(mesh.indices.count % 3 == 0)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
        #expect(mesh.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.alpha >= 0 && $0.alpha <= 1 })
    }
}

@Test func minimizeGenieGridIsTwentyByThirty() {
    let mesh = MinimizeEffects.mesh(.genie, progress: 0.3, geometry: bottom)
    #expect(mesh.vertices.count == 21 * 31)
}

@Test func minimizeGenieNarrowsTheNearEdgeFirst() {
    // Early on the top stays the window's width while the edge nearest the dock narrows.
    let mesh = MinimizeEffects.mesh(.genie, progress: 0.3, geometry: bottom)
    let cols = MinimizeEffects.columns + 1
    let top = mesh.vertices[0..<cols], last = mesh.vertices[(mesh.vertices.count - cols)...]
    let topWidth = Double(top.last!.x - top.first!.x), bottomWidth = Double(last.last!.x - last.first!.x)
    #expect(abs(topWidth - bottom.window.width) < 40)
    #expect(bottomWidth < topWidth * 0.85)
    // And its far edge leans toward the tile (to the right here).
    #expect(Double(last.first!.x) > bottom.window.minX + 20)
}

@Test func minimizeGenieMovesTowardTheDockMonotonically() {
    var previous = -Double.infinity
    for step in 0...10 {
        let mesh = MinimizeEffects.mesh(.genie, progress: Double(step) / 10, geometry: bottom)
        // The top row's height above the dock only goes down (Cocoa y falls toward a bottom dock).
        let y = -Double(mesh.vertices[MinimizeEffects.columns / 2].y)
        #expect(y >= previous - 0.001)
        previous = y
    }
}

@Test func minimizeShatterIsWholeAtRestAndApartMidway() {
    let rest = MinimizeEffects.mesh(.shatter, progress: 0, geometry: bottom)
    #expect(rest.vertices.count == MinimizeEffects.shardColumns * MinimizeEffects.shardRows * 6)
    let mid = MinimizeEffects.mesh(.shatter, progress: 0.35, geometry: bottom)
    let moved = zip(rest.vertices, mid.vertices).filter { abs($0.x - $1.x) + abs($0.y - $1.y) > 4 }.count
    #expect(moved > rest.vertices.count / 2)
}

@Test func minimizeDissolveStartsNearTheDock() {
    let mesh = MinimizeEffects.mesh(.dissolve, progress: 0.2, geometry: bottom)
    let cols = MinimizeEffects.particleColumns
    func moved(row: Int) -> Int {
        let rest = MinimizeEffects.mesh(.dissolve, progress: 0, geometry: bottom)
        return (0..<cols).filter { i in
            let k = (row * cols + i) * 4
            return abs(mesh.vertices[k].y - rest.vertices[k].y) + abs(mesh.vertices[k].x - rest.vertices[k].x) > 1
        }.count
    }
    #expect(moved(row: MinimizeEffects.particleRows - 1) > moved(row: 0))
}

@Test func minimizeTimingMatchesMacOSAndSlowMotion() {
    #expect(MinimizeTiming.duration(.genie, restoring: false, slow: false) == 0.5)
    #expect(MinimizeTiming.duration(.genie, restoring: false, slow: true) == 0.5 * MinimizeTiming.slowMotion)
    #expect(MinimizeTiming.duration(.scale, restoring: false, slow: false) < 0.5)
    #expect(MinimizeTiming.progress(elapsed: 0, duration: 0.5, restoring: false) == 0)
    #expect(MinimizeTiming.progress(elapsed: 0.5, duration: 0.5, restoring: false) == 1)
    #expect(MinimizeTiming.progress(elapsed: 0, duration: 0.5, restoring: true) == 1)
    #expect(MinimizeTiming.progress(elapsed: 0.5, duration: 0.5, restoring: true) == 0)
    // Coming back it leaves the tile quickly.
    #expect(MinimizeTiming.progress(elapsed: 0.1, duration: 0.5, restoring: true) < 0.6)
    var last = 0.0
    for i in 0...20 {
        let p = MinimizeTiming.progress(elapsed: Double(i) / 40, duration: 0.5, restoring: false)
        #expect(p >= last)
        last = p
    }
}

@Test func minimizeHashIsStableAndInRange() {
    #expect(MinimizeEffects.hash(42) == MinimizeEffects.hash(42))
    #expect((0..<500).allSatisfy { (0..<1).contains(MinimizeEffects.hash($0)) })
}
