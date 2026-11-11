import Foundation

// MARK: - Atelier HUD: the pure part
//
// The volume, brightness and keyboard-light keys reach apps as NX_SYSDEFINED events (CGEvent
// type 14) of subtype 8. Everything about them lives in `data1`: the key in the high 16 bits,
// the state in the next byte (0xA down, 0xB up) and the repeat flag in bit 0. This file holds
// the decoding, Apple's step arithmetic and the shapes the HUD draws, so they can be tested
// without a keyboard.

/// The media keys Atelier HUD can take over, by their NX_KEYTYPE number.
public enum MediaKey: Int, Sendable, CaseIterable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case keyboardUp = 21
    case keyboardDown = 22

    public var kind: HUDKind {
        switch self {
        case .volumeUp, .volumeDown, .mute: .volume
        case .brightnessUp, .brightnessDown: .brightness
        case .keyboardUp, .keyboardDown: .keyboard
        }
    }

    /// Which way the key moves its level; nil for Mute, which toggles.
    public var raises: Bool? {
        switch self {
        case .volumeUp, .brightnessUp, .keyboardUp: true
        case .volumeDown, .brightnessDown, .keyboardDown: false
        case .mute: nil
        }
    }
}

/// What the HUD shows a level of.
public enum HUDKind: String, Sendable, CaseIterable {
    case volume, brightness, keyboard
}

/// One media key press or release, decoded from an NX_SYSDEFINED event.
public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let down: Bool
    public let isRepeat: Bool

    public init(key: MediaKey, down: Bool, isRepeat: Bool) {
        self.key = key
        self.down = down
        self.isRepeat = isRepeat
    }

    /// The NX_SYSDEFINED subtype that carries media keys (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    public static let subtype = 8

    /// Nil for any other subtype, an unknown key, or a state that is neither down nor up
    /// (other system-defined events share the type and must pass untouched).
    public static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == Self.subtype, let key = MediaKey(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return MediaKeyEvent(key: key, down: state == 0xA, isRepeat: data1 & 0x1 == 1)
    }

    /// The inverse of `decode`, for test tools that post keys.
    public static func data1(key: MediaKey, down: Bool, isRepeat: Bool = false) -> Int {
        (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8) | (isRepeat ? 1 : 0)
    }
}

/// Apple's level arithmetic: sixteen steps, and with ⌥⇧ held, quarter steps.
public enum HUDStep {
    public static let steps = 16

    /// The next level from `value`, snapped to the grid the way Apple does it: a level between
    /// two marks goes to the next mark in the key's direction, so up then down from any mark
    /// lands back on it exactly.
    public static func step(_ value: Double, up: Bool, fine: Bool) -> Double {
        let count = Double(steps * (fine ? 4 : 1))
        let index = min(max(value, 0), 1) * count
        // A hair of slack, so a stored 0.5625 that reads back as 0.56249994 still counts as on its mark.
        let slack = 1e-3
        let next = up ? (index + slack).rounded(.down) + 1 : (index - slack).rounded(.up) - 1
        return min(max(next / count, 0), 1)
    }

    /// How full each of `count` chiclets is, 0 to 1: whole ones, then one partly filled, so a
    /// quarter step shows as a quarter of a chiclet.
    public static func chiclets(_ level: Double, count: Int = steps) -> [Double] {
        let filled = min(max(level, 0), 1) * Double(count)
        return (0..<count).map { min(max(filled - Double($0), 0), 1) }
    }

    /// The level as a whole percentage, as the HUD prints it.
    public static func percent(_ level: Double) -> Int {
        Int((min(max(level, 0), 1) * 100).rounded())
    }
}

/// The SF Symbol for a level: the waves, the sun and the key light grow with it.
public enum HUDSymbol {
    public static func name(_ kind: HUDKind, level: Double, muted: Bool = false) -> String {
        switch kind {
        case .volume:
            if muted || level <= 0 { return "speaker.slash.fill" }
            if level < 1.0 / 3 { return "speaker.wave.1.fill" }
            if level < 2.0 / 3 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            return level < 0.5 ? "light.min" : "light.max"
        }
    }
}

/// The keyboard light's "Turn off after" choices. System Settings offers a handful up to five
/// minutes; Atelier goes from five seconds to half an hour. 0 means never.
public enum KeyboardIdle {
    public static let never = 0.0
    public static let choices: [Double] = [5, 10, 30, 60, 120, 300, 600, 900, 1800, never]

    public static func label(_ seconds: Double) -> String {
        if seconds <= 0 { return "Never" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = seconds / 60
        return minutes == minutes.rounded() ? "\(Int(minutes)) min" : String(format: "%.1f min", minutes)
    }

    /// The choice closest to what CoreBrightness reports, so the picker shows something
    /// sensible for a time set elsewhere.
    public static func nearest(_ seconds: Double) -> Double {
        if seconds <= 0 { return never }
        return choices.filter { $0 > 0 }.min { abs($0 - seconds) < abs($1 - seconds) } ?? 300
    }
}

// MARK: - Private method signatures

/// Checks an Objective-C method's type encoding before Atelier calls it through a C function
/// pointer. CoreBrightness is private and its methods could change type in any release; calling
/// one with the wrong argument types would read garbage or crash, so a mismatch turns the
/// control off instead. Offsets and qualifiers are ignored, and BOOL matches both of its
/// encodings ("c" on Intel, "B" on Apple silicon).
public enum ObjCSignature {
    /// The bare type codes: "B36@0:8f16i20B24Q28" → ["B", "@", ":", "f", "i", "B", "Q"].
    public static func types(_ encoding: String) -> [String] {
        var chars = Array(encoding)[...]
        var result: [String] = []
        while let token = next(&chars) { result.append(token) }
        return result
    }

    /// One type from the front of `chars`, skipping offsets and qualifiers; nil at the end.
    private static func next(_ chars: inout ArraySlice<Character>) -> String? {
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V", "A"]
        while let c = chars.first, c.isNumber || qualifiers.contains(c) { chars = chars.dropFirst() }
        guard let c = chars.first else { return nil }
        chars = chars.dropFirst()
        switch c {
        case "^":
            // A pointer, kept with what it points to as one code.
            return "^" + (next(&chars) ?? "")
        case "{", "(", "[":
            let close: Character = c == "{" ? "}" : c == "(" ? ")" : "]"
            var depth = 1
            var text = String(c)
            while let d = chars.first, depth > 0 {
                text.append(d)
                chars = chars.dropFirst()
                if d == c { depth += 1 } else if d == close { depth -= 1 }
            }
            return text
        case "@" where chars.first == "?":
            chars = chars.dropFirst()
            return "@?"
        default:
            return String(c)
        }
    }

    /// Whether `encoding` has exactly the return and argument types expected, written the
    /// same way ("B@:fiBQ"), self and _cmd included.
    public static func matches(_ encoding: String, _ expected: String) -> Bool {
        func normal(_ code: String) -> String {
            switch code {
            case "c": "B"   // BOOL is a signed char on Intel.
            case "q": "Q"   // A keyboard ID may be declared signed or unsigned; same width.
            case "l", "L": "I"
            default: code
            }
        }
        let have = types(encoding).map(normal), want = types(expected).map(normal)
        return have == want
    }

    /// The same, for a setter whose result Atelier ignores: only the arguments must match, so a
    /// release that changes the return from BOOL to void (or back) still works. Ignoring a
    /// result is safe on both arm64 and x86_64, where it only lives in a register.
    public static func matchesArguments(_ encoding: String, _ expected: String) -> Bool {
        let have = types(encoding), want = types(expected)
        guard !have.isEmpty, !want.isEmpty else { return false }
        return matches(have.dropFirst().joined(), want.dropFirst().joined())
    }
}

/// What the HUD can promise about the media keys on this kind of Mac.
public enum HUDCompat {
    /// The Keyboard Light row's note. Apple silicon keyboards dropped the key-light keys, so
    /// there it can only take them from an external keyboard; Intel MacBooks without a Touch
    /// Bar still have them on F5 and F6.
    public static func keyboardKeysNote(appleSilicon: Bool, backlight: Bool, owned: Bool, seen: Int) -> String {
        guard backlight else { return "No backlit keyboard found on this Mac." }
        if owned && seen == 0 {
            return appleSilicon
                ? "Apple silicon keyboards have no key-light keys; this takes them from keyboards that do. The slider below works on any."
                : "Press a key-light key to check. A Touch Bar's own slider talks to the light directly, past every app."
        }
        return "The key-light keys get the same overlay, and quarter steps with ⌥⇧."
    }

    /// The brightness row's note once the tap is running, from what it has seen.
    public static func brightnessNote(appleSilicon: Bool, owned: Bool, tapActive: Bool, seen: Int, unseen: Int) -> String {
        guard owned, tapActive else { return "Atelier draws the overlay and eases the screen to each new step." }
        if seen > 0 { return "Brightness keys reach Atelier on this Mac (\(seen) so far)." }
        if unseen > 0 {
            return appleSilicon
                ? "This Mac's brightness keys go straight to the display, past every app, so Apple's overlay still shows for them. External keyboards' keys are Atelier's."
                : "This Mac changes brightness past every app (a Touch Bar slider does), so Apple's overlay still shows for it. Keyboard keys are Atelier's."
        }
        return "Press a brightness key to check: some Macs send the built-in keys straight to the display, where no app can see them."
    }
}
