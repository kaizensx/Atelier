import Foundation

// MARK: - The Studio's picture of the Mac it runs on
//
// The stage is a replica of the owner's own screen, so it has to draw the menu bar and the Dock
// the way *this* release draws them: Sonoma and Sequoia have a frosted, slightly opaque menu bar
// and a frosted Dock with tighter corners; Tahoe (26) and later draw both in Liquid Glass, the
// menu bar fully transparent by default. The decisions live here, as pure functions of the
// release and the screen's measurements, so they can be tested for every Mac without one.

/// How the stage draws the system chrome for a given macOS release.
public struct ShellStageChrome: Equatable, Sendable {
    /// Liquid Glass (macOS 26 and later) or the frosted look of macOS 14 and 15.
    public let liquidGlass: Bool
    /// The menu bar shows a frosted band behind its items. Before Tahoe it always does; from
    /// Tahoe on it is transparent unless Reduce Transparency is on.
    public let menuBarBand: Bool
    /// The Dock's corner radius as a fraction of the tile size. Measured from screenshots: the
    /// Sonoma/Sequoia Dock is about 0.28 of a tile, the Tahoe glass Dock is rounder (about 0.42).
    public let dockCornerFraction: Double
    /// The Dock tile name tag: a rounded rectangle before Tahoe, a capsule of glass after.
    public let capsuleLabels: Bool

    public init(liquidGlass: Bool, menuBarBand: Bool, dockCornerFraction: Double, capsuleLabels: Bool) {
        self.liquidGlass = liquidGlass
        self.menuBarBand = menuBarBand
        self.dockCornerFraction = dockCornerFraction
        self.capsuleLabels = capsuleLabels
    }

    public static func forRelease(major: Int, reduceTransparency: Bool = false) -> ShellStageChrome {
        let glass = major >= 26
        return ShellStageChrome(liquidGlass: glass,
                                menuBarBand: !glass || reduceTransparency,
                                dockCornerFraction: glass ? 0.42 : 0.28,
                                capsuleLabels: glass)
    }
}

/// The menu bar's height in points on one screen.
public enum ShellMenuBar {
    /// The height a menu bar has without a notch, since Big Sur (it was 22 points before).
    public static let standardHeight = 24.0

    /// - Parameters:
    ///   - frameMaxY: the screen frame's top edge.
    ///   - visibleMaxY: the visible frame's top edge; equal to `frameMaxY` while the menu bar hides itself.
    ///   - notchInset: `safeAreaInsets.top`, non-zero only on a display with a camera housing.
    /// The measured gap wins when there is one; a hidden menu bar falls back to the notch's height,
    /// which is what the bar is drawn at on those displays, or to the standard 24 points.
    public static func height(frameMaxY: Double, visibleMaxY: Double, notchInset: Double) -> Double {
        let measured = frameMaxY - visibleMaxY
        // A gap of a few points is the menu bar; a huge one is a Dock placed at the top by another app, never trusted.
        if measured >= 18, measured <= 60 { return measured }
        if notchInset > 0 { return notchInset }
        return standardHeight
    }

    /// The notch's width from the two auxiliary areas either side of it, or nil when there is none.
    public static func notchWidth(screenWidth: Double, leftArea: Double?, rightArea: Double?) -> Double? {
        guard let leftArea, let rightArea else { return nil }
        let width = screenWidth - leftArea - rightArea
        return width > 40 && width < screenWidth / 2 ? width : nil
    }
}

/// What a frame should take on a display, so the frame meter judges a 60 Hz Mac by 60 Hz.
public struct ShellFrameBudget: Equatable, Sendable {
    /// The display's top refresh rate, clamped to what a Mac can show.
    public let refreshRate: Int
    /// One frame at that rate, in milliseconds.
    public var frameMs: Double { 1000 / Double(refreshRate) }
    /// A frame that arrived later than half a frame past its slot.
    public var lateMs: Double { frameMs * 1.5 }
    /// A frame missed outright: two slots or more, and never under 25 ms so a ProMotion display
    /// gliding down to 48 Hz is not counted as a hitch.
    public var hitchMs: Double { max(frameMs * 2.5, 25) }

    public init(maximumFramesPerSecond: Int) {
        // A display that reports nothing (0) or nonsense is treated as the common 60 Hz.
        refreshRate = maximumFramesPerSecond >= 24 && maximumFramesPerSecond <= 240 ? maximumFramesPerSecond : 60
    }
}

/// How much the Studio's light (a full-window Metal fragment pass) may spend on this Mac.
public struct ShellLightTier: Equatable, Sendable {
    /// Drawable pixels per point, relative to the backing scale: 0.5 is a quarter of the pixels.
    public let resolution: Double
    /// The most frames a second the light draws, even while it moves.
    public let maxFPS: Int

    public init(resolution: Double, maxFPS: Int) {
        self.resolution = resolution
        self.maxFPS = maxFPS
    }

    /// - Parameters:
    ///   - appleGPU: the Metal device is an Apple GPU (Apple silicon). Intel UHD/Iris and AMD
    ///     Radeon GPUs share their memory bandwidth with the rest of the window, so they draw less.
    ///   - lowPowerDevice: an integrated GPU on a dual-GPU Intel MacBook Pro, the one we pick so
    ///     the light never wakes the discrete GPU.
    ///   - lowPowerMode: macOS Low Power Mode is on.
    ///   - refreshRate: the display's top rate.
    public static func choose(appleGPU: Bool, lowPowerDevice: Bool, lowPowerMode: Bool, refreshRate: Int) -> ShellLightTier {
        let rate = max(min(refreshRate, 120), 30)
        if lowPowerMode { return ShellLightTier(resolution: 0.33, maxFPS: min(rate, 30)) }
        if appleGPU { return ShellLightTier(resolution: 0.5, maxFPS: rate) }
        // The light is soft by design, so a third of the resolution is invisible and saves
        // more than half the fill rate on an Intel GPU.
        return ShellLightTier(resolution: lowPowerDevice ? 0.33 : 0.4, maxFPS: min(rate, 60))
    }
}

/// The facts a bug report needs about the Mac, gathered by the app and formatted here.
public struct ShellMacFacts: Equatable, Sendable {
    public var osVersion: String          // "15.3.1"
    public var osBuild: String            // "24D70"
    public var model: String              // "Mac17,8"
    public var chip: String               // "Apple M5 Pro" or "Intel Core i7-9750H"
    public var appleSilicon: Bool
    public var translated: Bool           // running under Rosetta
    public var displays: [Display]
    public var trackpad: String           // "Built-in, Force Touch", "Magic Trackpad", "None found"
    public var sip: String                // "On", "Off (fs, debug)", "Unknown"
    public var appVersion: String

    public struct Display: Equatable, Sendable {
        public var name: String
        public var main: Bool
        public var builtIn: Bool
        public var points: String         // "1728×1117"
        public var scale: Double
        public var refreshRate: Int
        public var notch: Bool
        public var edrHeadroom: Double    // maximumPotentialExtendedDynamicRangeColorComponentValue

        public init(name: String, main: Bool, builtIn: Bool, points: String, scale: Double, refreshRate: Int, notch: Bool, edrHeadroom: Double) {
            self.name = name; self.main = main; self.builtIn = builtIn; self.points = points; self.scale = scale
            self.refreshRate = refreshRate; self.notch = notch; self.edrHeadroom = edrHeadroom
        }

        /// What the display can do, in words: "XDR (16× EDR)", "HDR (2× EDR)", "SDR".
        public var range: String {
            if edrHeadroom >= 8 { return String(format: "XDR (%.0f× EDR)", edrHeadroom) }
            if edrHeadroom > 1.01 { return String(format: "HDR (%.1f× EDR)", edrHeadroom) }
            return "SDR"
        }
    }

    public init(osVersion: String, osBuild: String, model: String, chip: String, appleSilicon: Bool, translated: Bool,
                displays: [Display], trackpad: String, sip: String, appVersion: String) {
        self.osVersion = osVersion; self.osBuild = osBuild; self.model = model; self.chip = chip
        self.appleSilicon = appleSilicon; self.translated = translated; self.displays = displays
        self.trackpad = trackpad; self.sip = sip; self.appVersion = appVersion
    }

    /// The release's marketing name, for people reading the report.
    public static func releaseName(major: Int) -> String {
        switch major {
        case 14: "Sonoma"
        case 15: "Sequoia"
        case 26: "Tahoe"
        default: ""
        }
    }

    public var architecture: String {
        appleSilicon ? (translated ? "Apple silicon (Intel build under Rosetta)" : "Apple silicon") : "Intel"
    }

    /// The block pasted into an issue: plain text, one fact a line, so it reads well in Markdown.
    public var report: String {
        let major = Int(osVersion.split(separator: ".").first ?? "") ?? 0
        let name = Self.releaseName(major: major)
        var lines = [
            "Atelier \(appVersion)",
            "macOS \(osVersion)\(name.isEmpty ? "" : " \(name)") (\(osBuild))",
            "Mac: \(model), \(chip), \(architecture)",
        ]
        for (index, display) in displays.enumerated() {
            var traits = ["\(display.points) pt @\(String(format: "%g", display.scale))x", "\(display.refreshRate) Hz", display.range]
            if display.notch { traits.append("notch") }
            let role = [display.main ? "main" : nil, display.builtIn ? "built-in" : nil].compactMap { $0 }.joined(separator: ", ")
            lines.append("Display \(index + 1): \(display.name)\(role.isEmpty ? "" : " (\(role))") – " + traits.joined(separator: ", "))
        }
        if displays.isEmpty { lines.append("Displays: none reported") }
        lines.append("Trackpad: \(trackpad)")
        lines.append("System Integrity Protection: \(sip)")
        return lines.joined(separator: "\n")
    }
}
