import Foundation
import Testing
@testable import DockCore

private let system = PersonalCatalog.systemSettings
private let newAreas: Set<PersonalArea> = [.controlCenter, .spotlight, .missionControl, .lockScreen, .accessibility, .appKit, .quickLook]

@Test func systemCatalogueIsInAll() {
    let all = Set(PersonalCatalog.all.map(\.id))
    let included = system.allSatisfy { all.contains($0.id) }
    #expect(included)
    #expect(system.count >= 80)
}

@Test func systemIDsAreUnique() {
    let ids = system.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func systemEvidenceIsSpecific() {
    for setting in system {
        #expect(!setting.evidence.isEmpty && !setting.preview.isEmpty && !setting.title.isEmpty && !setting.detail.isEmpty,
                "\(setting.id)")
        // Evidence names a source: REA, a binary's strings, the shared cache, or this Mac's defaults.
        let named = ["REA", "__cstring", "string", "defaults", "log"].contains { setting.evidence.contains($0) }
        #expect(named, "\(setting.id)")
    }
}

@Test func systemControlsAreValid() {
    for setting in system {
        switch setting.control {
        case let .number(range, step, _):
            #expect(range.lowerBound < range.upperBound && step > 0 && step <= range.upperBound - range.lowerBound, "\(setting.id)")
            #expect(setting.kind == .int || setting.kind == .float, "\(setting.id)")
            if let fallback = setting.fallback?.number { #expect(range.contains(fallback), "\(setting.id)") }
        case let .choice(options):
            #expect(options.count >= 2, "\(setting.id)")
            #expect(Set(options.map(\.value)).count == options.count, "\(setting.id)")
            let kinds = options.allSatisfy { kindMatches($0.value, setting.kind) }
            #expect(kinds, "\(setting.id)")
        case let .toggle(on, off):
            #expect(on != off && kindMatches(on, setting.kind) && kindMatches(off, setting.kind), "\(setting.id)")
        default: break
        }
        if let fallback = setting.fallback { #expect(kindMatches(fallback, setting.kind), "\(setting.id)") }
    }
}

@Test func systemSettingsUseTheirAreas() {
    for area in newAreas { #expect(!PersonalCatalog.settings(in: area).isEmpty, "\(area)") }
    let guarded = system.filter { $0.domain == "com.apple.universalaccess" }.allSatisfy { $0.caution != nil && $0.effect == .logout }
    #expect(guarded)
}

@Test func experimentalSettingsAreFlagged() {
    let experimental = system.filter(\.isExperimental)
    #expect(experimental.count >= 5)
    // Every setting whose evidence comes only from REA decoding of hidden Dock keys is marked.
    let flagged = PersonalCatalog.hiddenDockMotionSettings.allSatisfy(\.isExperimental)
    #expect(flagged)
}

@Test func systemStaysOutOfTheTweakCatalogue() {
    // Keys Catalog.swift's tweaks already own (WindowManager, menu bar, clock, Dock). One home each.
    let owned: Set<String> = [
        "com.apple.WindowManager.EnableTiledWindowMargins", "com.apple.WindowManager.EnableStandardClickToShowDesktop",
        "com.apple.WindowManager.StandardHideDesktopIcons", "com.apple.WindowManager.AutoHide",
        "com.apple.WindowManager.TiledWindowSpacing", "com.apple.WindowManager.EnableStageManagerHotKey",
        "com.apple.WindowManager.HiddenStripPeekWidth", "com.apple.WindowManager.AnimationSpeed",
        "com.apple.menuextra.clock.ShowSeconds", "com.apple.menuextra.clock.IsAnalog", "com.apple.menuextra.clock.FlashDateSeparators",
        "NSGlobalDomain.NSStatusItemSpacing", "NSGlobalDomain.NSStatusItemSelectionPadding",
        "NSGlobalDomain.AppleReduceDesktopTinting", "NSGlobalDomain.AppleShowScrollBars",
        "com.apple.dock.spring-to-expose", "com.apple.dock.hilite-windows-in-expose", "com.apple.dock.show-space-bindings",
        "com.apple.dock.adaptive-glass", "com.apple.dock.genie-speed",
    ]
    #expect(system.filter { owned.contains($0.id) }.isEmpty)
}

@Test func systemSettingRoundTripsInAScratchDomain() throws {
    // Writes go to a scratch copy of each kind of setting, never to the real domain.
    let id = UUID().uuidString
    let domain = "net.dasantos.atelier.test.system.\(id)", suite = "net.dasantos.atelier.test.system.ledger.\(id)"
    defer {
        for name in [domain, suite] {
            UserDefaults().removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist"))
        }
    }
    let engine = PersonalEngine(ledger: PersonalLedger(suite: suite))
    for template in [system.first { $0.kind == .bool }!, system.first { $0.kind == .float }!, system.first { $0.kind == .int }!] {
        let copy = PersonalSetting(template.area, template.section, domain: domain, key: template.key, kind: template.kind,
                                   control: template.control, title: template.title, detail: template.detail,
                                   effect: template.effect, evidence: template.evidence, preview: template.preview)
        let value: PersonalValue = switch template.control {
        case let .toggle(on, _): on
        case let .choice(options): options[1].value
        case let .number(range, _, _): template.kind == .int ? .int(Int(range.upperBound)) : .float(range.upperBound)
        default: .bool(true)
        }
        try engine.apply(value, to: copy)
        #expect(engine.prefs.read(copy) == value)
        try engine.revert(copy)
        #expect(engine.prefs.read(copy) == nil)
    }
}

private func kindMatches(_ value: PersonalValue, _ kind: PersonalKind) -> Bool {
    switch (value, kind) {
    case (.bool, .bool), (.int, .int), (.float, .float), (.string, .string): true
    default: false
    }
}

@Test func menuBarHidingTellsRunningAppsAtOnce() {
    let keys = ["_HIHideMenuBar", "AppleMenuBarVisibleInFullscreen"]
    for key in keys {
        let found = PersonalCatalog.systemSettings.first { $0.key == key && $0.domain == "NSGlobalDomain" }
        #expect(found != nil)
        guard let found else { continue }
        #expect(PersonalCatalog.changeNotification(for: found) == "AppleInterfaceMenuBarHidingChangedNotification")
        #expect(found.effect == .immediate)
    }
    let other = PersonalCatalog.systemSettings.first { $0.key == "AppleICUForce24HourTime" }
    #expect(other.map(PersonalCatalog.changeNotification(for:)) == .some(nil))
}
