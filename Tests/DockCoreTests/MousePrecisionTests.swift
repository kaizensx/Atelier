import Foundation
import Testing
@testable import DockCore

@Test func fixedPointRoundTrips() {
    // macOS's default acceleration, as this Mac reports it: 45056 = 0.6875.
    #expect(Fixed1616.decode(45056) == 0.6875)
    #expect(Fixed1616.encode(0.6875) == 45056)
    #expect(Fixed1616.encode(-1) == -65536)
    #expect(Fixed1616.encode(400) == 26_214_400)
    #expect(Fixed1616.decode(26_214_400) == 400)
    for value in [0.0, 0.125, 1.5, 3, 12.25] { #expect(Fixed1616.decode(Fixed1616.encode(value)) == value) }
}

@Test func presetsWriteTheirAcceleration() {
    #expect(MouseCurve.linear.acceleration == -1)
    #expect(MouseCurve.macOS.acceleration == 0.6875)
    #expect(MouseCurve.system.acceleration == nil)
    #expect(MouseCurve.custom.acceleration == nil)
    // Ordered from flattest to steepest, so the chips read left to right.
    let values = MouseCurve.presets.compactMap(\.acceleration)
    #expect(values == values.sorted())
}

@Test func curvesHaveTheRightShape() {
    // Linear is the identity, scaled only by speed.
    #expect(MouseAccelTable.output(10, acceleration: -1) == 10)
    #expect(MouseAccelTable.output(10, acceleration: -1, speed: 2) == 20)
    // Every curve rises, and more acceleration means more pointer at speed.
    for accel in [0.0, 0.125, 0.6875, 3, 5] {
        var last = -1.0
        for v in stride(from: 0.0, through: 40, by: 0.5) {
            let y = MouseAccelTable.output(v, acceleration: accel)
            #expect(y > last)
            last = y
        }
    }
    #expect(MouseAccelTable.output(20, acceleration: 0.375) < MouseAccelTable.output(20, acceleration: 0.6875))
    #expect(MouseAccelTable.output(20, acceleration: 3) < MouseAccelTable.output(20, acceleration: 5))
    // At a crawl every curve is close to 1:1; that is what keeps slow aim fine.
    #expect(abs(MouseAccelTable.output(0.1, acceleration: 0.6875) - 0.1) < 0.01)
}

@Test func curveTableInterpolates() {
    let exact = MouseAccelTable.stop(for: 0.6875)
    #expect(exact.index == 0.6875 && exact.parabolic == Fixed1616.decode(54395))
    let between = MouseAccelTable.stop(for: 0.78125)   // halfway between 0.6875 and 0.875
    #expect(between.parabolic > exact.parabolic && between.parabolic < MouseAccelTable.stop(for: 0.875).parabolic)
    #expect(MouseAccelTable.stop(for: 4).parabolic > MouseAccelTable.stop(for: 3).parabolic)
}

@Test func curveInvertsForTheLiveReadout() {
    for accel in [-1.0, 0.125, 0.6875, 2] {
        let y = MouseAccelTable.output(13, acceleration: accel, speed: 1.5)
        #expect(abs(MouseAccelTable.input(forOutput: y, acceleration: accel, speed: 1.5) - 13) < 1e-6)
    }
    #expect(MouseAccelTable.input(forOutput: 0, acceleration: 1) == 0)
}

@Test func pointerSpeedIsResolution() {
    #expect(PointerResolution.resolution(forSpeed: 1) == 400)
    #expect(PointerResolution.resolution(forSpeed: 2) == 200)
    #expect(PointerResolution.raw(forSpeed: 1) == 26_214_400)
    #expect(PointerResolution.speed(forResolution: 100) == 4)
    // Clamped to what IOKit accepts and what the slider offers.
    #expect(PointerResolution.resolution(forSpeed: 100) == 400.0 / 6)
    #expect(PointerResolution.resolution(forSpeed: 0.01) == 1600)
    #expect(PointerResolution.speed(forResolution: 1) == 40)
}

@Test func buttonMapTable() {
    let map = MouseButtonMap.standard
    #expect(map.action(for: 3) == .back && map.action(for: 4) == .forward)
    #expect(map.action(for: 2) == .passThrough)
    // Left and right are never touched, whatever the table says.
    #expect(MouseButtonMap(actions: [0: .back, 1: .forward]).action(for: 0) == .passThrough)
    #expect(map.remappedCount == 2)
    // ⌘[ and ⌘].
    #expect(MouseButtonAction.back.keystroke?.keyCode == 33 && MouseButtonAction.back.keystroke?.flags == MouseButtonMap.commandFlag)
    #expect(MouseButtonAction.forward.keystroke?.keyCode == 30)
    #expect(MouseButtonAction.missionControl.keystroke == nil)
    // A recorded ⌃⌥⇧⌘K keeps every modifier.
    let combo = MouseButtonAction.shortcut(keyCode: 40, carbonModifiers: 0x100 | 0x200 | 0x800 | 0x1000)
    #expect(combo.keystroke?.flags == MouseButtonMap.commandFlag | MouseButtonMap.shiftFlag | MouseButtonMap.optionFlag | MouseButtonMap.controlFlag)
    // Survives the trip through UserDefaults.
    let custom = MouseButtonMap(actions: [2: .missionControl, 3: combo, 4: .appExpose])
    let data = try! JSONEncoder().encode(custom)
    #expect(try! JSONDecoder().decode(MouseButtonMap.self, from: data) == custom)
}

@Test func deviceIdentity() {
    #expect(MouseDeviceInfo.isApple(vendor: 0x05AC, builtIn: false))
    #expect(MouseDeviceInfo.isApple(vendor: 0, builtIn: true))
    #expect(!MouseDeviceInfo.isApple(vendor: 0x046D, builtIn: false))
    #expect(MouseDeviceInfo.key(vendor: 0x046D, product: 0xB034, name: "MX Master 3S") == "1133:45108:MX Master 3S")
    #expect(MouseDeviceInfo.vendorName(0x046D) == "Logitech")
    #expect(MouseDeviceInfo.vendorName(0x1234) == "0x1234")
}

@Test func pointerSpeedHonouredByReleaseAndDevice() {
    func honoured(_ vendor: Int?, builtIn: Bool = false, trackpad: Bool = false, _ major: Int, arm: Bool = true) -> Bool {
        MouseDeviceInfo.pointerSpeedHonoured(vendor: vendor, builtIn: builtIn, trackpad: trackpad, macOSMajor: major, appleSilicon: arm)
    }
    // Third-party mice: always, on every release and chip.
    for major in [14, 15, 26, 27] { #expect(honoured(0x046D, major)); #expect(honoured(0x046D, major, arm: false)) }
    // Magic Mouse and Magic Trackpad: Sonoma yes, Sequoia and later no.
    #expect(honoured(0x004C, 14))
    #expect(honoured(0x004C, trackpad: true, 14))
    for major in [15, 26, 27] { #expect(!honoured(0x004C, major)); #expect(!honoured(0x05AC, trackpad: true, major)) }
    // Built-in trackpad on Sonoma: Apple silicon may ignore it (vendor erased), Intel honours it.
    #expect(!honoured(nil, builtIn: true, trackpad: true, 14))
    #expect(!honoured(nil, trackpad: true, 14))
    #expect(honoured(nil, builtIn: true, trackpad: true, 14, arm: false))
    #expect(!honoured(0x05AC, builtIn: true, trackpad: true, 15, arm: false))
}
