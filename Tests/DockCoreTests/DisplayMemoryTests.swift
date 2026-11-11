import CoreGraphics
import Foundation
import Testing
@testable import DockCore

private func builtIn(frame: CGRect = CGRect(x: 0, y: 0, width: 1728, height: 1117)) -> DisplayFacts {
    DisplayFacts(uuid: "AAAA-BUILTIN", vendor: 0x610, model: 0xa053, serial: 0xfd626d62, name: "Built-in Display",
                 builtIn: true, frame: frame, visible: CGRect(x: frame.minX, y: frame.minY + 38, width: frame.width, height: frame.height - 38))
}

private func dell(frame: CGRect = CGRect(x: 1728, y: -200, width: 2560, height: 1440), serial: UInt32 = 0x4c4b3031,
                  uuid: String = "BBBB-DELL") -> DisplayFacts {
    DisplayFacts(uuid: uuid, vendor: 0x10ac, model: 0xa0c4, serial: serial, name: "DELL U2720Q", builtIn: false,
                 frame: frame, visible: CGRect(x: frame.minX, y: frame.minY + 25, width: frame.width, height: frame.height - 25), scale: 1)
}

private func window(_ app: String, _ title: String, _ frame: CGRect, id: Int? = nil, pid: Int32? = 100, display: String? = nil, order: Int = 0) -> RememberedWindow {
    RememberedWindow(app: app, appName: app, title: title, windowID: id, pid: pid, frame: frame, display: display, order: order)
}

// MARK: Fingerprint

@Test func fingerprintIgnoresListOrderAndUUIDWhenSerialIsKnown() {
    let a = DisplayConfiguration([builtIn(), dell()])
    let b = DisplayConfiguration([dell(uuid: "CHANGED-PORT"), builtIn()])
    #expect(a.key == b.key)
    #expect(a.key.hasPrefix("dm-") && a.key.count == 19)
    #expect(a.displays.count == 2)
    #expect(a.summary == "Built-in Display + DELL U2720Q")
}

@Test func fingerprintChangesWithArrangementResolutionAndScale() {
    let base = DisplayConfiguration([builtIn(), dell()]).key
    #expect(DisplayConfiguration([builtIn(), dell(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))]).key != base)
    #expect(DisplayConfiguration([builtIn(), dell(frame: CGRect(x: 1728, y: -200, width: 1920, height: 1080))]).key != base)
    var scaled = dell(); scaled.scale = 2
    #expect(DisplayConfiguration([builtIn(), scaled]).key != base)
    #expect(DisplayConfiguration([builtIn()]).key != base)
    #expect(DisplayConfiguration([builtIn()]).key == DisplayConfiguration([builtIn()]).key)
}

@Test func twinsWithoutSerialAreToldApartByPosition() {
    let left = dell(frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), serial: 0, uuid: "SAME")
    let right = dell(frame: CGRect(x: 3648, y: 0, width: 1920, height: 1080), serial: 0, uuid: "SAME")
    let config = DisplayConfiguration([right, builtIn(), left])
    #expect(Set(config.identities).count == 3)
    #expect(config.identities.contains("same") && config.identities.contains("same#2"))
    #expect(config.display(identity: "same")?.frame.minX == 1728)
}

@Test func fnvIsStable() {
    // Known FNV-1a 64 vectors.
    #expect(DisplayMemoryLogic.fnv1a("") == 0xcbf29ce484222325)
    #expect(DisplayMemoryLogic.fnv1a("a") == 0xaf63dc4c8601ec8c)
}

@Test func identityForRectUsesOverlapThenDistance() {
    let config = DisplayConfiguration([builtIn(), dell()])
    let dellID = dell().baseIdentity, builtID = builtIn().baseIdentity
    #expect(config.identity(for: CGRect(x: 2000, y: 100, width: 800, height: 600)) == dellID)
    #expect(config.identity(for: CGRect(x: 1500, y: 100, width: 400, height: 400)) == builtID) // 228 vs 172 wide
    #expect(config.identity(for: CGRect(x: 9000, y: 100, width: 10, height: 10)) == dellID)
    #expect(DisplayConfiguration([]).identity(for: .zero) == nil)
}

// MARK: Diff and merge

@Test func differsSeesMovesAddsAndRemovesButNotJitter() {
    let a = [window("com.a", "One", CGRect(x: 10, y: 10, width: 500, height: 400), id: 1),
             window("com.b", "Two", CGRect(x: 600, y: 10, width: 500, height: 400), id: 2)]
    var jitter = a; jitter[0].frame.origin.x += 1
    #expect(!DisplayMemoryLogic.differs(a, jitter))
    #expect(!DisplayMemoryLogic.differs(a, a.reversed()))
    var moved = a; moved[1].frame.origin.y += 40
    #expect(DisplayMemoryLogic.differs(a, moved))
    #expect(DisplayMemoryLogic.differs(a, Array(a.prefix(1))))
    var renamed = a; renamed[0].windowID = 9
    #expect(DisplayMemoryLogic.differs(a, renamed))
}

@Test func mergeKeepsWindowsOnOtherSpacesWhileTheyLive() {
    let previous = [window("com.a", "Here", .zero, id: 1, order: 0), window("com.a", "Other Space", .zero, id: 2, order: 1),
                    window("com.b", "Closed", .zero, id: 3, order: 2), window("com.c", "No id", .zero, id: nil, order: 3)]
    let fresh = [window("com.a", "Here", CGRect(x: 5, y: 5, width: 5, height: 5), id: 1, order: 0)]
    let merged = DisplayMemoryLogic.merge(previous: previous, fresh: fresh, alive: [1, 2])
    #expect(merged.map(\.windowID) == [1, 2])
    #expect(merged.map(\.order) == [0, 1])
    #expect(merged[0].frame.minX == 5)
}

@Test func listSignatureIgnoresOrderAndSubpointNoise() {
    let a: [(id: Int, bounds: CGRect)] = [(1, CGRect(x: 0, y: 0, width: 10, height: 10)), (2, CGRect(x: 20, y: 0, width: 10, height: 10))]
    let b: [(id: Int, bounds: CGRect)] = [(2, CGRect(x: 20.2, y: 0, width: 10, height: 10)), (1, CGRect(x: 0, y: 0, width: 10, height: 10))]
    #expect(DisplayMemoryLogic.listSignature(a) == DisplayMemoryLogic.listSignature(b))
    #expect(DisplayMemoryLogic.listSignature(a) != DisplayMemoryLogic.listSignature([a[0]]))
}

// MARK: Matching

@Test func matchPrefersWindowIDThenTitleThenSimilarThenOrder() {
    let saved = [
        window("com.apple.TextEdit", "Notes.txt", .zero, id: 41, pid: 7, order: 0),
        window("com.apple.Safari", "Inbox (3) — Mail", .zero, id: 900, pid: 8, order: 1),   // id gone: Safari relaunched
        window("com.apple.Safari", "Apple", .zero, id: 901, pid: 8, order: 2),
        window("com.apple.Terminal", "zsh", .zero, id: 5, pid: 9, order: 3),
        window("com.apple.Terminal", "ssh box", .zero, id: 6, pid: 9, order: 4),
        window("com.missing", "Gone", .zero, id: 77, pid: 10, order: 5),
    ]
    let live = [
        LiveWindow(app: "com.apple.Terminal", title: "vim", windowID: 50, pid: 19, frame: .zero),
        LiveWindow(app: "com.apple.Safari", title: "Apple", windowID: 1201, pid: 18, frame: .zero),
        LiveWindow(app: "com.apple.TextEdit", title: "Renamed.txt", windowID: 41, pid: 7, frame: .zero),
        LiveWindow(app: "com.apple.Safari", title: "Inbox (5) — Mail", windowID: 1200, pid: 18, frame: .zero),
        LiveWindow(app: "com.apple.Terminal", title: "top", windowID: 51, pid: 19, frame: .zero),
    ]
    let pairs = DisplayMemoryLogic.match(saved: saved, live: live)
    let map = Dictionary(uniqueKeysWithValues: pairs.map { ($0.saved, ($0.live, $0.reason)) })
    #expect(map[0]?.0 == 2 && map[0]?.1 == .windowID)
    #expect(map[1]?.0 == 3 && map[1]?.1 == .similarTitle)
    #expect(map[2]?.0 == 1 && map[2]?.1 == .title)
    #expect(map[3]?.0 == 0 && map[3]?.1 == .appOrder)
    #expect(map[4]?.0 == 4 && map[4]?.1 == .appOrder)
    #expect(map[5] == nil)
    #expect(pairs.map(\.saved) == pairs.map(\.saved).sorted())
    #expect(Set(pairs.map(\.live)).count == pairs.count)
}

@Test func windowIDNeedsSameAppAndProcess() {
    let saved = [window("com.a", "x", .zero, id: 10, pid: 1)]
    #expect(DisplayMemoryLogic.match(saved: saved, live: [LiveWindow(app: "com.b", title: "y", windowID: 10, pid: 1, frame: .zero)]).isEmpty)
    let other = DisplayMemoryLogic.match(saved: saved, live: [LiveWindow(app: "com.a", title: "z", windowID: 10, pid: 2, frame: .zero)])
    #expect(other.first?.reason == .appOrder)
}

@Test func similarityScores() {
    #expect(DisplayMemoryLogic.similarity("Report.txt — Edited", "report.txt") == 1)
    #expect(DisplayMemoryLogic.similarity("Inbox (3)", "Inbox (5)") >= DisplayMemoryLogic.similarityThreshold)
    #expect(DisplayMemoryLogic.similarity("Budget 2026.numbers", "Holiday photos") < DisplayMemoryLogic.similarityThreshold)
    #expect(DisplayMemoryLogic.similarity("", "x") == 0)
}

// MARK: Placement

@Test func sameConfigurationRestoresTheExactFrame() {
    let config = DisplayConfiguration([builtIn(), dell()])
    let w = window("com.a", "x", CGRect(x: 2000, y: 100, width: 900, height: 700), display: dell().baseIdentity)
    let (frame, placement) = DisplayMemoryLogic.target(for: w, saved: config, current: config)
    #expect(frame == w.frame && placement == .exact)
}

@Test func windowFollowsItsDisplayWhenArrangementChanges() {
    let saved = DisplayConfiguration([builtIn(), dell()])
    let now = DisplayConfiguration([builtIn(), dell(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))])
    let w = window("com.a", "x", CGRect(x: 2000, y: 100, width: 900, height: 700))
    let (frame, placement) = DisplayMemoryLogic.target(for: w, saved: saved, current: now)
    #expect(placement == .followed)
    #expect(frame == CGRect(x: 2000 - 1728 - 2560, y: 300, width: 900, height: 700))
}

@Test func windowScalesWithItsDisplayAtAnotherResolution() {
    let saved = DisplayConfiguration([dell(frame: CGRect(x: 0, y: 0, width: 2560, height: 1465))])
    let now = DisplayConfiguration([dell(frame: CGRect(x: 0, y: 0, width: 1280, height: 745))])
    let w = window("com.a", "x", CGRect(x: 1280, y: 25, width: 1280, height: 720))
    let (frame, placement) = DisplayMemoryLogic.target(for: w, saved: saved, current: now)
    #expect(placement == .followed)
    #expect(frame == CGRect(x: 640, y: 25, width: 640, height: 360))
}

@Test func missingDisplayRehomesOntoThePrimaryAndStaysOnScreen() {
    let saved = DisplayConfiguration([builtIn(), dell()])
    let now = DisplayConfiguration([builtIn()])
    let w = window("com.a", "x", CGRect(x: 3500, y: 1000, width: 2400, height: 300))
    let (frame, placement) = DisplayMemoryLogic.target(for: w, saved: saved, current: now)
    #expect(placement == .rehomed)
    let visible = builtIn().visible
    #expect(visible.contains(frame))
    #expect(frame.width == visible.width && frame.height == 300)
}

@Test func fitAndProportional() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(DisplayMemoryLogic.fit(CGRect(x: 90, y: -10, width: 50, height: 50), in: bounds) == CGRect(x: 50, y: 0, width: 50, height: 50))
    #expect(DisplayMemoryLogic.fit(CGRect(x: 0, y: 0, width: 500, height: 10), in: bounds).width == 100)
    #expect(DisplayMemoryLogic.proportional(CGRect(x: 50, y: 50, width: 10, height: 10), from: bounds,
                                            to: CGRect(x: 100, y: 0, width: 200, height: 200)) == CGRect(x: 200, y: 100, width: 20, height: 20))
    #expect(!DisplayMemoryLogic.needsMove(CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 2, y: 0, width: 10, height: 10)))
    #expect(DisplayMemoryLogic.needsMove(CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 9, y: 0, width: 10, height: 10)))
}

// MARK: Settle gate and journal

@Test func gateWaitsOutABurstAndFiresOnce() {
    var gate = DisplaySettleGate(quiet: 1.2, stable: 1.0, maxWait: 15)
    #expect(gate.observe(key: "A", now: 0) == nil)          // nothing pending
    gate.noteChange(now: 10)
    #expect(gate.observe(key: "B", now: 10.1) == nil)
    gate.noteChange(now: 10.5)                              // burst continues
    #expect(gate.observe(key: "B", now: 11.5) == nil)       // only 1.0 s quiet
    #expect(gate.observe(key: "C", now: 11.8) == nil)       // key flickered
    #expect(gate.observe(key: "C", now: 12.5) == nil)       // C seen 0.7 s
    #expect(gate.observe(key: "C", now: 12.9) == "C")
    #expect(!gate.settling)
    #expect(gate.observe(key: "C", now: 13) == nil)         // once
}

@Test func gateWaitsForADisplayAndGivesUpOnFlapping() {
    var gate = DisplaySettleGate(quiet: 1, stable: 1, maxWait: 5)
    gate.noteChange(now: 0)
    #expect(gate.observe(key: nil, now: 3) == nil)          // lid closed, nothing attached
    var t = 3.0, flip = false
    var settled: String?
    while t < 10, settled == nil {
        gate.noteChange(now: t)
        flip.toggle()
        settled = gate.observe(key: flip ? "A" : "B", now: t + 0.1)
        t += 0.5
    }
    #expect(settled != nil)
    #expect(t <= 5.6)
}

@Test func journalDropsSnapshotsTakenJustBeforeAReconfiguration() {
    var journal = SnapshotJournal<Int>(confirmDelay: 1.5)
    journal.propose(key: "A", payload: 1, now: 0)
    #expect(journal.due(now: 1, currentKey: "A") == nil)
    journal.invalidate()                                    // displays began changing at t=1.2
    #expect(journal.due(now: 2, currentKey: "A") == nil)
    journal.propose(key: "A", payload: 2, now: 3)
    #expect(journal.due(now: 4.6, currentKey: "A")?.payload == 2)
    #expect(journal.pending == nil)
    journal.propose(key: "A", payload: 3, now: 5)
    #expect(journal.due(now: 7, currentKey: "B") == nil)    // configuration changed meanwhile
}

@Test func setupRoundTripsThroughJSON() throws {
    let config = DisplayConfiguration([builtIn(), dell()])
    let setup = DisplaySetup(configuration: config, windows: [window("com.a", "x", CGRect(x: 1, y: 2, width: 3, height: 4), id: 5)],
                             updated: Date(timeIntervalSince1970: 1000), restores: 2)
    let decoded = try JSONDecoder().decode(DisplaySetup.self, from: JSONEncoder().encode(setup))
    #expect(decoded == setup)
    #expect(decoded.id == config.key)
}
