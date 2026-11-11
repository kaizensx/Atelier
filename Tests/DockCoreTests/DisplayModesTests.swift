import Foundation
import Testing
@testable import DockCore

// The real mode list of a 14" MacBook Pro (M5, Built-in Retina Display, 3456×2234 panel),
// captured read-only with CGDisplayCopyAllDisplayModes and kCGDisplayShowDuplicateLowResolutionModes.
// The current mode at capture was 54 (1728×1117 HiDPI, 120 Hz); safe-area top 32 pt.

private func m(_ id: Int32, _ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double, _ flags: UInt32) -> DisplayModeInfo {
    DisplayModeInfo(modeID: id, width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: hz, ioFlags: flags)
}

private let builtIn: [DisplayModeInfo] = [
    m(0, 960, 600, 1920, 1200, 120.00, 0x3), m(1, 960, 600, 1920, 1200, 60.00, 0x3), m(2, 960, 600, 1920, 1200, 59.94, 0x3),
    m(3, 960, 600, 1920, 1200, 50.00, 0x3), m(4, 960, 600, 1920, 1200, 48.00, 0x3), m(5, 960, 600, 1920, 1200, 47.95, 0x3),
    m(6, 1168, 730, 2336, 1460, 120.00, 0x3), m(7, 1168, 730, 2336, 1460, 60.00, 0x3), m(8, 1168, 730, 2336, 1460, 59.94, 0x3),
    m(9, 1168, 730, 2336, 1460, 50.00, 0x3), m(10, 1168, 730, 2336, 1460, 48.00, 0x3), m(11, 1168, 730, 2336, 1460, 47.95, 0x3),
    m(12, 1168, 755, 2336, 1510, 120.00, 0x3), m(13, 1168, 755, 2336, 1510, 60.00, 0x3), m(14, 1168, 755, 2336, 1510, 59.94, 0x3),
    m(15, 1168, 755, 2336, 1510, 50.00, 0x3), m(16, 1168, 755, 2336, 1510, 48.00, 0x3), m(17, 1168, 755, 2336, 1510, 47.95, 0x3),
    m(18, 1280, 800, 2560, 1600, 120.00, 0x3), m(19, 1280, 800, 2560, 1600, 60.00, 0x3), m(20, 1280, 800, 2560, 1600, 59.94, 0x3),
    m(21, 1280, 800, 2560, 1600, 50.00, 0x3), m(22, 1280, 800, 2560, 1600, 48.00, 0x3), m(23, 1280, 800, 2560, 1600, 47.95, 0x3),
    m(24, 1312, 820, 2624, 1640, 120.00, 0x3), m(25, 1312, 820, 2624, 1640, 60.00, 0x3), m(26, 1312, 820, 2624, 1640, 59.94, 0x3),
    m(27, 1312, 820, 2624, 1640, 50.00, 0x3), m(28, 1312, 820, 2624, 1640, 48.00, 0x3), m(29, 1312, 820, 2624, 1640, 47.95, 0x3),
    m(30, 1312, 848, 2624, 1696, 120.00, 0x3), m(31, 1312, 848, 2624, 1696, 60.00, 0x3), m(32, 1312, 848, 2624, 1696, 59.94, 0x3),
    m(33, 1312, 848, 2624, 1696, 50.00, 0x3), m(34, 1312, 848, 2624, 1696, 48.00, 0x3), m(35, 1312, 848, 2624, 1696, 47.95, 0x3),
    m(36, 1496, 935, 2992, 1870, 120.00, 0x3), m(37, 1496, 935, 2992, 1870, 60.00, 0x3), m(38, 1496, 935, 2992, 1870, 59.94, 0x3),
    m(39, 1496, 935, 2992, 1870, 50.00, 0x3), m(40, 1496, 935, 2992, 1870, 48.00, 0x3), m(41, 1496, 935, 2992, 1870, 47.95, 0x3),
    m(42, 1496, 967, 2992, 1934, 120.00, 0x3), m(43, 1496, 967, 2992, 1934, 60.00, 0x3), m(44, 1496, 967, 2992, 1934, 59.94, 0x3),
    m(45, 1496, 967, 2992, 1934, 50.00, 0x3), m(46, 1496, 967, 2992, 1934, 48.00, 0x3), m(47, 1496, 967, 2992, 1934, 47.95, 0x3),
    m(48, 1728, 1080, 3456, 2160, 120.00, 0x3), m(49, 1728, 1080, 3456, 2160, 60.00, 0x3), m(50, 1728, 1080, 3456, 2160, 59.94, 0x3),
    m(51, 1728, 1080, 3456, 2160, 50.00, 0x3), m(52, 1728, 1080, 3456, 2160, 48.00, 0x3), m(53, 1728, 1080, 3456, 2160, 47.95, 0x3),
    m(54, 1728, 1117, 3456, 2234, 120.00, 0x2000007), m(55, 1728, 1117, 3456, 2234, 60.00, 0x2000003), m(56, 1728, 1117, 3456, 2234, 59.94, 0x2000003),
    m(57, 1728, 1117, 3456, 2234, 50.00, 0x2000003), m(58, 1728, 1117, 3456, 2234, 48.00, 0x2000003), m(59, 1728, 1117, 3456, 2234, 47.95, 0x2000003),
    m(60, 1920, 1200, 1920, 1200, 120.00, 0x3), m(61, 1920, 1200, 1920, 1200, 60.00, 0x3), m(62, 1920, 1200, 1920, 1200, 59.94, 0x3),
    m(63, 1920, 1200, 1920, 1200, 50.00, 0x3), m(64, 1920, 1200, 1920, 1200, 48.00, 0x3), m(65, 1920, 1200, 1920, 1200, 47.95, 0x3),
    m(66, 2056, 1285, 4112, 2570, 120.00, 0x3), m(67, 2056, 1285, 4112, 2570, 60.00, 0x3), m(68, 2056, 1285, 4112, 2570, 59.94, 0x3),
    m(69, 2056, 1285, 4112, 2570, 50.00, 0x3), m(70, 2056, 1285, 4112, 2570, 48.00, 0x3), m(71, 2056, 1285, 4112, 2570, 47.95, 0x3),
    m(72, 2056, 1329, 4112, 2658, 120.00, 0x3), m(73, 2056, 1329, 4112, 2658, 60.00, 0x3), m(74, 2056, 1329, 4112, 2658, 59.94, 0x3),
    m(75, 2056, 1329, 4112, 2658, 50.00, 0x3), m(76, 2056, 1329, 4112, 2658, 48.00, 0x3), m(77, 2056, 1329, 4112, 2658, 47.95, 0x3),
    m(78, 2336, 1460, 2336, 1460, 120.00, 0x3), m(79, 2336, 1460, 2336, 1460, 60.00, 0x3), m(80, 2336, 1460, 2336, 1460, 59.94, 0x3),
    m(81, 2336, 1460, 2336, 1460, 50.00, 0x3), m(82, 2336, 1460, 2336, 1460, 48.00, 0x3), m(83, 2336, 1460, 2336, 1460, 47.95, 0x3),
    m(84, 2336, 1510, 2336, 1510, 120.00, 0x3), m(85, 2336, 1510, 2336, 1510, 60.00, 0x3), m(86, 2336, 1510, 2336, 1510, 59.94, 0x3),
    m(87, 2336, 1510, 2336, 1510, 50.00, 0x3), m(88, 2336, 1510, 2336, 1510, 48.00, 0x3), m(89, 2336, 1510, 2336, 1510, 47.95, 0x3),
    m(90, 2560, 1600, 2560, 1600, 120.00, 0x3), m(91, 2560, 1600, 2560, 1600, 60.00, 0x3), m(92, 2560, 1600, 2560, 1600, 59.94, 0x3),
    m(93, 2560, 1600, 2560, 1600, 50.00, 0x3), m(94, 2560, 1600, 2560, 1600, 48.00, 0x3), m(95, 2560, 1600, 2560, 1600, 47.95, 0x3),
    m(96, 2624, 1640, 2624, 1640, 120.00, 0x3), m(97, 2624, 1640, 2624, 1640, 60.00, 0x3), m(98, 2624, 1640, 2624, 1640, 59.94, 0x3),
    m(99, 2624, 1640, 2624, 1640, 50.00, 0x3), m(100, 2624, 1640, 2624, 1640, 48.00, 0x3), m(101, 2624, 1640, 2624, 1640, 47.95, 0x3),
    m(102, 2624, 1696, 2624, 1696, 120.00, 0x3), m(103, 2624, 1696, 2624, 1696, 60.00, 0x3), m(104, 2624, 1696, 2624, 1696, 59.94, 0x3),
    m(105, 2624, 1696, 2624, 1696, 50.00, 0x3), m(106, 2624, 1696, 2624, 1696, 48.00, 0x3), m(107, 2624, 1696, 2624, 1696, 47.95, 0x3),
    m(108, 2992, 1870, 2992, 1870, 120.00, 0x3), m(109, 2992, 1870, 2992, 1870, 60.00, 0x3), m(110, 2992, 1870, 2992, 1870, 59.94, 0x3),
    m(111, 2992, 1870, 2992, 1870, 50.00, 0x3), m(112, 2992, 1870, 2992, 1870, 48.00, 0x3), m(113, 2992, 1870, 2992, 1870, 47.95, 0x3),
    m(114, 2992, 1934, 2992, 1934, 120.00, 0x3), m(115, 2992, 1934, 2992, 1934, 60.00, 0x3), m(116, 2992, 1934, 2992, 1934, 59.94, 0x3),
    m(117, 2992, 1934, 2992, 1934, 50.00, 0x3), m(118, 2992, 1934, 2992, 1934, 48.00, 0x3), m(119, 2992, 1934, 2992, 1934, 47.95, 0x3),
    m(120, 3456, 2160, 3456, 2160, 120.00, 0x3), m(121, 3456, 2160, 3456, 2160, 60.00, 0x3), m(122, 3456, 2160, 3456, 2160, 59.94, 0x3),
    m(123, 3456, 2160, 3456, 2160, 50.00, 0x3), m(124, 3456, 2160, 3456, 2160, 48.00, 0x3), m(125, 3456, 2160, 3456, 2160, 47.95, 0x3),
    m(126, 3456, 2234, 3456, 2234, 120.00, 0x2000003), m(127, 3456, 2234, 3456, 2234, 60.00, 0x2000003), m(128, 3456, 2234, 3456, 2234, 59.94, 0x2000003),
    m(129, 3456, 2234, 3456, 2234, 50.00, 0x2000003), m(130, 3456, 2234, 3456, 2234, 48.00, 0x2000003), m(131, 3456, 2234, 3456, 2234, 47.95, 0x2000003),
]

private func mode(_ id: Int32) -> DisplayModeInfo { builtIn.first { $0.modeID == id }! }
private let current = mode(54)
private let fraction = NotchFreeLogic.notchFraction(safeAreaTop: 32, screenHeight: 1117)!

@Test func fixtureIsTheWholeList() {
    #expect(builtIn.count == 132)
    #expect(current.width == 1728 && current.height == 1117 && current.isHiDPI && current.isDefault)
    #expect(mode(126).isNative && !mode(126).isHiDPI)
}

@Test func notchFreeFindsTheSixteenTenTwinOfEveryScaledSize() {
    let pairs: [(Int32, Int32)] = [(54, 48), (42, 36), (72, 66), (30, 24), (12, 6), (126, 120), (114, 108), (102, 96), (84, 78)]
    for (notched, free) in pairs {
        let got = NotchFreeLogic.notchFreeMode(for: mode(notched), in: builtIn, notchFraction: fraction)
        #expect(got == mode(free), "\(mode(notched).signature) → \(got?.signature ?? "nil")")
        #expect(got?.aspectName == "16:10")
        // And back again.
        let back = NotchFreeLogic.notchedMode(for: mode(free), in: builtIn, notchFraction: fraction)
        #expect(back == mode(notched))
    }
}

@Test func notchFreeKeepsTheScaleAndTheRefresh() {
    // 1728×1117 at 60 Hz goes to 1728×1080 at 60 Hz, not 120.
    let at60 = mode(55)
    #expect(at60.refreshRate == 60)
    let free = NotchFreeLogic.notchFreeMode(for: at60, in: builtIn, notchFraction: fraction)
    #expect(free == mode(49))
    #expect(free?.refreshRate == 60 && free?.scale == 2)
    // 59.94 stays 59.94.
    #expect(NotchFreeLogic.notchFreeMode(for: mode(44), in: builtIn, notchFraction: fraction)?.refreshRate == 59.94)
    // The 1× twin of 1728×1117 does not exist; the 1× native goes to the 1× 3456×2160.
    #expect(NotchFreeLogic.notchFreeMode(for: mode(126), in: builtIn, notchFraction: fraction)?.scale == 1)
}

@Test func notchFreeHasNothingForSizesWithoutATwin() {
    // 960×600 and 1280×800 are already 16:10 with no taller twin; 1920×1200 is 1× only.
    for id: Int32 in [0, 18, 60] {
        #expect(NotchFreeLogic.notchFreeMode(for: mode(id), in: builtIn, notchFraction: fraction) == nil)
    }
    #expect(NotchFreeLogic.isNotchFree(mode(48), in: builtIn, notchFraction: fraction))
    #expect(!NotchFreeLogic.isNotchFree(mode(54), in: builtIn, notchFraction: fraction))
    #expect(!NotchFreeLogic.isNotchFree(mode(0), in: builtIn, notchFraction: fraction))
}

@Test func notchFractionComesFromTheSafeAreaOrTheModes() {
    #expect(abs(fraction - 32.0 / 1117) < 1e-9)
    #expect(NotchFreeLogic.notchFraction(safeAreaTop: 0, screenHeight: 1117) == nil)
    // Once Notch-Free is on the safe area is 0: the native mode and its twin still know.
    let fromModes = NotchFreeLogic.notchFraction(fromModes: builtIn)!
    #expect(abs(fromModes - (1 - 2160.0 / 2234)) < 1e-9)
    #expect(NotchFreeLogic.notchFreeMode(for: current, in: builtIn, notchFraction: fromModes) == mode(48))
    // Measured at another size the safe area is still 32 pt; the match holds.
    let at1496 = NotchFreeLogic.notchFraction(safeAreaTop: 32, screenHeight: 967)!
    #expect(NotchFreeLogic.notchFreeMode(for: mode(42), in: builtIn, notchFraction: at1496) == mode(36))
    // A display with no notched twin knows nothing.
    #expect(NotchFreeLogic.notchFraction(fromModes: builtIn.filter { $0.pixelHeight != 2160 }) == nil)
    // Nonsense fractions are refused.
    #expect(NotchFreeLogic.notchFreeMode(for: current, in: builtIn, notchFraction: 0.3) == nil)
}

@Test func notchBandIsTheRowsTheNotchedModeSpendsUpTop() {
    #expect(NotchFreeLogic.bandPoints(notched: mode(54), notchFree: mode(48)) == 37)
    #expect(NotchFreeLogic.bandPoints(notched: mode(42), notchFree: mode(36)) == 32)
}

@Test func pickerGroupsByAspectWithEveryRefresh() {
    let groups = DisplayModeGrouping.groups(builtIn, current: current)
    // The current aspect first.
    #expect(groups.first?.name == current.aspectName)
    #expect(groups.contains { $0.name == "16:10" })
    let all = groups.flatMap(\.resolutions)
    // 22 sizes × 6 refresh rates = 132.
    #expect(all.count == 22)
    #expect(all.allSatisfy { $0.modes.count == 6 })
    let rates = DisplayModeGrouping.refreshRates(builtIn)
    #expect(rates == [120, 60, 59.94, 50, 48, 47.95])
    // Fastest first inside a size, largest size first inside a section.
    let first = groups[0].resolutions
    #expect(first.first!.modes.first!.refreshRate == 120)
    #expect(zip(first, first.dropFirst()).allSatisfy { $0.width >= $1.width })
    // HiDPI before 1× at the same point size never collides: the ids differ by pixel size.
    #expect(Set(all.map(\.id)).count == all.count)
}

@Test func pickerCanHideLowResolutionDuplicates() {
    let all = DisplayModeGrouping.groups(builtIn, hiDPIOnly: false).flatMap(\.resolutions)
    let scaled = DisplayModeGrouping.groups(builtIn, hiDPIOnly: true).flatMap(\.resolutions)
    // On this panel every 1× mode shares its pixel grid with a HiDPI one: all ten go, twelve HiDPI sizes stay.
    #expect(all.count == 22 && scaled.count == 12)
    #expect(scaled.allSatisfy { $0.isHiDPI })
    #expect(DisplayModeGrouping.isLowResolutionDuplicate(mode(78), in: builtIn))   // 2336×1460 1× = 1168×730 HiDPI
    #expect(!DisplayModeGrouping.isLowResolutionDuplicate(mode(6), in: builtIn))
    // A plain external monitor's 1× modes have no HiDPI twin and all stay.
    let external = [m(1, 1920, 1080, 1920, 1080, 60, 0x2000003), m(2, 1280, 720, 1280, 720, 60, 0x3)]
    #expect(DisplayModeGrouping.groups(external, hiDPIOnly: true).flatMap(\.resolutions).count == 2)
}

@Test func pickerKeepsTheRefreshWhenChangingSize() {
    let target = DisplayModeGrouping.groups(builtIn).flatMap(\.resolutions).first { $0.width == 1496 && $0.height == 935 }!
    #expect(DisplayModeGrouping.pick(target, keeping: mode(55))?.refreshRate == 60)
    #expect(DisplayModeGrouping.pick(target, keeping: nil)?.refreshRate == 120)
    #expect(target.mode(closestTo: 50)?.refreshRate == 50)
}

@Test func aspectNames() {
    #expect(DisplayAspect.name(width: 1728, height: 1080) == "16:10")
    #expect(DisplayAspect.name(width: 1920, height: 1080) == "16:9")
    #expect(DisplayAspect.name(width: 1366, height: 768) == "16:9")
    #expect(DisplayAspect.name(width: 3440, height: 1440) == "21:9")
    #expect(DisplayAspect.name(width: 2560, height: 1440) == "16:9")
    #expect(DisplayAspect.name(width: 1728, height: 1117) == "1.55:1")
    #expect(DisplayAspect.name(width: 2560, height: 1080) == "21:9")
    #expect(DisplayAspect.name(width: 1000, height: 1000) == "1:1")
}

@Test func refreshText() {
    #expect(DisplayModeInfo.refreshText(120) == "120 Hz")
    #expect(DisplayModeInfo.refreshText(59.94) == "59.94 Hz")
    #expect(DisplayModeInfo.refreshText(47.952) == "47.95 Hz")
    #expect(DisplayModeInfo.refreshText(0) == "—")
}

@Test func hiDPIPlanDoublesThePixels() {
    let plan = HiDPIMath.plan(points: (1920, 1080), refreshRate: 60, hiDPI: true, millimetres: (597, 336))!
    #expect(plan.pixelWidth == 3840 && plan.pixelHeight == 2160)
    #expect(plan.maxPixelsWide == 3840 && plan.maxPixelsHigh == 2160)
    #expect(plan.modeSizes.first! == (3840, 2160))
    #expect(plan.modeSizes.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 })
    #expect(plan.sizeInMillimeters == (597, 336))
    let flat = HiDPIMath.plan(points: (1920, 1080), hiDPI: false)!
    #expect(flat.pixelWidth == 1920)
    // A default physical size gives the default PPI.
    #expect(abs(HiDPIMath.ppi(pixelWidth: 1920, millimetres: flat.sizeInMillimeters.width)! - HiDPIMath.defaultPPI) < 0.01)
    // Too big for WindowServer, or too small to be a screen.
    #expect(HiDPIMath.plan(points: (5000, 2800), hiDPI: true) == nil)
    #expect(HiDPIMath.plan(points: (100, 100), hiDPI: true) == nil)
}

@Test func hiDPIScaledSizesKeepTheShape() {
    let sizes = HiDPIMath.scaledSizes(native: (2560, 1440))
    #expect(sizes.first! == (1280, 720))
    #expect(sizes.contains { $0 == (1920, 1080) })
    #expect(sizes.last! == (2560, 1440))
    #expect(sizes.allSatisfy { $0.width % 8 == 0 && abs(Double($0.width) / Double($0.height) - 16.0 / 9) < 0.01 })
    // A 4K panel cannot go all the way to 3840 points at 2× (7680 is fine, 8192 is the limit).
    #expect(HiDPIMath.scaledSizes(native: (3840, 2160)).last!.width == 3840)
    #expect(HiDPIMath.scaledSizes(native: (5120, 2880)).allSatisfy { $0.width * 2 <= HiDPIMath.maxPixelSide })
    #expect(HiDPIMath.ppi(pixelWidth: 1920, millimetres: 527)! < HiDPIMath.lowPPI)   // 24" 1080p
    #expect(HiDPIMath.ppi(pixelWidth: 3456, millimetres: 344)! > HiDPIMath.lowPPI)   // this MacBook Pro
}

@Test func parsesSizes() {
    #expect(HiDPIMath.parseSize("1920x1080")! == (1920, 1080, nil))
    #expect(HiDPIMath.parseSize("2560×1440@120")! == (2560, 1440, 120))
    #expect(HiDPIMath.parseSize("1280*720@59.94hz")! == (1280, 720, 59.94))
    #expect(HiDPIMath.parseSize("big") == nil)
    #expect(HiDPIMath.parseSize("0x1080") == nil)
}

@Test func revertMachineUndoesUnconfirmedChanges() {
    let a = mode(54), b = mode(48), c = mode(36)
    var (state, action) = ModeRevertMachine.next(.idle, .applied(previous: a, applied: b, now: 100))
    #expect(action == .none)
    #expect(ModeRevertMachine.remaining(state, now: 100) == 15)
    #expect(ModeRevertMachine.remaining(state, now: 107.2) == 8)
    (state, action) = ModeRevertMachine.next(state, .tick(now: 114.9))
    #expect(action == .none)
    (state, action) = ModeRevertMachine.next(state, .tick(now: 115))
    #expect(action == .restore(a) && state == .idle)
    // Keep ends it with nothing to do.
    (state, _) = ModeRevertMachine.next(.idle, .applied(previous: a, applied: b, now: 0))
    (state, action) = ModeRevertMachine.next(state, .keep)
    #expect(state == .idle && action == .none)
    #expect(ModeRevertMachine.next(state, .tick(now: 999)).1 == .none)
    // Revert now.
    (state, _) = ModeRevertMachine.next(.idle, .applied(previous: a, applied: b, now: 0))
    #expect(ModeRevertMachine.next(state, .revertNow).1 == .restore(a))
    // Two changes in a row go back to the first mode, with a fresh 15 s.
    (state, _) = ModeRevertMachine.next(.idle, .applied(previous: a, applied: b, now: 0))
    (state, _) = ModeRevertMachine.next(state, .applied(previous: b, applied: c, now: 10))
    #expect(state == .pending(previous: a, applied: c, deadline: 25))
    // Going back to the first mode by hand ends probation.
    (state, _) = ModeRevertMachine.next(state, .applied(previous: c, applied: a, now: 12))
    #expect(state == .idle)
    // Applying the same mode is no change.
    #expect(ModeRevertMachine.next(.idle, .applied(previous: a, applied: a, now: 0)).0 == .idle)
    // Abandon drops it.
    (state, _) = ModeRevertMachine.next(.idle, .applied(previous: a, applied: b, now: 0))
    #expect(ModeRevertMachine.next(state, .abandon) == (.idle, .none))
}

@Test func modesRoundTripThroughCodable() throws {
    let data = try JSONEncoder().encode(current)
    #expect(try JSONDecoder().decode(DisplayModeInfo.self, from: data) == current)
}
