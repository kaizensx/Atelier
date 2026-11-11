import Foundation
import Testing
@testable import DockCore

/// Every write goes to a scratch domain, never a real one.
private func scratch() -> (domain: String, suite: String) {
    let id = UUID().uuidString
    return ("net.dasantos.atelier.test.\(id)", "net.dasantos.atelier.test.ledger.\(id)")
}

private func cleanUp(_ domain: String, _ suite: String) {
    for name in [domain, suite] {
        CFPreferencesSetMultiple(nil, CFPreferencesCopyKeyList(name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                                 name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        UserDefaults().removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist"))
    }
}

private func setting(_ domain: String, key: String = "Sample", kind: PersonalKind = .int) -> PersonalSetting {
    PersonalSetting(.finder, "Test", domain: domain, key: key, kind: kind, control: .number(0...10, step: 1, unit: ""),
                    title: "Sample", detail: "", effect: .immediate, evidence: "test", preview: "")
}

@Test func catalogueHasNoDuplicateKeys() {
    let ids = PersonalCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func catalogueStaysOutOfTheTweakCatalogue() {
    // Keys the Catalog.swift toggles already own. Kept in step by hand; a clash fails here.
    let owned: Set<String> = [
        "com.apple.finder.ShowStatusBar", "com.apple.finder.ShowPathbar", "com.apple.finder.ShowPreviewPane",
        "com.apple.finder._FXShowPosixPathInTitle", "com.apple.finder._FXSortFoldersFirst",
        "com.apple.finder.AppleShowAllFiles", "com.apple.finder.QuitMenuItem", "com.apple.finder.DisableAllAnimations",
        "com.apple.finder.ShowRecentTags", "com.apple.finder.FXEnableExtensionChangeWarning",
        "NSGlobalDomain.NSAutomaticWindowAnimationsEnabled", "NSGlobalDomain.QLPanelAnimationDuration",
        "NSGlobalDomain.NSWindowResizeTime", "NSGlobalDomain.NSScrollAnimationEnabled",
        "NSGlobalDomain.AppleShowScrollBars", "com.apple.screencapture.disable-shadow",
        "com.apple.screencapture.show-thumbnail", "com.apple.screencapture.include-date",
        "com.apple.dock.mru-spaces", "NSGlobalDomain.AppleSpacesSwitchOnActivate",
    ]
    #expect(PersonalCatalog.all.filter { owned.contains($0.id) }.isEmpty)
}

@Test func everySettingSaysWhereItWasFound() {
    #expect(PersonalCatalog.all.allSatisfy { !$0.evidence.isEmpty && !$0.preview.isEmpty })
}

@Test func applyThenRevertRestoresAnAbsentKey() throws {
    let (domain, suite) = scratch()
    defer { cleanUp(domain, suite) }
    let engine = PersonalEngine(ledger: PersonalLedger(suite: suite))
    let sample = setting(domain)
    #expect(engine.prefs.read(sample) == nil)
    try engine.apply(.int(7), to: sample)
    #expect(engine.prefs.read(sample) == .int(7))
    try engine.apply(.int(9), to: sample)
    try engine.revert(sample)
    #expect(engine.prefs.read(sample) == nil)
    #expect(!engine.ledger.isTracked(sample.id))
}

@Test func revertRestoresTheFirstOriginal() throws {
    let (domain, suite) = scratch()
    defer { cleanUp(domain, suite) }
    let engine = PersonalEngine(ledger: PersonalLedger(suite: suite))
    let sample = setting(domain, kind: .string)
    try engine.prefs.write(.string("mine"), for: sample)
    try engine.apply(.string("a"), to: sample)
    try engine.apply(.string("b"), to: sample)
    try engine.revert(sample)
    #expect(engine.prefs.read(sample) == .string("mine"))
}

@Test func boolsReadBackFromNumbers() {
    #expect(PersonalValue(NSNumber(value: 1), as: .bool) == .bool(true))
    #expect(PersonalValue("0" as CFString, as: .bool) == .bool(false))
    #expect(PersonalValue(NSNumber(value: 2.5), as: .float) == .float(2.5))
}

@Test func desktopIconsMergeKeepsUnknownKeys() {
    let existing: [String: Any] = ["GroupBy": "Kind", "IconViewSettings": ["iconSize": 64, "backgroundType": 0]]
    var options = DesktopIconOptions(desktopViewSettings: existing)
    #expect(options.iconSize == 64)
    options.iconSize = 400
    let merged = options.merged(into: existing)
    let icon = merged["IconViewSettings"] as? [String: Any]
    #expect(merged["GroupBy"] as? String == "Kind")
    #expect(icon?["backgroundType"] as? Int == 0)
    #expect(icon?["iconSize"] as? Double == 128)
}

@Test func textTransforms() {
    #expect(TextTransform.snake.apply("Hello WorldAgain") == "hello_world_again")
    #expect(TextTransform.camel.apply("make it-work") == "makeItWork")
    #expect(TextTransform.kebab.apply("Some File Name") == "some-file-name")
    #expect(TextTransform.jsonMinify.apply("{ \"a\" : [1, 2] }") == "{\"a\":[1,2]}")
    #expect(TextTransform.jsonPretty.apply("not json") == nil)
    #expect(TextTransform.base64Decode.apply(TextTransform.base64Encode.apply("Atelier")!) == "Atelier")
    #expect(TextTransform.sentence.apply("hello. world") == "Hello. World")
    #expect(TextTransform.uniqueLines.apply("a\nb\na") == "a\nb")
}

@Test func renamePlanNumbersAndAvoidsCollisions() {
    let date = Date(timeIntervalSince1970: 0)
    let plan = RenamePlan(pattern: "Trip {n}", start: 1, padding: 3)
    let names = plan.names(for: [.init(name: "a.jpg", date: date), .init(name: "b.JPG", date: date), .init(name: "c", date: date)])
    #expect(names == ["Trip 001.jpg", "Trip 002.JPG", "Trip 003"])
    let same = RenamePlan(pattern: "x").names(for: [.init(name: "a.txt", date: date), .init(name: "b.txt", date: date)])
    #expect(same == ["x.txt", "x 2.txt"])
    let replaced = RenamePlan(pattern: "{name}", find: "IMG_", replace: "").names(for: [.init(name: "IMG_1.png", date: date)])
    #expect(replaced == ["1.png"])
}

@Test func keyRemapJSON() {
    #expect(KeyRemap.json([]) == "{\"UserKeyMapping\":[]}")
    let json = KeyRemap.json([.capsToEscape, .capsToControl])
    #expect(json == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771296}]}")
    #expect((try? JSONSerialization.jsonObject(with: Data(KeyRemap.json(KeyRemap.allCases).utf8))) != nil)
}

// MARK: - OS availability

@Test func everyCatalogueKeyHasAnOSDecision() {
    let missing = PersonalCatalog.all.filter { !PersonalAvailability.isAudited(domain: $0.domain, key: $0.key) }.map(\.id)
    #expect(missing.isEmpty, "Add these to PersonalAvailability: \(missing)")
}

@Test func osRangeContainsAndLabels() {
    let range = PersonalOSRange(15, .feature, "x")
    #expect(!range.contains(major: 14))
    #expect(range.contains(major: 15) && range.contains(major: 26) && range.contains(major: 27))
    #expect(range.requirement(onMajor: 14) == "Needs macOS 15 or later")
    let legacy = PersonalOSRange(14, max: 15, .documented, "x")
    #expect(legacy.contains(major: 14) && legacy.contains(major: 15) && !legacy.contains(major: 26))
    #expect(legacy.requirement(onMajor: 26) == "Replaced after macOS 15")
    #expect(PersonalOSRange(14, .thisMacOnly, "x").verificationNote(onMajor: 27) == nil)
    #expect(PersonalOSRange(14, .thisMacOnly, "x").verificationNote(onMajor: 15) != nil)
    #expect(PersonalOSRange(14, .documented, "x").verificationNote(onMajor: 15) == nil)
}

@Test func compatShimVersionReadsAsTahoe() {
    #expect(PersonalAvailability.normalizedMajor(16) == 26)
    #expect(PersonalAvailability.normalizedMajor(15) == 15)
    #expect(PersonalAvailability.normalizedMajor(27) == 27)
}

@Test func screenshotFolderRowsSwapAcrossReleases() {
    let capture = PersonalCatalog.settings(in: .capture)
    func keys(_ major: Int) -> [String] {
        PersonalAvailability.partition(capture, major: major).supported.filter { $0.control == .folder }.map(\.key)
    }
    #expect(keys(14) == ["location"])
    #expect(keys(15) == ["location"])
    #expect(keys(26) == ["location-screenshot", "location-screenrecording"])
    #expect(keys(27) == ["location-screenshot", "location-screenrecording"])
}

@Test func featureGatesByRelease() {
    let all = PersonalCatalog.all
    func supported(_ key: String, _ major: Int) -> Bool { all.first { $0.key == key }!.isAvailable(onMajor: major) }
    #expect(!supported("EnableTilingByEdgeDrag", 14) && supported("EnableTilingByEdgeDrag", 15))
    #expect(!supported("SUIDisableInvocationAnimation", 15) && supported("SUIDisableInvocationAnimation", 26))
    #expect(supported("KeyRepeat", 14) && supported("KeyRepeat", 27))
    #expect(supported("Bluetooth", 14) && supported("Bluetooth", 27))
    // Every setting is readable on the release the evidence came from, except the legacy folder.
    let notHere = PersonalAvailability.partition(all, major: PersonalAvailability.verifiedMajor).unsupported.map(\.key)
    #expect(notHere == ["location"])
    // Partition keeps order and loses nothing.
    let split = PersonalAvailability.partition(all, major: 14)
    #expect(split.supported.count + split.unsupported.count == all.count)
}

@Test func themeIconStylesNeedTahoe() {
    #expect(PersonalAvailability.themeIconStyleSupported("default", major: 14))
    #expect(!PersonalAvailability.themeIconStyleSupported("tinted", major: 15))
    #expect(PersonalAvailability.themeIconStyleSupported("clear", major: 26))
    #expect(!PersonalAvailability.range(domain: "com.apple.dock", key: "adaptive-glass").contains(major: 15))
}
