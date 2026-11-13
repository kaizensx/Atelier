import CoreGraphics
import Foundation

// The Atelier Dock as pure data and physics. Nothing here touches AppKit or SwiftUI, so the
// whole frame step can be compiled on its own and measured.

// MARK: - The lens

/// Read from Dock 1.8 (macOS 27.3), `sub_1000118d4` and `sub_100011b68` in the arm64e slice:
///
///     F = 3 × tile                                     -[DockBar fSize] is 3
///     R = ((large − tile) / 2) / sin(π·tile / 4F) × ramp
///     x' = x + R·sin(π·d / 2F)      for |d| < F, d = x − fishCenter
///     x' = x ± R                    past that
///
/// The Dock warps tile edges, it does not scale icons: an icon's size is whatever is left
/// between its warped edges. `fishCenter` is the raw pointer clamped to the bar, and the ramp
/// runs for `floor(log(gap / 2 + 1) × 42 + 1)` ms, a one-shot time-based tween.
///
/// Three things are kept: edge warping (icons never overlap), a reach of three tiles, and a
/// peak that lands exactly on the large size. Three are replaced:
///
/// 1. The width profile `1 + A·cos(πd / 2F)` has a slope jump at ±F, so neighbours start to
///    move abruptly. Ours integrates `1 + A·cos²(πd / 2F)`, which reaches ±F with zero slope.
///    For the same peak, neighbours also travel about 20% less sideways.
/// 2. `fishCenter` is a spring with velocity, not the pointer. It carries momentum, and it
///    coasts on when the pointer leaves.
/// 3. The radius breathes with pointer speed: a fast sweep spreads the lens, a slow one
///    tightens it for aiming. The ramp is a spring too, so every change can be interrupted.
///
/// The curve presets change the power of the profile (cos² or the narrower cos⁴) and the
/// radius. Every profile still reaches its radius with zero slope.
enum DockLens {
    static let reach = 3.0

    /// The width profile at `distance`, 1 at the centre and 0 at the radius.
    static func profile(_ distance: Double, radius: Double, power: Int = 2) -> Double {
        guard radius > 0, abs(distance) < radius else { return 0 }
        let c = cos(.pi * distance / (2 * radius))
        return power == 4 ? c * c * c * c : c * c
    }

    /// The integral of the profile from 0 to `distance`. Odd, and flat past the radius.
    static func integral(_ distance: Double, radius: Double, power: Int = 2) -> Double {
        guard radius > 0 else { return 0 }
        let x = min(max(distance, -radius), radius)
        if power == 4 {
            let theta = .pi * x / (2 * radius)
            return 2 * radius / .pi * (3 * theta / 8 + sin(2 * theta) / 4 + sin(4 * theta) / 32)
        }
        return x / 2 + radius / (2 * .pi) * sin(.pi * x / radius)
    }

    /// Sideways shift of a tile edge `distance` points from the centre.
    static func shift(_ distance: Double, gain: Double, radius: Double, power: Int = 2) -> Double {
        gain * integral(distance, radius: radius, power: power)
    }

    /// The gain that makes a tile centred under the lens exactly `large` wide.
    static func gain(tile: Double, large: Double, radius: Double, power: Int = 2) -> Double {
        guard large > tile, radius > 0 else { return 0 }
        let width = 2 * integral(tile / 2, radius: radius, power: power)
        return width > 0 ? (large - tile) / width : 0
    }
}

/// How the lens shapes the icons around the pointer.
enum DockCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle, classic, fisheye, wave
    var id: String { rawValue }
    var title: String { rawValue == "fisheye" ? "Fisheye" : rawValue.capitalized }

    /// The lens radius, as a multiple of Lens Width.
    var reachScale: Double {
        switch self {
        case .gentle: 1.35
        case .classic: 1
        case .fisheye: 0.8
        case .wave: 2.1
        }
    }

    /// cos² is soft, cos⁴ puts most of the growth on the icon under the pointer.
    var power: Int { self == .fisheye ? 4 : 2 }

    /// How hard the lens centre is pulled toward the pointer. A soft pull makes the wave roll
    /// behind the pointer.
    var stiffness: Double {
        switch self {
        case .gentle: 340
        case .classic: 520
        case .fisheye: 640
        case .wave: 170
        }
    }
}

// MARK: - Settings

enum OwnDockEdge: String, CaseIterable, Identifiable, Codable, Sendable {
    case bottom, left, right, top
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var horizontal: Bool { self == .bottom || self == .top }
}

/// The material of the bar.
enum DockStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case glass, tinted, midnight, frost, neon, wallpaper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Glass"
        case .tinted: "Tinted"
        case .midnight: "Midnight"
        case .frost: "Frost"
        case .neon: "Neon Edge"
        case .wallpaper: "Wallpaper"
        }
    }
}

/// What marks an open app.
enum DockIndicator: String, Codable, CaseIterable, Identifiable, Sendable {
    case dot, bar, glow, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What resting the pointer on a tile shows.
enum DockHover: String, Codable, CaseIterable, Identifiable, Sendable {
    case peek, label, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .peek: "Live Peek"
        case .label: "Name"
        case .none: "Nothing"
        }
    }
}

/// Where the name or the Live Peek card floats.
enum DockLabelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Clear of the fully grown lens, like the macOS Dock.
    case lens
    /// Just above the icon, following it as it grows.
    case icon
    var id: String { rawValue }
    var title: String { self == .lens ? "Above the Lens" : "Above the Icon" }
}

/// What an app does while it opens.
enum DockLaunchStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bounce, pulse, glow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bounce: "Bounce"
        case .pulse: "Pulse Ring"
        case .glow: "Glow"
        }
    }
}

enum DockAccent: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, purple, pink, orange, green, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Every look-and-feel setting of the Atelier Dock, saved as one value.
struct DockAppearance: Codable, Equatable, Sendable {
    var style = DockStyle.glass
    var accent = DockAccent.blue
    var indicator = DockIndicator.bar
    var hover = DockHover.peek
    /// 0 is nearly square, 1 is a capsule.
    var roundness = 2.0 / 3
    /// Glass around the icons, as a fraction of the icon size.
    var padding = 0.14
    /// Room between icons, as a fraction of the icon size.
    var spacing = 0.0
    /// How many icons the lens reaches on each side.
    var reach = 3.0
    /// Points between the bar and the screen edge.
    var gap = 6.0
    var launch = DockLaunchStyle.bounce
    var divider = true
    var runningOnly = false
    /// Nil follows Replace System Dock: on while this dock stands in for the macOS one.
    var showTrash: Bool?
    var curve = DockCurve.classic
    /// Icons rise under the pointer instead of growing.
    var hoverLift = false
    var labelPosition = DockLabelPosition.lens
    var iconShadow = true
    var reflection = false
    var badges = true
    /// Tiles hop when their app asks for attention.
    var attention = true
    /// Clicking the icon of the app in front hides it.
    var clickToHide = false
    /// Scrolling on an app's icon brings its windows forward one by one.
    var scrollWindows = true
    var minimized = true
    var recents = false
    var recentCount = 3

    init() {}

    /// Kept for the places that only ask whether icons hop.
    var bounce: Bool {
        get { launch == .bounce }
        set { launch = newValue ? .bounce : (launch == .bounce ? .pulse : launch) }
    }

    /// Back to the default look. Contents and behaviour stay as they are.
    mutating func resetLook() {
        let fresh = DockAppearance()
        style = fresh.style
        accent = fresh.accent
        indicator = fresh.indicator
        roundness = fresh.roundness
        padding = fresh.padding
        spacing = fresh.spacing
        reach = fresh.reach
        gap = fresh.gap
        curve = fresh.curve
        hoverLift = fresh.hoverLift
        iconShadow = fresh.iconShadow
        reflection = fresh.reflection
    }

    // Every field is optional when reading, so settings saved by an older build still load.
    private enum CodingKeys: String, CodingKey {
        case style, accent, indicator, hover, roundness, padding, spacing, reach, gap, bounce, launch, divider,
             runningOnly, showTrash, curve, hoverLift, labelPosition, iconShadow, reflection, badges, attention,
             clickToHide, scrollWindows, minimized, recents, recentCount
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockAppearance()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        style = read(.style, d.style)
        accent = read(.accent, d.accent)
        indicator = read(.indicator, d.indicator)
        hover = read(.hover, d.hover)
        roundness = Self.clamp(read(.roundness, d.roundness), 0...1)
        padding = Self.clamp(read(.padding, d.padding), 0.04...0.3)
        spacing = Self.clamp(read(.spacing, d.spacing), 0...0.5)
        reach = Self.clamp(read(.reach, d.reach), 2...5)
        gap = Self.clamp(read(.gap, d.gap), 0...32)
        // Older builds saved a bounce switch only.
        let hopped: Bool = read(.bounce, true)
        launch = read(.launch, hopped ? .bounce : .pulse)
        divider = read(.divider, d.divider)
        runningOnly = read(.runningOnly, d.runningOnly)
        showTrash = read(.showTrash, nil as Bool?)
        curve = read(.curve, d.curve)
        hoverLift = read(.hoverLift, d.hoverLift)
        labelPosition = read(.labelPosition, d.labelPosition)
        iconShadow = read(.iconShadow, d.iconShadow)
        reflection = read(.reflection, d.reflection)
        badges = read(.badges, d.badges)
        attention = read(.attention, d.attention)
        clickToHide = read(.clickToHide, d.clickToHide)
        scrollWindows = read(.scrollWindows, d.scrollWindows)
        minimized = read(.minimized, d.minimized)
        recents = read(.recents, d.recents)
        recentCount = min(max(read(.recentCount, d.recentCount), 1), 8)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(accent, forKey: .accent)
        try c.encode(indicator, forKey: .indicator)
        try c.encode(hover, forKey: .hover)
        try c.encode(roundness, forKey: .roundness)
        try c.encode(padding, forKey: .padding)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(reach, forKey: .reach)
        try c.encode(gap, forKey: .gap)
        // Written for older builds, which read only this.
        try c.encode(bounce, forKey: .bounce)
        try c.encode(launch, forKey: .launch)
        try c.encode(divider, forKey: .divider)
        try c.encode(runningOnly, forKey: .runningOnly)
        try c.encodeIfPresent(showTrash, forKey: .showTrash)
        try c.encode(curve, forKey: .curve)
        try c.encode(hoverLift, forKey: .hoverLift)
        try c.encode(labelPosition, forKey: .labelPosition)
        try c.encode(iconShadow, forKey: .iconShadow)
        try c.encode(reflection, forKey: .reflection)
        try c.encode(badges, forKey: .badges)
        try c.encode(attention, forKey: .attention)
        try c.encode(clickToHide, forKey: .clickToHide)
        try c.encode(scrollWindows, forKey: .scrollWindows)
        try c.encode(minimized, forKey: .minimized)
        try c.encode(recents, forKey: .recents)
        try c.encode(recentCount, forKey: .recentCount)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Contents

/// How a section is set apart from the one before it.
enum DockSectionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case line, gap, dot, label
    var id: String { rawValue }
    var title: String {
        switch self {
        case .line: "Line"
        case .gap: "Gap"
        case .dot: "Dot"
        case .label: "Label"
        }
    }
    /// Room the separator takes along the bar, as a share of one icon.
    var weight: Double {
        switch self {
        case .line: 0.36
        case .gap: 0.62
        case .dot: 0.42
        case .label: 0.42
        }
    }
}

/// What a tile draws, in small values only: the scene copies it every frame.
struct DockFace: Equatable, Sendable {
    enum Clock: UInt8, Sendable { case system, twelve, twentyFour }
    enum Battery: UInt8, Sendable { case percent, time, ring }
    enum Style: UInt8, Sendable { case standard, glass, accent, dark }
    var style = Style.standard
    var caption = false
    var clock = Clock.system
    var seconds = false
    var date = true
    var analog = false
    var battery = Battery.percent
    var ring = true
    var count = true
    /// A folder or stack drawn as its newest items, fanned like the macOS Dock does.
    var fanned = false
}

struct OwnDockItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case app, stack, file, folder
        case clock, battery, downloads, clipboard, orbit, spacer, spacerLarge
        /// A stack that fills itself: recent apps, a folder, a Spotlight search.
        case smart
        /// A plugin's Dock tile or stack. `path` is a `PluginDockPath`.
        case plugin
    }
    var kind: Kind
    var path: String
    /// The user's section, or nil for the dock's own order.
    var section: UUID?
    /// The side the owner put it on; nil keeps the macOS Dock's rule.
    var right: Bool? = nil
    var id: String { path }

    /// The tiles that are not files: their `path` is an identifier under this prefix.
    static let tilePrefix = "atelier:"
    static func tile(_ kind: Kind) -> OwnDockItem {
        let unique = kind == .spacer || kind == .spacerLarge || kind == .smart ? ":" + UUID().uuidString.prefix(8) : ""
        return OwnDockItem(kind: kind, path: tilePrefix + kind.rawValue + unique)
    }

    var isTile: Bool { path.hasPrefix(Self.tilePrefix) }

    var title: String {
        switch kind {
        case .folder: return FileManager.default.displayName(atPath: path)
        case .file: return URL(fileURLWithPath: path).lastPathComponent
        case .app, .stack: return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .clock: return "Clock"
        case .battery: return "Battery"
        case .downloads: return "Downloads"
        case .clipboard: return "Clipboard"
        case .orbit: return "Orbit"
        case .spacer: return "Small Spacer"
        case .spacerLarge: return "Spacer"
        case .smart: return "Smart Stack"
        case .plugin: return path.hasPrefix("atelier:plugin:stack:") ? "Plugin Stack" : "Plugin Tile"
        }
    }

    var isSpacer: Bool { kind == .spacer || kind == .spacerLarge }

    /// Apps and spacers sit left of the divider, everything else right of it, as in the macOS
    /// Dock, unless the owner moved it: any tile can sit on either side.
    var rightSide: Bool { right ?? (kind != .app && kind != .spacer && kind != .spacerLarge) }

    var slotKind: DockSlot.Kind {
        switch kind {
        case .app: .app
        case .stack: .stack
        case .file: .file
        case .folder: .folder
        case .clock: .clock
        case .battery: .battery
        case .downloads: .downloads
        case .clipboard: .clipboard
        case .orbit: .orbit
        case .spacer: .spacer
        case .spacerLarge: .spacerLarge
        case .smart: .smart
        case .plugin: .plugin
        }
    }
}

struct DockSlot: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case app, stack, file, folder, divider, vitals, trash
        case clock, battery, downloads, clipboard, orbit, spacer, spacerLarge
        /// A minimised window. `path` is its app.
        case window
        /// The start of one of the user's sections. `title` is its name.
        case section
        case smart
        /// A plugin's tile or stack. `id` is its `PluginDockPath`.
        case plugin
    }
    var id: String
    var kind: Kind
    var path = ""
    var title = ""
    var pinned = false
    var running = false
    var frontmost = false
    var hidden = false
    var launching = false
    /// For the Trash: whether it holds anything.
    var full = false
    /// The notification badge the app shows in the macOS Dock.
    var badge: String?
    /// The app asks for attention.
    var attention = false
    /// A picture the user chose instead of the file's own icon.
    var icon: String?
    /// For a minimised window: its app.
    var pid: Int32 = 0
    /// Not kept, recently used.
    var recent = false
    /// The tile's size, from its options. 1 is the dock's icon size.
    var scale = 1.0
    var face = DockFace()
    var sectionStyle = DockSectionStyle.line
    /// For a fanned folder or stack: the newest items, front first.
    var preview: [String] = []
    /// For a smart stack: its symbol.
    var symbol: String?

    var weight: Double {
        switch kind {
        case .spacer: 0.5
        case .divider, .section: sectionStyle.weight
        default: scale
        }
    }
    var movable: Bool {
        switch kind {
        case .divider, .vitals, .trash, .window, .section: false
        default: true
        }
    }
    var empty: Bool { kind == .divider || kind == .spacer || kind == .spacerLarge || kind == .section }
    var spacer: Bool { kind == .spacer || kind == .spacerLarge }

    static let divider = DockSlot(id: "divider", kind: .divider)
    static let rightDivider = DockSlot(id: "divider.right", kind: .divider)
    static let recentDivider = DockSlot(id: "divider.recent", kind: .divider)
    static let vitals = DockSlot(id: "vitals", kind: .vitals, title: "Now Vitals")
}

/// Everything that moves in one tile. All of it is spring state, so any motion can be
/// interrupted by the next input without a jump.
struct TileBody: Sendable {
    var appear = 0.0, appearV = 0.0, appearTarget = 1.0
    var offset = 0.0, offsetV = 0.0
    var lift = 0.0, liftV = 0.0
    var press = 0.0, pressV = 0.0, pressTarget = 0.0
    var ring: Double?
    var burst = DockBurst.launch
    var nextPulse = 0.0
    var nextRing = 0.0
    /// Focus Mode: how far the icon is dimmed.
    var dim = 0.0, dimV = 0.0
    /// A file is held over the tile, and it would take it.
    var grow = 0.0, growV = 0.0
}

struct DockMetrics: Sendable {
    var edge = OwnDockEdge.bottom
    var tile = 56.0
    var large = 96.0
    var magnify = true
    var panel = CGSize(width: 1200, height: 400)
    var gap = 6.0
    var padding = 0.14
    var spacing = 0.0
    var reach = DockLens.reach
    var roundness = 2.0 / 3
    var curve = DockCurve.classic
    var hoverLift = false
    var labelOverIcon = false
    var along: Double { edge.horizontal ? panel.width : panel.height }

    /// Takes the shape settings. `scale` shrinks the point values for a scale model.
    mutating func apply(_ look: DockAppearance, scale: Double = 1) {
        padding = look.padding
        spacing = look.spacing
        reach = look.reach
        roundness = look.roundness
        gap = look.gap * scale
        curve = look.curve
        hoverLift = look.hoverLift
        labelOverIcon = look.labelPosition == .icon
    }

    /// How far icons rise in Hover Lift.
    var rise: Double { min(max(large - tile, 0) * 0.55, tile * 0.7) }
}

struct DockTile: Identifiable, Sendable {
    var slot: DockSlot
    var id: String { slot.id }
    var center: CGPoint
    var size: Double
    /// The drawn icon. Smaller than `size` by the spacing between icons.
    var icon: Double = 0
    var base: Double
    var span: ClosedRange<Double>
    var scaleAlong = 1.0
    var scaleCross = 1.0
    var alpha = 1.0
    var ring: Double?
    var indicator = CGPoint.zero
    var glow = 0.0
    var dragging = false
    /// Chosen with the keyboard.
    var focused = false
    /// The centre of the icon's reflection in the glass.
    var mirror = CGPoint.zero
    /// Arrange mode, the pointer on it: it shows its remove button.
    var armed = false
    /// How close the lens is: 1 under the pointer, 0 out of reach or with no pointer.
    var near = 0.0
    /// Where the lens is, from -1 (pointer far before) through 0 to 1 (far after).
    var lean = 0.0
    /// 0 to 1 while the tile arrives or leaves.
    var appear = 1.0
    /// What the ring timer is playing.
    var burst = DockBurst.launch
}

struct DockScene: Sendable {
    var edge = OwnDockEdge.bottom
    var tiles: [DockTile] = []
    var bar = CGRect.zero
    var radius = 16.0
    var tile = 56.0
    /// One icon plus its share of the spacing, along the bar.
    var unit = 56.0
    var hide = 0.0
    var hideOffset = CGSize.zero
    var ramp = 0.0
    var peekAlong = 0.0
    var peekCross = 0.0
    var peekShow = 0.0
    var panel = CGSize.zero
    /// The lens centre along the bar.
    var lens = 0.0
    /// Glass between the icons and the bar's long edges.
    var pad = 0.0
}

/// The dock as pure physics: no AppKit, no windows, and no global state. The real panel and
/// the settings preview each run one of these.
struct DockField: Sendable {
    var slots: [DockSlot] = []
    var bodies: [String: TileBody] = [:]
    var motion = true
    /// Icons hop while their app opens.
    var bounce = true
    /// A ring of light leaves the icon again and again while its app opens.
    var launchPulse = false

    var pointer: Double?
    var hovering = false
    var center = 0.0, centerV = 0.0
    var ramp = 0.0, rampV = 0.0
    var spread = 0.0, spreadV = 0.0
    private var lastPointer: Double?
    private var pointerSpeed = 0.0

    var hideTarget = 0.0
    var hide = 0.0, hideV = 0.0
    /// How briskly the bar slides away and back. Zero is at once.
    var hideStiffness = 170.0
    /// Focus Mode: how much apps other than the one in front fade. Zero is off.
    var focusDim = 0.0
    /// The tile a dragged file is over, when it would take it.
    var dropID: String?
    /// Arrange mode: the tile under the pointer, which shows its remove button.
    var armedID: String?

    var peekTarget = false
    var peekShow = 0.0, peekShowV = 0.0
    var peekAlongTarget: Double?
    var peekAlong = 0.0, peekAlongV = 0.0
    /// The tile the card belongs to. The card follows that tile's live centre, so it stays
    /// over the icon while the lens is still opening or settling.
    var peekID: String?

    var dragID: String?
    var dragPoint = CGPoint.zero
    var dragOut = false
    /// The tile chosen with the keyboard.
    var focusID: String?
    /// While typing to find: the tiles that match. Nil when nothing is typed.
    var matches: Set<String>?
    private var clock = 0.0

    private static let substep = 1.0 / 240

    private static func spring(_ x: inout Double, _ v: inout Double, to target: Double,
                               stiffness k: Double, damping z: Double, dt: Double) {
        v += (-k * (x - target) - 2 * z * k.squareRoot() * v) * dt
        x += v * dt
    }

    // MARK: Contents

    /// Takes a new list. Anything that left stays as a ghost until it has shrunk away.
    mutating func sync(_ new: [DockSlot], instant: Bool = false) {
        var merged = new
        let ids = Set(new.map(\.id))
        for (index, old) in slots.enumerated() where !ids.contains(old.id) {
            guard !instant, bodies[old.id] != nil else { bodies[old.id] = nil; continue }
            var ghost = old
            ghost.launching = false
            ghost.attention = false
            let before = index > 0 ? slots[index - 1].id : nil
            let at = before.flatMap { id in merged.firstIndex { $0.id == id } }.map { $0 + 1 } ?? min(index, merged.count)
            merged.insert(ghost, at: at)
            bodies[old.id]?.appearTarget = 0
        }
        for slot in new {
            var body = bodies[slot.id] ?? TileBody()
            body.appearTarget = 1
            if instant || !motion { body.appear = 1; body.appearV = 0 }
            bodies[slot.id] = body
        }
        slots = merged
    }

    mutating func pulse(_ id: String, strength: Double = 1, tile: Double) {
        guard motion else { return }
        bodies[id]?.liftV += tile * 15 * strength
    }

    /// The launch is over: a ring of light leaves the icon.
    mutating func ignite(_ id: String, tile: Double) {
        guard motion else { return }
        bodies[id]?.ring = 0
        bodies[id]?.burst = .launch
        if bounce { pulse(id, strength: 0.42, tile: tile) }
    }

    /// A drop or the Trash taking something: the tile plays that burst once.
    mutating func burst(_ id: String, _ kind: DockBurst) {
        guard motion else { return }
        bodies[id]?.ring = 0
        bodies[id]?.burst = kind
    }

    mutating func setPressed(_ id: String?, _ on: Bool) {
        guard let id else { return }
        bodies[id]?.pressTarget = on ? 1 : 0
    }

    /// Moves the dragged tile past any neighbour whose middle it has crossed.
    mutating func reorder(using scene: DockScene) {
        guard let dragID, let from = slots.firstIndex(where: { $0.id == dragID }) else { return }
        let along = scene.edge.horizontal ? dragPoint.x : dragPoint.y
        let direction: Int
        if from + 1 < slots.count, slots[from + 1].pinned,
           let next = scene.tiles.first(where: { $0.id == slots[from + 1].id }), along > (next.span.lowerBound + next.span.upperBound) / 2 {
            direction = 1
        } else if from > 0, slots[from - 1].pinned,
                  let previous = scene.tiles.first(where: { $0.id == slots[from - 1].id }), along < (previous.span.lowerBound + previous.span.upperBound) / 2 {
            direction = -1
        } else { return }
        let other = slots[from + direction].id
        slots.swapAt(from, from + direction)
        bodies[other]?.offset += Double(direction) * scene.unit
    }

    // MARK: Geometry

    func fitted(_ m: DockMetrics) -> (tile: Double, large: Double) {
        let sum = slots.reduce(0) { $0 + $1.weight * (bodies[$1.id]?.appear ?? 1) }
        let unit = 1 + m.spacing
        let growth = m.magnify && !m.hoverLift
            ? max(m.large - m.tile, 0) * 1.7 * unit * m.reach * m.curve.reachScale / DockLens.reach : 0
        let wanted = m.tile * unit * sum + growth + m.tile * 0.28
        let usable = m.along - 32
        guard wanted > usable, wanted > 0 else { return (m.tile, m.large) }
        let shrink = usable / wanted
        return (m.tile * shrink, m.large * shrink)
    }

    private func point(_ along: Double, _ cross: Double, _ m: DockMetrics) -> CGPoint {
        switch m.edge {
        case .bottom: CGPoint(x: along, y: m.panel.height - m.gap - cross)
        case .top: CGPoint(x: along, y: m.gap + cross)
        case .left: CGPoint(x: m.gap + cross, y: along)
        case .right: CGPoint(x: m.panel.width - m.gap - cross, y: along)
        }
    }

    private func origin(_ tile: Double, _ m: DockMetrics) -> (start: Double, total: Double) {
        let unit = tile * (1 + m.spacing)
        let total = slots.reduce(0) { $0 + unit * $1.weight * (bodies[$1.id]?.appear ?? 1) }
        return ((m.along - total) / 2, total)
    }

    // MARK: Time

    mutating func step(_ elapsed: Double, _ m: DockMetrics) {
        var remaining = min(elapsed, 0.05)
        let (tile, _) = fitted(m)
        while remaining > 0 {
            let dt = min(remaining, Self.substep)
            advance(dt, tile: tile, m)
            remaining -= dt
        }
        if slots.contains(where: { (bodies[$0.id]?.appearTarget ?? 1) == 0 && (bodies[$0.id]?.appear ?? 0) < 0.02 }) {
            for slot in slots where (bodies[slot.id]?.appearTarget ?? 1) == 0 && (bodies[slot.id]?.appear ?? 0) < 0.02 {
                bodies[slot.id] = nil
                slots.removeAll { $0.id == slot.id }
            }
        }
    }

    private mutating func advance(_ dt: Double, tile: Double, _ m: DockMetrics) {
        clock += dt
        let span = origin(tile, m)
        let lensOn = hovering && m.magnify

        if let raw = pointer, hovering {
            let target = min(max(raw, span.start), span.start + span.total)
            if let lastPointer { pointerSpeed += (abs(raw - lastPointer) / dt - pointerSpeed) * min(dt * 14, 1) }
            lastPointer = raw
            if ramp < 0.02 {
                // The lens opens where the pointer is. It does not slide in from where it last was.
                center = target
                centerV = 0
            } else if motion {
                Self.spring(&center, &centerV, to: target, stiffness: m.curve.stiffness, damping: 0.74, dt: dt)
            } else {
                center = target
                centerV = 0
            }
        } else {
            // Nothing is steering, so the lens coasts on what it had.
            lastPointer = nil
            pointerSpeed = 0
            centerV *= exp(-6 * dt)
            center += centerV * dt
        }
        if motion {
            Self.spring(&ramp, &rampV, to: lensOn ? 1 : 0, stiffness: 190, damping: 0.86, dt: dt)
            Self.spring(&spread, &spreadV, to: min(pointerSpeed / 2600, 1), stiffness: 70, damping: 1, dt: dt)
            if hideStiffness > 0 {
                Self.spring(&hide, &hideV, to: hideTarget, stiffness: hideStiffness, damping: 0.96, dt: dt)
            } else {
                hide = hideTarget
                hideV = 0
            }
        } else {
            Self.spring(&ramp, &rampV, to: lensOn ? 1 : 0, stiffness: 320, damping: 1, dt: dt)
            spread = 0
            hide = hideTarget
            hideV = 0
        }

        if peekTarget, let along = peekAlongTarget {
            if peekShow < 0.04 || !motion { peekAlong = along; peekAlongV = 0 }
            else { Self.spring(&peekAlong, &peekAlongV, to: along, stiffness: 420, damping: 0.86, dt: dt) }
        }
        Self.spring(&peekShow, &peekShowV, to: peekTarget ? 1 : 0, stiffness: 320, damping: motion ? 0.8 : 1, dt: dt)

        // Each tile hops on its own spring. It used to be tied to its neighbours, which sent a
        // wave along the bar: a launch or a request for attention looked like several apps
        // bouncing. Only the app that opens or asks moves now, as in the macOS Dock.
        for index in slots.indices {
            let slot = slots[index]
            guard var body = bodies[slot.id] else { continue }
            let z = 0.24, k = 120.0
            body.liftV += (-k * body.lift - 2 * z * k.squareRoot() * body.liftV) * dt
            body.lift += body.liftV * dt
            if motion, (bounce && slot.launching) || slot.attention {
                body.nextPulse -= dt
                if body.nextPulse <= 0 {
                    body.liftV += tile * (slot.attention ? 17 : 15)
                    body.nextPulse = slot.attention ? 1.0 : 1.15
                }
            }
            if motion, launchPulse, slot.launching {
                body.nextRing -= dt
                if body.nextRing <= 0, body.ring == nil {
                    body.ring = 0
                    body.burst = .launch
                    body.nextRing = 0.85
                }
            }
            let dimTarget = focusDim > 0 && slot.kind == .app && !slot.frontmost ? focusDim : 0
            let growTarget: Double = slot.id == dropID ? 1 : 0
            if motion {
                Self.spring(&body.dim, &body.dimV, to: dimTarget, stiffness: 160, damping: 1, dt: dt)
                Self.spring(&body.grow, &body.growV, to: growTarget, stiffness: 520, damping: 0.7, dt: dt)
                Self.spring(&body.appear, &body.appearV, to: body.appearTarget, stiffness: 240, damping: 0.86, dt: dt)
                Self.spring(&body.offset, &body.offsetV, to: 0, stiffness: 340, damping: 0.82, dt: dt)
                Self.spring(&body.press, &body.pressV, to: body.pressTarget, stiffness: 800, damping: 0.75, dt: dt)
            } else {
                body.appear += (body.appearTarget - body.appear) * min(dt * 16, 1)
                body.dim = dimTarget
                body.grow = growTarget
                body.offset = 0
                body.press = body.pressTarget
            }
            if let ring = body.ring { body.ring = ring + dt / 0.75 > 1 ? nil : ring + dt / 0.75 }
            bodies[slot.id] = body
        }
    }

    /// True when nothing would change on the next frame.
    func settled() -> Bool {
        guard abs(ramp - (hovering ? ramp : 0)) < 0.001, abs(rampV) < 0.01, abs(centerV) < 0.5, abs(spreadV) < 0.01,
              abs(spread) < 0.01 || hovering, abs(hide - hideTarget) < 0.001, abs(hideV) < 0.01,
              abs(peekShowV) < 0.01, abs(peekShow - (peekTarget ? 1 : 0)) < 0.001 else { return false }
        return slots.allSatisfy { slot in
            guard let body = bodies[slot.id] else { return true }
            let dimTarget = focusDim > 0 && slot.kind == .app && !slot.frontmost ? focusDim : 0
            let growTarget: Double = slot.id == dropID ? 1 : 0
            return abs(body.dim - dimTarget) < 0.002 && abs(body.dimV) < 0.01
                && abs(body.grow - growTarget) < 0.002 && abs(body.growV) < 0.01
                && !slot.launching && !(slot.attention && motion) && body.ring == nil
                && abs(body.appear - body.appearTarget) < 0.002
                && abs(body.lift) < 0.05 && abs(body.liftV) < 0.5 && abs(body.offset) < 0.05
                && abs(body.press - body.pressTarget) < 0.002
        }
    }

    // MARK: Output

    func scene(_ m: DockMetrics) -> DockScene {
        let (tile, large) = fitted(m)
        let stretch = 1 + m.spacing, unit = tile * stretch
        let pad = tile * m.padding, bar = tile + pad * 2
        let power = m.curve.power
        let radius = unit * (m.reach * m.curve.reachScale + 1.1 * spread)
        let lifting = m.magnify && m.hoverLift
        // The lens works on whole units, so the icon in the middle still lands on `large`.
        let gain = m.magnify && !lifting ? DockLens.gain(tile: unit, large: large * stretch, radius: radius, power: power) * ramp : 0
        var fitted = m
        fitted.tile = tile
        fitted.large = large
        let rise = lifting ? fitted.rise * ramp : 0
        let (start, total) = origin(tile, m)
        func warp(_ edge: Double) -> Double { edge + DockLens.shift(edge - center, gain: gain, radius: radius, power: power) }

        var result = DockScene(edge: m.edge, tile: tile, unit: unit, panel: m.panel)
        result.tiles.reserveCapacity(slots.count)
        var cursor = start
        var peekTop: Double?
        for slot in slots {
            guard let body = bodies[slot.id] else { continue }
            let width = unit * slot.weight * body.appear
            let a = warp(cursor), b = warp(cursor + width)
            cursor += width
            let size = b - a
            let along = (a + b) / 2 + body.offset
            let dragging = slot.id == dragID

            var tileOut = DockTile(slot: slot, center: .zero, size: size, icon: size / stretch * 0.96, base: tile, span: a...max(a, b))
            let lift = max(body.lift, 0)
            let hover = rise > 0 && !slot.empty ? rise * DockLens.profile((a + b) / 2 - center, radius: radius, power: power) : 0
            let cross = slot.kind == .divider || slot.kind == .section ? bar / 2 : pad + tileOut.icon / 2 + lift + hover
            tileOut.center = point(along, cross, m)
            tileOut.mirror = point(along, pad - tileOut.icon / 2 - lift - hover, m)
            if dragging {
                tileOut.center = dragPoint
                tileOut.dragging = true
            }
            if m.labelOverIcon, peekID.map({ $0 == slot.id }) ?? (peekAlong >= a && peekAlong < b), !slot.empty {
                peekTop = pad + tileOut.icon + lift + hover
            }
            // Below the rest line the icon has landed on the glass and squashes against it.
            let squash = min(max(-body.lift / max(tile, 1), 0), 0.34)
            let stretch = min(abs(body.liftV) / 2600, 0.1) * (body.lift > 0 ? 1 : 0)
            let press: Double = (1 - 0.09 * body.press) * (dragging ? 1.1 : 1) * (1 + 0.16 * body.grow)
            let cross2: Double = 1 - squash * 0.9 + stretch
            let along2: Double = 1 + squash * 0.6 - stretch * 0.6
            tileOut.scaleCross = cross2 * press
            tileOut.scaleAlong = along2 * press
            let fade: Double = slot.hidden ? 0.55 : 1
            let pulledOut: Double = dragging && dragOut ? 0.45 : 1
            let filtered: Double = matches.map { $0.contains(slot.id) || slot.kind == .divider ? 1 : 0.24 } ?? 1
            tileOut.alpha = min(body.appear * 1.4, 1) * fade * pulledOut * filtered * (1 - body.dim)
            tileOut.ring = body.ring
            tileOut.indicator = point(along, pad * 0.5, m)
            tileOut.glow = slot.launching || slot.attention ? 0.5 + 0.5 * sin(clock * 5) : 0
            tileOut.focused = slot.id == focusID
            tileOut.armed = slot.id == armedID
            tileOut.burst = body.burst
            tileOut.appear = body.appear
            if ramp > 0.001, radius > 0 {
                let distance = (a + b) / 2 - center
                tileOut.near = DockLens.profile(distance, radius: radius, power: power) * ramp
                tileOut.lean = min(max(distance / radius, -1), 1) * ramp
            }
            result.tiles.append(tileOut)
        }
        let low = warp(start) - pad, high = warp(start + total) + pad
        let corners = [point(low, 0, m), point(high, bar, m)]
        result.bar = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                            width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
        result.radius = bar * (0.08 + 0.42 * min(max(m.roundness, 0), 1))
        result.hide = hide
        let away = (bar + m.gap + 18) * hide
        switch m.edge {
        case .bottom: result.hideOffset = CGSize(width: 0, height: away)
        case .top: result.hideOffset = CGSize(width: 0, height: -away)
        case .left: result.hideOffset = CGSize(width: -away, height: 0)
        case .right: result.hideOffset = CGSize(width: away, height: 0)
        }
        result.ramp = ramp
        result.lens = center
        result.pad = pad
        result.peekAlong = peekAlong
        // Anchored to the live tile: the spring only carries the slide from one tile to the next.
        if let peekID, let anchor = result.tiles.first(where: { $0.id == peekID }) {
            let live = (anchor.span.lowerBound + anchor.span.upperBound) / 2
            result.peekAlong = live + (peekAlong - (peekAlongTarget ?? peekAlong))
        }
        if let peekTop {
            result.peekCross = m.gap + peekTop + 10
        } else {
            let grown = lifting ? rise : max(large - tile, 0) * ramp
            result.peekCross = m.gap + bar + grown + 12
        }
        result.peekShow = peekShow
        return result
    }
}
