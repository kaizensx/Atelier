import Foundation

// MARK: - Display modes: the rules, with no CoreGraphics in sight
//
// Two features change what a display shows, and both reduce to arithmetic on a list of modes:
//
// - Notch-Free: a notched panel lists every scaled size twice, once at the panel's own aspect
//   (1728×1117) and once at 16:10 (1728×1080). The 16:10 twin is the same width and the same
//   scale with the notch rows cut off the top: macOS draws them black and puts the menu bar
//   below them. Finding the twin is a match on width, scale and refresh, with the height that
//   leaves out what the notch takes, measured from the screen's own safe area, never assumed.
// - HiDPI Anywhere: a virtual display at twice the wanted size, in HiDPI, that a low-PPI
//   monitor mirrors; the sizes worth offering and the descriptor's numbers are plain maths.
//
// And every mode change made by hand is on probation for 15 seconds, like System Settings:
// `ModeRevertMachine` decides when the old mode comes back.

/// One display mode, as `CGDisplayCopyAllDisplayModes` lists it.
public struct DisplayModeInfo: Hashable, Sendable, Codable, Identifiable {
    /// `ioDisplayModeID`: stable for a display while it is connected.
    public var modeID: Int32
    /// Size in points: what windows and the menu bar are laid out in.
    public var width: Int
    public var height: Int
    /// Size in pixels: what the framebuffer is.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Hz; 0 for a display that does not say.
    public var refreshRate: Double
    /// `ioFlags`.
    public var ioFlags: UInt32
    public var usableForDesktop: Bool

    public init(modeID: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, ioFlags: UInt32 = 0, usableForDesktop: Bool = true) {
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.ioFlags = ioFlags
        self.usableForDesktop = usableForDesktop
    }

    public var id: Int32 { modeID }
    /// `kDisplayModeNativeFlag`: the panel's own pixel grid.
    public static let nativeFlag: UInt32 = 0x0200_0000
    /// `kDisplayModeDefaultFlag`: what System Settings calls Default.
    public static let defaultFlag: UInt32 = 0x0000_0004

    public var isNative: Bool { ioFlags & Self.nativeFlag != 0 }
    public var isDefault: Bool { ioFlags & Self.defaultFlag != 0 }
    /// Pixels per point, rounded to a tenth: 2 for HiDPI, 1 for a plain mode.
    public var scale: Double { width > 0 ? (Double(pixelWidth) / Double(width) * 10).rounded() / 10 : 1 }
    public var isHiDPI: Bool { scale >= 1.5 }
    public var aspect: Double { height > 0 ? Double(width) / Double(height) : 0 }
    public var aspectName: String { DisplayAspect.name(width: width, height: height) }
    /// Refresh rounded to hundredths, so 59.94 and 60 stay apart but float noise does not.
    public var refreshKey: Int { Int((refreshRate * 100).rounded()) }

    /// Same picture size and grid, any refresh.
    public func sameResolution(_ other: DisplayModeInfo) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }

    /// "1728 × 1117".
    public var sizeText: String { "\(width) × \(height)" }
    /// "120 Hz", "59.94 Hz".
    public var refreshText: String { DisplayModeInfo.refreshText(refreshRate) }

    public static func refreshText(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        let rounded = (hz * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) Hz" : String(format: "%.2f Hz", rounded)
    }

    /// A short line for diagnostics and the defaults: "54:1728x1117@120.00/3456x2234".
    public var signature: String {
        String(format: "%d:%dx%d@%.2f/%dx%d", modeID, width, height, refreshRate, pixelWidth, pixelHeight)
    }
}

// MARK: - Aspect

public enum DisplayAspect {
    /// The names people know, by ratio. Anything else gets its reduced fraction or a decimal.
    static let known: [(name: String, ratio: Double)] = [
        ("16:10", 16.0 / 10), ("16:9", 16.0 / 9), ("3:2", 3.0 / 2), ("4:3", 4.0 / 3), ("5:4", 5.0 / 4),
        ("21:9", 64.0 / 27), ("32:9", 32.0 / 9), ("1:1", 1),
    ]

    public static func name(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let ratio = Double(width) / Double(height)
        // 0.6 % absorbs 1366×768, 1280×720 and friends without merging 16:10 with 3:2.
        if let hit = known.first(where: { abs($0.ratio - ratio) / $0.ratio < 0.006 }) { return hit.name }
        // "21:9" is a family, not a ratio: 2560×1080 (2.37), 3440×1440 (2.39), 3840×1600 (2.4).
        if ratio > 2.3, ratio < 2.42 { return "21:9" }
        let g = gcd(width, height)
        let (a, b) = (width / g, height / g)
        if a <= 32, b <= 32 { return "\(a):\(b)" }
        return String(format: "%.2f:1", ratio)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
}

// MARK: - Grouping for the picker

/// One picture size with every refresh it comes in: one row of the picker.
public struct DisplayResolution: Hashable, Sendable, Identifiable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Fastest first.
    public var modes: [DisplayModeInfo]

    public var id: String { "\(width)x\(height)/\(pixelWidth)x\(pixelHeight)" }
    public var isHiDPI: Bool { modes.first?.isHiDPI ?? false }
    public var isNative: Bool { modes.contains(where: \.isNative) }
    public var isDefault: Bool { modes.contains(where: \.isDefault) }
    public var refreshRates: [Double] { modes.map(\.refreshRate) }
    public var aspectName: String { DisplayAspect.name(width: width, height: height) }

    public func mode(closestTo hz: Double) -> DisplayModeInfo? {
        modes.min { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) }
    }
}

/// Resolutions that share an aspect: one section of the picker.
public struct DisplayAspectGroup: Hashable, Sendable, Identifiable {
    public var name: String
    /// Largest first.
    public var resolutions: [DisplayResolution]
    public var id: String { name }
}

public enum DisplayModeGrouping {
    /// Every desktop-usable mode as aspect sections, then sizes, then refresh rates.
    /// `hiDPIOnly` hides the "duplicate low resolution" modes: a 1× mode with the same pixel grid
    /// as a HiDPI one (2336×1460 at 1× next to 1168×730 HiDPI), which macOS hides by default.
    /// Sections: the one holding the current mode first, then by how many sizes they hold.
    public static func groups(_ modes: [DisplayModeInfo], current: DisplayModeInfo? = nil,
                              hiDPIOnly: Bool = false) -> [DisplayAspectGroup] {
        var usable = modes.filter(\.usableForDesktop)
        if hiDPIOnly {
            usable = usable.filter { !isLowResolutionDuplicate($0, in: usable) }
        }
        let byResolution = Dictionary(grouping: usable) { "\($0.width)x\($0.height)/\($0.pixelWidth)x\($0.pixelHeight)" }
        let resolutions = byResolution.values.compactMap { list -> DisplayResolution? in
            guard let first = list.first else { return nil }
            let unique = Dictionary(list.map { ($0.refreshKey, $0) }, uniquingKeysWith: { a, _ in a }).values
            return DisplayResolution(width: first.width, height: first.height, pixelWidth: first.pixelWidth,
                                     pixelHeight: first.pixelHeight,
                                     modes: unique.sorted { $0.refreshRate > $1.refreshRate })
        }
        let byAspect = Dictionary(grouping: resolutions, by: \.aspectName)
        var groups = byAspect.map { name, list in
            DisplayAspectGroup(name: name, resolutions: list.sorted(by: resolutionOrder))
        }
        let currentAspect = current?.aspectName
        groups.sort { a, b in
            if (a.name == currentAspect) != (b.name == currentAspect) { return a.name == currentAspect }
            if a.resolutions.count != b.resolutions.count { return a.resolutions.count > b.resolutions.count }
            return a.name < b.name
        }
        return groups
    }

    /// A 1× mode whose pixel grid a HiDPI mode also has: the same pixels, drawn without scaling.
    public static func isLowResolutionDuplicate(_ mode: DisplayModeInfo, in modes: [DisplayModeInfo]) -> Bool {
        !mode.isHiDPI && modes.contains { $0.isHiDPI && $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight }
    }

    /// Largest point size first; at the same size, HiDPI before 1×.
    static func resolutionOrder(_ a: DisplayResolution, _ b: DisplayResolution) -> Bool {
        if a.width != b.width { return a.width > b.width }
        if a.height != b.height { return a.height > b.height }
        return a.pixelWidth > b.pixelWidth
    }

    /// Every distinct refresh rate a display offers, fastest first.
    public static func refreshRates(_ modes: [DisplayModeInfo]) -> [Double] {
        Dictionary(modes.map { ($0.refreshKey, $0.refreshRate) }, uniquingKeysWith: { a, _ in a })
            .values.sorted(by: >)
    }

    /// Where to go when the picker asks for a size: that size at the current refresh if it has
    /// it, else its fastest.
    public static func pick(_ resolution: DisplayResolution, keeping current: DisplayModeInfo?) -> DisplayModeInfo? {
        if let current, let same = resolution.modes.first(where: { $0.refreshKey == current.refreshKey }) { return same }
        return resolution.modes.first
    }
}

// MARK: - Notch-Free

public enum NotchFreeLogic {
    /// What share of the screen's height the notch takes: the safe-area top over the screen's
    /// height, both in points of the current mode. 32 / 1117 on a 14" MacBook Pro.
    public static func notchFraction(safeAreaTop: Double, screenHeight: Double) -> Double? {
        guard safeAreaTop > 0, screenHeight > safeAreaTop else { return nil }
        return safeAreaTop / screenHeight
    }

    /// The notch share read off the mode list alone, for when the safe area cannot say (Notch-Free
    /// is already on, so the screen no longer reaches the notch): the panel's native mode against
    /// its same-width twin a few percent shorter.
    public static func notchFraction(fromModes modes: [DisplayModeInfo]) -> Double? {
        guard let native = modes.filter(\.isNative).max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
        else { return nil }
        let twins = modes.filter {
            $0.pixelWidth == native.pixelWidth && $0.pixelHeight < native.pixelHeight
                && Double($0.pixelHeight) > Double(native.pixelHeight) * (1 - maxFraction)
        }
        guard let twin = twins.max(by: { $0.pixelHeight < $1.pixelHeight }) else { return nil }
        return 1 - Double(twin.pixelHeight) / Double(native.pixelHeight)
    }

    /// No notch takes more than this of a screen; a "twin" further away is a different size.
    static let maxFraction = 0.08

    /// The mode that shows `current` with the notch rows left out: same width, same scale, the
    /// refresh closest to the current one, and the height nearest to what is left once the notch
    /// share is taken off. Never taller; never more than `maxFraction` shorter. When two heights
    /// are equally close, the 16:10 one wins, since that is the shape Apple cut these panels from.
    public static func notchFreeMode(for current: DisplayModeInfo, in modes: [DisplayModeInfo],
                                     notchFraction: Double) -> DisplayModeInfo? {
        guard notchFraction > 0, notchFraction < maxFraction else { return nil }
        let target = Double(current.height) * (1 - notchFraction)
        let floor = Double(current.height) * (1 - maxFraction)
        let candidates = modes.filter {
            $0.usableForDesktop && $0.width == current.width && $0.scale == current.scale
                && $0.height < current.height && Double($0.height) >= floor
        }
        return best(candidates, target: target, refresh: current.refreshRate)
    }

    /// The way back: the same width and scale, taller by the notch, at the closest refresh.
    public static func notchedMode(for current: DisplayModeInfo, in modes: [DisplayModeInfo],
                                   notchFraction: Double) -> DisplayModeInfo? {
        guard notchFraction > 0, notchFraction < maxFraction else { return nil }
        let target = Double(current.height) / (1 - notchFraction)
        let ceiling = Double(current.height) / (1 - maxFraction)
        let candidates = modes.filter {
            $0.usableForDesktop && $0.width == current.width && $0.scale == current.scale
                && $0.height > current.height && Double($0.height) <= ceiling
        }
        return best(candidates, target: target, refresh: current.refreshRate)
    }

    /// Whether `mode` is already a notch-free one: a taller same-width twin exists.
    public static func isNotchFree(_ mode: DisplayModeInfo, in modes: [DisplayModeInfo], notchFraction: Double) -> Bool {
        notchedMode(for: mode, in: modes, notchFraction: notchFraction) != nil
            && notchFreeMode(for: mode, in: modes, notchFraction: notchFraction) == nil
    }

    private static func best(_ candidates: [DisplayModeInfo], target: Double, refresh: Double) -> DisplayModeInfo? {
        // The height first, then the refresh: a 60 Hz twin of the right size beats a 120 Hz wrong one.
        guard let height = candidates.map(\.height).min(by: { a, b in
            let da = abs(Double(a) - target), db = abs(Double(b) - target)
            if abs(da - db) > 0.5 { return da < db }
            let sa = isSixteenTen(candidates.first { $0.height == a }!), sb = isSixteenTen(candidates.first { $0.height == b }!)
            return sa && !sb
        }) else { return nil }
        let sameHeight = candidates.filter { $0.height == height }
        return sameHeight.min { a, b in
            let da = abs(a.refreshRate - refresh), db = abs(b.refreshRate - refresh)
            if da != db { return da < db }
            return a.refreshRate > b.refreshRate
        }
    }

    static func isSixteenTen(_ mode: DisplayModeInfo) -> Bool { abs(mode.aspect - 1.6) < 0.01 }

    /// How tall the black band is, in points of the notch-free mode, for the miniature.
    public static func bandPoints(notched: DisplayModeInfo, notchFree: DisplayModeInfo) -> Double {
        // The band covers the same panel rows the notched mode spends on its top strip.
        guard notched.pixelHeight > 0 else { return 0 }
        let rows = Double(notched.pixelHeight - notchFree.pixelHeight)
        return rows / notchFree.scale
    }
}

// MARK: - HiDPI Anywhere

/// The numbers a HiDPI virtual display is made of.
public struct VirtualDisplayPlan: Equatable, Sendable {
    /// The size things are laid out in.
    public var pointWidth: Int
    public var pointHeight: Int
    /// The framebuffer: twice the points when HiDPI.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var hiDPI: Bool
    /// The descriptor's ceiling, at least the pixel size.
    public var maxPixelsWide: Int
    public var maxPixelsHigh: Int
    /// Physical size that gives the virtual screen the PPI asked for.
    public var sizeInMillimeters: (width: Double, height: Double)

    /// The modes handed to `CGVirtualDisplaySettings`, in pixels: with `hiDPI` on, macOS offers
    /// each W×H entry also as a W/2 × H/2 point HiDPI mode.
    public var modeSizes: [(width: Int, height: Int)]

    public static func == (a: VirtualDisplayPlan, b: VirtualDisplayPlan) -> Bool {
        a.pointWidth == b.pointWidth && a.pointHeight == b.pointHeight && a.pixelWidth == b.pixelWidth
            && a.pixelHeight == b.pixelHeight && a.refreshRate == b.refreshRate && a.hiDPI == b.hiDPI
            && a.maxPixelsWide == b.maxPixelsWide && a.maxPixelsHigh == b.maxPixelsHigh
            && a.sizeInMillimeters == b.sizeInMillimeters
            && a.modeSizes.map { "\($0.width)x\($0.height)" } == b.modeSizes.map { "\($0.width)x\($0.height)" }
    }
}

public enum HiDPIMath {
    /// What WindowServer accepts for a virtual display's framebuffer side.
    public static let maxPixelSide = 8192
    /// A PPI that looks right at a desk when nothing else is known (a 27" 5K is 218, 1× is ~109).
    public static let defaultPPI = 110.0

    /// Pixels per inch from a pixel width and the width in millimetres.
    public static func ppi(pixelWidth: Int, millimetres: Double) -> Double? {
        guard millimetres > 1 else { return nil }
        return Double(pixelWidth) / (millimetres / 25.4)
    }

    /// Below this a monitor is "low PPI": macOS will not offer it HiDPI on its own.
    public static let lowPPI = 150.0

    /// A virtual display for `points` (the size wanted on screen). With `hiDPI`, twice the
    /// pixels; `millimetres` makes it report the physical size of the monitor it stands in for,
    /// so apps that care about real size (Preview's "actual size") stay right.
    public static func plan(points: (width: Int, height: Int), refreshRate: Double = 60, hiDPI: Bool,
                            millimetres: (width: Double, height: Double)? = nil) -> VirtualDisplayPlan? {
        guard points.width >= 320, points.height >= 200 else { return nil }
        let scale = hiDPI ? 2 : 1
        let pw = points.width * scale, ph = points.height * scale
        guard pw <= maxPixelSide, ph <= maxPixelSide else { return nil }
        let mm = millimetres ?? (Double(points.width) / defaultPPI * 25.4, Double(points.height) / defaultPPI * 25.4)
        // A few smaller sizes of the same shape, so the display can be rescaled from System Settings too.
        var sizes: [(Int, Int)] = [(pw, ph)]
        for factor in [0.8333, 0.75, 0.6667] {
            let w = even(Double(pw) * factor), h = even(Double(ph) * factor)
            if w >= 640, h >= 400, !sizes.contains(where: { $0.0 == w }) { sizes.append((w, h)) }
        }
        return VirtualDisplayPlan(pointWidth: points.width, pointHeight: points.height, pixelWidth: pw, pixelHeight: ph,
                                  refreshRate: refreshRate, hiDPI: hiDPI, maxPixelsWide: pw, maxPixelsHigh: ph,
                                  sizeInMillimeters: mm, modeSizes: sizes.map { (width: $0.0, height: $0.1) })
    }

    /// Point sizes worth offering a monitor of `native` pixels as HiDPI "looks like" sizes:
    /// its shape, from half its width (pixel-perfect 2×) up to its full width (crisp text at
    /// 1:1 points, 4× the pixels), on widths that are multiples of 8.
    public static func scaledSizes(native: (width: Int, height: Int)) -> [(width: Int, height: Int)] {
        guard native.width > 0, native.height > 0 else { return [] }
        let aspect = Double(native.width) / Double(native.height)
        var out: [(width: Int, height: Int)] = []
        let fractions = [0.5, 0.5625, 0.625, 0.6667, 0.75, 0.8, 0.875, 1.0]
        for f in fractions {
            let w = Int((Double(native.width) * f / 8).rounded()) * 8
            let h = even(Double(w) / aspect)
            guard w * 2 <= maxPixelSide, h * 2 <= maxPixelSide, w >= 640 else { continue }
            if !out.contains(where: { $0.width == w }) { out.append((w, h)) }
        }
        return out
    }

    /// Parses "1920x1080", "1920×1080" or "1920*1080@120".
    public static func parseSize(_ text: String) -> (width: Int, height: Int, refresh: Double?)? {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "*", with: "x")
            .split(separator: "@", maxSplits: 1)
        let dims = parts.first?.split(separator: "x") ?? []
        guard dims.count == 2, let w = Int(dims[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(dims[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0 else { return nil }
        let hz = parts.count > 1 ? Double(parts[1].replacingOccurrences(of: "hz", with: "")) : nil
        return (w, h, hz)
    }

    static func even(_ value: Double) -> Int { Int((value / 2).rounded()) * 2 }
}

// MARK: - Keep this mode?

/// A mode change on probation. Applying starts it; the person keeps it, or it reverts on its own
/// when the time runs out, so a mode that leaves the screen black undoes itself.
public enum ModeRevertState: Equatable, Sendable {
    case idle
    case pending(previous: DisplayModeInfo, applied: DisplayModeInfo, deadline: Double)
}

public enum ModeRevertEvent: Equatable, Sendable {
    case applied(previous: DisplayModeInfo, applied: DisplayModeInfo, now: Double)
    case keep
    case revertNow
    case tick(now: Double)
    /// The display went away or the mode changed under us: nothing left to revert.
    case abandon
}

public enum ModeRevertAction: Equatable, Sendable {
    case none
    case restore(DisplayModeInfo)
}

public enum ModeRevertMachine {
    public static let seconds = 15.0

    public static func next(_ state: ModeRevertState, _ event: ModeRevertEvent) -> (ModeRevertState, ModeRevertAction) {
        switch (state, event) {
        case (.idle, .applied(let previous, let applied, let now)):
            if previous == applied { return (.idle, .none) }
            return (.pending(previous: previous, applied: applied, deadline: now + seconds), .none)
        case (.pending(let previous, _, _), .applied(_, let applied, let now)):
            // A second change while on probation: the way back is still the first mode.
            if previous == applied { return (.idle, .none) }
            return (.pending(previous: previous, applied: applied, deadline: now + seconds), .none)
        case (.pending, .keep), (.pending, .abandon):
            return (.idle, .none)
        case (.pending(let previous, _, _), .revertNow):
            return (.idle, .restore(previous))
        case (.pending(let previous, _, let deadline), .tick(let now)):
            return now >= deadline ? (.idle, .restore(previous)) : (state, .none)
        case (.idle, _):
            return (.idle, .none)
        }
    }

    /// Whole seconds left, for the countdown; 0 when nothing is pending.
    public static func remaining(_ state: ModeRevertState, now: Double) -> Int {
        guard case .pending(_, _, let deadline) = state else { return 0 }
        return max(0, Int((deadline - now).rounded(.up)))
    }
}
