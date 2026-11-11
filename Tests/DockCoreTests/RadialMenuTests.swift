import Foundation
import Testing
@testable import DockCore

private func pick(_ angle: Double, _ distance: Double, from previous: RadialSelection = .centre,
                  tuning: RadialTuning = RadialTuning()) -> RadialSelection {
    let offset = RadialGeometry.offset(angle: angle, distance: distance)
    return RadialPicker.select(dx: offset.dx, dy: offset.dy, previous: previous, tuning: tuning)
}

// MARK: - Geometry

@Test func radialAngleIsCompassStyle() {
    #expect(RadialGeometry.angle(dx: 10, dy: 0) == 0)
    #expect(abs(RadialGeometry.angle(dx: 0, dy: -10) - 90) < 1e-9) // Screen y grows down: up is 90°.
    #expect(abs(RadialGeometry.angle(dx: -10, dy: 0) - 180) < 1e-9)
    #expect(abs(RadialGeometry.angle(dx: 0, dy: 10) - 270) < 1e-9)
    #expect(RadialGeometry.delta(from: 350, to: 10) == 20)
    #expect(RadialGeometry.delta(from: 10, to: 350) == -20)
}

@Test func radialSectorsAreCentredOnTheirAngle() {
    #expect(RadialSector.containing(angle: 0) == .east)
    #expect(RadialSector.containing(angle: 22.4) == .east)
    #expect(RadialSector.containing(angle: 22.6) == .northEast)
    #expect(RadialSector.containing(angle: 359) == .east)
    #expect(RadialSector.containing(angle: -10) == .east)
    #expect(RadialSector.containing(angle: 337.4) == .southEast)
    #expect(RadialSector.containing(angle: 180) == .west)
}

// MARK: - Picking

@Test func radialCentreMaximises() {
    #expect(pick(0, 0).pick == .maximize)
    #expect(pick(45, 20).pick == .maximize)
}

@Test func radialInnerRingHoldsHalvesAndQuarters() {
    let expected: [(Double, RadialPick)] = [(0, .rightHalf), (45, .topRight), (90, .topHalf), (135, .topLeft),
                                            (180, .leftHalf), (225, .bottomLeft), (270, .bottomHalf), (315, .bottomRight)]
    for (angle, layout) in expected { #expect(pick(angle, 70).pick == layout) }
}

@Test func radialOuterRingHoldsThirds() {
    let expected: [(Double, RadialPick)] = [(0, .rightThird), (45, .rightTwoThirds), (90, .centerThird), (135, .leftTwoThirds),
                                            (180, .leftThird), (225, .center), (270, .center), (315, .center)]
    for (angle, layout) in expected { #expect(pick(angle, 140).pick == layout) }
}

@Test func radialThirdsOffKeepsTheInnerRingFarOut() {
    var tuning = RadialTuning()
    tuning.thirds = false
    let far = pick(180, 400, tuning: tuning)
    #expect(far.band == .inner)
    #expect(far.pick == .leftHalf)
}

@Test func radialDeadZoneHasHysteresis() {
    let tuning = RadialTuning()
    // Just past the dead zone from the centre is not enough: it needs the extra half band.
    #expect(pick(0, tuning.deadZone + 1).band == .center)
    let out = pick(0, tuning.deadZone + tuning.radiusHysteresis)
    #expect(out.pick == .rightHalf)
    // Once out, coming back a little inside the edge keeps the half.
    #expect(pick(0, tuning.deadZone - 1, from: out).pick == .rightHalf)
    #expect(pick(0, tuning.deadZone - tuning.radiusHysteresis, from: out).pick == .maximize)
}

@Test func radialOuterEdgeHasHysteresis() {
    let tuning = RadialTuning()
    let inner = pick(180, 80)
    #expect(pick(180, tuning.outerRadius + 1, from: inner).band == .inner)
    let outer = pick(180, tuning.outerRadius + tuning.radiusHysteresis, from: inner)
    #expect(outer.pick == .leftThird)
    #expect(pick(180, tuning.outerRadius - 2, from: outer).pick == .leftThird)
    #expect(pick(180, tuning.outerRadius - tuning.radiusHysteresis - 1, from: outer).pick == .leftHalf)
}

@Test func radialAngleHysteresisHoldsTheSector() {
    let right = pick(0, 70)
    // 25° is in north-east, but within 22.5 + 7 of east, so east holds.
    #expect(pick(25, 70, from: right).pick == .rightHalf)
    #expect(pick(31, 70, from: right).pick == .topRight)
    // Fresh, 25° is north-east.
    #expect(pick(25, 70).pick == .topRight)
}

@Test func radialPickerReportsChangesOnlyWhenThePickChanges() {
    var picker = RadialPicker()
    #expect(picker.update(dx: 0, dy: 0) == false)
    #expect(picker.update(dx: 70, dy: 0) == true)
    #expect(picker.update(dx: 72, dy: 2) == false)
    // Across the shared southern arc of the outer ring the pick stays Center.
    let a = RadialGeometry.offset(angle: 230, distance: 150), b = RadialGeometry.offset(angle: 300, distance: 150)
    #expect(picker.update(dx: a.dx, dy: a.dy) == true)
    #expect(picker.selection.pick == .center)
    #expect(picker.update(dx: b.dx, dy: b.dy) == false)
    #expect(picker.selection.sector == .southEast)
}

@Test func radialPicksMatchLayoutNames() {
    // The app maps these through WindowGeometry.Layout(rawValue:).
    let names = Set(RadialPick.allCases.map(\.rawValue))
    #expect(names.isSuperset(of: ["leftHalf", "rightHalf", "topHalf", "bottomHalf", "topLeft", "topRight", "bottomLeft",
                                  "bottomRight", "maximize", "leftThird", "centerThird", "rightThird", "leftTwoThirds",
                                  "rightTwoThirds", "center"]))
    #expect(names.count == 15)
}

// MARK: - Segments

@Test func radialSegmentsMergeTheSouthernArc() {
    #expect(RadialMap.segments(.inner).count == 8)
    let outer = RadialMap.segments(.outer)
    #expect(outer.count == 6)
    let centre = outer.first { $0.pick == .center }
    #expect(centre?.count == 3)
    #expect(centre?.angle == 270)
    #expect(centre?.span == 135)
    #expect(RadialMap.segments(.center).isEmpty)
    #expect(RadialMap.segment(for: RadialSelection(band: .outer, sector: .southWest))?.pick == .center)
    #expect(RadialMap.segment(for: .centre) == nil)
    // Every sector belongs to exactly one segment.
    for band in [RadialBand.inner, .outer] {
        for sector in RadialSector.allCases {
            #expect(RadialMap.segments(band).filter { $0.contains(sector) }.count == 1)
        }
    }
}

// MARK: - Keys

@Test func radialArrowsPickDirectionsAndCorners() {
    var keys = RadialKeys()
    var current = keys.press(.left, current: .centre, thirds: true)
    #expect(current.pick == .leftHalf)
    current = keys.press(.up, current: current, thirds: true)
    #expect(current.pick == .topLeft)
    keys.release(.left)
    keys.release(.up)
    #expect(current.pick == .topLeft) // Letting go keeps the pick.
    current = keys.press(.right, current: current, thirds: true)
    #expect(current.pick == .rightHalf)
}

@Test func radialSameArrowAgainStepsOutToThirds() {
    var keys = RadialKeys()
    var current = keys.press(.right, current: .centre, thirds: true)
    keys.release(.right)
    current = keys.press(.right, current: current, thirds: true)
    #expect(current.pick == .rightThird)
    keys.release(.right)
    current = keys.press(.right, current: current, thirds: true)
    #expect(current.pick == .rightHalf)
    keys.release(.right)
    #expect(keys.press(.right, current: current, thirds: false).pick == .rightHalf)
}

@Test func radialOpposingArrowsCancelToCentre() {
    var keys = RadialKeys()
    let left = keys.press(.left, current: .centre, thirds: true)
    #expect(keys.press(.right, current: left, thirds: true).pick == .maximize)
    #expect(RadialArrow(keycode: 123) == .left)
    #expect(RadialArrow(keycode: 126) == .up)
    #expect(RadialArrow(keycode: 0) == nil)
}

// MARK: - Trigger and gate

@Test func radialTriggersNeedTheirModifiersAlone() {
    typealias M = RadialTrigger.Mask
    #expect(RadialTrigger.controlOption.exactly(M.control | M.option))
    #expect(!RadialTrigger.controlOption.exactly(M.control | M.option | M.shift))
    #expect(RadialTrigger.controlOption.holds(M.control | M.option | M.shift))
    #expect(!RadialTrigger.controlOption.holds(M.control))
    #expect(RadialTrigger.rightOption.exactly(M.option | M.rightOption))
    #expect(!RadialTrigger.rightOption.exactly(M.option | 0x20)) // Left option only.
    #expect(RadialTrigger.rightCommand.exactly(M.command | M.rightCommand))
    #expect(RadialTrigger.function.exactly(M.function))
    #expect(!RadialTrigger.hyper.exactly(M.all))
    #expect(RadialTrigger.hyper.delay >= 0.3)
}

@Test func radialGateOpensAfterTheDelay() {
    var gate = RadialGate()
    #expect(gate.triggerDown(now: 1) == .none)
    #expect(gate.tick(now: 1.1, delay: 0.2) == .none)
    #expect(gate.tick(now: 1.2, delay: 0.2) == .open)
    #expect(gate.isOpen)
    #expect(gate.otherInput() == .none)
    #expect(gate.isOpen)
    #expect(gate.triggerUp() == .commit)
    #expect(gate.phase == .idle)
}

@Test func radialGateStandsDownForChordsAndQuickClicks() {
    var gate = RadialGate()
    _ = gate.triggerDown(now: 0)
    _ = gate.otherInput()
    #expect(gate.tick(now: 1, delay: 0.2) == .none)
    #expect(gate.phase == .idle)
    _ = gate.triggerDown(now: 2)
    #expect(gate.triggerUp() == .click)
    #expect(gate.triggerUp() == .none)
}

@Test func radialGateEscapeCancels() {
    var gate = RadialGate()
    #expect(gate.escape() == .none)
    _ = gate.triggerDown(now: 0)
    _ = gate.tick(now: 0.5, delay: 0.2)
    #expect(gate.escape() == .cancel)
    #expect(gate.triggerUp() == .none)
}

@Test func radialRingStaysOnScreen() {
    let inside = RadialGeometry.clampedCentre(x: 500, y: 400, radius: 150, minX: 0, minY: 0, maxX: 1728, maxY: 1117)
    #expect(inside.x == 500 && inside.y == 400)
    let corner = RadialGeometry.clampedCentre(x: 10, y: 1110, radius: 150, minX: 0, minY: 0, maxX: 1728, maxY: 1117)
    #expect(corner.x == 150 && corner.y == 967)
}
