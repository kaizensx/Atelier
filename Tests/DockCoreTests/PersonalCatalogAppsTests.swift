import Foundation
import Testing
@testable import DockCore

// The app catalogue's integrity, and container-domain writes against a scratch folder.
// Nothing here touches a real app's preferences.

private let appRows = PersonalCatalog.appCatalogue
private let appNames = Set(PersonalCatalog.apps.map(\.name))

@Test func appCatalogueIsBigAndSpread() {
    #expect(appRows.count >= 100)
    #expect(Set(appRows.map(\.section)).count >= 15)
    #expect(appRows.filter(\.experimental).count >= 5)
}

@Test func appCatalogueIsInTheMainCatalogue() {
    let ids = Set(PersonalCatalog.all.map(\.id))
    #expect(appRows.allSatisfy { ids.contains($0.id) })
    #expect(PersonalCatalog.finderExtraSettings.allSatisfy { ids.contains($0.id) })
}

@Test func everyAppRowBelongsToAKnownApp() {
    #expect(appRows.allSatisfy { $0.area == .apps && appNames.contains($0.section) })
    #expect(Set(PersonalCatalog.apps.map(\.bundleID)).count == PersonalCatalog.apps.count)
    #expect(appNames.count == PersonalCatalog.apps.count)
}

@Test func appRowsOfferARelaunchOfTheirOwnApp() {
    for row in appRows {
        #expect(row.effect == .relaunch(row.section))
        #expect(row.effect.relaunchTarget == row.section)
    }
    #expect(PersonalEffect.restart("Finder").relaunchTarget == nil)
    #expect(PersonalEffect.restart("Activity Monitor").relaunchTarget == "Activity Monitor")
}

@Test func containersMatchTheirApp() {
    for row in appRows {
        guard case let .container(bundleID) = row.storage else { continue }
        #expect(PersonalCatalog.app(named: row.section)?.bundleID == bundleID)
        #expect(row.storage.needsFullDiskAccess)
    }
    #expect(!PersonalStorage.standard.needsFullDiskAccess)
}

@Test func experimentalRowsSaySo() {
    let all = appRows + PersonalCatalog.finderExtraSettings
    #expect(all.filter(\.experimental).allSatisfy { $0.caution?.hasPrefix("Experimental") == true })
}

@Test func appControlsAreUsable() {
    for row in appRows {
        #expect(!row.title.isEmpty && !row.detail.isEmpty && !row.evidence.isEmpty && !row.preview.isEmpty)
        switch row.control {
        case let .toggle(on, off):
            #expect(on != off)
            #expect(PersonalValue(on.plist, as: row.kind) == on)
        case let .choice(options):
            #expect(options.count >= 2)
            #expect(Set(options.map(\.value)).count == options.count)
            #expect(options.allSatisfy { PersonalValue($0.value.plist, as: row.kind) == $0.value })
        case let .number(range, step, _):
            #expect(step > 0 && range.lowerBound < range.upperBound)
            if let fallback = row.fallback?.number { #expect(range.contains(fallback)) }
        default: break
        }
        if let fallback = row.fallback { #expect(PersonalValue(fallback.plist, as: row.kind) == fallback) }
    }
}

@Test func containerDomainIsAPath() {
    let prefs = PersonalPrefs(containers: "/tmp/boxes")
    let row = PersonalCatalog.textEditSettings[0]
    #expect(prefs.storeDomain(row) == "/tmp/boxes/com.apple.TextEdit/Data/Library/Preferences/com.apple.TextEdit")
    #expect(prefs.storeDomain(PersonalCatalog.calendarSettings[0]) == "com.apple.iCal")
}

// MARK: Container writes, in a scratch folder

private func scratchContainers() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("atelier-containers-\(UUID().uuidString)")
}

private func sample(_ bundleID: String) -> PersonalSetting {
    PersonalSetting(.apps, "Sample", domain: bundleID, key: "Flag", kind: .bool, control: .toggle(on: .bool(true), off: .bool(false)),
                    title: "Flag", detail: "", effect: .relaunch("Sample"), evidence: "test", preview: "",
                    storage: .container(bundleID))
}

@Test func containerApplyThenRevertRemovesTheKey() throws {
    let root = scratchContainers()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleID = "net.dasantos.atelier.test.\(UUID().uuidString)"
    let prefs = PersonalPrefs(containers: root.path)
    try FileManager.default.createDirectory(atPath: prefs.preferencesFolder(container: bundleID), withIntermediateDirectories: true)
    let suite = "net.dasantos.atelier.test.ledger.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let engine = PersonalEngine(prefs: prefs, ledger: PersonalLedger(suite: suite))
    let row = sample(bundleID)

    #expect(prefs.isReachable(row))
    #expect(prefs.read(row) == nil)
    try engine.apply(.bool(true), to: row)
    #expect(prefs.read(row) == .bool(true))
    try engine.revert(row)
    #expect(prefs.read(row) == nil)
    #expect(!engine.ledger.isTracked(row.id))
}

@Test func missingContainerIsNotCreated() {
    let root = scratchContainers()
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "net.dasantos.atelier.test.ledger.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bundleID = "net.dasantos.atelier.test.\(UUID().uuidString)"
    let prefs = PersonalPrefs(containers: root.path)
    let engine = PersonalEngine(prefs: prefs, ledger: PersonalLedger(suite: suite))
    let row = sample(bundleID)

    #expect(prefs.blocker(row) != nil)
    #expect(throws: (any Error).self) { try engine.apply(.bool(true), to: row) }
    #expect(!engine.ledger.isTracked(row.id))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(bundleID).path))
}
