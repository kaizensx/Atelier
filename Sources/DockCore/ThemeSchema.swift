import Foundation

/// The Atelier theme format, version 1: `atelier-theme.json` inside a `.ateliertheme` folder.
///
/// The table below is the single source of truth. The validator walks it, the JSON Schema in
/// `docs/atelier-theme.schema.json` mirrors it (a unit test keeps the two in step), and
/// `docs/THEMES.md` documents it. Every section is optional: a key that is absent leaves that
/// part of the Mac as it is.
public enum ThemeSchema {
    public static let format = 1
    public static let fileName = "atelier-theme.json"
    public static let bundleExtension = "ateliertheme"
    /// Bundles larger than this are refused before anything is read.
    public static let maxBundleBytes = 40 * 1024 * 1024
    public static let maxManifestBytes = 256 * 1024

    public indirect enum Kind: Equatable, Sendable {
        case string(maxLength: Int)
        case oneOf([String])
        case number(ClosedRange<Double>)
        case integer(ClosedRange<Int>)
        case bool
        case color
        /// A colour, or one of the named swatches.
        case colorOr([String])
        /// A list of colours, `count` long.
        case colors(ClosedRange<Int>)
        /// One of the named presets, or a list of colours.
        case presetOrColors([String], ClosedRange<Int>)
        /// A path inside the bundle, with one of these extensions.
        case file([String])
        case url
        case strings(maxCount: Int, maxLength: Int)
        case object([Field])
    }

    public struct Field: Equatable, Sendable {
        public let key: String
        public let kind: Kind
        public let summary: String
        public let required: Bool
        public init(_ key: String, _ kind: Kind, _ summary: String, required: Bool = false) {
            self.key = key; self.kind = kind; self.summary = summary; self.required = required
        }
    }

    // MARK: Vocabulary. These mirror Atelier's own enums; the app logs any that drift.

    public static let dockStyles = ["glass", "tinted", "midnight", "frost", "neon", "wallpaper"]
    public static let dockAccents = ["blue", "purple", "pink", "orange", "green", "graphite"]
    public static let dockIndicators = ["dot", "bar", "glow", "none"]
    public static let dockHovers = ["peek", "label", "none"]
    public static let dockCurves = ["gentle", "classic", "fisheye", "wave"]
    public static let dockLaunches = ["bounce", "pulse", "glow"]
    public static let dockLabels = ["lens", "icon"]
    public static let widgetMaterials = ["glass", "clear", "tinted", "dark", "frosted", "outline", "bare"]
    public static let widgetTints = ["blue", "indigo", "purple", "pink", "red", "orange", "amber", "green", "mint", "teal", "graphite"]
    public static let widgetFonts = ["system", "rounded", "serif", "mono"]
    public static let iconHarmonies = ["off", "halo", "cutout", "fade"]
    public static let menuBarSkins = ["none", "notchless", "sunset", "ocean", "aurora", "graphite"]
    public static let wallpaperModes = ["keep", "live", "mesh", "image", "off"]
    public static let shaders = ["liquidLight", "nebula", "auroraSilk", "topography", "glassRain", "silkWaves", "gradientMesh", "starfield", "retroHorizon"]
    public static let palettes = ["natural", "wallpaper", "midnight", "ember", "lagoon", "orchid", "glacier", "forest", "dune", "graphite"]
    public static let cycles = ["clock", "day", "dusk", "night"]
    public static let meshHues = ["aurora", "dusk", "ocean", "ember", "mono"]
    public static let backdrops = ["light", "wallpaper", "live", "midnight", "aurora", "ember", "graphite", "paper"]
    public static let studioAccents = ["sky", "violet", "mint", "rose", "amber", "silver"]
    public static let iconStyles = ["default", "clear", "tinted"]
    public static let iconModes = ["dark", "light"]
    public static let iconTints = ["Blue", "Purple", "Pink", "Orange", "Yellow", "Green", "Graphite"]
    public static let clockFaces = ["thin", "bold", "rounded", "serif", "mono", "words", "analog", "flip", "stacked", "dot"]
    public static let appearances = ["dark", "light"]

    static let imageTypes = ["png", "jpg", "jpeg", "heic", "tiff"]
    static let soundTypes = ["aiff", "aif", "wav", "caf", "m4a", "mp3"]

    // MARK: The table

    public static let sections: [Field] = [
        Field("format", .integer(1...1), "Format version. Always 1 for this release.", required: true),
        Field("id", .string(maxLength: 120), "Reverse-DNS identifier, unique to this theme: `com.example.midnight-glass`.", required: true),
        Field("name", .string(maxLength: 60), "Name shown in the gallery.", required: true),
        Field("version", .string(maxLength: 20), "Semantic version of the theme: `1.2.0`.", required: true),
        Field("author", .string(maxLength: 80), "Who made it."),
        Field("description", .string(maxLength: 400), "One or two sentences for the gallery."),
        Field("homepage", .url, "An https link for more about the theme."),
        Field("preview", .file(imageTypes), "A picture for the gallery card, inside the bundle."),
        Field("tags", .strings(maxCount: 8, maxLength: 24), "Words the gallery can filter by."),
        Field("appearance", .oneOf(appearances), "Whether the theme is designed for a dark or a light setup. Informational."),
        Field("colors", .object([
            Field("accent", .color, "The theme's main colour. Feeds the Dock, widgets and Studio when they have no colour of their own."),
            Field("secondary", .color, "A second colour, used for rings and gradients."),
            Field("glassTint", .color, "The tint for Liquid Glass widget surfaces when `widgets.tint` is absent (snapped to the nearest widget tint)."),
        ]), "The palette everything else can borrow from."),
        Field("dock", .object([
            Field("style", .oneOf(dockStyles), "Atelier Dock design."),
            Field("accent", .colorOr(dockAccents), "Dock accent: a named accent or a colour (snapped to the nearest named accent)."),
            Field("indicator", .oneOf(dockIndicators), "What marks an open app."),
            Field("hover", .oneOf(dockHovers), "What resting on a tile shows."),
            Field("roundness", .number(0...1), "0 is nearly square, 1 a capsule."),
            Field("padding", .number(0.04...0.3), "Glass around the icons, as a fraction of the icon size."),
            Field("spacing", .number(0...0.5), "Room between icons, as a fraction of the icon size."),
            Field("gap", .number(0...32), "Points between the bar and the screen edge."),
            Field("curve", .oneOf(dockCurves), "Magnification curve."),
            Field("launch", .oneOf(dockLaunches), "What an app does while it opens."),
            Field("labelPosition", .oneOf(dockLabels), "Where tile names appear."),
            Field("hoverLift", .bool, "Icons rise under the pointer instead of growing."),
            Field("iconShadow", .bool, "Soft shadow under icons."),
            Field("reflection", .bool, "A reflection under the bar."),
            Field("divider", .bool, "A divider before folders and Trash."),
            Field("followTheme", .bool, "The Dock takes its tint from the menu bar skin or mesh wallpaper instead of `dock.accent` (Atelier Dock's Follow Look setting). Turned off when the theme sets `dock.accent` and leaves this out."),
        ]), "The Atelier Dock."),
        Field("widgets", .object([
            Field("material", .oneOf(widgetMaterials), "Surface of every widget that follows the board style."),
            Field("tint", .colorOr(widgetTints), "Surface tint."),
            Field("accent", .colorOr(widgetTints), "Accent for rings, bars and highlights."),
            Field("radius", .number(10...40), "Corner radius in points."),
            Field("opacity", .number(0.35...1), "Surface opacity."),
            Field("font", .oneOf(widgetFonts), "Type family."),
            Field("shadow", .number(0...1), "0 flat, 1 a deep soft shadow."),
            Field("border", .number(0...2), "Extra rim in points."),
            Field("padding", .number(0...14), "Extra room inside the edge in points."),
            Field("scale", .number(0.85...1.2), "Text scale."),
            Field("blur", .number(0...1), "Background blur."),
            Field("gradient", .object([
                Field("from", .colorOr(widgetTints), "Start colour."),
                Field("to", .colorOr(widgetTints), "End colour."),
                Field("angle", .number(0...360), "Degrees; 0 runs left to right."),
            ]), "A gradient under the content. Omit for none."),
            Field("iconHarmony", .oneOf(iconHarmonies), "How desktop icons make room for widgets."),
        ]), "The widget board's style."),
        Field("menuBar", .object([
            Field("skin", .oneOf(menuBarSkins), "A menu bar skin. `none` removes it."),
        ]), "The menu bar."),
        Field("wallpaper", .object([
            Field("mode", .oneOf(wallpaperModes), "`live` a Metal live wallpaper, `mesh` a still mesh that follows the hour, `image` a picture from the bundle, `off` turns Atelier's wallpapers off, `keep` (default) leaves it alone."),
            Field("shader", .oneOf(shaders), "Live wallpaper, for `live`."),
            Field("palette", .presetOrColors(palettes, 4...4), "Live wallpaper colours: a preset or four colours from dark to light."),
            Field("speed", .number(0.2...2.5), "Live wallpaper speed. 1 is as designed."),
            Field("intensity", .number(0...1), "Contrast and colour. 0.5 is as designed."),
            Field("grain", .number(0...1), "Film grain."),
            Field("scale", .number(0.6...1.8), "Pattern scale."),
            Field("dim", .number(0...0.7), "Darkening, for legibility."),
            Field("cycle", .oneOf(cycles), "Follow the clock, or hold day, dusk or night."),
            Field("mesh", .oneOf(meshHues), "Mesh colours, for `mesh`."),
            Field("image", .file(imageTypes), "A picture inside the bundle, for `image`."),
        ]), "The desktop."),
        Field("studio", .object([
            Field("backdrop", .oneOf(backdrops), "The room around Atelier's stage."),
            Field("accent", .colorOr(studioAccents), "Accent of Atelier's own controls. A colour is used exactly."),
            Field("glow", .number(0...1), "How much of the room's colour shows."),
            Field("tilt", .bool, "The stage leans toward the pointer."),
            Field("reflection", .bool, "A glossy floor under the stage."),
        ]), "Atelier's own window."),
        Field("icons", .object([
            Field("style", .oneOf(iconStyles), "macOS app icon style. Needs a Dock restart, which Atelier does."),
            Field("mode", .oneOf(iconModes), "Light or dark icons, for `clear` and `tinted`."),
            Field("tint", .colorOr(iconTints), "Icon tint, for `tinted`."),
        ]), "macOS icon appearance."),
        Field("clock", .object([
            Field("show", .bool, "A Big Clock on the desktop."),
            Field("face", .oneOf(clockFaces), "Its face."),
        ]), "The desktop clock."),
        Field("effects", .object([
            Field("dockGlow", .bool, "Light pools under the Dock."),
            Field("dayLine", .bool, "A hairline under the menu bar fills as the day passes."),
        ]), "Atelier's desktop effects."),
        Field("sounds", .object([
            Field("apply", .string(maxLength: 120), "Played when the theme is applied: a system sound name (`Glass`) or a file in the bundle."),
            Field("focusEnd", .string(maxLength: 120), "Played when a Focus Island countdown ends."),
            Field("cornerFire", .string(maxLength: 120), "Played when a hot corner fires."),
        ]), "Sounds."),
    ]

    /// Clamps numbers into range and drops values the schema would reject, so a theme read
    /// from live settings always validates.
    public static func sanitize(_ root: [String: JSONValue]) -> [String: JSONValue] {
        func clean(_ object: [String: JSONValue], _ fields: [Field]) -> [String: JSONValue] {
            var out = object
            for field in fields {
                guard let value = object[field.key] else { continue }
                switch (field.kind, value) {
                case (.number(let range), .number(let number)):
                    out[field.key] = .number(number.isFinite ? min(max(number, range.lowerBound), range.upperBound) : range.lowerBound)
                case (.oneOf(let options), .string(let text)) where !options.contains(text):
                    out[field.key] = nil
                case (.object(let inner), .object(let nested)):
                    out[field.key] = .object(clean(nested, inner))
                default: break
                }
            }
            return out
        }
        return clean(root, sections)
    }

    public static func field(_ path: String) -> Field? {
        var fields = sections
        var found: Field?
        for key in path.split(separator: ".").map(String.init) {
            guard let next = fields.first(where: { $0.key == key }) else { return nil }
            found = next
            if case .object(let inner) = next.kind { fields = inner } else { fields = [] }
        }
        return found
    }
}

// MARK: - Validation

public struct ThemeIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public let severity: Severity
    /// Dotted path to the key: `dock.roundness`. Empty for the whole file.
    public let path: String
    public let message: String

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

public struct ThemeValidation: Sendable {
    public var issues: [ThemeIssue] = []
    public var errors: [ThemeIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ThemeIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    mutating func error(_ path: String, _ message: String) { issues.append(ThemeIssue(severity: .error, path: path, message: message)) }
    mutating func warn(_ path: String, _ message: String) { issues.append(ThemeIssue(severity: .warning, path: path, message: message)) }
}

public enum ThemeValidator {
    /// Validates a parsed `atelier-theme.json`. `files` lists the paths inside the bundle, so
    /// references to pictures and sounds can be checked; pass nil to skip that check.
    public static func validate(_ value: JSONValue, files: Set<String>? = nil) -> ThemeValidation {
        var result = ThemeValidation()
        guard let root = value.object else {
            result.error("", "The theme must be a JSON object, got \(value.shortDescription).")
            return result
        }
        if let format = root["format"]?.number, format > Double(ThemeSchema.format) {
            result.error("format", "This theme needs a newer Atelier (format \(Int(format)); this build reads format \(ThemeSchema.format)).")
            return result
        }
        check(root, fields: ThemeSchema.sections, prefix: "", files: files, into: &result)
        if let id = root["id"]?.string, !ThemeIdentifier.isValid(id) {
            result.error("id", "\"\(id)\" is not a reverse-DNS identifier. Use letters, digits and hyphens between dots, like com.example.my-theme.")
        }
        if let version = root["version"]?.string, SemVer(version) == nil {
            result.error("version", "\"\(version)\" is not a version. Use major.minor.patch, like 1.0.0.")
        }
        if let name = root["name"]?.string, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.error("name", "The name is empty.")
        }
        let wallpaper = root["wallpaper"]?.object ?? [:]
        switch wallpaper["mode"]?.string {
        case "live" where wallpaper["shader"] == nil:
            result.warn("wallpaper.shader", "Mode is live but no shader is named; the current live wallpaper is kept.")
        case "image" where wallpaper["image"] == nil:
            result.error("wallpaper.image", "Mode is image, so a picture inside the bundle is required.")
        case "mesh" where wallpaper["mesh"] == nil:
            result.warn("wallpaper.mesh", "Mode is mesh but no mesh colours are named; aurora is used.")
        default: break
        }
        return result
    }

    public static func validate(data: Data, files: Set<String>? = nil) -> (JSONValue?, ThemeValidation) {
        var result = ThemeValidation()
        guard data.count <= ThemeSchema.maxManifestBytes else {
            result.error("", "\(ThemeSchema.fileName) is larger than \(ThemeSchema.maxManifestBytes / 1024) KB.")
            return (nil, result)
        }
        do {
            let value = try JSONValue.parse(data)
            return (value, validate(value, files: files))
        } catch {
            result.error("", "\(ThemeSchema.fileName) is not valid JSON: \(Self.describe(error)).")
            return (nil, result)
        }
    }

    /// Validates an object against any field table: themes, manifests, plugin specs.
    public static func validate(fields: [ThemeSchema.Field], object: [String: JSONValue], files: Set<String>? = nil) -> ThemeValidation {
        var result = ThemeValidation()
        check(object, fields: fields, prefix: "", files: files, into: &result)
        return result
    }

    static func describe(_ error: Error) -> String {
        let text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func check(_ object: [String: JSONValue], fields: [ThemeSchema.Field], prefix: String,
                              files: Set<String>?, into result: inout ThemeValidation) {
        let known = Set(fields.map(\.key))
        for key in object.keys.sorted() where !known.contains(key) && !key.hasPrefix("$") && !key.hasPrefix("x-") {
            let close = fields.map(\.key).min { distance($0, key) < distance($1, key) }
            let hint = close.flatMap { distance($0, key) <= 2 ? " Did you mean \"\($0)\"?" : nil } ?? ""
            result.warn(join(prefix, key), "Unknown key, ignored.\(hint)")
        }
        for field in fields {
            let path = join(prefix, field.key)
            guard let value = object[field.key], !value.isNull else {
                if field.required { result.error(path, "Required, but missing.") }
                continue
            }
            check(value, kind: field.kind, path: path, files: files, into: &result)
        }
    }

    private static func check(_ value: JSONValue, kind: ThemeSchema.Kind, path: String, files: Set<String>?,
                              into result: inout ThemeValidation) {
        let got = value.shortDescription
        switch kind {
        case .string(let max):
            guard let text = value.string else { return result.error(path, "Expected text, got \(got).") }
            if text.count > max { result.error(path, "Longer than \(max) characters.") }
        case .oneOf(let options):
            guard let text = value.string else { return result.error(path, "Expected one of \(list(options)), got \(got).") }
            if !options.contains(text) {
                let close = options.min { distance($0, text) < distance($1, text) }
                let hint = close.flatMap { distance($0.lowercased(), text.lowercased()) <= 2 ? " Did you mean \"\($0)\"?" : nil } ?? ""
                result.error(path, "\"\(text)\" is not one of \(list(options)).\(hint)")
            }
        case .number(let range):
            guard let number = value.number else { return result.error(path, "Expected a number from \(format(range.lowerBound)) to \(format(range.upperBound)), got \(got).") }
            if !range.contains(number) { result.error(path, "\(format(number)) is outside \(format(range.lowerBound))…\(format(range.upperBound)).") }
        case .integer(let range):
            guard let number = value.number, number.rounded() == number else { return result.error(path, "Expected a whole number, got \(got).") }
            if !range.contains(Int(number)) { result.error(path, "\(Int(number)) is outside \(range.lowerBound)…\(range.upperBound).") }
        case .bool:
            if value.bool == nil { result.error(path, "Expected true or false, got \(got).") }
        case .color:
            guard let text = value.string, ThemeColor(hex: text) != nil else {
                return result.error(path, "Expected a colour like \"#8FB8FF\" or \"#8FB8FFCC\", got \(got).")
            }
        case .colorOr(let names):
            guard let text = value.string else { return result.error(path, "Expected a colour or one of \(list(names)), got \(got).") }
            if !names.contains(text), ThemeColor(hex: text) == nil {
                result.error(path, "\"\(text)\" is neither a colour like \"#8FB8FF\" nor one of \(list(names)).")
            }
        case .colors(let count):
            checkColors(value, count: count, path: path, into: &result)
        case .presetOrColors(let names, let count):
            if let text = value.string {
                if !names.contains(text) { result.error(path, "\"\(text)\" is not one of \(list(names)).") }
            } else if value.array != nil {
                checkColors(value, count: count, path: path, into: &result)
            } else {
                result.error(path, "Expected one of \(list(names)) or a list of \(count.lowerBound) colours, got \(got).")
            }
        case .file(let types):
            guard let text = value.string else { return result.error(path, "Expected a path inside the bundle, got \(got).") }
            guard ThemeIdentifier.isSafeRelativePath(text) else {
                return result.error(path, "\"\(text)\" must be a relative path inside the bundle, without \"..\".")
            }
            let ext = (text as NSString).pathExtension.lowercased()
            if !types.contains(ext) { result.error(path, "\"\(text)\" must be one of: \(types.joined(separator: ", ")).") }
            if let files, !files.contains(text) { result.error(path, "\"\(text)\" is not in the bundle.") }
        case .url:
            guard let text = value.string, let url = URL(string: text), url.scheme == "https", url.host != nil else {
                return result.error(path, "Expected an https link, got \(got).")
            }
        case .strings(let maxCount, let maxLength):
            guard let items = value.array else { return result.error(path, "Expected a list of text, got \(got).") }
            if items.count > maxCount { result.error(path, "At most \(maxCount) entries.") }
            for (index, item) in items.enumerated() {
                guard let text = item.string else { result.error("\(path)[\(index)]", "Expected text, got \(item.shortDescription)."); continue }
                if text.count > maxLength { result.error("\(path)[\(index)]", "Longer than \(maxLength) characters.") }
            }
        case .object(let fields):
            guard let object = value.object else { return result.error(path, "Expected an object, got \(got).") }
            check(object, fields: fields, prefix: path, files: files, into: &result)
        }
    }

    private static func checkColors(_ value: JSONValue, count: ClosedRange<Int>, path: String, into result: inout ThemeValidation) {
        guard let items = value.array else { return result.error(path, "Expected a list of colours, got \(value.shortDescription).") }
        if !count.contains(items.count) {
            let wanted = count.lowerBound == count.upperBound ? "\(count.lowerBound)" : "\(count.lowerBound) to \(count.upperBound)"
            result.error(path, "Expected \(wanted) colours, got \(items.count).")
        }
        for (index, item) in items.enumerated() where item.string.flatMap(ThemeColor.init(hex:)) == nil {
            result.error("\(path)[\(index)]", "Expected a colour like \"#8FB8FF\", got \(item.shortDescription).")
        }
    }

    private static func join(_ prefix: String, _ key: String) -> String { prefix.isEmpty ? key : prefix + "." + key }
    private static func list(_ options: [String]) -> String {
        options.count <= 6 ? options.joined(separator: ", ") : options.prefix(6).joined(separator: ", ") + ", …"
    }
    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    /// Levenshtein distance, for "did you mean" hints.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
    }
}

// MARK: - The document

/// A validated theme. Reads are typed and never fail: a value that is missing or of the wrong
/// kind reads as nil, which means "leave this as it is".
public struct ThemeDocument: Equatable, Sendable, Identifiable {
    public var root: [String: JSONValue]

    public init(root: [String: JSONValue]) { self.root = root }

    /// Parses and validates. Throws the validation when it has errors.
    public init(data: Data, files: Set<String>? = nil) throws {
        let (value, validation) = ThemeValidator.validate(data: data, files: files)
        guard let object = value?.object, validation.isValid else { throw ThemeError.invalid(validation.issues) }
        root = object
    }

    public var id: String { root["id"]?.string ?? "" }
    public var name: String { root["name"]?.string ?? "Untitled" }
    public var version: String { root["version"]?.string ?? "1.0.0" }
    public var author: String? { root["author"]?.string }
    public var summary: String? { root["description"]?.string }
    public var tags: [String] { root["tags"]?.array?.compactMap(\.string) ?? [] }

    public func value(_ path: String) -> JSONValue? {
        var current: JSONValue? = .object(root)
        for key in path.split(separator: ".") { current = current?[String(key)] }
        return current.flatMap { $0.isNull ? nil : $0 }
    }
    public func string(_ path: String) -> String? { value(path)?.string }
    public func number(_ path: String) -> Double? { value(path)?.number }
    public func bool(_ path: String) -> Bool? { value(path)?.bool }
    public func color(_ path: String) -> ThemeColor? { string(path).flatMap(ThemeColor.init(hex:)) }
    public func colors(_ path: String) -> [ThemeColor]? {
        value(path)?.array?.compactMap { $0.string.flatMap(ThemeColor.init(hex:)) }
    }

    public mutating func set(_ path: String, _ value: JSONValue?) {
        let keys = path.split(separator: ".").map(String.init)
        guard let first = keys.first else { return }
        if keys.count == 1 { root[first] = value; return }
        var section = root[first]?.object ?? [:]
        if keys.count == 2 {
            section[keys[1]] = value
        } else {
            var inner = section[keys[1]]?.object ?? [:]
            inner[keys[2]] = value
            section[keys[1]] = inner.isEmpty ? nil : .object(inner)
        }
        root[first] = section.isEmpty ? nil : .object(section)
    }

    /// Lays `patch` over this theme, key by key. Used by plugins and by "only change the colours".
    public func merged(with patch: [String: JSONValue]) -> ThemeDocument {
        func merge(_ base: [String: JSONValue], _ over: [String: JSONValue]) -> [String: JSONValue] {
            var out = base
            for (key, value) in over {
                if case .object(let inner) = value, case .object(let existing)? = base[key] {
                    out[key] = .object(merge(existing, inner))
                } else {
                    out[key] = value.isNull ? nil : value
                }
            }
            return out
        }
        return ThemeDocument(root: merge(root, patch))
    }

    public func data() throws -> Data { try JSONValue.object(root).data(pretty: true) }

    /// The sections this theme touches, for the gallery's "what changes" list.
    public var touched: [String] {
        ["dock", "widgets", "menuBar", "wallpaper", "studio", "icons", "clock", "effects", "sounds", "colors"].filter { root[$0] != nil }
    }
}

public enum ThemeError: Error, LocalizedError, Equatable {
    case invalid([ThemeIssue])
    case missingManifest
    case tooLarge(Int)
    case notABundle
    case badURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            let errors = issues.filter { $0.severity == .error }
            let lines = errors.prefix(6).map { "• " + $0.description }
            let more = errors.count > 6 ? "\n…and \(errors.count - 6) more." : ""
            return "This theme has \(errors.count == 1 ? "a problem" : "\(errors.count) problems"):\n" + lines.joined(separator: "\n") + more
        case .missingManifest: return "There is no \(ThemeSchema.fileName) inside the bundle."
        case .tooLarge(let bytes): return "The theme is \(bytes / 1_048_576) MB; the limit is \(ThemeSchema.maxBundleBytes / 1_048_576) MB."
        case .notABundle: return "Themes are folders named something.\(ThemeSchema.bundleExtension), or a bare \(ThemeSchema.fileName)."
        case .badURL(let reason): return reason
        }
    }
}

// MARK: - Links and schedules

public enum ThemeLink {
    /// `atelier://theme?url=https://…/x.ateliertheme.zip` or `…/atelier-theme.json`.
    /// Only https is followed, and never to a local or private address.
    public static func download(from link: URL) throws -> URL {
        guard link.scheme == "atelier" || link.scheme == "dockstacks", link.host() == "theme" else {
            throw ThemeError.badURL("Not an Atelier theme link.")
        }
        guard let text = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: text) else {
            throw ThemeError.badURL("The link has no url= to download from.")
        }
        guard target.scheme == "https", let host = target.host()?.lowercased(), !host.isEmpty else {
            throw ThemeError.badURL("Themes are only downloaded over https.")
        }
        if isPrivate(host) { throw ThemeError.badURL("Themes are not downloaded from local or private addresses.") }
        let name = target.lastPathComponent.lowercased()
        guard name.hasSuffix(".json") || name.hasSuffix(".zip") else {
            throw ThemeError.badURL("The link must point at an \(ThemeSchema.fileName) or a zipped .\(ThemeSchema.bundleExtension).")
        }
        return target
    }

    public static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") { return true }
        if host.contains(":") { return host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("[") }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true
        default: return false
        }
    }
}

/// Up to four Looks across the day. Each entry starts at an hour and holds until the next.
public struct ThemeSchedule: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable, Identifiable {
        public var id: String { "\(hour)-\(theme)" }
        /// 0 ..< 24, may be fractional (7.5 is 7:30).
        public var hour: Double
        public var theme: String
        public init(hour: Double, theme: String) { self.hour = hour; self.theme = theme }
    }

    public var enabled = false
    public var slots: [Slot] = []
    public init(enabled: Bool = false, slots: [Slot] = []) { self.enabled = enabled; self.slots = slots }

    /// The theme due at `hour`: the last slot that started at or before it, wrapping past midnight.
    public func theme(at hour: Double) -> String? {
        let sorted = slots.filter { (0..<24).contains($0.hour) }.sorted { $0.hour < $1.hour }
        guard let last = sorted.last else { return nil }
        return (sorted.last { $0.hour <= hour } ?? last).theme
    }

    /// Whether anything changes between two readings of the clock, so the schedule only acts
    /// when a slot begins and never fights a Look the owner picked by hand in the meantime.
    public func change(from previous: Double, to now: Double) -> String? {
        guard enabled, previous != now else { return nil }
        let crossed = slots.contains { slot in
            previous < now ? (slot.hour > previous && slot.hour <= now) : (slot.hour > previous || slot.hour <= now)
        }
        return crossed ? theme(at: now) : nil
    }
}
