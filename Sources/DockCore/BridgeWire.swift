import Foundation

// MARK: - Dock Bridge wire protocol
//
// Ported from koekeishiya/yabai (MIT) src/osax/common.h and src/sa.m. The binary framing is
// kept byte-for-byte compatible with yabai's scheme so the ObjC payload (Native/payload.m)
// and this Swift client agree without a second implementation:
//
//     [int16 length][uint8 opcode][payload bytes ...]
//
// `length` counts the opcode and payload, not the two length bytes themselves. Every scalar
// is packed little-endian (Apple silicon is little-endian), matching yabai's `pack()` macro,
// which is a raw `memcpy` of each value in order.
//
// Atelier re-numbers the opcodes into its own contiguous set and versions the protocol, so a
// client and a payload of different versions refuse each other at the handshake rather than
// misreading a message.
//
// Original work: Copyright © 2019 Åsmund Vikane. MIT License. Adapted for Atelier.

/// The protocol version carried in the handshake. Bump on any wire-format change.
public let bridgeProtocolVersion: UInt32 = 1

/// Commands the Dock payload understands. Values must match `Native/common.h`.
public enum BridgeOpcode: UInt8, Sendable {
    case handshake        = 0x01
    case heartbeat        = 0x02
    case spaceFocus       = 0x03
    case spaceCreate      = 0x04
    case spaceDestroy     = 0x05
    case spaceMove        = 0x06
    case windowToSpace    = 0x07
    case windowOpacity    = 0x08
    case windowOpacityFade = 0x09
    case windowLayer      = 0x0A
    case windowSticky     = 0x0B
    case windowShadow     = 0x0C
    case windowScale      = 0x0D
}

/// CoreGraphics window-level keys the payload maps through `CGWindowLevelForKey`. Only the two
/// Atelier needs: a window sitting at the normal level, or floating above every other window.
public enum BridgeWindowLevel: Int32, Sendable {
    case normal = 4   // kCGNormalWindowLevelKey
    case onTop  = 5   // kCGFloatingWindowLevelKey
}

/// Builds a request frame. Appends scalars little-endian, then prepends the int16 length, so
/// the bytes are identical to what yabai's `sa_payload_init`/`pack`/`sa_payload_send` produce.
public struct BridgeMessage {
    public let opcode: BridgeOpcode
    private var body: [UInt8] = []

    public init(_ opcode: BridgeOpcode) { self.opcode = opcode }

    public mutating func pack<T>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { body.append(contentsOf: $0) }
    }

    /// Packs a C float (32-bit), the width the payload unpacks for alpha/duration/scale.
    public mutating func pack(float value: Double) { pack(Float(value)) }

    /// The complete frame, ready to `send()`.
    public func encoded() -> [UInt8] {
        let length = Int16(1 + body.count)          // opcode + payload
        var out = [UInt8]()
        out.reserveCapacity(2 + Int(length))
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(opcode.rawValue)
        out.append(contentsOf: body)
        return out
    }
}

/// The request encoders, one per contract method. Pure functions: easy to unit-test against a
/// known byte layout, and the single place the wire format lives on the Swift side.
public enum BridgeWire {

    public static func handshake() -> [UInt8] { BridgeMessage(.handshake).encoded() }
    public static func heartbeat() -> [UInt8] { BridgeMessage(.heartbeat).encoded() }

    public static func setOpacity(_ wid: UInt32, alpha: Double, duration: Double) -> [UInt8] {
        var m = BridgeMessage(duration > 0 ? .windowOpacityFade : .windowOpacity)
        m.pack(wid)
        m.pack(float: alpha)
        if duration > 0 { m.pack(float: duration) }
        return m.encoded()
    }

    public static func setLayer(_ wid: UInt32, _ level: BridgeWindowLevel) -> [UInt8] {
        var m = BridgeMessage(.windowLayer)
        m.pack(wid)
        m.pack(level.rawValue)
        return m.encoded()
    }

    public static func setSticky(_ wid: UInt32, _ sticky: Bool) -> [UInt8] {
        var m = BridgeMessage(.windowSticky)
        m.pack(wid)
        m.pack(UInt8(sticky ? 1 : 0))
        return m.encoded()
    }

    public static func setShadow(_ wid: UInt32, _ shadow: Bool) -> [UInt8] {
        var m = BridgeMessage(.windowShadow)
        m.pack(wid)
        m.pack(UInt8(shadow ? 1 : 0))
        return m.encoded()
    }

    /// Scale about an anchor in screen points; the payload rebuilds the affine transform.
    public static func setScale(_ wid: UInt32, scale: Double, anchorX: Double, anchorY: Double) -> [UInt8] {
        var m = BridgeMessage(.windowScale)
        m.pack(wid)
        m.pack(float: scale)
        m.pack(float: anchorX)
        m.pack(float: anchorY)
        return m.encoded()
    }

    public static func moveWindowToSpace(_ wid: UInt32, space sid: UInt64) -> [UInt8] {
        var m = BridgeMessage(.windowToSpace)
        m.pack(sid)
        m.pack(wid)
        return m.encoded()
    }

    public static func focusSpace(_ sid: UInt64) -> [UInt8] {
        var m = BridgeMessage(.spaceFocus)
        m.pack(sid)
        return m.encoded()
    }

    public static func createSpace(onDisplay display: UInt32) -> [UInt8] {
        var m = BridgeMessage(.spaceCreate)
        m.pack(display)
        return m.encoded()
    }

    public static func destroySpace(_ sid: UInt64) -> [UInt8] {
        var m = BridgeMessage(.spaceDestroy)
        m.pack(sid)
        return m.encoded()
    }

    /// Move `src` to sit directly after `dst` (a reorder on the same display).
    public static func moveSpace(_ src: UInt64, after dst: UInt64, focus: Bool) -> [UInt8] {
        var m = BridgeMessage(.spaceMove)
        m.pack(src)
        m.pack(dst)
        m.pack(UInt64(0))              // source_prev_space_id: unused for a same-display reorder
        m.pack(UInt8(focus ? 1 : 0))
        return m.encoded()
    }

    // MARK: Response decoding

    /// The handshake reply: a NUL-terminated version string followed by a uint32 attribute
    /// mask. Returns nil if the bytes are too short or unterminated. Mirrors yabai's
    /// `scripting_addition_request_handshake`.
    public static func decodeHandshake(_ bytes: [UInt8]) -> (version: String, attributes: UInt32)? {
        guard let nul = bytes.firstIndex(of: 0) else { return nil }
        guard bytes.count >= nul + 1 + 4 else { return nil }
        let version = String(decoding: bytes[0..<nul], as: UTF8.self)
        var attr: UInt32 = 0
        for i in 0..<4 { attr |= UInt32(bytes[nul + 1 + i]) << (8 * i) }
        return (version, attr)
    }
}
