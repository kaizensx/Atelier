import Foundation

// MARK: - Instant Spaces: the pure parts
//
// Everything here is plain data in, plain data out, so it can be tested without a window
// server: the bytes of a synthetic Dock swipe, the walk from one desktop to another, the
// keyboard chords, and reading the window server's description of the desktops.

/// The Dock's own trackpad gesture, rebuilt as an event. A three-finger swipe arrives at the
/// Dock as a "dock control" event (CGS type 30) whose HID type is 23 (DockSwipe). A swipe that
/// ends with a huge velocity and almost no travel commits the switch with nothing left to
/// animate, which is what makes it instant. Technique from InstantSpaceSwitcher (jurplel).
public enum DockSwipe {
    public enum Phase: Int64, Sendable { case began = 1, changed = 2, ended = 4 }

    /// Private CGEvent fields a real swipe carries. Numbers, not names: Apple publishes none.
    public enum Field {
        public static let cgsType: UInt32 = 55
        public static let hidType: UInt32 = 110
        public static let swipeMotion: UInt32 = 123
        public static let progress: UInt32 = 124
        public static let positionX: UInt32 = 125
        public static let velocityX: UInt32 = 129
        public static let velocityY: UInt32 = 130
        public static let phase: UInt32 = 132
        public static let phaseAlias: UInt32 = 134
        public static let zoomDeltaY: UInt32 = 138
        public static let timestampAlias: UInt32 = 169
    }

    public static let dockControl: Int64 = 30
    /// The companion every real swipe comes with; the Dock ignores a swipe without one.
    public static let gesture: Int64 = 29
    public static let dockSwipe: Int64 = 23
    public static let horizontal: Int64 = 1
    /// The smallest non-zero 16.16 value: it keeps the direction and leaves nothing to slide.
    public static let progress = 0.000016
    /// The fling that commits the switch. The payload is 16.16 fixed point, so ~32767 is the ceiling.
    public static let fling = 9999.0
    /// The tag CGEventCreateData uses for the raw IOHID payload macOS 27 insists on.
    public static let payloadTag: UInt16 = 4205

    /// Signed travel for a direction on macOS 27. The Dock reads the sign through the
    /// natural-scrolling preference, so it flips with it; "right" is negative with it on.
    public static func sign(right: Bool, naturalScrolling: Bool) -> Double {
        let natural: Double = right ? -1 : 1
        return naturalScrolling ? natural : -natural
    }

    /// Signed travel for a direction on a given release. Before macOS 27 the Dock takes a
    /// synthetic swipe's sign as it comes, whatever the scrolling preference: right is
    /// positive. (InstantSpaceSwitcher's legacy path on 13–26 and yabai's SIP-on path on 26
    /// both post it that way; the natural-scrolling flip arrived with 27's IOHID payload.)
    public static func sign(right: Bool, naturalScrolling: Bool, major: Int) -> Double {
        usesPayload(major: major) ? sign(right: right, naturalScrolling: naturalScrolling) : (right ? 1 : -1)
    }

    /// macOS 27 ignores a synthetic swipe unless it carries the raw IOHID payload and comes
    /// with a companion gesture event. Earlier releases take the bare Dock-control event,
    /// with velocity on every phase and no companion.
    public static func usesPayload(major: Int) -> Bool { major >= 27 }

    /// 16.16 fixed point, never rounding a non-zero value to zero (that would drop the direction).
    public static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64((value * 65536).rounded(.towardZero)))
        if fixed == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    /// The raw IOHID queue element macOS 27 wants appended to a synthetic swipe: a header, a
    /// fluid-touch gesture event, and on the last phase a velocity event. All little-endian,
    /// packed, exactly as IOHIDFamily lays them out (28 + 40 + 28 bytes).
    public static func payload(phase: Phase, progress: Double, positionX: Double, velocityX: Double,
                               timestamp: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out += $0 } }
        let withVelocity = velocityX != 0 || phase == .ended
        // Queue element header: timestamp, sender, options, attribute length, event count.
        put(timestamp); put(UInt64(0)); put(UInt32(0)); put(UInt32(0)); put(UInt32(withVelocity ? 2 : 1))
        // Fluid touch gesture (type 23): base (size, type, options = phase << 24, depth, pad).
        put(UInt32(40)); put(UInt32(23)); put(UInt32(truncatingIfNeeded: (phase.rawValue & 0xFF) << 24)); out += [0, 0, 0, 0]
        put(fixed1616(positionX)); put(Int32(0)); put(Int32(0))
        put(UInt32(0))                       // swipe mask
        put(UInt16(horizontal)); put(UInt16(3)) // motion, flavour 3 = Dock primary
        put(fixed1616(progress))
        if withVelocity {
            // Velocity (type 9), one level deeper.
            put(UInt32(28)); put(UInt32(9)); put(UInt32(0)); out += [1, 0, 0, 0]
            put(fixed1616(velocityX)); put(Int32(0)); put(Int32(0))
        }
        return out
    }

    /// Appends the payload to a serialized CGEvent under its tag. Only format version 2 is
    /// understood (its first four bytes are 00 00 00 02); anything else returns nil rather
    /// than guessing, and the caller falls back to Control-Arrow.
    public static func augment(eventData: [UInt8], payload: [UInt8]) -> [UInt8]? {
        guard eventData.count >= 4, eventData[0] == 0, eventData[1] == 0, eventData[2] == 0, eventData[3] == 2,
              payload.count <= 0xFFFF else { return nil }
        let size = UInt16(payload.count)
        return eventData + [UInt8(size >> 8), UInt8(size & 0xFF), UInt8(payloadTag >> 8), UInt8(payloadTag & 0xFF)] + payload
    }
}

/// One display's desktops as the window server lists them (CGSCopyManagedDisplaySpaces).
public struct ManagedDisplay: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public let id: Int          // ManagedSpaceID
        public let uuid: String
        /// 0 is a desktop; 4 is a full-screen app. The swipe walks through both.
        public let type: Int
        public init(id: Int, uuid: String, type: Int) { self.id = id; self.uuid = uuid; self.type = type }
    }
    public let identifier: String
    public let current: Int
    public let spaces: [Space]
    public init(identifier: String, current: Int, spaces: [Space]) {
        self.identifier = identifier; self.current = current; self.spaces = spaces
    }

    public var desktops: [Space] { spaces.filter { $0.type == 0 } }

    public static func parse(_ raw: [[String: Any]]) -> [ManagedDisplay] {
        raw.map { display in
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? 0
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = space["ManagedSpaceID"] as? Int else { return nil }
                return Space(id: id, uuid: space["uuid"] as? String ?? "\(id)", type: space["type"] as? Int ?? 0)
            }
            return ManagedDisplay(identifier: display["Display Identifier"] as? String ?? "", current: current, spaces: spaces)
        }
    }
}

public enum SpaceWalk {
    /// Signed number of one-desktop swipes from `from` to `to` in Mission Control's order
    /// (positive is right). Full-screen apps sit in that order too, so they count as steps.
    /// Nil when either end is unknown.
    public static func steps(in order: [Int], from: Int, to: Int) -> Int? {
        guard let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) else { return nil }
        return b - a
    }

    /// Where a switch to `target` has to happen. With "Displays have separate Spaces" on, the
    /// window server lists one entry per display, and both the Dock's swipe and Control-Arrow
    /// act on the display under the pointer, so a desktop that lives on another display
    /// cannot be reached from here. `cursorDisplay` is that display's UUID, nil when unknown
    /// (then the display holding the target is trusted).
    public enum Route: Equatable, Sendable {
        case display(Int)
        case otherDisplay
        case unknown
    }

    public static func route(to target: Int, in displays: [ManagedDisplay], cursorDisplay: String?) -> Route {
        guard let holder = displays.firstIndex(where: { $0.spaces.contains { $0.id == target } }) else { return .unknown }
        guard displays.count > 1, let cursorDisplay,
              let under = displays.firstIndex(where: { $0.identifier.caseInsensitiveCompare(cursorDisplay) == .orderedSame })
        else { return .display(holder) }
        return under == holder ? .display(holder) : .otherDisplay
    }

    /// The display whose desktops a "Desktop N" shortcut means: the one under the pointer
    /// when each display has its own Spaces, else the only list there is.
    public static func displayForShortcuts(_ displays: [ManagedDisplay], cursorDisplay: String?) -> ManagedDisplay? {
        guard displays.count > 1, let cursorDisplay else { return displays.first }
        return displays.first { $0.identifier.caseInsensitiveCompare(cursorDisplay) == .orderedSame } ?? displays.first
    }
}

/// Whether Mission Control's own "Move left a space" (79) and "Move right a space" (81)
/// shortcuts are on, from `com.apple.symbolichotkeys`' AppleSymbolicHotKeys. Control-Arrow is
/// Atelier's fallback, and it only does something while macOS still listens for it. An entry
/// that is missing means the system default, which is on.
public enum SpaceArrowShortcuts {
    public static let leftID = "79"
    public static let rightID = "81"

    public static func enabled(_ table: [String: Any]?) -> (left: Bool, right: Bool) {
        func on(_ id: String) -> Bool {
            guard let entry = table?[id] as? [String: Any] else { return true }
            if let flag = entry["enabled"] as? Bool { return flag }
            if let number = entry["enabled"] as? NSNumber { return number.boolValue }
            return true
        }
        return (on(leftID), on(rightID))
    }
}

/// The ways a window can be moved to another desktop without injecting anything, newest first.
public enum SpaceSendMethod: String, Sendable, CaseIterable {
    /// SkyLight's bridged window-management operation (yabai #2788, confirmed on 26.4+ and 27).
    case bridged
    /// SLSMoveWindowsToManagedSpace, which an ordinary process may call up to macOS 14.4.
    case direct
    /// The legacy workspace compat-ID pair, which yabai used on 14.5+ until Sequoia closed it.
    case compatID

    /// The methods worth trying on a release, in order. The bridge is used wherever it exists;
    /// the older two only on the releases where they are known to work for a process outside
    /// the Dock (yabai `workspace_use_macos_space_workaround`, issues #2240 and #2331). On 15
    /// and later without the bridge there is no SIP-on way, and none is pretended.
    public static func candidates(major: Int, minor: Int, bridgeAvailable: Bool) -> [SpaceSendMethod] {
        var list: [SpaceSendMethod] = bridgeAvailable ? [.bridged] : []
        if major < 14 || (major == 14 && minor < 5) { list.append(.direct) }
        else if major == 14 { list.append(.compatID) }
        return list
    }
}

/// The modifier chord that, with a number key, jumps to a desktop; Shift added sends the
/// focused window there instead.
public enum SpaceChord: String, CaseIterable, Identifiable, Sendable {
    case control, option, controlOption, hyper
    public var id: String { rawValue }

    // CGEventFlags raw values, so this file needs no CoreGraphics.
    public static let controlFlag: UInt64 = 0x40000
    public static let optionFlag: UInt64 = 0x80000
    public static let shiftFlag: UInt64 = 0x20000
    public static let commandFlag: UInt64 = 0x100000
    static let relevant: UInt64 = controlFlag | optionFlag | shiftFlag | commandFlag

    public var title: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .controlOption: "⌃⌥"
        case .hyper: "Hyper"
        }
    }

    public var jumpFlags: UInt64 {
        switch self {
        case .control: Self.controlFlag
        case .option: Self.optionFlag
        case .controlOption: Self.controlFlag | Self.optionFlag
        case .hyper: Self.relevant
        }
    }

    /// Hyper already holds Shift, so it has no free chord for sending; the menu and drag still do.
    public var sendFlags: UInt64? { self == .hyper ? nil : jumpFlags | Self.shiftFlag }

    /// "⌃1" style label for a desktop number.
    public func label(_ number: Int, send: Bool = false) -> String {
        send ? (self == .hyper ? "" : "⇧" + title + "\(number)") : title + (self == .hyper ? "-" : "") + "\(number)"
    }
}

public enum SpaceHotkey: Equatable, Sendable {
    case jump(Int)
    case send(Int)

    /// ANSI number-row key codes for 1…9.
    public static let digitKeycodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// What a key press means, if anything. Modifiers must match exactly, so ⌃⌥1 is not ⌃1
    /// and Atelier never swallows a chord it does not own.
    public static func match(keycode: Int64, flags: UInt64, chord: SpaceChord) -> SpaceHotkey? {
        guard let index = digitKeycodes.firstIndex(of: keycode) else { return nil }
        let held = flags & SpaceChord.relevant
        if held == chord.jumpFlags { return .jump(index + 1) }
        if let send = chord.sendFlags, held == send { return .send(index + 1) }
        return nil
    }
}

public enum InstantSpacesReport {
    public static func line(instant: Bool, jumps: Int, sends: Int, probe: String, send: String, hotkeys: Bool, tap: Bool,
                            lastMs: Double?) -> String {
        "spacesInstant=\(instant) spacesJumps=\(jumps) spacesSends=\(sends) spacesProbe=\(probe) spacesSend=\(send) " +
            "spacesHotkeys=\(hotkeys) spacesTap=\(tap) spacesLastMs=\(lastMs.map { String(format: "%.0f", $0) } ?? "-")"
    }
}
