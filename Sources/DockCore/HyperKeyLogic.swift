import Foundation

// MARK: - Hyper Key mapping

/// The one hidutil entry Hyper Key adds: Caps Lock becomes F18, a key no Mac keyboard has and
/// no app listens for, so Atelier's event tap can own it without stepping on anything.
public enum HyperMapping {
    /// F18, HID page 7 usage 0x6D.
    public static let f18: UInt64 = 0x7_0000_006D
    public static let capsLock: UInt64 = KeyRemap.capsLock

    /// The Remap Keys entry that already claims Caps Lock, if any. Hyper gives way to it
    /// rather than silently overriding a choice made elsewhere.
    public static func conflict(in remaps: [KeyRemap]) -> KeyRemap? {
        remaps.first { remap in remap.pairs.contains { $0.0 == capsLock } }
    }

    /// The full UserKeyMapping for `hidutil property --set`: the Remap Keys entries, plus Caps
    /// Lock → F18 when Hyper is on and nothing else claims Caps Lock. hidutil replaces the
    /// whole list on every set, so both features always write it through this one function.
    public static func json(remaps: [KeyRemap], hyper: Bool) -> String {
        var pairs = remaps.flatMap(\.pairs)
        if hyper, conflict(in: remaps) == nil { pairs.append((capsLock, f18)) }
        return KeyRemap.json(pairs: pairs)
    }
}

extension KeyRemap {
    /// Builds the UserKeyMapping JSON from raw source and destination pairs. Later pairs win
    /// on a shared source key.
    public static func json(pairs: [(UInt64, UInt64)]) -> String {
        var bySource: [UInt64: UInt64] = [:], order: [UInt64] = []
        for (source, destination) in pairs {
            if bySource[source] == nil { order.append(source) }
            bySource[source] = destination
        }
        let entries = order.map { "{\"HIDKeyboardModifierMappingSrc\":\($0),\"HIDKeyboardModifierMappingDst\":\(bySource[$0]!)}" }
        return "{\"UserKeyMapping\":[" + entries.joined(separator: ",") + "]}"
    }
}

// MARK: - Hyper Key state

/// What the event tap does with each key while Hyper Key runs. Kept free of CoreGraphics so the
/// timing rules can be tested: F18 (the remapped Caps Lock) is always swallowed; other keys
/// pressed while it is held get all four modifiers; a short press with nothing else in between
/// becomes Escape.
public struct HyperKeyState: Sendable {
    /// macOS virtual key codes (kVK_F18, kVK_Escape).
    public static let hyperKeycode: Int64 = 79
    public static let escapeKeycode: Int64 = 53
    /// A press longer than this is a held modifier the user changed their mind about, not a tap.
    public static let tapLimit: UInt64 = 300_000_000

    public enum Verdict: Equatable, Sendable {
        /// The event goes on unchanged.
        case pass
        /// The event goes on with ⌃⌥⇧⌘ added.
        case passWithHyper
        /// The event is dropped.
        case swallow
        /// The event is dropped and an Escape press is sent in its place.
        case swallowAndEscape
    }

    public private(set) var held = false
    /// Whether another key went down while Hyper was held, which rules out a tap.
    public private(set) var used = false
    private var pressedAt: UInt64 = 0

    public init() {}

    /// - Parameters:
    ///   - now: a monotonic clock in nanoseconds.
    ///   - tapForEscape: whether a lone tap should become Escape.
    public mutating func key(code: Int64, down: Bool, isRepeat: Bool, now: UInt64, tapForEscape: Bool) -> Verdict {
        if code == Self.hyperKeycode {
            if down {
                // Key repeat while Caps Lock is held must not restart the tap timer.
                if !isRepeat || !held {
                    held = true
                    used = false
                    pressedAt = now
                }
                return .swallow
            }
            let lone = held && !used && now &- pressedAt < Self.tapLimit
            held = false
            used = false
            return lone && tapForEscape ? .swallowAndEscape : .swallow
        }
        guard held else { return .pass }
        if down { used = true }
        return .passWithHyper
    }

    /// Forgets a press in progress, for when the tap is removed mid-press.
    public mutating func reset() {
        held = false
        used = false
    }
}

// MARK: - Lost key-ups

extension HyperKeyState {
    /// Squares the state with the key's real position. A key-up can go missing: while a
    /// password field has Secure Input on, macOS keeps every keystroke from event taps, so a
    /// Caps Lock let go there is never seen, and without this every later key would arrive with
    /// ⌃⌥⇧⌘ held. `hyperDown` is the HID system's own record of whether the key is down.
    public mutating func reconcile(hyperDown: Bool) {
        if held && !hyperDown { reset() }
    }
}

// MARK: - Is macOS honouring the mapping?

/// Watches for the one sign that hidutil's Caps Lock → F18 is not in effect: a real Caps Lock
/// event (a flags change with kVK_CapsLock) reaching the tap while Atelier believes the key is
/// mapped. macOS 14.2 and later sometimes keep a mapping in the list (`hidutil property --get`
/// shows it) without applying it to a keyboard until that keyboard reconnects; a write made
/// right after a wake or a reconnect can also land before the keyboard is ready. The watcher
/// asks for one fresh write first, and only reports the problem if Caps Lock still leaks
/// through after that write had time to land.
public struct HyperMappingWatch: Sendable, Equatable {
    /// kVK_CapsLock.
    public static let capsLockKeycode: Int64 = 57
    /// How long a rewrite has to take effect before a second leak counts as a failure.
    public static let settle: UInt64 = 2_000_000_000
    /// After this long without a leak, a later one starts over with a rewrite.
    public static let forgive: UInt64 = 60_000_000_000

    public enum Action: Equatable, Sendable {
        case none
        /// Send the whole list to hidutil again.
        case rewrite
        /// The rewrite did not help: tell the person.
        case report
    }

    private var rewroteAt: UInt64?
    public private(set) var reported = false

    public init() {}

    /// Feed every flags-changed event the tap sees while the mapping should be active.
    public mutating func flagsChanged(keycode: Int64, mapped: Bool, now: UInt64) -> Action {
        guard mapped, keycode == Self.capsLockKeycode else { return .none }
        if let at = rewroteAt, now &- at < Self.forgive {
            // Too soon: the write may still be on its way.
            guard now &- at >= Self.settle else { return .none }
            if reported { return .none }
            reported = true
            return .report
        }
        rewroteAt = now
        reported = false
        return .rewrite
    }

    /// The mapping was written afresh for another reason (wake, a keyboard arriving).
    public mutating func reset() {
        rewroteAt = nil
        reported = false
    }
}

// MARK: - Hold ⌘Q to Quit

/// What Hold ⌘Q does with a ⌘Q key-down. Kept apart from the tap so the lost-key-up case can be
/// tested: if the key-up of an earlier press was never seen (Secure Input took it, or macOS
/// briefly disabled the tap), a fresh, non-repeat press must start over instead of being
/// treated as the old press repeating, or every later ⌘Q would be swallowed for good.
public enum QuitHoldDecision: Equatable, Sendable {
    /// Swallow it: the ring is already filling (key repeat).
    case swallowRepeat
    /// Start a new hold (the previous one, if any, is abandoned first).
    case begin
    /// Let it through untouched (not a plain ⌘Q).
    case pass

    /// - Parameters:
    ///   - command: ⌘ is held; `otherModifiers`: ⇧, ⌥ or ⌃ is held too.
    ///   - holding: a hold is in progress as far as Atelier knows.
    public static func keyDown(command: Bool, otherModifiers: Bool, isRepeat: Bool, holding: Bool) -> QuitHoldDecision {
        guard command, !otherModifiers else { return .pass }
        if holding && isRepeat { return .swallowRepeat }
        return .begin
    }
}
