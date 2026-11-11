import Foundation

/// Spots a quick side-to-side shake of the pointer, the gesture people use to find it.
public struct ShakeDetector: Sendable {
    public var window: Double
    public var reversalsNeeded: Int
    public var minimumTravel: Double

    private var lastX: Double?
    private var direction = 0
    private var segmentStart = 0.0
    private var reversals: [Double] = []

    public init(window: Double = 0.7, reversalsNeeded: Int = 4, minimumTravel: Double = 60) {
        self.window = window
        self.reversalsNeeded = reversalsNeeded
        self.minimumTravel = minimumTravel
    }

    /// Feed every pointer x. Returns true once per detected shake.
    public mutating func add(x: Double, time: Double) -> Bool {
        defer { lastX = x }
        guard let lastX else { segmentStart = x; return false }
        let dx = x - lastX
        guard abs(dx) >= 0.5 else { return false }
        let heading = dx > 0 ? 1 : -1
        if direction == 0 {
            direction = heading
        } else if heading != direction {
            if abs(lastX - segmentStart) >= minimumTravel { reversals.append(time) }
            segmentStart = lastX
            direction = heading
        }
        reversals.removeAll { time - $0 > window }
        guard reversals.count >= reversalsNeeded else { return false }
        reversals.removeAll()
        return true
    }
}

/// The Night Tint schedule. Minutes run from midnight; a window may cross midnight.
public enum NightSchedule {
    /// 0 outside the window, 1 inside it, with a linear ramp of `fade` minutes after the
    /// start and before the end.
    public static func strength(minute: Double, start: Double, end: Double, fade: Double) -> Double {
        let length = span(start, end)
        guard length > 0 else { return 0 }
        let into = span(start, minute)
        guard into < length else { return 0 }
        let ramp = min(max(fade, 0), length / 2)
        guard ramp > 0 else { return 1 }
        if into < ramp { return into / ramp }
        let left = length - into
        if left < ramp { return left / ramp }
        return 1
    }

    /// When to look again: each minute while ramping, otherwise at the next ramp.
    public static func secondsUntilNextUpdate(minute: Double, start: Double, end: Double, fade: Double) -> Double {
        let length = span(start, end)
        guard length > 0 else { return 3600 }
        let ramp = min(max(fade, 0), length / 2)
        let into = span(start, minute)
        let ramping = into < length && (into < ramp || length - into < ramp)
        if ramping { return 60 }
        let toStart = span(minute, start)
        let toEndRamp = span(minute, end - ramp)
        let next = [toStart, toEndRamp].filter { $0 > 0 }.min() ?? 1440
        return max(next * 60, 30)
    }

    /// Minutes from `a` forward to `b`, wrapping at midnight.
    static func span(_ a: Double, _ b: Double) -> Double {
        let value = (b - a).truncatingRemainder(dividingBy: 1440)
        return value < 0 ? value + 1440 : value
    }
}

// MARK: - What the desktop features can count on, per Mac

/// The decisions the wallpaper, widget and Desktop+ features make about the Mac they run on,
/// kept free of AppKit so each one is tested on every release and chip without that hardware.
public enum DesktopCompat {
    // MARK: Dock

    public enum DockEdge: Equatable, Sendable { case bottom, left, right, hidden }

    /// Which edge of a display holds the Dock, from the gap between its frame and its visible
    /// frame (AppKit coordinates, origin bottom left). A hidden Dock still leaves a few points,
    /// so anything under `threshold` counts as hidden. The menu bar only ever insets the top.
    public static func dockEdge(frame: CGRect, visible: CGRect, threshold: Double = 30) -> DockEdge {
        let bottom = visible.minY - frame.minY
        let left = visible.minX - frame.minX
        let right = frame.maxX - visible.maxX
        let widest = max(bottom, left, right)
        guard widest >= threshold else { return .hidden }
        if widest == bottom { return .bottom }
        return widest == left ? .left : .right
    }

    // MARK: Preferences as other processes write them

    /// A Boolean preference however it was written: `defaults write -bool`, `-int` or `-string`.
    /// Nil when the key is missing or holds something else.
    public static func bool(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as NSNumber: return value.intValue != 0
        case let value as String:
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Whether Finder draws icons on the desktop. Finder's own `CreateDesktop` switch works on
    /// every release; from macOS 14, Desktop & Dock's "Show Items: On Desktop" writes
    /// `StandardHideDesktopIcons` in `com.apple.WindowManager` as well, and either one hides them.
    public static func finderShowsIcons(createDesktop: Any?, standardHideDesktopIcons: Any?, major: Int) -> Bool {
        if bool(createDesktop) == false { return false }
        if major >= 14, bool(standardHideDesktopIcons) == true { return false }
        return true
    }

    // MARK: Menu Bar Hider

    /// macOS enforces a hard 10,000 point ceiling on a status item's length.
    public static let statusItemMaximum = 10_000.0

    /// Up to macOS 26 an over-long divider simply pushes the items to its left off the bar.
    /// macOS 27 composites the menu bar as one surface and drops an item too long to fit from
    /// the layout altogether, and a dropped item pushes nothing, so there the length is worked
    /// out from the display instead (dwarvesf/hidden#360 and its v1.11.1 fix).
    public static func hiderNeedsMeasuring(major: Int) -> Bool { major >= 27 }

    /// Room held back from macOS 27's cutoff, so rounding never tips the divider over it.
    public static let hiderMargin = 24.0

    /// How long the divider grows to push the items left of it off the bar.
    ///
    /// Measured on macOS 27.3 (1728 pt display, divider beside Control Centre): a status item
    /// whose window, its length plus `padding`, is wider than half the display is dropped from
    /// the bar, and items are fully gone (no overflow chevron) once the divider's left edge
    /// passes the display's middle. Half the display less a margin meets both for any divider
    /// in the right half. The window frame cannot tell a dropped item from a laid-out one there,
    /// so nothing is probed live. `padding` is the window's width less the item's length.
    public static func hiderLength(major: Int, screenWidth: Double, padding: Double) -> Double {
        guard hiderNeedsMeasuring(major: major) else { return statusItemMaximum }
        let length = screenWidth / 2 - max(0, padding) - hiderMargin
        return min(statusItemMaximum, max(10, length.rounded(.down)))
    }

    /// `NSStatusItem Preferred Position` values that place the arrow beside Control Centre
    /// and the divider just left of it, so every other icon starts out tucked. Smaller sits
    /// further right; 0 means "no preference" and lands at the far left. Only seeded when
    /// missing: macOS rewrites them when you Command-drag either item.
    public static let hiderToggleSlot = 1.0
    public static let hiderDividerSlot = 2.0

    // MARK: Generated wallpapers

    /// The pixel size to paint a display at: its full backing size, inside the largest texture
    /// every Mac GPU from macOS 14 accepts (16,384 on Apple silicon and on Intel and AMD alike),
    /// keeping the aspect ratio when a display is larger than that.
    public static func wallpaperPixels(width: Double, height: Double, scale: Double, maxTexture: Int = 16_384) -> (width: Int, height: Int) {
        let w = max(width * scale, 1), h = max(height * scale, 1)
        let fit = min(1, Double(maxTexture) / max(w, h))
        return (max(Int((w * fit).rounded()), 1), max(Int((h * fit).rounded()), 1))
    }

    public enum ImageFormat: String, Equatable, Sendable { case heic, png }

    /// HEIC keeps the dither at a fraction of a PNG's size, but ImageIO can only write it where
    /// the Mac has an encoder for it; older Intel Macs without one get PNG.
    public static func wallpaperFormat(writable types: [String]) -> ImageFormat {
        types.contains("public.heic") ? .heic : .png
    }

    public enum OriginalWallpaperProblem: Equatable, Sendable {
        case none
        /// The picture is there but this app may not read it (Downloads, Desktop, an external disk).
        case unreadable
        /// The wallpaper store names no picture file: an Aerial, a dynamic or built-in wallpaper, or a
        /// colour, which macOS 14 and later keep as a provider rather than a file.
        case systemWallpaper
    }

    public static func originalWallpaperProblem(foundFile: Bool, readable: Bool) -> OriginalWallpaperProblem {
        guard foundFile else { return .systemWallpaper }
        return readable ? .none : .unreadable
    }
}
