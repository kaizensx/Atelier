import Foundation
import Testing
@testable import DockCore

// MARK: Packets

@Test func ddcGetRequestMatchesM1ddcBytes() {
    // m1ddc: 0x82 0x01 code, checksum 0x6E ^ 0x51 ^ the three bytes.
    let packet = DDCPacket.getRequest(0x10)
    let expected: [UInt8] = [0x82, 0x01, 0x10, UInt8(0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10)]
    #expect(packet == expected)
    #expect(packet.last == 0xAC)
    // MonitorControl's read seed: destination only.
    let legacy = DDCPacket.getRequest(0x10, seed: .destinationOnly)
    let legacySum: UInt8 = 0x6E ^ 0x82 ^ 0x01 ^ 0x10
    #expect(legacy.last == legacySum)
}

@Test func ddcSetRequestMatchesMonitorControlAndIntelFraming() {
    let packet = DDCPacket.setRequest(0x10, value: 0x0150)
    let checksum: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x01 ^ 0x50
    let expected: [UInt8] = [0x84, 0x03, 0x10, 0x01, 0x50, checksum]
    #expect(packet == expected)
    // IntelDDC prepends 0x51 and seeds with 0x6E alone: the same checksum byte.
    let framed = DDCPacket.framed(packet!)
    #expect(framed.first == 0x51)
    #expect(DDCPacket.checksum(seed: 0x6E, framed.dropLast()) == framed.last)
}

@Test func ddcNeverBuildsFactoryResetOrPowerWrites() {
    for code: UInt8 in [0x04, 0x05, 0x06, 0x08, 0x0A, 0xD6, 0x00, 0x14, 0xFF] {
        #expect(DDCPacket.setRequest(code, value: 1) == nil)
        #expect(!DDCSafety.mayWrite(code))
    }
    for code in VCPCode.allCases {
        #expect(DDCSafety.mayWrite(code.rawValue))
        #expect(DDCSafety.mayWrite(code.rawValue, externalDisplays: 1))
        // No external display: nothing is written, whatever the code.
        #expect(!DDCSafety.mayWrite(code.rawValue, externalDisplays: 0))
    }
}

@Test func ddcParsesAGoodReply() {
    let reply = DDCPacket.makeReply(code: 0x10, current: 63, maximum: 100)
    #expect(reply.count == 11)
    #expect(DDCPacket.parseReply(reply, code: 0x10) == .value(current: 63, maximum: 100))
    // Two-byte values.
    let wide = DDCPacket.makeReply(code: 0x62, current: 0x0102, maximum: 0x0304)
    #expect(DDCPacket.parseReply(wide, code: 0x62) == .value(current: 0x0102, maximum: 0x0304))
}

@Test func ddcRejectsBadReplies() {
    var reply = DDCPacket.makeReply(code: 0x10, current: 63, maximum: 100)
    #expect(DDCPacket.parseReply(Array(reply.prefix(8)), code: 0x10) == .invalid("short reply"))
    #expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 11), code: 0x10) == .invalid("no answer"))
    #expect(DDCPacket.parseReply([UInt8](repeating: 0xFF, count: 11), code: 0x10) == .invalid("no answer"))
    #expect(DDCPacket.parseReply(reply, code: 0x12) == .invalid("wrong code"))
    reply[9] ^= 1
    #expect(DDCPacket.parseReply(reply, code: 0x10) == .invalid("bad checksum"))
    let unsupported = DDCPacket.makeReply(code: 0x62, current: 0, maximum: 0, result: 1)
    #expect(DDCPacket.parseReply(unsupported, code: 0x62) == .unsupported)
}

// MARK: Retry plan

@Test func ddcRetryPlanFollowsMonitorControlTimings() {
    let policy = DDCRetryPolicy.standard
    let plan = policy.plan(read: true)
    // Five attempts, each: two delayed writes, the read delay, a read, a check.
    #expect(plan.filter { $0 == .read }.count == 5)
    #expect(plan.filter { $0 == .check }.count == 5)
    #expect(plan.filter { if case .write = $0 { true } else { false } }.count == 10)
    #expect(Array(plan.prefix(6)) == [.wait(10_000), .write(.standard), .wait(10_000), .write(.standard), .wait(50_000), .read])
    // The second attempt switches seed; no wait after the last check.
    #expect(plan.contains(.write(.destinationOnly)))
    #expect(plan.last == .check)
    // A write never reads and never changes its checksum.
    let write = policy.plan(read: false)
    #expect(!write.contains(.read))
    #expect(!write.contains(.write(.destinationOnly)))
    #expect(abs(policy.worstCase(read: true) - (5 * 0.07 + 4 * 0.02)) < 1e-9)
    #expect(DDCRetryPolicy.probe.worstCase(read: true) < 0.25)
}

// MARK: Values

@Test func ddcScaleMapsBothWays() {
    #expect(DDCScale.raw(0.5, maximum: 100) == 50)
    #expect(DDCScale.raw(1, maximum: 0) == 100)
    #expect(DDCScale.raw(2, maximum: 80) == 80)
    #expect(DDCScale.raw(-1, maximum: 80) == 0)
    #expect(DDCScale.raw(.nan, maximum: 80) == 0)
    #expect(DDCScale.fraction(40, maximum: 80) == 0.5)
    #expect(DDCScale.fraction(200, maximum: 100) == 1)
    for raw: UInt16 in 0...100 { #expect(DDCScale.raw(DDCScale.fraction(raw, maximum: 100), maximum: 100) == raw) }
}

@Test func ddcSoftwareDimNeverGoesBlack() {
    #expect(DDCScale.softwareScale(1) == 1)
    #expect(DDCScale.softwareScale(0) == DDCScale.softwareFloor)
    #expect(DDCScale.softwareScale(0) > 0.1)
    #expect(DDCScale.softwareScale(.infinity) == 1)
    #expect(DDCScale.softwareScale(0.5) < DDCScale.softwareScale(0.6))
}

@Test func ddcMuteAndInputValues() {
    #expect(DDCScale.muteValue(true) == 1)
    #expect(DDCScale.muteValue(false) == 2)
    #expect(DDCScale.isMuted(0x0101))
    #expect(!DDCScale.isMuted(2))
    #expect(DDCInput.name(0x0F) == "DisplayPort 1")
    #expect(DDCInput.name(0x1211) == "HDMI 1")
    #expect(DDCInput.name(0x7A) == "Input 0x7A")
    #expect(DDCInput.common.allSatisfy { DDCInput.names[$0] != nil })
}

@Test func ddcCodesParseFromTokens() {
    #expect(VCPCode(token: "0x10") == .brightness)
    #expect(VCPCode(token: "16") == .brightness)
    #expect(VCPCode(token: "Volume") == .volume)
    #expect(VCPCode(token: "0x8d") == .mute)
    #expect(VCPCode(token: "0x04") == nil)
    #expect(VCPCode(token: "reset") == nil)
}

// MARK: Glide and coalescing

@Test func ddcGlideIsShortEasedAndLandsExactly() {
    let steps = DDCGlide.steps(from: 0.2, to: 0.8, maximum: 100)
    #expect(steps.count <= 7)
    #expect(steps.last == 80)
    #expect(steps == steps.sorted())
    #expect(Set(steps).count == steps.count)
    // Eased out: the first step covers more than a sixth of the way.
    #expect(Double(steps[0]) - 20 > 60.0 / 6)
    let down = DDCGlide.steps(from: 0.8, to: 0.2, maximum: 100)
    #expect(down.last == 20)
    #expect(down == down.sorted(by: >))
    #expect(DDCGlide.steps(from: 0.5, to: 0.5, maximum: 100) == [50])
    // A tiny move on a coarse scale is one write.
    #expect(DDCGlide.steps(from: 0.5, to: 0.51, maximum: 10) == [5])
}

@Test func ddcCoalescerKeepsOnlyTheNewestValue() {
    var bus = DDCCoalescer()
    bus.push(0x10, 10); bus.push(0x10, 20); bus.push(0x62, 5); bus.push(0x10, 30)
    let first = bus.next()
    #expect(first?.code == 0x10 && first?.value == 30)
    bus.record(0x10, 30)
    let second = bus.next()
    #expect(second?.code == 0x62 && second?.value == 5)
    #expect(bus.next() == nil)
    // The same value again is not sent; after a reconnect it is.
    bus.push(0x10, 30)
    #expect(bus.next() == nil)
    bus.forget()
    bus.push(0x10, 30)
    #expect(bus.next()?.value == 30)
    #expect(bus.isEmpty)
}

// MARK: Matching

@Test func ddcMatchScoresEdidFieldsLikeMonitorControl() {
    // Vendor 0x10AC (Dell), product 0xA0C4 stored little-endian, week 12 of 2021, 60×34 cm.
    // The layout macOS writes "EDID UUID" in: dashes included, fields at fixed offsets.
    let uuid = "10ACC4A0-0000-0000-0C1F-0104B53C2278"
    let display = DDCDisplayFacts(vendor: 0x10AC, product: 0xA0C4, serial: 77, week: 12, year: 2021,
                                  horizontalMM: 600, verticalMM: 340, location: "IOService:/x/y", name: "DELL U2720Q")
    let service = DDCServiceFacts(edidUUID: uuid, path: "IOService:/x/y", productName: "dell u2720q", serial: 77,
                                  location: "External", index: 1)
    #expect(DDCMatch.score(display, service) == 4 + 10 + 1 + 1)
    #expect(DDCMatch.score(display, DDCServiceFacts(edidUUID: uuid, index: 2)) == 4)
    #expect(DDCMatch.score(DDCDisplayFacts(), DDCServiceFacts()) == 0)
}

@Test func ddcAssignGivesEachServiceOneDisplay() {
    let a = DDCDisplayFacts(location: "IOService:/a", name: "A")
    let b = DDCDisplayFacts(location: "IOService:/b", name: "B")
    let services = [DDCServiceFacts(path: "IOService:/b", productName: "B", index: 1),
                    DDCServiceFacts(path: "IOService:/a", productName: "A", index: 2),
                    DDCServiceFacts(productName: "A", index: 3)]
    let map = DDCMatch.assign(displays: [(1, a), (2, b)], services: services)
    #expect(map[1] == 2)
    #expect(map[2] == 1)
    // Two identical monitors and one service: only one gets it.
    let twin = DDCMatch.assign(displays: [(1, a), (3, a)], services: [services[2]])
    #expect(twin.count == 1)
    #expect(DDCMatch.assign(displays: [(9, DDCDisplayFacts())], services: services).isEmpty)
}

@Test func ddcEligibilitySkipsBuiltInVirtualAndDummies() {
    #expect(DDCEligibility.verdict(builtIn: true, virtual: false, appleNative: true, serviceLocation: "Embedded") == .skip("built-in panel"))
    #expect(DDCEligibility.verdict(builtIn: false, virtual: true, appleNative: false, serviceLocation: nil) == .skip("virtual display"))
    #expect(DDCEligibility.verdict(builtIn: false, virtual: false, appleNative: false, serviceLocation: "External", dummy: true) == .skip("dummy plug"))
    #expect(DDCEligibility.verdict(builtIn: false, virtual: false, appleNative: true, serviceLocation: "External") == .native)
    #expect(DDCEligibility.verdict(builtIn: false, virtual: false, appleNative: false, serviceLocation: "Embedded") == .skip("not external"))
    #expect(DDCEligibility.verdict(builtIn: false, virtual: false, appleNative: false, serviceLocation: "External") == .ddc)
    // No AV service found (Intel, or an adapter that hides it): still a candidate for the I²C path.
    #expect(DDCEligibility.verdict(builtIn: false, virtual: false, appleNative: false, serviceLocation: nil) == .ddc)
    #expect(DDCEligibility.isDummy(manufacturer: "AOC", product: "28E850"))
}

@Test func ddcMemoryKeyIsStablePerMonitor() {
    let one = DDCMemory.key(vendor: 0x10AC, model: 0xA0C4, serial: 12345, name: "DELL U2720Q")
    #expect(one == "ddc.monitor.10ac-a0c4-12345")
    #expect(DDCMemory.key(vendor: 0x10AC, model: 0xA0C4, serial: 0, name: "DELL U2720Q") == "ddc.monitor.10ac-a0c4-dellu2720q")
    #expect(one.hasPrefix("ddc."))
}

@Test func ddcAudioMatchesMonitorSpeakers() {
    #expect(DDCAudio.matches(device: "DELL U2720Q", display: "DELL U2720Q"))
    #expect(DDCAudio.matches(device: "LG HDR 4K", display: "LG HDR 4K (1)"))
    #expect(!DDCAudio.matches(device: "MacBook Pro Speakers", display: "DELL U2720Q"))
    #expect(!DDCAudio.matches(device: "", display: "DELL"))
}

// MARK: Hook

@Test func ddcHookParsesEveryForm() {
    #expect(DDCCommand.parse([]) == .list)
    #expect(DDCCommand.parse([("list", nil)]) == .list)
    #expect(DDCCommand.parse([("read", "0x10"), ("display", "5")]) == .read(.brightness, display: 5))
    #expect(DDCCommand.parse([("set", "0x62"), ("value", "30")]) == .set(.volume, value: 30, display: nil))
    #expect(DDCCommand.parse([("brightness", "0.4"), ("display", "7")]) == .level(.brightness, fraction: 0.4, display: 7))
    #expect(DDCCommand.parse([("refresh", nil)]) == .refresh)
    if case .invalid = DDCCommand.parse([("set", "0x04"), ("value", "1")]) {} else { Issue.record("factory reset must not parse") }
    if case .invalid = DDCCommand.parse([("set", "0x10")]) {} else { Issue.record("set without value") }
    if case .invalid = DDCCommand.parse([("brightness", "3")]) {} else { Issue.record("out of range") }
    if case .invalid = DDCCommand.parse([("read", "0x10"), ("display", "main")]) {} else { Issue.record("bad display") }
}
