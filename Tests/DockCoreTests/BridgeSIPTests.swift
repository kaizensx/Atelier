import Foundation
import Testing
@testable import DockCore

// CSR flag decoding: a set bit means that protection is OFF (allowed).

@Test func fullyEnabledConfigIsNotBridgeCapable() {
    let s = BridgeSIP(config: 0x00)
    #expect(s.isFullyEnabled)
    #expect(!s.isBridgeCapable)
    #expect(!s.filesystemProtectionsOff && !s.debuggingRestrictionsOff && !s.nvramProtectionsOff)
}

@Test func fsAndTfpOffIsBridgeCapable() {
    // 0x02 | 0x04 = 0x06
    let s = BridgeSIP(config: 0x06)
    #expect(s.filesystemProtectionsOff)
    #expect(s.debuggingRestrictionsOff)
    #expect(!s.nvramProtectionsOff)
    #expect(s.isBridgeCapable)
    #expect(!s.isFullyEnabled)
}

@Test func nvramBitDecoded() {
    let s = BridgeSIP(config: 0x40)
    #expect(s.nvramProtectionsOff)
    #expect(!s.filesystemProtectionsOff)
    #expect(!s.isBridgeCapable)   // needs fs + tfp too
}

@Test func onlyFsOffIsNotEnough() {
    let s = BridgeSIP(config: 0x02)
    #expect(s.filesystemProtectionsOff)
    #expect(!s.debuggingRestrictionsOff)
    #expect(!s.isBridgeCapable)
}

@Test func flagsStringShowsHexConfig() {
    #expect(BridgeSIP(config: 0x06).flags == "fs=off tfp=off nvram=on config=0x06")
    #expect(BridgeSIP(config: 0x00).flags == "fs=on tfp=on nvram=on config=0x00")
}

@Test func parseEnabledText() {
    let s = BridgeSIP.parse(csrutil: "System Integrity Protection status: enabled.")
    #expect(s.isFullyEnabled)
    #expect(!s.isBridgeCapable)
    #expect(s.rawConfig == nil)
}

@Test func parseDisabledText() {
    let s = BridgeSIP.parse(csrutil: "System Integrity Protection status: disabled.")
    #expect(!s.isFullyEnabled)
    #expect(s.isBridgeCapable)
}

@Test func parsePerProtectionBreakdown() {
    let text = """
    System Integrity Protection status: unknown (Custom Configuration).

    Configuration:
        Apple Internal: disabled
        Kext Signing: enabled
        Filesystem Protections: disabled
        Debugging Restrictions: disabled
        DTrace Restrictions: enabled
        NVRAM Protections: enabled
        BaseSystem Verification: enabled

    This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.
    """
    let s = BridgeSIP.parse(csrutil: text)
    #expect(s.filesystemProtectionsOff)
    #expect(s.debuggingRestrictionsOff)
    #expect(!s.nvramProtectionsOff)        // NVRAM Protections: enabled
    #expect(s.isBridgeCapable)             // fs + tfp off is enough to load
}

@Test func parseBreakdownAllEnabledIsNotCapable() {
    let text = """
    Configuration:
        Filesystem Protections: enabled
        Debugging Restrictions: enabled
        NVRAM Protections: enabled
    """
    let s = BridgeSIP.parse(csrutil: text)
    #expect(!s.isBridgeCapable)
}
