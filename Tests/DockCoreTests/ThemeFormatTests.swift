import Foundation
import Testing
@testable import DockCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func theme(_ extra: String = "") -> String {
    #"{"format":1,"id":"com.example.test","name":"Test","version":"1.0.0""# + (extra.isEmpty ? "" : "," + extra) + "}"
}

private func validate(_ text: String, files: Set<String>? = []) -> ThemeValidation {
    ThemeValidator.validate(data: Data(text.utf8), files: files).1
}

@Test func minimalThemeIsValid() {
    let result = validate(theme())
    #expect(result.isValid)
    #expect(result.issues.isEmpty)
}

@Test func missingRequiredKeysAreNamed() {
    let result = validate(#"{"format":1}"#)
    #expect(!result.isValid)
    #expect(Set(result.errors.map(\.path)) == ["id", "name", "version"])
}

@Test func notJSONSaysSo() {
    let result = validate("{ nope")
    #expect(result.errors.first?.message.contains("not valid JSON") == true)
}

@Test func newerFormatIsRefusedClearly() {
    let result = validate(#"{"format":2,"id":"a.b","name":"x","version":"1.0.0"}"#)
    #expect(result.errors.first?.path == "format")
    #expect(result.errors.first?.message.contains("newer Atelier") == true)
}

@Test func wrongEnumSuggestsTheNearestValue() {
    let result = validate(theme(#""dock":{"style":"glas"}"#))
    let error = result.errors.first
    #expect(error?.path == "dock.style")
    #expect(error?.message.contains("Did you mean \"glass\"") == true)
}

@Test func numbersAreRangeChecked() {
    let result = validate(theme(#""dock":{"roundness":1.5},"widgets":{"radius":"big"}"#))
    #expect(result.errors.map(\.path).sorted() == ["dock.roundness", "widgets.radius"])
    #expect(result.errors.first { $0.path == "dock.roundness" }?.message.contains("outside 0…1") == true)
}

@Test func coloursMustBeHex() {
    let bad = validate(theme(#""colors":{"accent":"blue"}"#))
    #expect(bad.errors.first?.path == "colors.accent")
    #expect(validate(theme(##""colors":{"accent":"#8FB8FF","secondary":"#abc","glassTint":"#11223344"}"##)).isValid)
}

@Test func colourOrNameAcceptsBoth() {
    #expect(validate(theme(#""dock":{"accent":"pink"}"#)).isValid)
    #expect(validate(theme(##""dock":{"accent":"#FF00AA"}"##)).isValid)
    #expect(!validate(theme(#""dock":{"accent":"fuchsia"}"#)).isValid)
}

@Test func paletteIsPresetOrFourColours() {
    #expect(validate(theme(#""wallpaper":{"palette":"ember"}"#)).isValid)
    #expect(validate(theme(##""wallpaper":{"palette":["#000000","#111111","#888888","#FFFFFF"]}"##)).isValid)
    let three = validate(theme(##""wallpaper":{"palette":["#000000","#111111","#888888"]}"##))
    #expect(three.errors.first?.message.contains("Expected 4 colours, got 3") == true)
    let badStop = validate(theme(##""wallpaper":{"palette":["#000000","#111111","#888888","white"]}"##))
    #expect(badStop.errors.first?.path == "wallpaper.palette[3]")
}

@Test func unknownKeysWarnWithAHint() {
    let result = validate(theme(#""dokc":{},"x-mine":1,"$schema":"s.json""#))
    #expect(result.isValid)
    #expect(result.warnings.count == 1)
    #expect(result.warnings.first?.message.contains("Did you mean \"dock\"") == true)
}

@Test func imageModeNeedsAPictureInTheBundle() {
    #expect(validate(theme(#""wallpaper":{"mode":"image"}"#)).errors.first?.path == "wallpaper.image")
    let missing = validate(theme(#""wallpaper":{"mode":"image","image":"images/wall.heic"}"#), files: [])
    #expect(missing.errors.first?.message.contains("not in the bundle") == true)
    #expect(validate(theme(#""wallpaper":{"mode":"image","image":"images/wall.heic"}"#), files: ["images/wall.heic"]).isValid)
}

@Test func pathsCannotEscapeTheBundle() {
    for path in ["../secret.png", "/etc/x.png", "a/../../b.png", ".hidden.png", "~/x.png"] {
        let result = validate(theme(#""preview":"\#(path)""#), files: nil)
        #expect(!result.isValid, "\(path) should be refused")
    }
    #expect(validate(theme(#""preview":"art/preview.png""#), files: ["art/preview.png"]).isValid)
}

@Test func identifiersAndVersions() {
    #expect(ThemeIdentifier.isValid("com.example.midnight-glass"))
    #expect(!ThemeIdentifier.isValid("midnight"))
    #expect(!ThemeIdentifier.isValid("com..x"))
    #expect(!ThemeIdentifier.isValid("com.ex ample.x"))
    #expect(validate(#"{"format":1,"id":"bad id","name":"x","version":"one"}"#).errors.map(\.path).sorted() == ["id", "version"])
    #expect(SemVer("1.2.10")! > SemVer("1.2.9")!)
    #expect(SemVer("2")! == SemVer("2.0.0")!)
    #expect(SemVer("1.x") == nil)
}

@Test func colourParsingAndNearest() {
    let color = ThemeColor(hex: "#FF8000")
    #expect(color?.red == 1)
    #expect(color?.hex == "#FF8000")
    #expect(ThemeColor(hex: "#fff")?.hex == "#FFFFFF")
    #expect(ThemeColor(hex: "#00000080")?.alpha ?? 0 > 0.49)
    #expect(ThemeColor(hex: "FF8000") == nil)
    let swatches: [(String, ThemeColor)] = [("red", .init(red: 1, green: 0, blue: 0)), ("blue", .init(red: 0, green: 0, blue: 1))]
    #expect(ThemeColor(hex: "#E01030")?.nearest(swatches) == "red")
}

@Test func documentReadsSetsAndMerges() throws {
    var document = try ThemeDocument(data: Data(theme(#""dock":{"style":"neon","gap":10}"#).utf8))
    #expect(document.string("dock.style") == "neon")
    #expect(document.number("dock.gap") == 10)
    #expect(document.string("dock.missing") == nil)
    document.set("widgets.gradient.angle", .number(90))
    #expect(document.number("widgets.gradient.angle") == 90)
    let merged = document.merged(with: ["dock": .object(["style": .string("frost")])])
    #expect(merged.string("dock.style") == "frost")
    #expect(merged.number("dock.gap") == 10, "merging keeps keys the patch does not name")
    #expect(document.touched == ["dock", "widgets"])
}

@Test func invalidDocumentThrowsReadableError() {
    #expect(throws: ThemeError.self) { try ThemeDocument(data: Data(#"{"format":1}"#.utf8)) }
    do { _ = try ThemeDocument(data: Data(#"{"format":1}"#.utf8)) } catch {
        #expect(error.localizedDescription.contains("3 problems"))
        #expect(error.localizedDescription.contains("id: Required"))
    }
}

@Test func sanitizeMakesLiveSettingsValid() {
    let root: [String: JSONValue] = [
        "format": .number(1), "id": .string("a.b"), "name": .string("x"), "version": .string("1.0.0"),
        "dock": .object(["gap": .number(99), "style": .string("from-the-future")]),
    ]
    #expect(!ThemeValidator.validate(.object(root)).isValid)
    let clean = ThemeSchema.sanitize(root)
    #expect(ThemeValidator.validate(.object(clean)).isValid)
    #expect(clean["dock"]?["gap"]?.number == 32)
    #expect(clean["dock"]?["style"] == nil)
}

@Test func themeLinksAreHttpsAndPublicOnly() throws {
    let good = try ThemeLink.download(from: URL(string: "atelier://theme?url=https://example.com/t/atelier-theme.json")!)
    #expect(good.host() == "example.com")
    #expect(throws: ThemeError.self) { try ThemeLink.download(from: URL(string: "atelier://theme?url=http://example.com/a.json")!) }
    #expect(throws: ThemeError.self) { try ThemeLink.download(from: URL(string: "atelier://theme?url=https://192.168.1.4/a.json")!) }
    #expect(throws: ThemeError.self) { try ThemeLink.download(from: URL(string: "atelier://theme?url=https://localhost/a.zip")!) }
    #expect(throws: ThemeError.self) { try ThemeLink.download(from: URL(string: "atelier://theme?url=https://example.com/a.exe")!) }
    #expect(throws: ThemeError.self) { try ThemeLink.download(from: URL(string: "atelier://studio?url=https://example.com/a.json")!) }
    #expect(ThemeLink.isPrivate("10.0.0.2") && ThemeLink.isPrivate("172.20.1.1") && !ThemeLink.isPrivate("172.32.0.1"))
}

@Test func scheduleWrapsPastMidnight() {
    let schedule = ThemeSchedule(enabled: true, slots: [.init(hour: 7, theme: "day"), .init(hour: 20, theme: "night")])
    #expect(schedule.theme(at: 12) == "day")
    #expect(schedule.theme(at: 22) == "night")
    #expect(schedule.theme(at: 3) == "night", "before the first slot, the last one still holds")
    #expect(schedule.change(from: 6.98, to: 7) == "day")
    #expect(schedule.change(from: 7, to: 7.02) == nil, "nothing begins, so a hand-picked Look is left alone")
    #expect(schedule.change(from: 19.5, to: 20.5) == "night")
    #expect(schedule.change(from: 23.99, to: 0.01) == nil)
    var off = schedule
    off.enabled = false
    #expect(off.change(from: 6.9, to: 7.1) == nil)
    let late = ThemeSchedule(enabled: true, slots: [.init(hour: 0, theme: "midnight")])
    #expect(late.change(from: 23.99, to: 0.0) == "midnight")
}

// MARK: - Shipped files

@Test func exampleThemesValidate() throws {
    let folder = repository.appendingPathComponent("examples/themes")
    let bundles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == ThemeSchema.bundleExtension }
    #expect(bundles.count == 3)
    for bundle in bundles {
        let data = try Data(contentsOf: bundle.appendingPathComponent(ThemeSchema.fileName))
        let result = ThemeValidator.validate(data: data, files: nil).1
        #expect(result.isValid, "\(bundle.lastPathComponent): \(result.errors)")
        #expect(result.warnings.isEmpty, "\(bundle.lastPathComponent): \(result.warnings)")
    }
}

/// The JSON Schema and the reference in docs/ are generated from the validator's table.
/// `ATELIER_WRITE_SCHEMA=1 swift test --filter jsonSchemaMatchesTheTable` rewrites the schema.
@Test func jsonSchemaMatchesTheTable() throws {
    let url = repository.appendingPathComponent("docs/atelier-theme.schema.json")
    let generated = ThemeSchemaExport.jsonSchema()
    if ProcessInfo.processInfo.environment["ATELIER_WRITE_SCHEMA"] == "1" {
        try generated.data(pretty: true).write(to: url, options: .atomic)
    }
    let shipped = try JSONValue.parse(Data(contentsOf: url))
    #expect(shipped == generated, "docs/atelier-theme.schema.json is out of date; regenerate it")
    let guide = try String(contentsOf: repository.appendingPathComponent("docs/THEMES.md"), encoding: .utf8)
    #expect(guide.contains(ThemeSchemaExport.markdown()), "the reference tables in docs/THEMES.md are out of date")
}
