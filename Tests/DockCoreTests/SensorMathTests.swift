import DockCore
import Foundation
import Testing

@Suite struct SensorMathTests {
    @Test func fourCCRoundTrips() {
        #expect(FourCC.code("TB0T") == 0x5442_3054)
        #expect(FourCC.code("#KEY") == 0x234B_4559)
        #expect(FourCC.text(0x5442_3054) == "TB0T")
        // The type code keeps its trailing space; a short string is padded with spaces.
        #expect(FourCC.text(FourCC.code("flt ")) == "flt ")
        #expect(FourCC.code("flt") == FourCC.code("flt "))
        for key in ["F0Ac", "PSTR", "Tp1g", "Tg0f"] { #expect(FourCC.text(FourCC.code(key)) == key) }
    }

    @Test func decodesFloatLittleEndian() {
        // 36.5 as a float is 0x42120000; the SMC stores it low byte first.
        #expect(SMCDecode.value(type: "flt ", bytes: [0x00, 0x00, 0x12, 0x42]) == 36.5)
        #expect(SMCDecode.value(type: "flt ", bytes: [0x00, 0xE0, 0xA8, 0x44]) == 1351)
        #expect(SMCDecode.value(type: "flt ", bytes: [0x00, 0x00]) == nil)
    }

    @Test func decodesIntegersBigEndian() {
        #expect(SMCDecode.value(type: "ui8 ", bytes: [2]) == 2)
        #expect(SMCDecode.value(type: "ui16", bytes: [0x96, 0x00]) == 38400)
        #expect(SMCDecode.value(type: "ui32", bytes: [0, 0, 0x0E, 0x2C]) == 3628)
        #expect(SMCDecode.value(type: "si16", bytes: [0xFF, 0xFE]) == -2)
        #expect(SMCDecode.value(type: "flag", bytes: [1]) == 1)
        #expect(SMCDecode.value(type: "hex_", bytes: [1, 2, 3, 4]) == nil)
    }

    @Test func decodesFixedPoint() {
        // sp78: 0x2480 is 36.5; negative values keep their sign.
        #expect(SMCDecode.value(type: "sp78", bytes: [0x24, 0x80]) == 36.5)
        #expect(SMCDecode.value(type: "sp78", bytes: [0xFF, 0x00]) == -1)
        // fpe2: 1350 rpm is 5400 = 0x1518.
        #expect(SMCDecode.value(type: "fpe2", bytes: [0x15, 0x18]) == 1350)
    }

    @Test func classifiesKeys() {
        #expect(SensorKind.of("Tp0C") == .cpu)
        #expect(SensorKind.of("Tg43") == .gpu)
        #expect(SensorKind.of("TB0T") == .battery)
        #expect(SensorKind.of("Ts0P") == .skin)
        #expect(SensorKind.of("F1Ac") == .fan)
        #expect(SensorKind.of("FNum") == .other)
        #expect(SensorKind.of("PSTR") == .power)
        #expect(SensorKind.of("Tp") == .other)
    }

    @Test func filtersNonsense() {
        #expect(SensorFilter.temperature(-9199) == nil)
        #expect(SensorFilter.temperature(.nan) == nil)
        #expect(SensorFilter.temperature(0) == nil)
        #expect(SensorFilter.temperature(54.2) == 54.2)
        #expect(SensorFilter.fan(0) == 0, "a stopped fan is a true reading")
        #expect(SensorFilter.fan(-1) == nil)
        #expect(SensorFilter.watts(.infinity) == nil)
        #expect(SensorFilter.watts(19.9) == 19.9)
    }

    @Test func summarisesMeanAndMax() {
        let s = SensorSummary([50, 52, 54, 60])
        #expect(s?.mean == 54)
        #expect(s?.max == 60)
        #expect(s?.count == 4)
        #expect(SensorSummary([]) == nil)
    }

    @Test func smootherIsRateIndependent() {
        // One second in four quarter steps lands where one one-second step does.
        var fast = Smoother(tau: 2), slow = Smoother(tau: 2)
        fast.add(40, dt: 0); slow.add(40, dt: 0)
        for _ in 0..<4 { fast.add(60, dt: 0.25) }
        slow.add(60, dt: 1)
        #expect(abs(fast.value! - slow.value!) < 1e-9)
        #expect(slow.value! > 40 && slow.value! < 60)
        // The first sample is taken as it is.
        var first = Smoother(tau: 2)
        #expect(first.add(51, dt: 1) == 51)
    }

    @Test func ringKeepsNewestInOrder() {
        var ring = SampleRing(capacity: 3)
        #expect(ring.isEmpty)
        #expect(ring.latest == nil)
        for i in 1...5 { ring.append(Double(i * 10), at: Double(i)) }
        #expect(ring.count == 3)
        #expect(ring.samples.map(\.value) == [30, 40, 50])
        #expect(ring.latest?.value == 50)
        ring.removeAll()
        #expect(ring.isEmpty)
    }

    @Test func ringWindowAndRange() {
        var ring = SampleRing(capacity: 600)
        for t in 0..<300 { ring.append(Double(t % 7), at: Double(t)) }
        let window = ring.window(120, now: 299)
        #expect(window.first?.time == 179)
        #expect(window.count == 121)
        #expect(ring.range(120, now: 299) == 0...6)
        #expect(ring.range(1, now: 1000) == nil)
    }

    @Test func heatScaleClamps() {
        #expect(HeatScale.temperature(20) == 0)
        #expect(HeatScale.temperature(100) == 1)
        #expect(abs(HeatScale.temperature(67.5) - 0.5) < 1e-9)
        #expect(HeatScale.fan(1350, min: 1350, max: 5350) == 0)
        #expect(HeatScale.fan(3350, min: 1350, max: 5350) == 0.5)
        #expect(HeatScale.fan(3000, min: 0, max: 0) == 0)
        #expect(HeatScale.watts(.nan) == 0)
    }

    @Test func sparklineKeepsFlatLinesCentred() {
        let flat = SparkScale.normalise([45, 45, 45])
        #expect(flat.allSatisfy { abs($0 - 0.5) < 1e-9 })
        let ramp = SparkScale.normalise([40, 50, 60])
        #expect(abs(ramp[0] - 0.08) < 1e-9 && abs(ramp[2] - 0.92) < 1e-9)
        #expect(SparkScale.normalise([]).isEmpty)
    }
}
