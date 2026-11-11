import Foundation
import Testing
@testable import DockCore

// Wire protocol: the bytes must match exactly what Native/payload.m unpacks (little-endian,
// int16 length counting opcode+payload). These assertions pin that layout down.

@Test func handshakeFrameIsOpcodeOnly() {
    #expect(BridgeWire.handshake() == [0x01, 0x00, 0x01])  // len=1, op=handshake
}

@Test func heartbeatFrame() {
    #expect(BridgeWire.heartbeat() == [0x01, 0x00, 0x02])
}

@Test func stickyPacksWidThenBool() {
    // wid = 0x11223344, sticky = true
    let bytes = BridgeWire.setSticky(0x1122_3344, true)
    #expect(bytes == [0x06, 0x00, 0x0B, 0x44, 0x33, 0x22, 0x11, 0x01])
}

@Test func shadowFalsePacksZeroByte() {
    let bytes = BridgeWire.setShadow(1, false)
    #expect(bytes == [0x06, 0x00, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x00])
}

@Test func opacityNoDurationUsesPlainOpcodeAndFloatBits() {
    // alpha 0.5f == 0x3F000000, little-endian 00 00 00 3F
    let bytes = BridgeWire.setOpacity(1, alpha: 0.5, duration: 0)
    #expect(bytes == [0x09, 0x00, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F])
}

@Test func opacityWithDurationSwitchesOpcodeAndAppendsDuration() {
    let bytes = BridgeWire.setOpacity(1, alpha: 0.0, duration: 0.5)
    // op = 0x09 (fade), wid, alpha(0.0 -> 00 00 00 00), duration(0.5 -> 00 00 00 3F)
    #expect(bytes == [0x0D, 0x00, 0x09, 0x01, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F])
}

@Test func onTopUsesFloatingLevelKey() {
    let bytes = BridgeWire.setLayer(1, .onTop)
    // op windowLayer=0x0A, wid u32, level Int32 = 5
    #expect(bytes == [0x09, 0x00, 0x0A, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
}

@Test func moveWindowToSpacePacksSidThenWid() {
    let bytes = BridgeWire.moveWindowToSpace(2, space: 7)
    #expect(bytes == [0x0D, 0x00, 0x07,
                      0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   // sid u64 = 7
                      0x02, 0x00, 0x00, 0x00])                           // wid u32 = 2
}

@Test func moveSpaceAfterPacksSrcDstZeroPrevFocus() {
    let bytes = BridgeWire.moveSpace(3, after: 9, focus: true)
    #expect(bytes == [0x1A, 0x00, 0x06,
                      0x03, 0,0,0,0,0,0,0,     // src
                      0x09, 0,0,0,0,0,0,0,     // dst
                      0,0,0,0,0,0,0,0,         // prev = 0
                      0x01])                   // focus
}

@Test func scaleFrameLength() {
    // op + wid(4) + 3 floats(12) => length 17 = 0x11
    let bytes = BridgeWire.setScale(1, scale: 0.5, anchorX: 0, anchorY: 0)
    #expect(bytes[0] == 0x11 && bytes[1] == 0x00 && bytes[2] == 0x0D)
    #expect(bytes.count == 2 + 17)
}

@Test func decodeHandshakeReadsVersionAndAttributes() {
    var bytes = Array("1.0.0".utf8)
    bytes.append(0)
    bytes.append(contentsOf: [0x1F, 0x00, 0x00, 0x00])  // attrib = 0x1F
    let decoded = BridgeWire.decodeHandshake(bytes)
    #expect(decoded?.version == "1.0.0")
    #expect(decoded?.attributes == 0x1F)
}

@Test func decodeHandshakeRejectsTruncated() {
    #expect(BridgeWire.decodeHandshake([0x31, 0x00, 0x01]) == nil)  // no room for attrib
    #expect(BridgeWire.decodeHandshake([0x31, 0x32]) == nil)         // no NUL
}

@Test func protocolVersionMatchesNativeConstant() {
    // Native/common.h defines SA_PROTOCOL_VERSION 1.
    #expect(bridgeProtocolVersion == 1)
}
