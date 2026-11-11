import Foundation

// Everything the owner can choose about Orbit, as plain values. Foundation only, so the
// layout and frame code can be measured outside the app.

struct OrbitRGB: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Hue in 0..<1, for sorting by colour.
    var hue: Double {
        let high = max(r, g, b), low = min(r, g, b), span = high - low
        guard span > 0.0001 else { return 0 }
        var h: Double
        if high == r { h = (g - b) / span }
        else if high == g { h = 2 + (b - r) / span }
        else { h = 4 + (r - g) / span }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    var saturation: Double {
        let high = max(r, g, b), low = min(r, g, b)
        return high <= 0 ? 0 : (high - low) / high
    }

    /// The colour wells in settings offer these.
    static let palette: [OrbitRGB] = [
        OrbitRGB(0.36, 0.58, 1), OrbitRGB(0.98, 0.42, 0.62), OrbitRGB(0.42, 0.86, 0.74), OrbitRGB(0.72, 0.46, 1),
        OrbitRGB(0.32, 0.80, 0.98), OrbitRGB(1, 0.58, 0.28), OrbitRGB(0.52, 0.86, 0.42), OrbitRGB(0.66, 0.72, 0.86),
        OrbitRGB(0.86, 0.76, 0.56), OrbitRGB(1, 0.36, 0.36), OrbitRGB(1, 0.84, 0.3), OrbitRGB(0.96, 0.93, 0.86),
        OrbitRGB(0.05, 0.06, 0.1), OrbitRGB(0.2, 0.9, 0.6),
    ]
}

// MARK: - Categories

/// Apps sorted into constellations from their LSApplicationCategoryType.
enum OrbitCategory: String, CaseIterable, Identifiable, Sendable {
    case work, create, develop, media, social, play, life, utilities, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: "Work"
        case .create: "Create"
        case .develop: "Develop"
        case .media: "Media"
        case .social: "Social"
        case .play: "Play"
        case .life: "Life"
        case .utilities: "Utilities"
        case .other: "Everything Else"
        }
    }

    var symbol: String {
        switch self {
        case .work: "briefcase.fill"
        case .create: "paintpalette.fill"
        case .develop: "hammer.fill"
        case .media: "play.circle.fill"
        case .social: "bubble.left.and.bubble.right.fill"
        case .play: "gamecontroller.fill"
        case .life: "leaf.fill"
        case .utilities: "wrench.and.screwdriver.fill"
        case .other: "sparkles"
        }
    }

    var rgb: OrbitRGB {
        switch self {
        case .work: OrbitRGB(0.36, 0.58, 1)
        case .create: OrbitRGB(0.98, 0.42, 0.62)
        case .develop: OrbitRGB(0.42, 0.86, 0.74)
        case .media: OrbitRGB(0.72, 0.46, 1)
        case .social: OrbitRGB(0.32, 0.80, 0.98)
        case .play: OrbitRGB(1, 0.58, 0.28)
        case .life: OrbitRGB(0.52, 0.86, 0.42)
        case .utilities: OrbitRGB(0.66, 0.72, 0.86)
        case .other: OrbitRGB(0.86, 0.76, 0.56)
        }
    }

    /// Many apps, Apple's own included, declare no category. A few names fill that gap.
    nonisolated static func of(path: String) -> OrbitCategory {
        let root = URL(fileURLWithPath: path)
        let plists = ["Contents/Info.plist", "WrappedBundle/Info.plist"].map(root.appendingPathComponent)
        for plist in plists {
            guard let data = try? Data(contentsOf: plist),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            if let value = info["LSApplicationCategoryType"] as? String, let found = mapped(value) { return found }
            break
        }
        let name = root.deletingPathExtension().lastPathComponent
        if let known = named[name] { return known }
        return path.hasPrefix("/System/") ? .utilities : .other
    }

    private nonisolated static func mapped(_ value: String) -> OrbitCategory? {
        let kind = value.replacingOccurrences(of: "public.app-category.", with: "")
        if kind.hasSuffix("games") { return .play }
        switch kind {
        case "developer-tools": return .develop
        case "productivity", "business", "finance", "reference", "education": return .work
        case "graphics-design", "photography", "video": return .create
        case "music", "entertainment", "news", "books": return .media
        case "social-networking": return .social
        case "utilities": return .utilities
        case "lifestyle", "healthcare-fitness", "medical", "sports", "travel", "weather", "food-and-drink", "shopping":
            return .life
        default: return nil
        }
    }

    private nonisolated static let named: [String: OrbitCategory] = [
        "Weather": .life, "Stocks": .life, "Home": .life, "Clock": .life, "FindMy": .life, "Find My": .life,
        "Podcasts": .media, "Phone": .social, "Blender": .create, "BambuStudio": .create,
    ]
}

/// A constellation of the owner's own making.
struct OrbitCustomCategory: Codable, Hashable, Identifiable, Sendable {
    var id = "custom:" + UUID().uuidString
    var name: String
    var symbol = "star.fill"
    var colour = OrbitRGB(0.86, 0.76, 0.56)

    static let symbols = ["star.fill", "heart.fill", "bolt.fill", "flame.fill", "moon.fill", "globe", "book.fill",
                          "music.note", "camera.fill", "cart.fill", "graduationcap.fill", "terminal.fill"]
}

/// One constellation as drawn: built in or custom, after renames and recolours.
struct OrbitGroup: Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    var rgb: OrbitRGB
}

// MARK: - Choices

enum OrbitLayoutStyle: String, Codable, CaseIterable, Sendable {
    case orbits, galaxy, grid, honeycomb, arc, pages
    var title: String {
        switch self {
        case .orbits: "Orbits"
        case .galaxy: "Galaxy"
        case .grid: "Grid"
        case .honeycomb: "Honeycomb"
        case .arc: "Arc"
        case .pages: "Pages"
        }
    }
    /// Layouts that turn. The rest hold still.
    var drifts: Bool { self == .orbits || self == .galaxy }
    /// Layouts whose title sits in the middle of the sky.
    var centredTitle: Bool { self == .orbits || self == .galaxy }
}

enum OrbitLabelMode: String, Codable, CaseIterable, Sendable {
    case always, hover, never
    var title: String { rawValue.capitalized }
}

enum OrbitLabelFont: String, Codable, CaseIterable, Sendable {
    case system, rounded, serif, mono
    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
}

enum OrbitInk: String, Codable, CaseIterable, Sendable {
    case light, dark
}

enum OrbitOpenStyle: String, Codable, CaseIterable, Sendable {
    case spiral, bloom, fade, zoom
    var title: String {
        switch self {
        case .spiral: "Spiral In"
        case .bloom: "Bloom"
        case .fade: "Fade"
        case .zoom: "Zoom"
        }
    }
}

enum OrbitSort: String, Codable, CaseIterable, Sendable {
    case category, name, mostUsed, recent, colour
    var title: String {
        switch self {
        case .category: "Category"
        case .name: "Name"
        case .mostUsed: "Most Used"
        case .recent: "Recent"
        case .colour: "Colour"
        }
    }
}

enum OrbitDriftDirection: String, Codable, CaseIterable, Sendable {
    case alternate, clockwise, counter
    var title: String {
        switch self {
        case .alternate: "Alternate"
        case .clockwise: "Clockwise"
        case .counter: "Counter"
        }
    }
}

enum OrbitNebula: String, Codable, CaseIterable, Sendable {
    case constellation, custom, wallpaper
    var title: String {
        switch self {
        case .constellation: "Constellation"
        case .custom: "Custom"
        case .wallpaper: "Wallpaper"
        }
    }
}

enum OrbitDisplay: String, Codable, CaseIterable, Sendable {
    case pointer, main
    var title: String { self == .pointer ? "With Pointer" : "Main Display" }
}

enum OrbitOpenButton: String, Codable, CaseIterable, Sendable {
    case none, middle, back, forward
    var title: String {
        switch self {
        case .none: "Off"
        case .middle: "Middle"
        case .back: "Button 4"
        case .forward: "Button 5"
        }
    }
    /// NSEvent.buttonNumber for the button.
    var number: Int? {
        switch self {
        case .none: nil
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }
}

// MARK: - Options

struct OrbitOptions: Codable, Equatable, Sendable {
    // Layout
    var layout = OrbitLayoutStyle.orbits
    /// 0 lets the screen decide.
    var rings = 0
    var ringSpacing = 92.0
    var iconSize = 62.0
    var showRings = true

    // Look
    var labels = OrbitLabelMode.always
    var labelFont = OrbitLabelFont.system
    var ink = OrbitInk.light
    var showRunning = true
    var showRecents = true
    var hoverScale = 1.09

    // Background
    var blur = 1.0
    var dim = 0.5
    var tint = OrbitRGB(0.36, 0.58, 1)
    var tintAmount = 0.0
    var stars = true
    var nebula = OrbitNebula.constellation
    var nebulaColour = OrbitRGB(0.72, 0.46, 1)
    var nebulaStrength = 0.26
    var liveWallpaper = false

    // Motion
    var drift = true
    var driftSpeed = 1.0
    var driftDirection = OrbitDriftDirection.alternate
    var openStyle = OrbitOpenStyle.spiral

    // Apps and categories
    var sort = OrbitSort.category
    var hidden: [String] = []
    var favourites: [String] = []
    var customCategories: [OrbitCustomCategory] = []
    var renamed: [String: String] = [:]
    var recoloured: [String: OrbitRGB] = [:]
    /// App path to category id, built in or custom.
    var assigned: [String: String] = [:]

    // Search
    var fuzzy = true
    var searchSettings = false
    var searchFiles = false

    // Keys and opening
    var typeToSearch = true
    var wrapNavigation = true
    var numberKeys = true
    var display = OrbitDisplay.pointer
    var openButton = OrbitOpenButton.none

    static let standard = OrbitOptions()

    /// Missing or unreadable keys fall back to the defaults one by one, so a setting added
    /// later never resets the others.
    static func decode(_ data: Data) -> OrbitOptions {
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = try? JSONEncoder().encode(OrbitOptions()),
              var merged = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return OrbitOptions() }
        for (key, value) in stored where merged[key] != nil {
            var trial = merged
            trial[key] = value
            if let data = try? JSONSerialization.data(withJSONObject: trial),
               (try? JSONDecoder().decode(OrbitOptions.self, from: data)) != nil { merged = trial }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return OrbitOptions() }
        return (try? JSONDecoder().decode(OrbitOptions.self, from: data)) ?? OrbitOptions()
    }

    /// Fields whose change moves apps to new places, as opposed to only restyling them.
    func needsReplan(from old: OrbitOptions) -> Bool {
        layout != old.layout || rings != old.rings || ringSpacing != old.ringSpacing || iconSize != old.iconSize
            || sort != old.sort || hidden != old.hidden || favourites != old.favourites
            || customCategories != old.customCategories || renamed != old.renamed || recoloured != old.recoloured
            || assigned != old.assigned || showRecents != old.showRecents || driftSpeed != old.driftSpeed
            || driftDirection != old.driftDirection
    }

    /// Fields that change how labels are drawn.
    func needsRestyle(from old: OrbitOptions) -> Bool {
        labelFont != old.labelFont || ink != old.ink || labels != old.labels || iconSize != old.iconSize
    }

    func group(for id: String) -> OrbitGroup {
        if let custom = customCategories.first(where: { $0.id == id }) {
            return OrbitGroup(id: id, title: custom.name, symbol: custom.symbol, rgb: custom.colour)
        }
        let builtIn = OrbitCategory(rawValue: id) ?? .other
        return OrbitGroup(id: builtIn.rawValue, title: renamed[builtIn.rawValue] ?? builtIn.title,
                          symbol: builtIn.symbol, rgb: recoloured[builtIn.rawValue] ?? builtIn.rgb)
    }

    /// Built in first, then the owner's, in the order pages appear.
    var groups: [OrbitGroup] {
        OrbitCategory.allCases.map { group(for: $0.rawValue) } + customCategories.map { group(for: $0.id) }
    }
}

// MARK: - Themes

/// Presets that set the look, the sky and the motion together. Apps, search and keys stay yours.
enum OrbitTheme: String, CaseIterable, Identifiable, Sendable {
    case cosmos, minimal, neon, paper, aurora
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Two colours for the swatch in settings.
    var swatch: (OrbitRGB, OrbitRGB) {
        switch self {
        case .cosmos: (OrbitRGB(0.05, 0.06, 0.14), OrbitRGB(0.72, 0.46, 1))
        case .minimal: (OrbitRGB(0.12, 0.12, 0.13), OrbitRGB(0.66, 0.72, 0.86))
        case .neon: (OrbitRGB(0.06, 0.02, 0.1), OrbitRGB(1, 0.2, 0.75))
        case .paper: (OrbitRGB(0.96, 0.93, 0.86), OrbitRGB(0.55, 0.42, 0.3))
        case .aurora: (OrbitRGB(0.02, 0.1, 0.12), OrbitRGB(0.2, 0.9, 0.6))
        }
    }

    func apply(to base: OrbitOptions) -> OrbitOptions {
        var o = base
        let standard = OrbitOptions.standard
        o.rings = standard.rings
        o.ringSpacing = standard.ringSpacing
        o.iconSize = standard.iconSize
        o.showRings = true
        o.labels = .always
        o.labelFont = .system
        o.ink = .light
        o.hoverScale = standard.hoverScale
        o.blur = 1
        o.dim = 0.5
        o.tintAmount = 0
        o.stars = true
        o.nebula = .constellation
        o.nebulaStrength = 0.26
        o.drift = true
        o.driftSpeed = 1
        o.driftDirection = .alternate
        o.openStyle = .spiral
        switch self {
        case .cosmos:
            o.layout = .orbits
        case .minimal:
            o.layout = .grid
            o.showRings = false
            o.labels = .hover
            o.stars = false
            o.dim = 0.35
            o.nebulaStrength = 0.08
            o.openStyle = .fade
            o.hoverScale = 1.05
        case .neon:
            o.layout = .galaxy
            o.labelFont = .mono
            o.dim = 0.72
            o.tint = OrbitRGB(0.5, 0.05, 0.6)
            o.tintAmount = 0.18
            o.nebula = .custom
            o.nebulaColour = OrbitRGB(0.1, 0.9, 1)
            o.nebulaStrength = 0.42
            o.openStyle = .bloom
            o.driftSpeed = 1.6
            o.hoverScale = 1.18
        case .paper:
            o.layout = .honeycomb
            o.labelFont = .serif
            o.ink = .dark
            o.dim = 0
            o.tint = OrbitRGB(0.96, 0.93, 0.86)
            o.tintAmount = 0.86
            o.stars = false
            o.nebula = .custom
            o.nebulaColour = OrbitRGB(0.85, 0.7, 0.5)
            o.nebulaStrength = 0.16
            o.showRings = false
            o.openStyle = .zoom
        case .aurora:
            o.layout = .orbits
            o.labelFont = .rounded
            o.dim = 0.55
            o.tint = OrbitRGB(0.0, 0.25, 0.3)
            o.tintAmount = 0.2
            o.nebula = .custom
            o.nebulaColour = OrbitRGB(0.2, 0.9, 0.6)
            o.nebulaStrength = 0.36
            o.openStyle = .bloom
            o.driftSpeed = 0.7
            o.driftDirection = .counter
        }
        return o
    }

    /// The theme the options currently match, if any.
    static func matching(_ options: OrbitOptions) -> OrbitTheme? {
        allCases.first { $0.apply(to: options) == options }
    }
}
