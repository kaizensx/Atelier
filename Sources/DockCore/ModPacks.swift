import AudioToolbox
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// MARK: - Mod packs: data-only mods
//
// Six kinds of mod carry data and nothing else: icon packs, sound packs, shader packs (live
// wallpapers described by numbers, never compiled code), snap layout packs, minimise effect
// packs and Looks (a theme plus packs and a wallpaper). No code in a pack ever runs. Each pack is
// a folder with one JSON manifest and its files, and every part of it is checked here before
// Atelier uses it: the manifest's keys and ranges, every path, every file's real format (by its
// first bytes, not its name), its size, an image's pixels and a sound's length.
//
// The rules are pure where they can be: `ModPacks.validate(_:source:)` takes the manifest and a
// description of the files, so the tests can feed it anything. `ModPacks.load(_:)` reads a real
// folder from disk (ImageIO for pictures, AudioToolbox for sounds) and then runs the same rules.

/// The data-only kinds. Their raw values are the `kind` the catalog's index uses.
public enum ModPackKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case icons, sounds, shader, layouts, effects, look

    public var id: String { rawValue }

    public var bundleExtension: String {
        switch self {
        case .icons: "ateliericons"
        case .sounds: "ateliersounds"
        case .shader: "ateliershader"
        case .layouts: "atelierlayouts"
        case .effects: "ateliereffects"
        case .look: "atelierlook"
        }
    }

    /// The manifest inside the folder.
    public var manifestName: String {
        switch self {
        case .icons: "atelier-icons.json"
        case .sounds: "atelier-sounds.json"
        case .shader: "atelier-shader.json"
        case .layouts: "atelier-layouts.json"
        case .effects: "atelier-effects.json"
        case .look: "atelier-look.json"
        }
    }

    public var title: String {
        switch self {
        case .icons: "Icon Pack"
        case .sounds: "Sound Pack"
        case .shader: "Shader"
        case .layouts: "Layouts"
        case .effects: "Effects"
        case .look: "Look"
        }
    }

    public var plural: String {
        switch self {
        case .icons: "Icon Packs"
        case .sounds: "Sound Packs"
        case .shader: "Shaders"
        case .layouts: "Layouts"
        case .effects: "Effects"
        case .look: "Looks"
        }
    }

    public var symbol: String {
        switch self {
        case .icons: "square.grid.3x3.fill"
        case .sounds: "speaker.wave.2"
        case .shader: "sparkles.tv"
        case .layouts: "rectangle.split.3x1"
        case .effects: "wand.and.rays"
        case .look: "theatermasks"
        }
    }

    /// The folder under Application Support/Atelier it installs into.
    public var folderName: String {
        switch self {
        case .icons: "IconPacks"
        case .sounds: "SoundPacks"
        case .shader: "ShaderPacks"
        case .layouts: "LayoutPacks"
        case .effects: "EffectPacks"
        case .look: "LookPacks"
        }
    }

    /// The largest zipped package the catalog accepts for this kind.
    public var maxPackageBytes: Int {
        switch self {
        case .icons: 60 * 1024 * 1024
        case .sounds: 20 * 1024 * 1024
        case .shader: 1024 * 1024
        case .layouts: 256 * 1024
        case .effects: 256 * 1024
        case .look: 80 * 1024 * 1024
        }
    }

    /// The largest folder on disk, whatever its zip was.
    public var maxBundleBytes: Int {
        switch self {
        case .icons: ModPackLimits.maxIcons * ModPackLimits.maxIconBytes / 4
        case .sounds: 40 * 1024 * 1024
        case .shader, .layouts, .effects: 1024 * 1024
        case .look: 200 * 1024 * 1024
        }
    }

    public static func of(extension ext: String) -> ModPackKind? {
        allCases.first { $0.bundleExtension == ext.lowercased() }
    }
}

extension ModKind {
    /// The pack kind of a data-only mod; nil for plugins, themes and native mods.
    public var pack: ModPackKind? { ModPackKind(rawValue: rawValue) }
    public init(_ pack: ModPackKind) { self = ModKind(rawValue: pack.rawValue) ?? .theme }
    public var isPack: Bool { pack != nil }
}

public enum ModPackLimits {
    public static let maxManifestBytes = 256 * 1024
    public static let maxIcons = 600
    public static let maxIconBytes = 1024 * 1024
    public static let minIconPixels = 256
    public static let maxSoundBytes = 1024 * 1024
    public static let maxUISoundSeconds = 2.0
    public static let maxTypingSeconds = 1.0
    public static let maxTypingVariants = 8
    public static let maxLayouts = 24
    public static let maxZones = 12
    /// A zone narrower or shorter than this share of the screen is degenerate.
    public static let minZoneSide = 0.05
    public static let maxEffects = 12
    public static let effectDuration: ClosedRange<Double> = 0.15...1.2
    public static let maxKeyframes = 16
    public static let maxWallpaperBytes = 20 * 1024 * 1024
    public static let minWallpaperPixels = 1024
}

// MARK: - Facts about the files

/// What Atelier learned about one file in a pack: its size and, read from its own bytes, what it
/// really is. Pixels are the shorter side of its largest picture; seconds a sound's length.
public struct ModPackFile: Equatable, Sendable {
    public enum Format: String, Sendable { case png, heic, icns, jpeg, wav, caf, m4a, json, other }
    public var bytes: Int
    public var format: Format
    public var pixels: Int?
    public var seconds: Double?

    public init(bytes: Int, format: Format, pixels: Int? = nil, seconds: Double? = nil) {
        self.bytes = bytes; self.format = format; self.pixels = pixels; self.seconds = seconds
    }

    public var isImage: Bool { [.png, .heic, .icns, .jpeg].contains(format) }
    public var isSound: Bool { [.wav, .caf, .m4a].contains(format) }

    /// The extension a path must have for each real format.
    static func extensions(_ format: Format) -> [String] {
        switch format {
        case .png: ["png"]
        case .heic: ["heic", "heif"]
        case .icns: ["icns"]
        case .jpeg: ["jpg", "jpeg"]
        case .wav: ["wav"]
        case .caf: ["caf"]
        case .m4a: ["m4a"]
        case .json: ["json"]
        case .other: []
        }
    }
}

/// A pack folder as the rules see it: every file with its facts, and a way to read one (for
/// the manifests of packs embedded in a Look). Paths are relative to the folder.
public struct ModPackSource {
    public var files: [String: ModPackFile]
    public var read: (String) -> Data?

    public init(files: [String: ModPackFile], read: @escaping (String) -> Data?) {
        self.files = files; self.read = read
    }

    /// The files of a folder inside this one, as their own source.
    func sub(_ folder: String) -> ModPackSource {
        let prefix = folder + "/"
        var inner: [String: ModPackFile] = [:]
        for (path, file) in files where path.hasPrefix(prefix) { inner[String(path.dropFirst(prefix.count))] = file }
        let read = self.read
        return ModPackSource(files: inner) { read(prefix + $0) }
    }
}

// MARK: - The packs

/// The fields every pack manifest starts with.
public struct ModPackHeader: Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var summary: String
}

public struct IconPack: Equatable, Sendable {
    /// Keys that are not bundle identifiers: the Dock's own tiles.
    public static let specialKeys = ["folder", "downloads", "trash", "trash.full"]
    public var header: ModPackHeader
    /// Bundle identifier (or a special key) to a path inside the pack.
    public var icons: [String: String]
}

/// The sounds Atelier plays that a sound pack may replace.
public enum SoundSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case dockLaunch = "dock.launch", dockDrop = "dock.drop", dockTrash = "dock.trash", dockMinimize = "dock.minimize"
    case timerDone = "timer.done", themeApply = "theme.apply"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dockLaunch: "Dock: app opens"
        case .dockDrop: "Dock: item dropped"
        case .dockTrash: "Dock: moved to Trash"
        case .dockMinimize: "Dock: window minimised"
        case .timerDone: "Timer or focus session ends"
        case .themeApply: "Theme applied"
        }
    }
}

/// The typing sound classes, the same five the built-in voices have.
public enum TypingSlot: String, CaseIterable, Codable, Sendable {
    case key, space, `return`, backspace, modifier

    public var keyClass: TypingKeyClass {
        switch self {
        case .key: .key
        case .space: .space
        case .return: .returnKey
        case .backspace: .backspace
        case .modifier: .modifier
        }
    }
}

public struct SoundPack: Equatable, Sendable {
    public var header: ModPackHeader
    public var sounds: [SoundSlot: String]
    /// Variants per class. When present, `key` is always there; the others fall back to it.
    public var typing: [TypingSlot: [String]]

    public var hasTyping: Bool { typing[.key]?.isEmpty == false }

    /// The variants a typing class plays, with the fallback to `key`.
    public func variants(_ slot: TypingSlot) -> [String] { typing[slot] ?? typing[.key] ?? [] }
}

/// A live wallpaper as numbers: one of Atelier's shaders, recoloured and retuned. Nothing is
/// compiled; the engine draws the base shader with these values, exactly as the controls in
/// Live Wallpaper would set them.
public struct ShaderPack: Equatable, Sendable {
    /// The shaders a pack may start from. The ones that draw over the owner's own wallpaper
    /// picture are left out: a pack must look the same on every Mac.
    public static let bases = ["liquidLight", "nebula", "auroraSilk", "topography", "glassRain", "silkWaves",
                               "gradientMesh", "starfield", "retroHorizon", "oceanCaustics", "northernLights",
                               "lavaLamp", "inkInWater", "fireflies", "liquidChrome"]
    public static let cycles = ["clock", "day", "dusk", "night"]
    public static let speedRange: ClosedRange<Double> = 0.2...2.5
    public static let scaleRange: ClosedRange<Double> = 0.6...1.8
    public static let dimRange: ClosedRange<Double> = 0...0.7

    public var header: ModPackHeader
    public var base: String
    /// Four stops, darkest first, or empty for the shader's own colours.
    public var palette: [ThemeColor]
    public var speed: Double
    public var intensity: Double
    public var grain: Double
    public var scale: Double
    public var dim: Double
    public var cycle: String
    public var pointer: Bool
}

public struct LayoutPack: Equatable, Sendable {
    public var header: ModPackHeader
    /// With ids derived from the pack's id, so adding the pack twice replaces, never duplicates.
    public var layouts: [CustomLayout]

    /// A stable id for the pack's layout at `index`.
    public static func layoutID(pack: String, index: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(pack)#\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public struct EffectPack: Equatable, Sendable {
    public var header: ModPackHeader
    public var effects: [PackMinimizeEffect]
}

/// One value over the effect's progress: t from 0 to 1, values between points are linear.
public struct PackKeyframe: Equatable, Sendable {
    public var t: Double
    public var value: Double
    public init(_ t: Double, _ value: Double) { self.t = t; self.value = value }
}

public enum PackCurve: String, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut, spring

    /// Progress along the effect for a share of its time. Spring overshoots a little and settles.
    public func apply(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .spring: return t >= 1 ? 1 : 1 - exp(-6 * t) * cos(9 * t)
        }
    }
}

/// A minimise effect described as numbers on top of one of the built-in meshes: a progress
/// curve, keyframes for opacity, scale, blur and shade, and an optional twist and wave.
public struct PackMinimizeEffect: Equatable, Sendable, Identifiable {
    public static let opacityRange: ClosedRange<Double> = 0...1
    public static let scaleRange: ClosedRange<Double> = 0.05...3
    public static let blurRange: ClosedRange<Double> = 0...8
    public static let shadeRange: ClosedRange<Double> = 0...2
    public static let twistRange: ClosedRange<Double> = -720...720
    public static let waveAmplitudeRange: ClosedRange<Double> = 0...0.2
    public static let waveFrequencyRange: ClosedRange<Double> = 0...8
    /// The built-in meshes an effect may start from.
    public static let bases: [MinimizeEffect] = [.genie, .scale, .suck, .lamp, .fold, .dissolve, .portal, .shatter, .liquid]

    public var id: String
    public var name: String
    public var base: MinimizeEffect
    public var duration: Double
    public var curve: PackCurve
    public var opacity: [PackKeyframe]
    public var scale: [PackKeyframe]
    public var blur: [PackKeyframe]
    public var shade: [PackKeyframe]
    /// Degrees turned by the end.
    public var twist: Double
    /// A share of the window's size, and waves across it.
    public var waveAmplitude: Double
    public var waveFrequency: Double

    public init(id: String, name: String, base: MinimizeEffect, duration: Double, curve: PackCurve = .easeInOut,
                opacity: [PackKeyframe] = [], scale: [PackKeyframe] = [], blur: [PackKeyframe] = [], shade: [PackKeyframe] = [],
                twist: Double = 0, waveAmplitude: Double = 0, waveFrequency: Double = 0) {
        self.id = id; self.name = name; self.base = base; self.duration = duration; self.curve = curve
        self.opacity = opacity; self.scale = scale; self.blur = blur; self.shade = shade
        self.twist = twist; self.waveAmplitude = waveAmplitude; self.waveFrequency = waveFrequency
    }

    /// The value of a track at t. An empty track is `rest` throughout.
    public static func sample(_ track: [PackKeyframe], at t: Double, rest: Double) -> Double {
        guard let first = track.first else { return rest }
        if t <= first.t { return first.value }
        for (a, b) in zip(track, track.dropFirst()) where t <= b.t {
            let span = max(b.t - a.t, 1e-9)
            return a.value + (b.value - a.value) * (t - a.t) / span
        }
        return track.last?.value ?? rest
    }

    /// Seconds, with the same restore and slow-motion rules as the built-in effects.
    public func duration(restoring: Bool, slow: Bool) -> Double {
        (restoring ? duration * 0.92 : duration) * (slow ? MinimizeTiming.slowMotion : 1)
    }

    /// Progress at a time into the animation. Restoring plays the same curve backwards in time,
    /// so the way back is the exact reverse of the way in.
    public func progress(elapsed: Double, duration: Double, restoring: Bool) -> Double {
        let x = min(max(elapsed / max(duration, 0.001), 0), 1)
        return restoring ? curve.apply(1 - x) : curve.apply(x)
    }

    /// The mesh at a progress: the base mesh, then scale, twist and wave around its centre,
    /// opacity and shade per vertex, and the blur for the whole frame.
    public func mesh(progress: Double, geometry g: MinimizeGeometry) -> MinimizeMesh {
        let t = min(max(progress, 0), 1)
        var mesh = MinimizeEffects.mesh(base, progress: t, geometry: g)
        guard !mesh.vertices.isEmpty else { return mesh }
        let s = Self.sample(scale, at: t, rest: 1)
        let o = Self.sample(opacity, at: t, rest: 1)
        let h = Self.sample(shade, at: t, rest: 1)
        let angle = twist * t * .pi / 180
        // Taper to nothing at both ends, so the first frame is the window and the last the tile.
        let wave = waveAmplitude * sin(.pi * t)
        var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
        for v in mesh.vertices { minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y) }
        let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
        let (sine, cosine) = (sin(angle), cos(angle))
        for index in mesh.vertices.indices {
            var v = mesh.vertices[index]
            var dx = (Double(v.x) - cx) * s, dy = (Double(v.y) - cy) * s
            if angle != 0 { (dx, dy) = (dx * cosine - dy * sine, dx * sine + dy * cosine) }
            if wave != 0 {
                dx += wave * g.window.width * sin(2 * .pi * (waveFrequency * Double(v.v) + t))
                dy += wave * g.window.height * 0.5 * sin(2 * .pi * (waveFrequency * Double(v.u) + t))
            }
            v.x = Float(cx + dx); v.y = Float(cy + dy)
            v.alpha *= Float(min(max(o, 0), 1))
            v.shade *= Float(h)
            mesh.vertices[index] = v
        }
        mesh.blur = Float(min(max(Self.sample(blur, at: t, rest: 0), 0), Self.blurRange.upperBound))
        return mesh
    }
}

/// A reference from a Look to a pack: one inside the Look's folder, or one installed by id.
public enum PackReference: Equatable, Sendable {
    case embedded(String)
    case installed(String)
}

/// The Dock settings a Look may set. Everything else about the Dock comes from its theme.
public struct LookDock: Equatable, Sendable {
    public static let edges = ["bottom", "left", "right", "top"]
    public static let tileRange: ClosedRange<Double> = 24...128
    public static let magnifiedRange: ClosedRange<Double> = 32...256
    public var edge: String?
    public var tileSize: Double?
    public var magnifiedSize: Double?
    public var magnification: Bool?
    public var autohide: Bool?

    public init(edge: String? = nil, tileSize: Double? = nil, magnifiedSize: Double? = nil, magnification: Bool? = nil, autohide: Bool? = nil) {
        self.edge = edge; self.tileSize = tileSize; self.magnifiedSize = magnifiedSize; self.magnification = magnification; self.autohide = autohide
    }

    public var isEmpty: Bool { self == LookDock() }
}

public struct LookPack: Equatable, Sendable {
    public var header: ModPackHeader
    /// The `.ateliertheme` folder inside the Look.
    public var theme: String
    /// A picture inside the Look.
    public var wallpaperImage: String?
    /// A shader pack, inside the Look or installed.
    public var wallpaperShader: PackReference?
    public var dock: LookDock
    public var iconPack: PackReference?
    public var soundPack: PackReference?
}

public enum ModPack: Equatable, Sendable {
    case icons(IconPack), sounds(SoundPack), shader(ShaderPack), layouts(LayoutPack), effects(EffectPack), look(LookPack)

    public var kind: ModPackKind {
        switch self {
        case .icons: .icons
        case .sounds: .sounds
        case .shader: .shader
        case .layouts: .layouts
        case .effects: .effects
        case .look: .look
        }
    }

    public var header: ModPackHeader {
        switch self {
        case .icons(let p): p.header
        case .sounds(let p): p.header
        case .shader(let p): p.header
        case .layouts(let p): p.header
        case .effects(let p): p.header
        case .look(let p): p.header
        }
    }
}

/// What the rules found. Errors stop a pack; warnings are shown and the pack is used.
public struct ModPackReport: Equatable, Sendable {
    public var errors: [String] = []
    public var warnings: [String] = []
    public var isValid: Bool { errors.isEmpty }
    public var summary: String { errors.joined(separator: " ") }
    mutating func error(_ text: String) { errors.append(text) }
    mutating func warn(_ text: String) { warnings.append(text) }
}

// MARK: - The rules

public enum ModPacks {
    /// Validates a pack folder described by `source`. Returns the pack only when it has no errors.
    public static func validate(_ kind: ModPackKind, source: ModPackSource) -> (ModPack?, ModPackReport) {
        var report = ModPackReport()
        guard let file = source.files[kind.manifestName], let data = source.read(kind.manifestName) else {
            report.error("The pack has no \(kind.manifestName).")
            return (nil, report)
        }
        guard file.bytes <= ModPackLimits.maxManifestBytes, data.count <= ModPackLimits.maxManifestBytes else {
            report.error("\(kind.manifestName) is larger than \(ModPackLimits.maxManifestBytes / 1024) KB.")
            return (nil, report)
        }
        guard let root = (try? JSONValue.parse(data))?.object else {
            report.error("\(kind.manifestName) is not a JSON object.")
            return (nil, report)
        }
        let total = source.files.values.reduce(0) { $0 + $1.bytes }
        if total > kind.maxBundleBytes { report.error("The pack is \(total / 1_048_576) MB; the limit is \(kind.maxBundleBytes / 1_048_576) MB.") }
        let pack: ModPack?
        switch kind {
        case .icons: pack = icons(root, source, &report).map(ModPack.icons)
        case .sounds: pack = sounds(root, source, &report).map(ModPack.sounds)
        case .shader: pack = shader(root, &report).map(ModPack.shader)
        case .layouts: pack = layouts(root, &report).map(ModPack.layouts)
        case .effects: pack = effects(root, &report).map(ModPack.effects)
        case .look: pack = look(root, source, &report).map(ModPack.look)
        }
        return (report.isValid ? pack : nil, report)
    }

    // MARK: Header

    static let headerKeys: Set<String> = ["format", "id", "name", "version", "author", "description"]

    static func header(_ root: [String: JSONValue], kind: ModPackKind, allowed: Set<String>, _ report: inout ModPackReport) -> ModPackHeader? {
        let name = kind.manifestName
        for key in root.keys.sorted() where !headerKeys.contains(key) && !allowed.contains(key) && !key.hasPrefix("x-") {
            report.error("\(name): unknown key \"\(key)\".")
        }
        guard root["format"]?.number == 1 else { report.error("\(name) needs \"format\": 1."); return nil }
        guard let id = root["id"]?.string, ThemeIdentifier.isValid(id) else {
            report.error("\(name) needs a reverse-DNS \"id\", like com.example.my-pack."); return nil
        }
        guard let version = root["version"]?.string, AppVersion(version) != nil else {
            report.error("\(name) needs a \"version\" like 1.0.0."); return nil
        }
        let title = (root["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 60 else { report.error("\(name) needs a \"name\" of 1 to 60 characters."); return nil }
        let author = root["author"]?.string ?? ""
        if author.count > 80 { report.error("\(name): the author is longer than 80 characters.") }
        let summary = root["description"]?.string ?? ""
        if summary.count > 400 { report.error("\(name): the description is longer than 400 characters.") }
        return ModPackHeader(id: id, name: title, version: version, author: author, summary: summary)
    }

    static func checkPath(_ path: String, in source: ModPackSource, label: String, _ report: inout ModPackReport) -> ModPackFile? {
        guard ThemeIdentifier.isSafeRelativePath(path) else { report.error("\(label): \"\(path)\" is not a path inside the pack."); return nil }
        guard let file = source.files[path] else { report.error("\(label): \(path) is not in the pack."); return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if !ModPackFile.extensions(file.format).contains(ext) {
            report.error("\(label): \(path) is not really a .\(ext) file.")
            return nil
        }
        return file
    }

    static func number(_ value: JSONValue?, _ range: ClosedRange<Double>, label: String, _ report: inout ModPackReport) -> Double? {
        guard let value else { return nil }
        guard let n = value.number, n.isFinite else { report.error("\(label) must be a number."); return nil }
        guard range.contains(n) else { report.error("\(label) must be between \(range.lowerBound) and \(range.upperBound).") ; return nil }
        return n
    }

    // MARK: Icons

    static func isBundleIdentifier(_ text: String) -> Bool {
        guard (3...155).contains(text.count) else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    static func icons(_ root: [String: JSONValue], _ source: ModPackSource, _ report: inout ModPackReport) -> IconPack? {
        guard let header = header(root, kind: .icons, allowed: ["icons"], &report) else { return nil }
        guard let map = root["icons"]?.object, !map.isEmpty else { report.error("\"icons\" must map bundle identifiers to pictures."); return nil }
        if map.count > ModPackLimits.maxIcons { report.error("The pack has \(map.count) icons; the limit is \(ModPackLimits.maxIcons).") }
        var icons: [String: String] = [:]
        for key in map.keys.sorted() {
            guard IconPack.specialKeys.contains(key) || isBundleIdentifier(key) else {
                report.error("icons: \"\(key)\" is not a bundle identifier or one of \(IconPack.specialKeys.joined(separator: ", "))."); continue
            }
            guard let path = map[key]?.string else { report.error("icons.\(key) must be a path."); continue }
            guard let file = checkPath(path, in: source, label: "icons.\(key)", &report) else { continue }
            guard [.png, .heic, .icns].contains(file.format) else { report.error("icons.\(key): \(path) must be PNG, HEIC or ICNS."); continue }
            if file.bytes > ModPackLimits.maxIconBytes { report.error("icons.\(key): \(path) is larger than 1 MB.") }
            guard let pixels = file.pixels else { report.error("icons.\(key): \(path) could not be read as a picture."); continue }
            if pixels < ModPackLimits.minIconPixels { report.error("icons.\(key): \(path) is \(pixels) px; icons need at least \(ModPackLimits.minIconPixels) px.") }
            icons[key] = path
        }
        return IconPack(header: header, icons: icons)
    }

    // MARK: Sounds

    static func sound(_ path: String, in source: ModPackSource, label: String, limit: Double, _ report: inout ModPackReport) -> Bool {
        guard let file = checkPath(path, in: source, label: label, &report) else { return false }
        guard file.isSound else { report.error("\(label): \(path) must be CAF, M4A or WAV."); return false }
        if file.bytes > ModPackLimits.maxSoundBytes { report.error("\(label): \(path) is larger than 1 MB."); return false }
        guard let seconds = file.seconds, seconds > 0 else { report.error("\(label): \(path) could not be read as a sound."); return false }
        if seconds > limit + 0.01 { report.error("\(label): \(path) is \(String(format: "%.2f", seconds)) s; the limit is \(limit) s."); return false }
        return true
    }

    static func sounds(_ root: [String: JSONValue], _ source: ModPackSource, _ report: inout ModPackReport) -> SoundPack? {
        guard let header = header(root, kind: .sounds, allowed: ["sounds", "typing"], &report) else { return nil }
        var sounds: [SoundSlot: String] = [:], typing: [TypingSlot: [String]] = [:]
        if let value = root["sounds"] {
            guard let map = value.object else { report.error("\"sounds\" must be an object."); return nil }
            for key in map.keys.sorted() {
                guard let slot = SoundSlot(rawValue: key) else {
                    report.error("sounds: \"\(key)\" is not a sound Atelier plays. Use \(SoundSlot.allCases.map(\.rawValue).joined(separator: ", "))."); continue
                }
                guard let path = map[key]?.string else { report.error("sounds.\(key) must be a path."); continue }
                if sound(path, in: source, label: "sounds.\(key)", limit: ModPackLimits.maxUISoundSeconds, &report) { sounds[slot] = path }
            }
        }
        if let value = root["typing"] {
            guard let map = value.object else { report.error("\"typing\" must be an object."); return nil }
            for key in map.keys.sorted() {
                guard let slot = TypingSlot(rawValue: key) else {
                    report.error("typing: \"\(key)\" is not a key class. Use \(TypingSlot.allCases.map(\.rawValue).joined(separator: ", "))."); continue
                }
                guard let list = map[key]?.array, (1...ModPackLimits.maxTypingVariants).contains(list.count) else {
                    report.error("typing.\(key) must list 1 to \(ModPackLimits.maxTypingVariants) sounds."); continue
                }
                var paths: [String] = []
                for (i, item) in list.enumerated() {
                    guard let path = item.string else { report.error("typing.\(key)[\(i)] must be a path."); continue }
                    if sound(path, in: source, label: "typing.\(key)[\(i)]", limit: ModPackLimits.maxTypingSeconds, &report) { paths.append(path) }
                }
                typing[slot] = paths
            }
            if typing[.key] == nil { report.error("typing needs at least \"key\"; the other classes fall back to it.") }
        }
        if sounds.isEmpty, typing.isEmpty, report.isValid { report.error("The pack has no sounds.") }
        return SoundPack(header: header, sounds: sounds, typing: typing)
    }

    // MARK: Shader

    static func shader(_ root: [String: JSONValue], _ report: inout ModPackReport) -> ShaderPack? {
        let keys: Set<String> = ["base", "palette", "speed", "intensity", "grain", "scale", "dim", "cycle", "pointer"]
        guard let header = header(root, kind: .shader, allowed: keys, &report) else { return nil }
        guard let base = root["base"]?.string, ShaderPack.bases.contains(base) else {
            report.error("\"base\" must be one of \(ShaderPack.bases.joined(separator: ", "))."); return nil
        }
        var palette: [ThemeColor] = []
        if let value = root["palette"] {
            let colors = value.array?.compactMap { $0.string.flatMap(ThemeColor.init(hex:)) } ?? []
            if colors.count != 4 || value.array?.count != 4 { report.error("\"palette\" must be four colours like \"#1B2A55\", darkest first.") }
            else { palette = colors }
        }
        let speed = number(root["speed"], ShaderPack.speedRange, label: "speed", &report) ?? 1
        let intensity = number(root["intensity"], 0...1, label: "intensity", &report) ?? 0.5
        let grain = number(root["grain"], 0...1, label: "grain", &report) ?? 0
        let scale = number(root["scale"], ShaderPack.scaleRange, label: "scale", &report) ?? 1
        let dim = number(root["dim"], ShaderPack.dimRange, label: "dim", &report) ?? 0
        let cycle = root["cycle"]?.string ?? "clock"
        if !ShaderPack.cycles.contains(cycle) { report.error("\"cycle\" must be one of \(ShaderPack.cycles.joined(separator: ", ")).") }
        if let value = root["pointer"], value.bool == nil { report.error("\"pointer\" must be true or false.") }
        return ShaderPack(header: header, base: base, palette: palette, speed: speed, intensity: intensity, grain: grain,
                          scale: scale, dim: dim, cycle: cycle, pointer: root["pointer"]?.bool ?? true)
    }

    // MARK: Layouts

    /// A zone must have room, and stay on the screen.
    public static func zoneProblem(_ zone: ZoneRect) -> String? {
        let values = [zone.x, zone.y, zone.width, zone.height]
        guard values.allSatisfy(\.isFinite) else { return "has a value that is not a number" }
        guard zone.x >= 0, zone.y >= 0, zone.x <= 1, zone.y <= 1 else { return "starts outside 0…1" }
        guard zone.width >= ModPackLimits.minZoneSide, zone.height >= ModPackLimits.minZoneSide else {
            return "is narrower or shorter than \(ModPackLimits.minZoneSide)"
        }
        guard zone.x + zone.width <= 1.0001, zone.y + zone.height <= 1.0001 else { return "reaches past the edge of the screen" }
        return nil
    }

    static func layouts(_ root: [String: JSONValue], _ report: inout ModPackReport) -> LayoutPack? {
        guard let header = header(root, kind: .layouts, allowed: ["layouts"], &report) else { return nil }
        guard let list = root["layouts"]?.array, !list.isEmpty else { report.error("\"layouts\" must list at least one layout."); return nil }
        if list.count > ModPackLimits.maxLayouts { report.error("The pack has \(list.count) layouts; the limit is \(ModPackLimits.maxLayouts).") }
        var layouts: [CustomLayout] = []
        for (i, item) in list.prefix(ModPackLimits.maxLayouts).enumerated() {
            guard let object = item.object else { report.error("layouts[\(i)] must be an object."); continue }
            for key in object.keys where !["name", "zones"].contains(key) { report.error("layouts[\(i)]: unknown key \"\(key)\".") }
            let name = (object["name"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.count > 40 { report.error("layouts[\(i)] needs a name of 1 to 40 characters.") }
            guard let zones = object["zones"]?.array, (1...ModPackLimits.maxZones).contains(zones.count) else {
                report.error("layouts[\(i)] needs 1 to \(ModPackLimits.maxZones) zones."); continue
            }
            var rects: [ZoneRect] = []
            for (j, zone) in zones.enumerated() {
                guard let z = zone.object, let x = z["x"]?.number, let y = z["y"]?.number,
                      let w = z["width"]?.number, let h = z["height"]?.number, z.count == 4 else {
                    report.error("layouts[\(i)].zones[\(j)] must be {\"x\", \"y\", \"width\", \"height\"}."); continue
                }
                let rect = ZoneRect(x: x, y: y, width: w, height: h)
                if let problem = zoneProblem(rect) { report.error("layouts[\(i)].zones[\(j)] \(problem)."); continue }
                if rects.contains(rect) { report.error("layouts[\(i)].zones[\(j)] repeats another zone.") }
                rects.append(rect)
            }
            layouts.append(CustomLayout(id: LayoutPack.layoutID(pack: header.id, index: i), name: name, zones: rects))
        }
        return LayoutPack(header: header, layouts: layouts)
    }

    // MARK: Effects

    static func keyframes(_ value: JSONValue?, range: ClosedRange<Double>, rest: Double, label: String, _ report: inout ModPackReport) -> [PackKeyframe] {
        guard let value else { return [] }
        guard let list = value.array, (2...ModPackLimits.maxKeyframes).contains(list.count) else {
            report.error("\(label) must list 2 to \(ModPackLimits.maxKeyframes) [t, value] pairs."); return []
        }
        var frames: [PackKeyframe] = []
        for (i, item) in list.enumerated() {
            guard let pair = item.array, pair.count == 2, let t = pair[0].number, let v = pair[1].number, t.isFinite, v.isFinite else {
                report.error("\(label)[\(i)] must be [t, value]."); return []
            }
            guard (0...1).contains(t) else { report.error("\(label)[\(i)]: t must be between 0 and 1."); return [] }
            guard range.contains(v) else { report.error("\(label)[\(i)]: the value must be between \(range.lowerBound) and \(range.upperBound)."); return [] }
            if let last = frames.last, t <= last.t { report.error("\(label): t must increase from one point to the next."); return [] }
            frames.append(PackKeyframe(t, v))
        }
        if frames.first?.t != 0 || frames.last?.t != 1 { report.error("\(label) must start at t 0 and end at t 1."); return [] }
        // Frame 0 is drawn over the real window, so it must be the window exactly.
        if frames.first?.value != rest { report.error("\(label) must start at \(rest), so the first frame is the window itself."); return [] }
        return frames
    }

    static func effects(_ root: [String: JSONValue], _ report: inout ModPackReport) -> EffectPack? {
        guard let header = header(root, kind: .effects, allowed: ["effects"], &report) else { return nil }
        guard let list = root["effects"]?.array, !list.isEmpty else { report.error("\"effects\" must list at least one effect."); return nil }
        if list.count > ModPackLimits.maxEffects { report.error("The pack has \(list.count) effects; the limit is \(ModPackLimits.maxEffects).") }
        let allowed: Set<String> = ["id", "name", "base", "duration", "curve", "opacity", "scale", "blur", "shade", "twist", "wave"]
        var effects: [PackMinimizeEffect] = [], ids = Set<String>()
        for (i, item) in list.prefix(ModPackLimits.maxEffects).enumerated() {
            let label = "effects[\(i)]"
            guard let e = item.object else { report.error("\(label) must be an object."); continue }
            for key in e.keys.sorted() where !allowed.contains(key) { report.error("\(label): unknown key \"\(key)\".") }
            let id = e["id"]?.string ?? ""
            guard (1...40).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                report.error("\(label) needs an \"id\" of letters, digits and hyphens."); continue
            }
            if !ids.insert(id).inserted { report.error("\(label): the id \"\(id)\" is used twice.") }
            let name = (e["name"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.count > 40 { report.error("\(label) needs a name of 1 to 40 characters.") }
            guard let base = e["base"]?.string.flatMap(MinimizeEffect.init(rawValue:)), PackMinimizeEffect.bases.contains(base) else {
                report.error("\(label).base must be one of \(PackMinimizeEffect.bases.map(\.rawValue).joined(separator: ", "))."); continue
            }
            guard e["duration"] != nil else { report.error("\(label).duration is required, in seconds (0.15 to 1.2)."); continue }
            guard let duration = number(e["duration"], ModPackLimits.effectDuration, label: "\(label).duration", &report) else { continue }
            let curve = e["curve"].map { $0.string.flatMap(PackCurve.init(rawValue:)) } ?? .easeInOut
            if curve == nil { report.error("\(label).curve must be one of \(PackCurve.allCases.map(\.rawValue).joined(separator: ", ")).") }
            let opacity = keyframes(e["opacity"], range: PackMinimizeEffect.opacityRange, rest: 1, label: "\(label).opacity", &report)
            let scale = keyframes(e["scale"], range: PackMinimizeEffect.scaleRange, rest: 1, label: "\(label).scale", &report)
            let blur = keyframes(e["blur"], range: PackMinimizeEffect.blurRange, rest: 0, label: "\(label).blur", &report)
            let shade = keyframes(e["shade"], range: PackMinimizeEffect.shadeRange, rest: 1, label: "\(label).shade", &report)
            let twist = number(e["twist"], PackMinimizeEffect.twistRange, label: "\(label).twist", &report) ?? 0
            var amplitude = 0.0, frequency = 0.0
            if let wave = e["wave"] {
                if let w = wave.object, Set(w.keys).isSubset(of: ["amplitude", "frequency"]) {
                    amplitude = number(w["amplitude"], PackMinimizeEffect.waveAmplitudeRange, label: "\(label).wave.amplitude", &report) ?? 0
                    frequency = number(w["frequency"], PackMinimizeEffect.waveFrequencyRange, label: "\(label).wave.frequency", &report) ?? 1
                } else {
                    report.error("\(label).wave must be {\"amplitude\", \"frequency\"}.")
                }
            }
            effects.append(PackMinimizeEffect(id: id, name: name, base: base, duration: duration, curve: curve ?? .easeInOut,
                                              opacity: opacity, scale: scale, blur: blur, shade: shade, twist: twist,
                                              waveAmplitude: amplitude, waveFrequency: frequency))
        }
        return EffectPack(header: header, effects: effects)
    }

    // MARK: Look

    static func reference(_ value: JSONValue?, kind: ModPackKind, label: String, source: ModPackSource, _ report: inout ModPackReport) -> PackReference? {
        guard let value else { return nil }
        guard let text = value.string else { report.error("\(label) must be a pack id or a .\(kind.bundleExtension) folder in the Look."); return nil }
        if text.lowercased().hasSuffix("." + kind.bundleExtension) {
            guard ThemeIdentifier.isSafeRelativePath(text), !text.contains("/") else { report.error("\(label): \"\(text)\" must sit at the top of the Look."); return nil }
            let inner = source.sub(text)
            guard !inner.files.isEmpty else { report.error("\(label): \(text) is not in the Look."); return nil }
            let (_, sub) = validate(kind, source: inner)
            for error in sub.errors { report.error("\(text): \(error)") }
            for warning in sub.warnings { report.warn("\(text): \(warning)") }
            return sub.isValid ? .embedded(text) : nil
        }
        guard ThemeIdentifier.isValid(text) else { report.error("\(label): \"\(text)\" is neither a pack id nor a .\(kind.bundleExtension) folder."); return nil }
        return .installed(text)
    }

    static func look(_ root: [String: JSONValue], _ source: ModPackSource, _ report: inout ModPackReport) -> LookPack? {
        guard let header = header(root, kind: .look, allowed: ["theme", "wallpaper", "dock", "iconPack", "soundPack"], &report) else { return nil }
        guard let theme = root["theme"]?.string, theme.lowercased().hasSuffix("." + ThemeSchema.bundleExtension),
              ThemeIdentifier.isSafeRelativePath(theme), !theme.contains("/") else {
            report.error("\"theme\" must name the .\(ThemeSchema.bundleExtension) folder at the top of the Look."); return nil
        }
        let themeSource = source.sub(theme)
        if let data = themeSource.read(ThemeSchema.fileName), themeSource.files[ThemeSchema.fileName] != nil {
            let (_, validation) = ThemeValidator.validate(data: data, files: Set(themeSource.files.keys))
            for issue in validation.errors { report.error("\(theme): \(issue.description)") }
        } else {
            report.error("\(theme) has no \(ThemeSchema.fileName).")
        }
        var image: String?, shader: PackReference?
        if let value = root["wallpaper"] {
            guard let w = value.object, w.count == 1, let key = w.keys.first, ["image", "shader"].contains(key) else {
                report.error("\"wallpaper\" must be {\"image\": path} or {\"shader\": pack}."); return nil
            }
            if key == "image", let path = w["image"]?.string {
                if let file = checkPath(path, in: source, label: "wallpaper.image", &report) {
                    if ![.png, .heic, .jpeg].contains(file.format) { report.error("wallpaper.image must be PNG, HEIC or JPEG.") }
                    if file.bytes > ModPackLimits.maxWallpaperBytes { report.error("wallpaper.image is larger than 20 MB.") }
                    if (file.pixels ?? 0) < ModPackLimits.minWallpaperPixels / 2 { report.error("wallpaper.image is too small to fill a screen.") }
                    image = path
                }
            } else {
                shader = reference(w["shader"], kind: .shader, label: "wallpaper.shader", source: source, &report)
            }
        }
        var dock = LookDock()
        if let value = root["dock"] {
            guard let d = value.object else { report.error("\"dock\" must be an object."); return nil }
            for key in d.keys.sorted() where !["edge", "tileSize", "magnifiedSize", "magnification", "autohide"].contains(key) {
                report.error("dock: unknown key \"\(key)\".")
            }
            if let edge = d["edge"] {
                if let e = edge.string, LookDock.edges.contains(e) { dock.edge = e } else { report.error("dock.edge must be bottom, left, right or top.") }
            }
            dock.tileSize = number(d["tileSize"], LookDock.tileRange, label: "dock.tileSize", &report)
            dock.magnifiedSize = number(d["magnifiedSize"], LookDock.magnifiedRange, label: "dock.magnifiedSize", &report)
            for key in ["magnification", "autohide"] where d[key] != nil && d[key]?.bool == nil { report.error("dock.\(key) must be true or false.") }
            dock.magnification = d["magnification"]?.bool
            dock.autohide = d["autohide"]?.bool
            if let tile = dock.tileSize, let large = dock.magnifiedSize, large < tile { report.error("dock.magnifiedSize must not be smaller than dock.tileSize.") }
        }
        let icons = reference(root["iconPack"], kind: .icons, label: "iconPack", source: source, &report)
        let sounds = reference(root["soundPack"], kind: .sounds, label: "soundPack", source: source, &report)
        return LookPack(header: header, theme: theme, wallpaperImage: image, wallpaperShader: shader, dock: dock,
                        iconPack: icons, soundPack: sounds)
    }
}

// MARK: - Reading a folder from disk

public enum ModPackDisk {
    /// The real format of a file, from its first bytes.
    public static func sniff(_ head: Data) -> ModPackFile.Format {
        let b = [UInt8](head.prefix(16))
        func ascii(_ range: Range<Int>) -> String { range.upperBound <= b.count ? String(bytes: b[range], encoding: .ascii) ?? "" : "" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii(0..<4) == "icns" { return .icns }
        if ascii(0..<4) == "caff" { return .caf }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return .wav }
        if ascii(4..<8) == "ftyp" {
            let brand = ascii(8..<12)
            if ["heic", "heix", "mif1", "msf1", "heim", "heis", "hevc", "hevx"].contains(brand) { return .heic }
            if ["M4A ", "M4B ", "mp42", "isom", "mp41"].contains(brand) { return .m4a }
        }
        if let first = b.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }), first == UInt8(ascii: "{") { return .json }
        return .other
    }

    /// The shorter side of the largest picture in an image file (an ICNS holds several).
    public static func pixels(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var best = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            best = max(best, min(w, h))
        }
        return best > 0 ? best : nil
    }

    /// A sound's length in seconds, read from its headers.
    public static func seconds(_ url: URL) -> Double? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var duration = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr, duration.isFinite else { return nil }
        return duration
    }

    /// Every regular file in a folder with its facts. Links, and anything that is not a plain
    /// file, make the whole folder unusable; hidden files are skipped.
    public static func inventory(_ folder: URL) throws -> [String: ModPackFile] {
        var files: [String: ModPackFile] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [:] }
        var count = 0
        while let url = walker.nextObject() as? URL {
            count += 1
            if count > 5_000 { throw ModCatalogError.package("The pack holds too many files.") }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw ModCatalogError.package("The pack contains a link, which is not allowed.") }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == "__MACOSX" {
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw ModCatalogError.package("The pack contains something that is not a file.") }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { throw ModCatalogError.package("The pack reaches outside its folder.") }
            let relative = String(path.dropFirst(base.count))
            let bytes = values.fileSize ?? 0
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 16)
            } ?? Data()
            var file = ModPackFile(bytes: bytes, format: sniff(head))
            // Only files small enough to be used are decoded at all.
            if file.isImage, bytes <= ModPackLimits.maxWallpaperBytes { file.pixels = pixels(url) }
            if file.isSound, bytes <= ModPackLimits.maxSoundBytes { file.seconds = seconds(url) }
            files[relative] = file
        }
        return files
    }

    public static func source(_ folder: URL) throws -> ModPackSource {
        let files = try inventory(folder)
        return ModPackSource(files: files) { path in
            guard ThemeIdentifier.isSafeRelativePath(path), let file = files[path], file.bytes <= ModPackLimits.maxManifestBytes else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(path))
        }
    }

    /// Reads and checks a pack folder. The kind comes from the folder's extension unless given.
    public static func load(_ folder: URL, kind: ModPackKind? = nil) -> Result<(ModPack, ModPackReport), ModCatalogError> {
        guard let kind = kind ?? ModPackKind.of(extension: folder.pathExtension) else {
            return .failure(.package("\(folder.lastPathComponent) is not a pack Atelier knows."))
        }
        let source: ModPackSource
        do { source = try self.source(folder) } catch {
            return .failure((error as? ModCatalogError) ?? .package(error.localizedDescription))
        }
        let (pack, report) = ModPacks.validate(kind, source: source)
        guard let pack else { return .failure(.package(report.summary.isEmpty ? "The pack is not valid." : report.summary)) }
        return .success((pack, report))
    }
}
