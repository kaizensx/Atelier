import DockCore
import Foundation
import Testing

@Suite struct FanControlTests {
    // MARK: Curves

    @Test func curveInterpolatesAndIsFlatPastTheEnds() throws {
        let curve = FanCurve([.init(50, 0), .init(70, 0.5), .init(90, 1)])
        #expect(curve.level(at: 49.9) == nil)
        #expect(curve.level(at: 50) == 0)
        #expect(curve.level(at: 60) == 0.25)
        #expect(curve.level(at: 80) == 0.75)
        #expect(curve.level(at: 90) == 1)
        #expect(curve.level(at: 140) == 1)
        let always = FanCurve([.init(50, 0.2), .init(90, 1)], systemBelowStart: false)
        #expect(always.level(at: 20) == 0.2)
    }

    @Test func curveCleansItsPoints() {
        let curve = FanCurve([.init(80, 2), .init(40, -1), .init(40, 0.5), .init(.nan, 0.3)])
        #expect(curve.points == [.init(40, 0), .init(80, 1)])
        #expect(FanCurve([]).points == [.init(0, 1)])
    }

    @Test func curveTextRoundTrips() throws {
        for preset in FanPreset.allCases {
            guard let curve = preset.curve else { continue }
            #expect(FanCurve.parse(curve.text) == curve)
        }
        #expect(FanCurve.parse("55:0,68:0.3,80:0.7,90:1")?.points.count == 4)
        #expect(FanCurve.parse("~0:1")?.systemBelowStart == false)
        #expect(FanCurve.parse("55:0,junk") == nil)
        #expect(FanCurve.parse("") == nil)
        #expect(FanCurve([.init(55, 0.25)]).text == "55:0.25")
    }

    @Test func movingAPointKeepsTheCurveRising() {
        var curve = FanCurve([.init(50, 0.1), .init(70, 0.5), .init(90, 1)])
        curve.move(1, celsius: 30, level: 0)
        #expect(curve.points[1] == .init(51, 0.1))
        curve.move(1, celsius: 200, level: 2)
        #expect(curve.points[1] == .init(89, 1))
        curve.move(9, celsius: 60, level: 0.5)
        #expect(curve.points.count == 3)
    }

    @Test func presetsMakeSense() throws {
        #expect(FanPreset.system.curve == nil)
        #expect(FanPreset.custom.curve == nil)
        let max = try #require(FanPreset.max.curve)
        #expect(max.level(at: 20) == 1)
        let silent = try #require(FanPreset.silent.curve), balanced = try #require(FanPreset.balanced.curve)
        for t in stride(from: 30.0, through: 100, by: 5) {
            #expect((silent.level(at: t) ?? 0) <= (balanced.level(at: t) ?? 0))
        }
    }

    // MARK: Targets

    @Test func neverBelowMinimumNorAboveMaximum() {
        #expect(FanTarget.rpm(level: 0, min: 1200, max: 5700) == 1200)
        #expect(FanTarget.rpm(level: 1, min: 1200, max: 5700) == 5700)
        #expect(FanTarget.rpm(level: 0.5, min: 1000, max: 5000) == 3000)
        #expect(FanTarget.rpm(level: -3, min: 1200, max: 5700) == 1200)
        #expect(FanTarget.rpm(level: .nan, min: 1200, max: 5700) == 5700)
        #expect(FanTarget.rpm(level: 0.5, min: 1200, max: 0) == 1200)
        #expect(FanTarget.clamp(0, min: 1200, max: 5700) == 1200)
        #expect(FanTarget.clamp(9000, min: 1200, max: 5700) == 5700)
        #expect(FanTarget.clamp(.infinity, min: 1200, max: 5700) == 5700)
    }

    // MARK: Governor

    @Test func governorHandsBackWithoutAReading() {
        var g = FanGovernor()
        let curve = FanPreset.max.curve!
        #expect(g.step(temperature: nil, curve: curve, dt: 1) == .system)
        #expect(g.step(temperature: .nan, curve: curve, dt: 1) == .system)
    }

    @Test func governorSlewsUpFastAndDownSlowly() {
        var g = FanGovernor()
        let curve = FanPreset.max.curve!
        #expect(g.step(temperature: 50, curve: curve, dt: 1) == .level(0.5))
        #expect(g.step(temperature: 50, curve: curve, dt: 1) == .level(1))
        let low = FanCurve([.init(0, 0.2)], systemBelowStart: false)
        let next = g.step(temperature: 50, curve: low, dt: 1)
        #expect(abs((next.level ?? 0) - 0.92) < 1e-9)
    }

    @Test func governorHysteresisStopsHunting() {
        var g = FanGovernor()
        g.riseRate = 100
        g.fallRate = 100
        let curve = FanCurve([.init(60, 0), .init(80, 1)])
        #expect(g.step(temperature: 70, curve: curve, dt: 1) == .level(0.5))
        // A drop of 2 degrees is inside the 3-degree band: nothing moves.
        #expect(g.step(temperature: 68, curve: curve, dt: 1) == .level(0.5))
        // Further down, it follows 3 degrees above the reading.
        #expect(g.step(temperature: 62, curve: curve, dt: 1) == .level(0.25))
        // Up is immediate.
        #expect(g.step(temperature: 76, curve: curve, dt: 1) == .level(0.8))
        // Below the curve's start (plus the band) it is the system's again.
        #expect(g.step(temperature: 50, curve: curve, dt: 1) == .system)
        #expect(g.level == nil)
    }

    @Test func governorHardLimitLatches() {
        var g = FanGovernor(hardLimit: 90)
        let curve = FanPreset.silent.curve!
        #expect(g.step(temperature: 91, curve: curve, dt: 1) == .overheat)
        #expect(g.step(temperature: 85, curve: curve, dt: 1) == .overheat)
        #expect(g.step(temperature: 81, curve: curve, dt: 1) != .overheat)
        #expect(FanGovernor(hardLimit: 300).hardLimit == 105)
        #expect(FanGovernor(hardLimit: 10).hardLimit == 80)
    }

    @Test func dryRunReportsRPMPerFan() {
        let rows = FanDryRun.run(curve: FanPreset.max.curve!, temperatures: [40, 40, 40], fans: [(1000, 5000), (1200, 6000)])
        #expect(rows.count == 3)
        #expect(rows[0].rpm == [3000, 3600])
        #expect(rows[2].rpm == [5000, 6000])
        let off = FanDryRun.run(curve: FanPreset.balanced.curve!, temperatures: [40], fans: [(1000, 5000)])
        #expect(off[0].demand == .system)
        #expect(off[0].rpm == [nil])
        #expect(FanDryRun.temperatures("40, 50,x,60") == [40, 50, 60])
        #expect(FanDryRun.temperatures("ramp").first == 35)
        #expect(FanDryRun.temperatures("ramp").max() == 100)
    }

    // MARK: SMC encoding

    @Test func encodesTheInverseOfDecode() throws {
        let float = try #require(SMCEncode.bytes(type: "flt ", value: 2400, size: 4))
        #expect(SMCDecode.value(type: "flt ", bytes: float) == 2400)
        #expect(float == [0x00, 0x00, 0x16, 0x45])
        #expect(SMCEncode.bytes(type: "ui8 ", value: 1, size: 1) == [1])
        #expect(SMCEncode.bytes(type: "ui8 ", value: 400, size: 1) == [255])
        #expect(SMCEncode.bytes(type: "ui16", value: 38400, size: 2) == [0x96, 0x00])
        let fpe2 = try #require(SMCEncode.bytes(type: "fpe2", value: 2000, size: 2))
        #expect(SMCDecode.value(type: "fpe2", bytes: fpe2) == 2000)
        #expect(SMCEncode.bytes(type: "ui32", value: 3628, size: 4) == [0, 0, 0x0E, 0x2C])
    }

    @Test func refusesWhatItCannotEncodeExactly() {
        #expect(SMCEncode.bytes(type: "flt ", value: 2400, size: 2) == nil)
        #expect(SMCEncode.bytes(type: "ui8 ", value: 1, size: 4) == nil)
        #expect(SMCEncode.bytes(type: "hex_", value: 1, size: 1) == nil)
        #expect(SMCEncode.bytes(type: "{fds", value: 1, size: 16) == nil)
        #expect(SMCEncode.bytes(type: "flt ", value: .nan, size: 4) == nil)
    }

    @Test func findsTheModeKeyInEitherCase() {
        #expect(FanKeys.mode(0, in: ["F0Ac", "F0md"]) == "F0md")
        #expect(FanKeys.mode(1, in: ["F1Md"]) == "F1Md")
        #expect(FanKeys.mode(0, in: ["F0Ac"]) == nil)
        #expect(FanKeys.fans(in: ["F0Ac", "F1Ac", "F3Ac", "F1Mn"]) == [0, 1, 3])
        #expect(SMCFanMode.manual.rawValue == 1)
        #expect(SMCFanMode.auto.rawValue == 0)
    }

    // MARK: Safety

    private func command(sent: Double, rpm: Double? = 3000, limit: Double = 95) -> FanCommand {
        FanCommand(sent: sent, seq: 1, fans: [.init(index: 0, rpm: rpm)], hardLimit: limit, reason: "test")
    }

    @Test func safetyReturnsToTheSystem() {
        var hot = false
        #expect(FanSafety.decide(command: nil, now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot) == .system("no command"))
        #expect(FanSafety.decide(command: command(sent: 89), now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot) == .system("heartbeat"))
        #expect(FanSafety.decide(command: command(sent: 111), now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot) == .system("heartbeat"))
        #expect(FanSafety.decide(command: command(sent: 99), now: 100, hottest: 60, asleep: true, wokeAt: nil, overheated: &hot) == .system("sleep"))
        #expect(FanSafety.decide(command: command(sent: 95), now: 100, hottest: 60, asleep: false, wokeAt: 97, overheated: &hot) == .system("wake"))
        #expect(FanSafety.decide(command: command(sent: 99), now: 100, hottest: nil, asleep: false, wokeAt: nil, overheated: &hot) == .system("no temperature"))
        var old = command(sent: 99)
        old.version = 99
        #expect(FanSafety.decide(command: old, now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot) == .system("version"))
        let quit = FanCommand.system(sent: 99, seq: 2, reason: "quit")
        #expect(FanSafety.decide(command: quit, now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot) == .system("quit"))
    }

    @Test func safetyFollowsAFreshCommand() {
        var hot = false
        #expect(FanSafety.decide(command: command(sent: 99), now: 100, hottest: 60, asleep: false, wokeAt: 50, overheated: &hot) == .manual([0: 3000]))
        let mixed = FanCommand(sent: 99, seq: 1, fans: [.init(index: 0, rpm: 2000), .init(index: 1, rpm: nil)], hardLimit: 95, reason: "x")
        let decision = FanSafety.decide(command: mixed, now: 100, hottest: 60, asleep: false, wokeAt: nil, overheated: &hot)
        #expect(decision == .manual([0: 2000]))
    }

    @Test func safetyOverheatLatchesAndClears() {
        var hot = false
        #expect(FanSafety.decide(command: command(sent: 99, limit: 90), now: 100, hottest: 91, asleep: false, wokeAt: nil, overheated: &hot) == .overheat)
        #expect(FanSafety.decide(command: command(sent: 99, limit: 90), now: 100, hottest: 84, asleep: false, wokeAt: nil, overheated: &hot) == .overheat)
        #expect(FanSafety.decide(command: command(sent: 99, limit: 90), now: 100, hottest: 81, asleep: false, wokeAt: nil, overheated: &hot) == .manual([0: 3000]))
        // A limit outside the range is pulled into it: 200 is treated as 105.
        #expect(FanSafety.decide(command: command(sent: 99, limit: 200), now: 100, hottest: 106, asleep: false, wokeAt: nil, overheated: &hot) == .overheat)
        // Even a command that asks for nothing to be manual cannot be overheated: the system cools.
        #expect(FanSafety.decide(command: .system(sent: 99, seq: 3, reason: "off"), now: 100, hottest: 120, asleep: false, wokeAt: nil, overheated: &hot) == .system("off"))
        #expect(hot == false)
    }

    @Test func protocolRoundTripsAsJSON() throws {
        let c = command(sent: 1234.5)
        #expect(try JSONDecoder().decode(FanCommand.self, from: JSONEncoder().encode(c)) == c)
        let s = FanHelperStatus(pid: 7, time: 1, state: "manual", reason: "balanced",
                                fans: [.init(index: 0, mode: 1, target: 2400, actual: 2390, min: 1200, max: 5700)],
                                modeKey: "F0md", hasUnlock: false, unlockUsed: false, hottest: 61, reclaims: 0, error: nil)
        #expect(try JSONDecoder().decode(FanHelperStatus.self, from: JSONEncoder().encode(s)) == s)
    }

    // MARK: Install

    @Test func installScriptsQuoteEveryPath() {
        let script = FanHelperInstall.installScript(helperSource: "/Applications/Atelier's.app/Contents/MacOS/AtelierFans",
                                                    plistSource: "/tmp/x y.plist", owner: 501)
        #expect(script.contains("'/Applications/Atelier'\\''s.app/Contents/MacOS/AtelierFans'"))
        #expect(script.contains("'/tmp/x y.plist'"))
        #expect(script.contains("/usr/sbin/chown 501 '/Library/Application Support/Atelier/Fans/Inbox'"))
        #expect(script.contains("/bin/launchctl bootstrap system '/Library/LaunchDaemons/net.dasantos.atelier.fans.plist'"))
        #expect(FanHelperInstall.removeScript.contains("bootout system/net.dasantos.atelier.fans"))
        #expect(FanHelperInstall.removeScript.hasSuffix("true"))
        let plist = FanHelperInstall.plist(owner: 501)
        #expect(plist.contains("<string>501</string>"))
        #expect(plist.contains("<key>KeepAlive</key><true/>"))
        let data = Data(plist.utf8)
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(parsed?["Label"] as? String == FanHelperInstall.label)
        #expect((parsed?["ProgramArguments"] as? [String])?.first == FanHelperInstall.helperPath)
    }
}
