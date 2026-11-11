import Foundation

// The dock's design system as plain values: which design the bar wears, how its icons are
// treated and which effects play. Nothing here draws; DockDesignViews.swift does. Saved as
// one value, so a profile can carry it and the scene can copy it cheaply.

// MARK: - Designs

/// The shape and material of the whole bar, beyond its colour.
enum DockDesign: String, Codable, CaseIterable, Identifiable, Sendable {
    case liquidGlass, islands, neonRim, ceramic, aurora, minimalLine, holographic, retro, paper, darkMetal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .islands: "Floating Islands"
        case .neonRim: "Neon Rim"
        case .ceramic: "Frosted Ceramic"
        case .aurora: "Aurora"
        case .minimalLine: "Minimal Line"
        case .holographic: "Holographic"
        case .retro: "Retro CRT"
        case .paper: "Paper"
        case .darkMetal: "Dark Metal"
        }
    }

    var blurb: String {
        switch self {
        case .liquidGlass: "The system's own glass, tinted by Glass Finish."
        case .islands: "Each section floats as its own glass pill."
        case .neonRim: "Dark glass with light running around the edge."
        case .ceramic: "Matte, milky and solid, with a soft glaze."
        case .aurora: "A slow living gradient behind the icons."
        case .minimalLine: "No bar. Icons stand on a hairline and reflect."
        case .holographic: "An iridescent rim that turns with the pointer."
        case .retro: "Phosphor green, scanlines and square pixels."
        case .paper: "A warm sheet of paper with ink marks."
        case .darkMetal: "Brushed dark aluminium with a bevelled edge."
        }
    }

    /// Something on the bar moves by itself. It runs in Core Animation, in the render
    /// server, and stops whenever the bar is hidden or Reduce Motion is on.
    var animated: Bool { self == .neonRim || self == .aurora }

    /// The glass finishes (Glass, Tinted, Midnight…) apply to the glass designs only.
    var usesGlassFinish: Bool { self == .liquidGlass || self == .islands || self == .holographic }

    /// A light surface: marks and plates are drawn in ink, not light.
    var light: Bool { self == .ceramic || self == .paper }

    /// What picking the design sets, so it arrives looking its best. Everything stays
    /// adjustable afterwards.
    var recommended: DockDesignLook {
        switch self {
        case .liquidGlass: DockDesignLook(mark: nil, indicator: .bar, curve: .classic, shadow: true, reflection: false,
                                          backplate: false, hover: .none)
        case .islands: DockDesignLook(mark: nil, indicator: .dot, curve: .gentle, shadow: true, reflection: false,
                                      backplate: false, hover: .none)
        case .neonRim: DockDesignLook(mark: .beam, indicator: .glow, curve: .classic, shadow: false, reflection: true,
                                      backplate: false, hover: .glow)
        case .ceramic: DockDesignLook(mark: .ink, indicator: .dot, curve: .gentle, shadow: true, reflection: false,
                                      backplate: true, hover: .none)
        case .aurora: DockDesignLook(mark: nil, indicator: .glow, curve: .wave, shadow: true, reflection: false,
                                     backplate: false, hover: .glow)
        case .minimalLine: DockDesignLook(mark: .led, indicator: .dot, curve: .fisheye, shadow: false, reflection: true,
                                          backplate: false, hover: .none)
        case .holographic: DockDesignLook(mark: nil, indicator: .bar, curve: .classic, shadow: true, reflection: true,
                                          backplate: false, hover: .tilt)
        case .retro: DockDesignLook(mark: .pixel, indicator: .dot, curve: .classic, shadow: false, reflection: false,
                                    backplate: true, hover: .wave)
        case .paper: DockDesignLook(mark: .ink, indicator: .dot, curve: .gentle, shadow: true, reflection: false,
                                    backplate: true, hover: .none)
        case .darkMetal: DockDesignLook(mark: .led, indicator: .dot, curve: .classic, shadow: true, reflection: true,
                                        backplate: false, hover: .none)
        }
    }
}

/// The marks a design brings, beside the classic Dot, Bar and Glow.
enum DockDesignMark: String, Codable, CaseIterable, Identifiable, Sendable {
    case led, pixel, ink, beam
    var id: String { rawValue }
    var title: String {
        switch self {
        case .led: "LED"
        case .pixel: "Pixel"
        case .ink: "Ink"
        case .beam: "Beam"
        }
    }
}

/// One choice of Open App Mark: a classic indicator or a design's own mark.
enum DockMarkChoice: Hashable, Sendable {
    case classic(DockIndicator)
    case design(DockDesignMark)

    static let all: [DockMarkChoice] = [.classic(.dot), .classic(.bar), .classic(.glow)]
        + DockDesignMark.allCases.map { .design($0) } + [.classic(.none)]

    var title: String {
        switch self {
        case .classic(let indicator): indicator.title
        case .design(let mark): mark.title
        }
    }
}

/// What a design sets when it is picked.
struct DockDesignLook: Sendable {
    var mark: DockDesignMark?
    var indicator: DockIndicator
    var curve: DockCurve
    var shadow: Bool
    var reflection: Bool
    var backplate: Bool
    var hover: DockHoverEffect
}

// MARK: - Effects

/// The burst that leaves an icon as its app finishes opening.
enum DockLaunchEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case ring, ripple, sparkle, bloom, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// How icons answer the pointer, apart from magnification.
enum DockHoverEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, glow, lift, tilt, wave
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.capitalized }
    var note: String {
        switch self {
        case .none: "Icons only magnify."
        case .glow: "A soft light gathers behind the icons near the pointer."
        case .lift: "Icons rise toward the pointer instead of growing. The bar keeps its length."
        case .tilt: "Icons lean toward the pointer in perspective."
        case .wave: "Icons near the pointer ride a gentle wave."
        }
    }
}

/// What a tile does when it takes a dropped file.
enum DockDropEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case pulse, ripple, swallow, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the Trash does when it takes something.
enum DockTrashEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case crumple, shake, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// How a minimised window arrives in the dock.
enum DockMinimizeEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case scale, genie, fade
    var id: String { rawValue }
    var title: String { self == .genie ? "Drop In" : rawValue.capitalized }
}

/// The burst a tile is playing, kept with its ring timer.
enum DockBurst: UInt8, Sendable {
    case launch, drop, trash
}

// MARK: - Prefs

/// The design and the effects, saved as one value.
struct DockDesignPrefs: Codable, Equatable, Sendable {
    var design = DockDesign.liquidGlass
    /// A design's own mark in place of the classic indicator. Nil uses the classic one.
    var mark: DockDesignMark?
    /// A plate behind each icon, in the design's material.
    var backplate = false
    /// Never `.lift`: that one is saved as the appearance's Hover Lift.
    var hover = DockHoverEffect.none
    var launch = DockLaunchEffect.ring
    var drop = DockDropEffect.pulse
    var trash = DockTrashEffect.crumple
    var minimize = DockMinimizeEffect.scale
    /// The rim breathes slowly while nothing else moves.
    var breathing = false
    /// Quiet system sounds for launches, drops, the Trash and minimising. Off by default.
    var sounds = false
    var volume = 0.35

    init() {}

    private enum CodingKeys: String, CodingKey {
        case design, mark, backplate, hover, launch, drop, trash, minimize, breathing, sounds, volume
    }

    // Every field optional, so later builds can add more.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockDesignPrefs()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        design = read(.design, d.design)
        mark = read(.mark, nil as DockDesignMark?)
        backplate = read(.backplate, d.backplate)
        hover = read(.hover, d.hover)
        if hover == .lift { hover = .none }
        launch = read(.launch, d.launch)
        drop = read(.drop, d.drop)
        trash = read(.trash, d.trash)
        minimize = read(.minimize, d.minimize)
        breathing = read(.breathing, d.breathing)
        sounds = read(.sounds, d.sounds)
        volume = min(max(read(.volume, d.volume), 0.05), 1)
    }
}

/// What the drawing side needs from the prefs, copied into the theme.
struct DockFX: Equatable, Sendable {
    var design = DockDesign.liquidGlass
    var mark: DockDesignMark?
    var backplate = false
    var hover = DockHoverEffect.none
    var launch = DockLaunchEffect.ring
    var drop = DockDropEffect.pulse
    var trash = DockTrashEffect.crumple
    var minimize = DockMinimizeEffect.scale
    var breathing = false

    init() {}

    init(_ prefs: DockDesignPrefs, lift: Bool) {
        design = prefs.design
        mark = prefs.mark
        backplate = prefs.backplate
        hover = lift ? .lift : prefs.hover
        launch = prefs.launch
        drop = prefs.drop
        trash = prefs.trash
        minimize = prefs.minimize
        breathing = prefs.breathing
    }
}

// MARK: - Islands

/// Floating Islands: where each glass pill goes along the bar. Pure, so it can be tested.
enum DockIslands {
    /// The along-axis spans of each island, split at dividers and section starts.
    /// `pieces` is (kind is a separator, span) per tile in bar order.
    static func spans(_ pieces: [(separator: Bool, span: ClosedRange<Double>)], start: Double, end: Double,
                      inset: Double) -> [ClosedRange<Double>] {
        var groups: [(low: Double, high: Double)] = []
        var open = false
        for piece in pieces {
            if piece.separator { open = false; continue }
            if open, let last = groups.last {
                groups[groups.count - 1] = (last.low, piece.span.upperBound + inset)
            } else {
                groups.append((piece.span.lowerBound - inset, piece.span.upperBound + inset))
                open = true
            }
        }
        guard !groups.isEmpty else { return [start...max(start, end)] }
        // The first starts with the bar, the last ends with it.
        groups[0].low = start
        groups[groups.count - 1].high = end
        return groups.map { $0.low...max($0.low, $0.high) }
    }
}
