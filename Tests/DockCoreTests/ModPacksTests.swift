import CoreGraphics
import Foundation
import Testing
@testable import DockCore

// MARK: Helpers

private let png = ModPackFile(bytes: 40_000, format: .png, pixels: 512)
private let wav = ModPackFile(bytes: 20_000, format: .wav, seconds: 0.4)

/// A pack source in memory: the manifest as text plus file facts.
private func source(_ kind: ModPackKind, _ manifest: String, files: [String: ModPackFile] = [:], extra: [String: String] = [:]) -> ModPackSource {
    var all = files
    var texts = extra
    texts[kind.manifestName] = manifest
    for (path, text) in texts { all[path] = ModPackFile(bytes: text.utf8.count, format: .json) }
    return ModPackSource(files: all) { texts[$0].map { Data($0.utf8) } }
}

private func header(_ id: String = "com.example.test") -> String {
    #""format": 1, "id": "\#(id)", "name": "Test", "version": "1.0.0", "author": "Tests""#
}

private func errors(_ kind: ModPackKind, _ src: ModPackSource) -> [String] {
    ModPacks.validate(kind, source: src).1.errors
}

private func has(_ list: [String], _ text: String) -> Bool { list.contains { $0.contains(text) } }

private var examples: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/packs", isDirectory: true)
}

// MARK: Kinds

@Test func packKindsMapOntoModKinds() {
    for pack in ModPackKind.allCases {
        let kind = ModKind(pack)
        #expect(kind.pack == pack)
        #expect(kind.isPack)
        #expect(kind.packageExtension == pack.bundleExtension)
        #expect(kind.maxPackageBytes == pack.maxPackageBytes)
        #expect(ModPackKind.of(extension: pack.bundleExtension.uppercased()) == pack)
    }
    #expect(ModKind.plugin.pack == nil && ModKind.theme.pack == nil && ModKind.native.pack == nil)
    #expect(ModKind(rawValue: "icons") == .icons)
    #expect(ModPackKind.look.bundleExtension == "atelierlook")
}

@Test func catalogParsesPackEntries() throws {
    let json = """
    {"format":1,"generated":"2026-11-12T10:00:00Z","mods":[
     {"id":"com.example.mono-glyphs","name":"Mono Glyphs","kind":"icons","version":"1.0.0",
      "package":{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/1.zip","sha256":"\(String(repeating: "ab", count: 32))","size":4096}},
     {"id":"com.example.too-big","name":"Too Big","kind":"layouts","version":"1.0.0",
      "package":{"url":"https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/p/2.zip","sha256":"\(String(repeating: "ab", count: 32))","size":9000000}}]}
    """
    let index = try ModIndexParser.parse(Data(json.utf8))
    #expect(index.mods.map(\.id) == ["com.example.mono-glyphs"])
    #expect(index.mods.first?.kind == .icons)
    #expect(ModQuery.filter(index.mods, kind: .icons, text: "", includeNative: false).count == 1)
}

// MARK: Sniffing

@Test func filesAreKnownByTheirBytesNotTheirNames() {
    #expect(ModPackDisk.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == .png)
    #expect(ModPackDisk.sniff(Data("icns....".utf8)) == .icns)
    #expect(ModPackDisk.sniff(Data("caff....".utf8)) == .caf)
    #expect(ModPackDisk.sniff(Data("RIFF\0\0\0\0WAVEfmt ".utf8)) == .wav)
    #expect(ModPackDisk.sniff(Data("\0\0\0\u{18}ftypheic".utf8)) == .heic)
    #expect(ModPackDisk.sniff(Data("\0\0\0\u{18}ftypM4A ".utf8)) == .m4a)
    #expect(ModPackDisk.sniff(Data("  {\"a\":1}".utf8)) == .json)
    #expect(ModPackDisk.sniff(Data("#!/bin/sh".utf8)) == .other)
}

// MARK: Header

@Test func headersAreStrict() {
    #expect(has(errors(.shader, source(.shader, #"{"format": 2, "id": "com.example.x", "name": "X", "version": "1.0.0", "base": "nebula"}"#)), "format"))
    #expect(has(errors(.shader, source(.shader, #"{"format": 1, "id": "nodots", "name": "X", "version": "1.0.0", "base": "nebula"}"#)), "reverse-DNS"))
    #expect(has(errors(.shader, source(.shader, #"{"format": 1, "id": "com.example.x", "name": "X", "version": "one", "base": "nebula"}"#)), "version"))
    #expect(has(errors(.shader, source(.shader, #"{"format": 1, "id": "com.example.x", "name": " ", "version": "1.0.0", "base": "nebula"}"#)), "name"))
    #expect(has(errors(.shader, source(.shader, "{\(header()), \"base\": \"nebula\", \"script\": \"x\"}")), "unknown key \"script\""))
    #expect(has(errors(.shader, source(.shader, "not json")), "not a JSON object"))
    #expect(has(errors(.shader, ModPackSource(files: [:]) { _ in nil }), "has no atelier-shader.json"))
    // x- keys are free for makers' notes.
    #expect(errors(.shader, source(.shader, "{\(header()), \"base\": \"nebula\", \"x-note\": \"hi\"}")).isEmpty)
}

// MARK: Icons

@Test func iconPackAcceptsBundleIDsAndSpecialKeys() {
    let manifest = "{\(header()), \"icons\": {\"com.apple.Safari\": \"i/s.png\", \"trash\": \"i/t.png\", \"downloads\": \"i/d.png\"}}"
    let (pack, report) = ModPacks.validate(.icons, source: source(.icons, manifest, files: ["i/s.png": png, "i/t.png": png, "i/d.png": png]))
    #expect(report.errors.isEmpty)
    guard case .icons(let icons)? = pack else { Issue.record("no pack"); return }
    #expect(icons.icons["com.apple.Safari"] == "i/s.png")
    #expect(icons.icons.count == 3)
}

@Test func iconPackRefusesBadIcons() {
    func run(_ icons: String, _ files: [String: ModPackFile]) -> [String] {
        errors(.icons, source(.icons, "{\(header()), \"icons\": {\(icons)}}", files: files))
    }
    #expect(has(run(#""not a bundle": "a.png""#, ["a.png": png]), "not a bundle identifier"))
    #expect(has(run(#""com.a.b": "missing.png""#, [:]), "not in the pack"))
    #expect(has(run(#""com.a.b": "../escape.png""#, [:]), "not a path inside the pack"))
    #expect(has(run(#""com.a.b": "a.png""#, ["a.png": ModPackFile(bytes: 10, format: .jpeg, pixels: 512)]), "not really a .png"))
    #expect(has(run(#""com.a.b": "a.jpg""#, ["a.jpg": ModPackFile(bytes: 10, format: .jpeg, pixels: 512)]), "PNG, HEIC or ICNS"))
    #expect(has(run(#""com.a.b": "a.png""#, ["a.png": ModPackFile(bytes: 2_000_000, format: .png, pixels: 512)]), "larger than 1 MB"))
    #expect(has(run(#""com.a.b": "a.png""#, ["a.png": ModPackFile(bytes: 100, format: .png, pixels: 128)]), "at least 256"))
    #expect(has(run(#""com.a.b": "a.png""#, ["a.png": ModPackFile(bytes: 100, format: .png)]), "could not be read"))
    #expect(has(errors(.icons, source(.icons, "{\(header()), \"icons\": {}}")), "must map"))
}

@Test func iconPackHasAnIconLimit() {
    var files: [String: ModPackFile] = [:], entries: [String] = []
    for i in 0...ModPackLimits.maxIcons {
        files["i/\(i).png"] = png
        entries.append("\"com.example.app\(i)\": \"i/\(i).png\"")
    }
    let found = errors(.icons, source(.icons, "{\(header()), \"icons\": {\(entries.joined(separator: ","))}}", files: files))
    #expect(has(found, "the limit is 600"))
}

// MARK: Sounds

@Test func soundPackChecksSlotsLengthsAndTyping() {
    let good = "{\(header()), \"sounds\": {\"dock.launch\": \"a.wav\", \"timer.done\": \"t.caf\"}, \"typing\": {\"key\": [\"k1.wav\", \"k2.wav\"], \"space\": [\"k1.wav\"]}}"
    let files = ["a.wav": wav, "t.caf": ModPackFile(bytes: 1000, format: .caf, seconds: 1.9), "k1.wav": wav, "k2.wav": wav]
    let (pack, report) = ModPacks.validate(.sounds, source: source(.sounds, good, files: files))
    #expect(report.errors.isEmpty)
    guard case .sounds(let sounds)? = pack else { Issue.record("no pack"); return }
    #expect(sounds.sounds[.dockLaunch] == "a.wav")
    #expect(sounds.hasTyping)
    #expect(sounds.variants(.backspace) == ["k1.wav", "k2.wav"])   // falls back to key
    #expect(sounds.variants(.space) == ["k1.wav"])

    func run(_ body: String, _ files: [String: ModPackFile]) -> [String] { errors(.sounds, source(.sounds, "{\(header()), \(body)}", files: files)) }
    #expect(has(run(#""sounds": {"dock.explode": "a.wav"}"#, ["a.wav": wav]), "not a sound Atelier plays"))
    #expect(has(run(#""sounds": {"dock.drop": "a.wav"}"#, ["a.wav": ModPackFile(bytes: 1, format: .wav, seconds: 2.5)]), "the limit is 2.0 s"))
    #expect(has(run(#""sounds": {"dock.drop": "a.wav"}"#, ["a.wav": ModPackFile(bytes: 2_000_000, format: .wav, seconds: 1)]), "larger than 1 MB"))
    #expect(has(run(#""sounds": {"dock.drop": "a.mp3"}"#, ["a.mp3": ModPackFile(bytes: 10, format: .other)]), "not really"))
    #expect(has(run(#""typing": {"space": ["a.wav"]}"#, ["a.wav": wav]), "at least \"key\""))
    #expect(has(run(#""typing": {"key": ["a.wav"]}"#, ["a.wav": ModPackFile(bytes: 10, format: .wav, seconds: 1.5)]), "the limit is 1.0 s"))
    #expect(has(run(#""typing": {"key": []}"#, [:]), "1 to 8"))
    #expect(has(run(#""sounds": {}"#, [:]), "no sounds"))
}

// MARK: Shader

@Test func shaderPackMapsOntoTheEngine() {
    let manifest = "{\(header()), \"base\": \"northernLights\", \"palette\": [\"#000000\", \"#112233\", \"#445566\", \"#FFFFFF\"], \"speed\": 0.7, \"scale\": 1.2, \"cycle\": \"night\", \"pointer\": false}"
    let (pack, report) = ModPacks.validate(.shader, source: source(.shader, manifest))
    #expect(report.errors.isEmpty)
    guard case .shader(let shader)? = pack else { Issue.record("no pack"); return }
    #expect(shader.base == "northernLights" && shader.palette.count == 4 && shader.speed == 0.7 && !shader.pointer)
    #expect(shader.intensity == 0.5 && shader.dim == 0)   // defaults: the shader as designed

    func run(_ body: String) -> [String] { errors(.shader, source(.shader, "{\(header()), \(body)}")) }
    #expect(has(run(#""base": "wallpaperRain""#), "\"base\" must be one of"))
    #expect(has(run(#""base": "customMetal""#), "\"base\" must be one of"))
    #expect(has(run(#""base": "nebula", "speed": 9"#), "speed must be between"))
    #expect(has(run(#""base": "nebula", "dim": 0.9"#), "dim must be between"))
    #expect(has(run(##""base": "nebula", "palette": ["#000", "#111"]"##), "four colours"))
    #expect(has(run(##""base": "nebula", "palette": ["red", "#111", "#222", "#333"]"##), "four colours"))
    #expect(has(run(#""base": "nebula", "cycle": "noon""#), "cycle"))
    #expect(has(run(#""base": "nebula", "speed": "fast""#), "must be a number"))
}

// MARK: Layouts

@Test func layoutZonesStayOnScreenAndHaveRoom() {
    #expect(ModPacks.zoneProblem(ZoneRect(x: 0, y: 0, width: 1, height: 1)) == nil)
    #expect(ModPacks.zoneProblem(ZoneRect(x: 0.5, y: 0, width: 0.6, height: 1))?.contains("past the edge") == true)
    #expect(ModPacks.zoneProblem(ZoneRect(x: -0.1, y: 0, width: 0.5, height: 1))?.contains("outside") == true)
    #expect(ModPacks.zoneProblem(ZoneRect(x: 0, y: 0, width: 0.01, height: 1))?.contains("narrower") == true)
    #expect(ModPacks.zoneProblem(ZoneRect(x: 0, y: 0, width: .nan, height: 1)) != nil)
}

@Test func layoutPackLimitsAndStableIDs() {
    let zone = #"{"x": 0, "y": 0, "width": 0.5, "height": 1}"#
    let layout = #"{"name": "Halves", "zones": [\#(zone), {"x": 0.5, "y": 0, "width": 0.5, "height": 1}]}"#
    let (pack, report) = ModPacks.validate(.layouts, source: source(.layouts, "{\(header()), \"layouts\": [\(layout)]}"))
    #expect(report.errors.isEmpty)
    guard case .layouts(let layouts)? = pack else { Issue.record("no pack"); return }
    #expect(layouts.layouts.first?.id == LayoutPack.layoutID(pack: "com.example.test", index: 0))
    #expect(LayoutPack.layoutID(pack: "a.b", index: 0) == LayoutPack.layoutID(pack: "a.b", index: 0))
    #expect(LayoutPack.layoutID(pack: "a.b", index: 0) != LayoutPack.layoutID(pack: "a.b", index: 1))

    let many = Array(repeating: layout, count: 25).joined(separator: ",")
    #expect(has(errors(.layouts, source(.layouts, "{\(header()), \"layouts\": [\(many)]}")), "the limit is 24"))
    let zones = Array(repeating: zone, count: 13).joined(separator: ",")
    #expect(has(errors(.layouts, source(.layouts, "{\(header()), \"layouts\": [{\"name\": \"X\", \"zones\": [\(zones)]}]}")), "1 to 12 zones"))
    #expect(has(errors(.layouts, source(.layouts, "{\(header()), \"layouts\": [{\"name\": \"X\", \"zones\": [\(zone), \(zone)]}]}")), "repeats"))
    #expect(has(errors(.layouts, source(.layouts, "{\(header()), \"layouts\": [{\"name\": \"X\", \"zones\": [{\"x\": 0, \"y\": 0, \"width\": 0.5}]}]}")), "must be {"))
}

// MARK: Effects

@Test func effectPackRulesKeepTheFirstFrameOnTheWindow() {
    func run(_ effect: String) -> [String] { errors(.effects, source(.effects, "{\(header()), \"effects\": [\(effect)]}")) }
    let ok = #"{"id": "mist", "name": "Mist", "base": "scale", "duration": 0.4, "opacity": [[0, 1], [1, 0]], "blur": [[0, 0], [1, 4]]}"#
    #expect(run(ok).isEmpty)
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 2}"#), "duration must be between"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.1}"#), "duration must be between"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale"}"#), "duration is required"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "system", "duration": 0.4}"#), "base must be one of"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "opacity": [[0, 0.5], [1, 0]]}"#), "must start at 1"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "opacity": [[0, 1], [0.5, 0.5], [0.4, 0], [1, 0]]}"#), "must increase"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "opacity": [[0, 1], [0.9, 0]]}"#), "end at t 1"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "blur": [[0, 0], [1, 20]]}"#), "between 0.0 and 8.0"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "curve": "bouncy"}"#), "curve"))
    #expect(has(run(#"{"id": "a", "name": "A", "base": "scale", "duration": 0.4, "shader": "x"}"#), "unknown key \"shader\""))
    #expect(has(run(#"{"id": "a b", "name": "A", "base": "scale", "duration": 0.4}"#), "needs an \"id\""))
    #expect(has(errors(.effects, source(.effects, "{\(header()), \"effects\": [\(ok), \(ok)]}")), "used twice"))
}

@Test func packEffectMeshStartsAsTheWindowAndBlursAndFades() {
    let g = MinimizeGeometry(window: CGRect(x: 100, y: 300, width: 400, height: 300), tile: CGRect(x: 500, y: 10, width: 50, height: 50), edge: .bottom)
    let effect = PackMinimizeEffect(id: "a", name: "A", base: .scale, duration: 0.5, curve: .easeIn,
                                    opacity: [PackKeyframe(0, 1), PackKeyframe(1, 0)], scale: [PackKeyframe(0, 1), PackKeyframe(1, 0.5)],
                                    blur: [PackKeyframe(0, 0), PackKeyframe(1, 6)], twist: 90, waveAmplitude: 0.1, waveFrequency: 2)
    let start = effect.mesh(progress: 0, geometry: g), base = MinimizeEffects.mesh(.scale, progress: 0, geometry: g)
    #expect(start.vertices.count == base.vertices.count)
    for (a, b) in zip(start.vertices, base.vertices) {
        #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && a.alpha == b.alpha)
    }
    #expect(start.blur == 0)
    let middle = effect.mesh(progress: 0.5, geometry: g)
    #expect(abs(middle.blur - 3) < 0.001)
    #expect(middle.vertices.allSatisfy { $0.alpha <= 0.5 + 0.001 })
    let end = effect.mesh(progress: 1, geometry: g)
    #expect(end.vertices.allSatisfy { $0.alpha == 0 })
    // Timing: the restore is the way in played backwards.
    #expect(effect.progress(elapsed: 0, duration: 1, restoring: false) == 0)
    #expect(effect.progress(elapsed: 1, duration: 1, restoring: false) == 1)
    #expect(effect.progress(elapsed: 0, duration: 1, restoring: true) == 1)
    #expect(abs(effect.progress(elapsed: 0.3, duration: 1, restoring: true) - effect.progress(elapsed: 0.7, duration: 1, restoring: false)) < 1e-9)
    #expect(effect.duration(restoring: false, slow: true) == 0.5 * MinimizeTiming.slowMotion)
    for curve in PackCurve.allCases { #expect(curve.apply(0) == 0 && abs(curve.apply(1) - 1) < 1e-9) }
    #expect(PackMinimizeEffect.sample([], at: 0.5, rest: 1) == 1)
    #expect(PackMinimizeEffect.sample([PackKeyframe(0, 0), PackKeyframe(1, 10)], at: 0.25, rest: 0) == 2.5)
}

// MARK: Look

@Test func lookChecksItsThemeAndEmbeddedPacks() {
    let theme = #"{"format": 1, "id": "com.example.look.theme", "name": "T", "version": "1.0.0"}"#
    let shader = "{\(header("com.example.sky")), \"base\": \"nebula\"}"
    let look = "{\(header()), \"theme\": \"t.ateliertheme\", \"wallpaper\": {\"shader\": \"sky.ateliershader\"}, \"dock\": {\"edge\": \"left\", \"tileSize\": 48, \"magnifiedSize\": 80, \"magnification\": true}, \"iconPack\": \"com.example.icons\"}"
    let texts = ["t.ateliertheme/atelier-theme.json": theme, "sky.ateliershader/atelier-shader.json": shader]
    let (pack, report) = ModPacks.validate(.look, source: source(.look, look, extra: texts))
    #expect(report.errors.isEmpty, "\(report.errors)")
    guard case .look(let l)? = pack else { Issue.record("no pack"); return }
    #expect(l.wallpaperShader == .embedded("sky.ateliershader"))
    #expect(l.iconPack == .installed("com.example.icons"))
    #expect(l.dock.edge == "left" && l.dock.tileSize == 48 && l.dock.magnification == true)

    func run(_ body: String, _ extra: [String: String] = texts, files: [String: ModPackFile] = [:]) -> [String] {
        errors(.look, source(.look, "{\(header()), \(body)}", files: files, extra: extra))
    }
    #expect(has(run(#""theme": "missing.ateliertheme""#), "has no atelier-theme.json"))
    #expect(has(run(#""theme": "../t.ateliertheme""#), "must name the .ateliertheme"))
    #expect(has(run(#""theme": "t.ateliertheme", "wallpaper": {"shader": "sky.ateliershader"}"#,
                    ["t.ateliertheme/atelier-theme.json": theme, "sky.ateliershader/atelier-shader.json": "{\(header("com.example.sky")), \"base\": \"evil\"}"]),
                "sky.ateliershader: \"base\" must be one of"))
    #expect(has(run(#""theme": "t.ateliertheme", "dock": {"tileSize": 500}"#), "dock.tileSize"))
    #expect(has(run(#""theme": "t.ateliertheme", "dock": {"tileSize": 60, "magnifiedSize": 40}"#), "must not be smaller"))
    #expect(has(run(#""theme": "t.ateliertheme", "dock": {"position": "left"}"#), "unknown key \"position\""))
    #expect(has(run(#""theme": "t.ateliertheme", "wallpaper": {"image": "w.png"}"#, files: ["w.png": ModPackFile(bytes: 30_000_000, format: .png, pixels: 3000)]), "larger than 20 MB"))
    #expect(has(run(#""theme": "t.ateliertheme", "wallpaper": {"image": "w.png"}"#, files: ["w.png": ModPackFile(bytes: 3000, format: .png, pixels: 100)]), "too small"))
    #expect(has(run(#""theme": "t.ateliertheme", "iconPack": "not an id""#), "neither a pack id"))
    #expect(has(run(#""theme": "t.ateliertheme", "wallpaper": {"image": "a.png", "shader": "x.y"}"#), "\"wallpaper\" must be"))
}

// MARK: The shipped examples, read from disk

@Test func shippedExamplesAreValid() throws {
    let expected: [(String, ModPackKind)] = [("mono-glyphs.ateliericons", .icons), ("soft-chimes.ateliersounds", .sounds),
                                             ("aurora-drift.ateliershader", .shader), ("studio-grids.atelierlayouts", .layouts),
                                             ("soft-effects.ateliereffects", .effects), ("dusk-studio.atelierlook", .look)]
    for (name, kind) in expected {
        switch ModPackDisk.load(examples.appendingPathComponent(name)) {
        case .failure(let error): Issue.record("\(name): \(error.description)")
        case .success(let (pack, report)):
            #expect(pack.kind == kind)
            #expect(pack.header.id.hasPrefix("com.example."))
            #expect(report.warnings.isEmpty, "\(name): \(report.warnings)")
        }
    }
}

@Test func diskReaderMeasuresPicturesAndSounds() throws {
    let folder = examples.appendingPathComponent("soft-chimes.ateliersounds")
    let files = try ModPackDisk.inventory(folder)
    let timer = try #require(files["sounds/timer.wav"])
    #expect(timer.format == .wav)
    #expect(abs((timer.seconds ?? 0) - 1.6) < 0.05)
    let icons = try ModPackDisk.inventory(examples.appendingPathComponent("mono-glyphs.ateliericons"))
    #expect(icons["icons/safari.png"]?.pixels == 512)
}

@Test func diskReaderRefusesLinksAndDisguisedFiles() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("packs-test-" + UUID().uuidString + ".ateliershader")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    try Data("{\(header()), \"base\": \"nebula\"}".utf8).write(to: temp.appendingPathComponent("atelier-shader.json"))
    if case .failure(let error) = ModPackDisk.load(temp) { Issue.record("valid shader refused: \(error)") }
    try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    guard case .failure(let error) = ModPackDisk.load(temp) else { Issue.record("a link was accepted"); return }
    #expect(error.description.contains("link"))
    // A sound pack whose "wav" is really a script.
    let sounds = FileManager.default.temporaryDirectory.appendingPathComponent("packs-test-" + UUID().uuidString + ".ateliersounds")
    try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sounds) }
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: sounds.appendingPathComponent("a.wav"))
    try Data("{\(header()), \"sounds\": {\"dock.drop\": \"a.wav\"}}".utf8).write(to: sounds.appendingPathComponent("atelier-sounds.json"))
    guard case .failure(let disguised) = ModPackDisk.load(sounds) else { Issue.record("a disguised file was accepted"); return }
    #expect(disguised.description.contains("not really a .wav"))
}
