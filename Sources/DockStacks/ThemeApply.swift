import AppKit
import DockCore
import SwiftUI

/// Turns a theme into settings, through each module's own public properties, and reads the
/// current settings back into a theme. Nothing here writes a preference directly: the modules
/// keep their own storage, so a theme behaves exactly like the owner changing each control.
@MainActor
enum ThemeApplier {
    // MARK: Swatches, for snapping a free colour to a module's named choices

    static let dockAccents: [(String, ThemeColor)] = [
        ("blue", .init(red: 0.2, green: 0.5, blue: 1)), ("purple", .init(red: 0.62, green: 0.35, blue: 0.95)),
        ("pink", .init(red: 1, green: 0.35, blue: 0.62)), ("orange", .init(red: 1, green: 0.58, blue: 0.2)),
        ("green", .init(red: 0.3, green: 0.82, blue: 0.4)), ("graphite", .init(red: 0.55, green: 0.55, blue: 0.58)),
    ]
    static let widgetTints: [(String, ThemeColor)] = [
        ("blue", .init(red: 0.55, green: 0.72, blue: 1)), ("indigo", .init(red: 0.6, green: 0.6, blue: 1)),
        ("purple", .init(red: 0.76, green: 0.56, blue: 1)), ("pink", .init(red: 1, green: 0.55, blue: 0.75)),
        ("red", .init(red: 1, green: 0.48, blue: 0.45)), ("orange", .init(red: 1, green: 0.64, blue: 0.36)),
        ("amber", .init(red: 1, green: 0.8, blue: 0.34)), ("green", .init(red: 0.5, green: 0.88, blue: 0.5)),
        ("mint", .init(red: 0.4, green: 0.92, blue: 0.78)), ("teal", .init(red: 0.36, green: 0.82, blue: 0.92)),
        ("graphite", .init(red: 0.78, green: 0.78, blue: 0.78)),
    ]
    static let studioAccents: [(String, ThemeColor)] = [
        ("sky", .init(red: 0.55, green: 0.72, blue: 1)), ("violet", .init(red: 0.72, green: 0.6, blue: 1)),
        ("mint", .init(red: 0.45, green: 0.9, blue: 0.75)), ("rose", .init(red: 1, green: 0.55, blue: 0.68)),
        ("amber", .init(red: 1, green: 0.76, blue: 0.4)), ("silver", .init(red: 0.86, green: 0.86, blue: 0.86)),
    ]
    static let iconTints: [(String, ThemeColor)] = [
        ("Blue", .init(red: 0, green: 0.48, blue: 1)), ("Purple", .init(red: 0.69, green: 0.32, blue: 0.87)),
        ("Pink", .init(red: 1, green: 0.18, blue: 0.33)), ("Orange", .init(red: 1, green: 0.58, blue: 0)),
        ("Yellow", .init(red: 1, green: 0.8, blue: 0)), ("Green", .init(red: 0.2, green: 0.78, blue: 0.35)),
        ("Graphite", .init(red: 0.56, green: 0.56, blue: 0.58)),
    ]

    /// A named value, or the nearest named value to a colour.
    static func pick(_ text: String?, names: [(String, ThemeColor)]) -> String? {
        guard let text else { return nil }
        if names.contains(where: { $0.0 == text }) { return text }
        return ThemeColor(hex: text)?.nearest(names)
    }

    // MARK: Apply

    /// Applies every section the theme names and leaves the rest alone.
    /// `bundle` is the theme's folder, for pictures and sounds; nil for built-in Looks.
    static func apply(_ theme: ThemeDocument, bundle: URL?) {
        let accentHex = theme.string("colors.accent")
        applyDock(theme, accentHex: accentHex)
        applyWidgets(theme, accentHex: accentHex)
        applyWallpaper(theme, bundle: bundle)
        applyStudio(theme, accentHex: accentHex)
        applyIcons(theme)
        applyClock(theme)

        let effects = Effects.shared
        if let skin = theme.string("menuBar.skin").flatMap(SkinPreset.init(rawValue:)) { effects.skin = skin }
        if let glow = theme.bool("effects.dockGlow") { effects.dockGlow = glow }
        if let line = theme.bool("effects.dayLine") { effects.dayLine = line }
        effects.look = theme.root["x-look"]?.string ?? theme.name

        ThemeSounds.configure(theme, bundle: bundle)
        ThemeSounds.play(.apply)
    }

    private static func applyDock(_ theme: ThemeDocument, accentHex: String?) {
        let dock = OwnDock.shared
        var look = dock.appearance
        if let value = theme.string("dock.style").flatMap(DockStyle.init(rawValue:)) { look.style = value }
        if let value = pick(theme.string("dock.accent") ?? accentHex, names: dockAccents).flatMap(DockAccent.init(rawValue:)) { look.accent = value }
        if let value = theme.string("dock.indicator").flatMap(DockIndicator.init(rawValue:)) { look.indicator = value }
        if let value = theme.string("dock.hover").flatMap(DockHover.init(rawValue:)) { look.hover = value }
        if let value = theme.number("dock.roundness") { look.roundness = value }
        if let value = theme.number("dock.padding") { look.padding = value }
        if let value = theme.number("dock.spacing") { look.spacing = value }
        if let value = theme.number("dock.gap") { look.gap = value }
        if let value = theme.string("dock.curve").flatMap(DockCurve.init(rawValue:)) { look.curve = value }
        if let value = theme.string("dock.launch").flatMap(DockLaunchStyle.init(rawValue:)) { look.launch = value }
        if let value = theme.string("dock.labelPosition").flatMap(DockLabelPosition.init(rawValue:)) { look.labelPosition = value }
        if let value = theme.bool("dock.hoverLift") { look.hoverLift = value }
        if let value = theme.bool("dock.iconShadow") { look.iconShadow = value }
        if let value = theme.bool("dock.reflection") { look.reflection = value }
        if let value = theme.bool("dock.divider") { look.divider = value }
        if look != dock.appearance { dock.appearance = look }
        // A theme that names a Dock accent means that accent, unless it asks to follow.
        let follow = theme.bool("dock.followTheme") ?? (theme.value("dock.accent") != nil ? false : nil)
        if let follow, follow != dock.followLook { dock.followLook = follow }
    }

    private static func applyWidgets(_ theme: ThemeDocument, accentHex: String?) {
        let board = WidgetBoard.shared
        var style = board.style
        func tint(_ path: String, fallback: String? = nil) -> WidgetTint? {
            pick(theme.string(path) ?? fallback, names: widgetTints).flatMap(WidgetTint.init(rawValue:))
        }
        if let value = theme.string("widgets.material").flatMap(WidgetMaterial.init(rawValue:)) { style.material = value }
        if let value = tint("widgets.tint", fallback: theme.string("colors.glassTint")) { style.tint = value }
        if let value = tint("widgets.accent", fallback: accentHex) { style.accent = value }
        if let value = theme.number("widgets.radius") { style.radius = value }
        if let value = theme.number("widgets.opacity") { style.opacity = value }
        if let value = theme.string("widgets.font").flatMap(WidgetFont.init(rawValue:)) { style.font = value }
        if let value = theme.number("widgets.shadow") { style.shadow = value }
        if let value = theme.number("widgets.border") { style.border = value }
        if let value = theme.number("widgets.padding") { style.padding = value }
        if let value = theme.number("widgets.scale") { style.scale = value }
        if let value = theme.number("widgets.blur") { style.blur = value }
        if theme.value("widgets.gradient") != nil {
            var gradient = style.gradient ?? WidgetGradient()
            if let value = tint("widgets.gradient.from") { gradient.from = value }
            if let value = tint("widgets.gradient.to") { gradient.to = value }
            if let value = theme.number("widgets.gradient.angle") { gradient.angle = value }
            style.gradient = gradient
        } else if theme.value("widgets.material") != nil {
            // A theme that sets the material but not a gradient means a plain surface.
            style.gradient = nil
        }
        if style != board.style { board.style = style }
        if let value = theme.string("widgets.iconHarmony").flatMap(IconHarmony.init(rawValue:)), value != board.harmony { board.harmony = value }
    }

    private static func applyWallpaper(_ theme: ThemeDocument, bundle: URL?) {
        let live = LiveWallpaper.shared, effects = Effects.shared
        let mode = theme.string("wallpaper.mode") ?? (theme.value("wallpaper.shader") != nil ? "live" : "keep")
        // Tuning applies to the named shader, or the current one, whatever the mode.
        let shader = theme.string("wallpaper.shader").flatMap(LivingShader.init(rawValue:)) ?? live.shader
        var tuning = live.tuning(for: shader)
        if let palette = theme.value("wallpaper.palette") {
            if let name = palette.string { tuning.palette = name }
            else if let colors = theme.colors("wallpaper.palette"), colors.count == 4 {
                tuning.palette = ThemePalettes.register(colors, for: theme.id)
            }
        }
        if let value = theme.number("wallpaper.speed") { tuning.speed = value }
        if let value = theme.number("wallpaper.intensity") { tuning.intensity = value }
        if let value = theme.number("wallpaper.grain") { tuning.grain = value }
        if let value = theme.number("wallpaper.scale") { tuning.scale = value }
        if let value = theme.number("wallpaper.dim") { tuning.dim = value }
        if let value = theme.string("wallpaper.cycle").flatMap(DayCycle.init(rawValue:)) { tuning.cycle = value }
        live.setTuning(tuning, for: shader)

        switch mode {
        case "live":
            if effects.living != nil { effects.living = nil }
            if theme.value("wallpaper.shader") != nil, live.scheduled { live.scheduled = false }
            if live.shader != shader { live.shader = shader }
            if !live.enabled { live.enabled = true }
        case "mesh":
            if live.enabled { live.enabled = false }
            effects.living = theme.string("wallpaper.mesh").flatMap(Hue.init(rawValue:)) ?? .aurora
        case "image":
            if live.enabled { live.enabled = false }
            if effects.living != nil { effects.living = nil }
            if let bundle, let path = theme.string("wallpaper.image") {
                let url = bundle.appendingPathComponent(path)
                ThemeWallpaper.set(url)
            } else if let original = theme.root["x-originalImage"]?.string.flatMap(URL.init(string:)) {
                ThemeWallpaper.set(original)
            }
        case "off":
            if live.enabled { live.enabled = false }
            if effects.living != nil { effects.living = nil }
            if let original = theme.root["x-originalImage"]?.string.flatMap(URL.init(string:)) { ThemeWallpaper.set(original) }
        default:
            break
        }
    }

    private static func applyStudio(_ theme: ThemeDocument, accentHex: String?) {
        let studio = StudioTheme.shared
        if let value = theme.string("studio.backdrop").flatMap(StudioBackdrop.init(rawValue:)), value != studio.backdrop { studio.backdrop = value }
        let accent = theme.string("studio.accent") ?? accentHex
        if let accent, let named = pick(accent, names: studioAccents).flatMap(StudioAccent.init(rawValue:)) {
            if named != studio.accent { studio.accent = named }
            // A colour is used exactly. StudioTheme only knows its six accents, so the exact
            // colour is laid over the nearest one and restored at launch by ThemeEngine.start().
            let exact = ThemeColor(hex: accent)
            ThemeEngine.exactAccent = exact?.hex
            if let exact { DS.Ink.current = Color(exact) }
            studio.objectWillChange.send()
        }
        if let value = theme.number("studio.glow") { studio.glow = value }
        if let value = theme.bool("studio.tilt") { studio.tilt = value }
        // "studio.reflection" is still accepted in theme files; the floor reflection is gone.
    }

    private static func applyIcons(_ theme: ThemeDocument) {
        guard let style = theme.string("icons.style") else { return }
        // Clear and tinted icons are Tahoe's. Before it, AppleIconAppearanceTheme means nothing
        // to the Dock, so a theme's icon section is skipped rather than written to be ignored.
        guard PersonalAvailability.themeIconStyleSupported(style) else { return }
        let mode = theme.string("icons.mode") == "light" ? "Light" : "Dark"
        let key: String? = switch style {
        case "clear": "Clear" + mode
        case "tinted": "Tinted" + mode
        default: nil
        }
        var tint: String?, rgb: String?
        if style == "tinted", let raw = theme.string("icons.tint") ?? theme.string("colors.accent") {
            if ThemeSchema.iconTints.contains(raw) { tint = raw }
            else if let color = ThemeColor(hex: raw) {
                tint = "Other"
                rgb = String(format: "%.6f %.6f %.6f 1.000000", color.red, color.green, color.blue)
            }
        }
        // Writing these restarts the Dock. Skip it when nothing would change.
        let domain = "NSGlobalDomain"
        let same = Prefs.current("AppleIconAppearanceTheme", domain: domain) == key
            && Prefs.current("AppleIconAppearanceTintColor", domain: domain) == tint
            && Prefs.current("AppleIconAppearanceCustomTintColor", domain: domain) == rgb
        guard !same else { return }
        Task.detached {
            try? IconTint.write(theme: key, tint: tint, rgb: rgb)
            await MainActor.run { Effects.shared.iconRevision += 1 }
        }
    }

    private static func applyClock(_ theme: ThemeDocument) {
        let board = WidgetBoard.shared
        if let show = theme.bool("clock.show"), show != board.desktopClock { board.desktopClock = show }
        guard let face = theme.string("clock.face").flatMap(ClockFace.init(rawValue:)) else { return }
        if theme.bool("clock.show") != false, let clock = board.placements.first(where: { $0.kind == .bigClock }) {
            board.update(clock.uid) {
                var options = $0.options.clock ?? ClockOptions()
                options.face = face
                $0.options.clock = options
            }
        }
    }

    // MARK: Capture

    /// The Mac as it is now, as a theme. Used for "Create Theme from my Mac" and to revert.
    static func capture(name: String = "My Mac", id: String = "local.my-mac") -> ThemeDocument {
        var theme = ThemeDocument(root: [
            "format": .number(1), "id": .string(id), "name": .string(name), "version": .string("1.0.0"),
            "author": .string(NSFullUserName().isEmpty ? "Me" : NSFullUserName()),
        ])
        let dock = OwnDock.shared.appearance
        theme.set("dock", .object([
            "style": .string(dock.style.rawValue), "accent": .string(dock.accent.rawValue),
            "indicator": .string(dock.indicator.rawValue), "hover": .string(dock.hover.rawValue),
            "roundness": .number(dock.roundness), "padding": .number(dock.padding), "spacing": .number(dock.spacing),
            "gap": .number(dock.gap), "curve": .string(dock.curve.rawValue), "launch": .string(dock.launch.rawValue),
            "labelPosition": .string(dock.labelPosition.rawValue), "hoverLift": .bool(dock.hoverLift),
            "iconShadow": .bool(dock.iconShadow), "reflection": .bool(dock.reflection), "divider": .bool(dock.divider),
            "followTheme": .bool(OwnDock.shared.followLook),
        ]))
        let board = WidgetBoard.shared, style = board.style
        var widgets: [String: JSONValue] = [
            "material": .string(style.material.rawValue), "tint": .string(style.tint.rawValue),
            "accent": .string(style.accent.rawValue), "radius": .number(style.radius), "opacity": .number(style.opacity),
            "font": .string(style.font.rawValue), "shadow": .number(style.shadow), "border": .number(style.border),
            "padding": .number(style.padding), "scale": .number(style.scale), "blur": .number(style.blur),
            "iconHarmony": .string(board.harmony.rawValue),
        ]
        if let gradient = style.gradient {
            widgets["gradient"] = .object(["from": .string(gradient.from.rawValue), "to": .string(gradient.to.rawValue), "angle": .number(gradient.angle)])
        }
        theme.set("widgets", .object(widgets))
        let effects = Effects.shared
        theme.set("menuBar", .object(["skin": .string(effects.skin.rawValue)]))
        theme.set("effects", .object(["dockGlow": .bool(effects.dockGlow), "dayLine": .bool(effects.dayLine)]))

        let live = LiveWallpaper.shared
        let tuning = live.tuning(for: live.shader)
        var wallpaper: [String: JSONValue] = [
            "shader": .string(live.shader.rawValue), "speed": .number(tuning.speed), "intensity": .number(tuning.intensity),
            "grain": .number(tuning.grain), "scale": .number(tuning.scale), "dim": .number(tuning.dim),
            "cycle": .string(tuning.cycle.rawValue),
        ]
        if let stops = ThemePalettes.colors(for: tuning.palette) {
            wallpaper["palette"] = .array(stops.map { .string($0.hex) })
        } else if ThemeSchema.palettes.contains(tuning.palette) {
            wallpaper["palette"] = .string(tuning.palette)
        }
        if live.enabled { wallpaper["mode"] = .string("live") }
        else if let hue = effects.living { wallpaper["mode"] = .string("mesh"); wallpaper["mesh"] = .string(hue.rawValue) }
        else { wallpaper["mode"] = .string("off") }
        theme.set("wallpaper", .object(wallpaper))
        if !live.enabled, effects.living == nil, let url = Wallpaper.url() { theme.root["x-originalImage"] = .string(url.absoluteString) }

        let studio = StudioTheme.shared
        theme.set("studio", .object([
            "backdrop": .string(studio.backdrop.rawValue),
            "accent": .string(ThemeEngine.exactAccent ?? studio.accent.rawValue),
            "glow": .number(studio.glow), "tilt": .bool(studio.tilt),
        ]))

        let domain = "NSGlobalDomain"
        let iconTheme = Prefs.current("AppleIconAppearanceTheme", domain: domain) ?? ""
        var icons: [String: JSONValue] = [
            "style": .string(iconTheme.hasPrefix("Tinted") ? "tinted" : iconTheme.hasPrefix("Clear") ? "clear" : "default"),
            "mode": .string(iconTheme.hasSuffix("Light") ? "light" : "dark"),
        ]
        if iconTheme.hasPrefix("Tinted") {
            let tint = Prefs.current("AppleIconAppearanceTintColor", domain: domain)
            if tint == "Other", let rgb = Prefs.current("AppleIconAppearanceCustomTintColor", domain: domain) {
                let v = rgb.split(separator: " ").compactMap { Double($0) }
                if v.count >= 3 { icons["tint"] = .string(ThemeColor(red: v[0], green: v[1], blue: v[2]).hex) }
            } else if let tint, ThemeSchema.iconTints.contains(tint) {
                icons["tint"] = .string(tint)
            }
        }
        theme.set("icons", .object(icons))

        var clock: [String: JSONValue] = ["show": .bool(board.desktopClock)]
        if let face = board.placements.first(where: { $0.kind == .bigClock })?.options.clock?.face { clock["face"] = .string(face.rawValue) }
        theme.set("clock", .object(clock))
        if let look = effects.look { theme.root["x-look"] = .string(look) }
        theme.root = ThemeSchema.sanitize(theme.root)
        return theme
    }

    // MARK: Stage preview

    /// What the stage can show of a theme today, through the existing Look preview.
    static func look(for theme: ThemeDocument) -> Look {
        let skin = theme.string("menuBar.skin").flatMap(SkinPreset.init(rawValue:)) ?? Effects.shared.skin
        let hue: Hue? = theme.string("wallpaper.mode") == "mesh"
            ? theme.string("wallpaper.mesh").flatMap(Hue.init(rawValue:)) ?? .aurora
            : theme.string("wallpaper.mode") == nil ? Effects.shared.living : nil
        var iconTheme: String?, tint: String?, rgb: String?
        // The stage shows only what applying would do: no icon style before macOS 26.
        switch theme.string("icons.style").flatMap({ PersonalAvailability.themeIconStyleSupported($0) ? $0 : nil }) {
        case "clear": iconTheme = "ClearDark"
        case "tinted":
            iconTheme = "TintedDark"
            if let raw = theme.string("icons.tint") ?? theme.string("colors.accent") {
                if let color = ThemeColor(hex: raw) {
                    tint = "Other"; rgb = "\(color.red) \(color.green) \(color.blue) 1"
                } else { tint = raw }
            }
        default: break
        }
        let face = theme.string("clock.face").flatMap(ClockFace.init(rawValue:))?.legacy ?? .thin
        let clock: ClockStyle? = theme.bool("clock.show") == true ? face : theme.bool("clock.show") == false ? nil
            : (WidgetBoard.shared.desktopClock ? face : nil)
        return Look(name: theme.name, skin: skin, hue: hue, theme: iconTheme, tint: tint, rgb: rgb, clock: clock,
                    glow: theme.bool("effects.dockGlow") ?? Effects.shared.dockGlow)
    }
}

extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

extension ThemeColor {
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

// MARK: - Palettes

/// Four-colour live wallpaper palettes that come from themes. LiveWallpaper only knows its
/// presets by id; until it asks here (snippet S6 in the integration notes), a custom palette
/// falls back to the closest preset so the wallpaper never loses its colour entirely.
@MainActor
enum ThemePalettes {
    /// Flip to true once LiveWallpaper.stops(for:) consults `stops(for:)` (snippet S6).
    static let integrated = true
    private static let key = "theme.palettes"
    private static var cache: [String: [ThemeColor]] = {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return saved.mapValues { $0.compactMap(ThemeColor.init(hex:)) }
    }()

    /// Registers four stops and returns the palette id to put in a LivingTuning.
    static func register(_ colors: [ThemeColor], for theme: String) -> String {
        guard integrated else { return nearestPreset(colors) }
        let id = "theme:" + theme
        cache[id] = colors
        UserDefaults.standard.set(cache.mapValues { $0.map(\.hex) }, forKey: key)
        return id
    }

    static func colors(for id: String) -> [ThemeColor]? { cache[id] }

    /// For LiveWallpaper.stops(for:). Display P3 stops, as the shaders expect.
    static func stops(for id: String) -> [SIMD3<Float>]? {
        cache[id]?.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
    }

    static func nearestPreset(_ colors: [ThemeColor]) -> String {
        let presets = LivingPalette.presets
        func score(_ preset: LivingPalette) -> Double {
            zip(colors, preset.stops).reduce(0) { sum, pair in
                sum + pair.0.distance(to: ThemeColor(red: Double(pair.1.x), green: Double(pair.1.y), blue: Double(pair.1.z)))
            }
        }
        return presets.min { score($0) < score($1) }?.id ?? LivingPalette.natural
    }
}

// MARK: - Still wallpaper pictures

@MainActor
enum ThemeWallpaper {
    static var lastError: String?

    static func set(_ url: URL) {
        lastError = nil
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            lastError = "The wallpaper picture is missing."
            return
        }
        do {
            for screen in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(url, for: screen) }
        } catch {
            lastError = "Couldn’t set the wallpaper: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sounds

/// Theme sounds. `apply` plays here; `focusEnd` and `cornerFire` play once Effects and
/// HotCorners call `ThemeSounds.play` (snippet S7).
@MainActor
enum ThemeSounds {
    enum Event: String, CaseIterable { case apply, focusEnd, cornerFire }
    private static var sounds: [Event: NSSound] = [:]

    static func configure(_ theme: ThemeDocument, bundle: URL?) {
        sounds = [:]
        for event in Event.allCases {
            guard let name = theme.string("sounds.\(event.rawValue)") else { continue }
            if let bundle, ThemeIdentifier.isSafeRelativePath(name), name.contains(".") {
                let url = bundle.appendingPathComponent(name)
                sounds[event] = NSSound(contentsOf: url, byReference: true)
            } else {
                sounds[event] = NSSound(named: NSSound.Name(name))
            }
        }
    }

    /// Plays the theme's sound for an event, or `fallback` when the theme has none.
    static func play(_ event: Event, fallback: String? = nil) {
        if let sound = sounds[event] {
            sound.stop()
            sound.play()
        } else if event == .apply, SoundPackRuntime.play(.themeApply) {
            // The sound pack in use has one.
        } else if let fallback {
            NSSound(named: NSSound.Name(fallback))?.play()
        }
    }
}
