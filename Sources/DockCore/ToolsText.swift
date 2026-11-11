import Foundation

// MARK: - Clipboard transforms

/// Pure text transforms for the clipboard tool. Each returns nil when it does not apply,
/// so the clipboard is never replaced with something worse.
public enum TextTransform: String, CaseIterable, Sendable, Identifiable {
    case plain, trim, upper, lower, title, sentence, camel, snake, kebab
    case jsonPretty, jsonMinify, urlEncode, urlDecode, base64Encode, base64Decode, sortLines, uniqueLines

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plain: "Plain Text"
        case .trim: "Trim Spaces"
        case .upper: "UPPERCASE"
        case .lower: "lowercase"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        case .camel: "camelCase"
        case .snake: "snake_case"
        case .kebab: "kebab-case"
        case .jsonPretty: "Pretty JSON"
        case .jsonMinify: "Minify JSON"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .sortLines: "Sort Lines"
        case .uniqueLines: "Remove Duplicate Lines"
        }
    }

    /// Words split on spaces, punctuation and case changes, for the code-style cases.
    static func words(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current); current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    public func apply(_ text: String) -> String? {
        switch self {
        case .plain: return text
        case .trim:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        case .sentence:
            var result = "", capitalise = true
            for character in text.lowercased() {
                if capitalise, character.isLetter { result.append(contentsOf: character.uppercased()); capitalise = false }
                else { result.append(character) }
                if ".!?\n".contains(character) { capitalise = true }
            }
            return result
        case .camel:
            let parts = Self.words(text)
            guard let first = parts.first else { return nil }
            return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .snake: let parts = Self.words(text); return parts.isEmpty ? nil : parts.joined(separator: "_")
        case .kebab: let parts = Self.words(text); return parts.isEmpty ? nil : parts.joined(separator: "-")
        case .jsonPretty, .jsonMinify:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            let options: JSONSerialization.WritingOptions = self == .jsonPretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
                : [.withoutEscapingSlashes, .fragmentsAllowed]
            guard let out = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
            return String(decoding: out, as: UTF8.self)
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed)
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: cleaned), let decoded = String(data: data, encoding: .utf8) else { return nil }
            return decoded
        case .sortLines:
            return text.components(separatedBy: "\n").sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return text.components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }
}

// MARK: - Batch rename

/// A rename plan. Tokens: {name} original name without extension, {n} counter, {date}
/// modification date as yyyy-MM-dd, {ext} extension. Find/replace runs on {name} first.
public struct RenamePlan: Sendable, Equatable {
    public var pattern: String
    public var find: String
    public var replace: String
    public var start: Int
    public var padding: Int

    public init(pattern: String = "{name}", find: String = "", replace: String = "", start: Int = 1, padding: Int = 2) {
        self.pattern = pattern; self.find = find; self.replace = replace; self.start = start; self.padding = padding
    }

    public struct Item: Sendable, Equatable {
        public let name: String
        public let date: Date
        public init(name: String, date: Date) { self.name = name; self.date = date }
    }

    /// New file names, in order. Names that collide get " 2", " 3" so nothing is overwritten.
    public func names(for items: [Item]) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var used = Set<String>(), result: [String] = []
        for (index, item) in items.enumerated() {
            let url = URL(fileURLWithPath: item.name)
            let ext = url.pathExtension
            var base = ext.isEmpty ? item.name : String(item.name.dropLast(ext.count + 1))
            if !find.isEmpty { base = base.replacingOccurrences(of: find, with: replace) }
            let number = String(start + index)
            let counter = String(repeating: "0", count: max(0, padding - number.count)) + number
            var stem = pattern.replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{n}", with: counter)
                .replacingOccurrences(of: "{date}", with: formatter.string(from: item.date))
                .replacingOccurrences(of: "{ext}", with: ext)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            if stem.trimmingCharacters(in: .whitespaces).isEmpty { stem = base }
            let full = { (s: String) in ext.isEmpty || pattern.contains("{ext}") ? s : s + "." + ext }
            var candidate = full(stem), copy = 2
            while used.contains(candidate.lowercased()) { candidate = full("\(stem) \(copy)"); copy += 1 }
            used.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }
}

// MARK: - Key remapping

/// hidutil UserKeyMapping entries. Usage IDs are HID page 7 (keyboard) codes OR'ed with
/// 0x700000000, as documented in Apple's TN2450.
public enum KeyRemap: String, CaseIterable, Sendable, Identifiable {
    case capsToEscape, capsToControl, swapOptionCommand, rightCommandToOption, sectionToGrave

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .capsToEscape: "Caps Lock → Escape"
        case .capsToControl: "Caps Lock → Control"
        case .swapOptionCommand: "Swap ⌥ and ⌘"
        case .rightCommandToOption: "Right ⌘ → Right ⌥"
        case .sectionToGrave: "§ → `"
        }
    }

    static let capsLock: UInt64 = 0x7_0000_0039
    static let escape: UInt64 = 0x7_0000_0029
    static let leftControl: UInt64 = 0x7_0000_00E0
    static let leftOption: UInt64 = 0x7_0000_00E2
    static let leftCommand: UInt64 = 0x7_0000_00E3
    static let rightOption: UInt64 = 0x7_0000_00E6
    static let rightCommand: UInt64 = 0x7_0000_00E7
    static let nonUSBackslash: UInt64 = 0x7_0000_0064
    static let grave: UInt64 = 0x7_0000_0035

    public var pairs: [(UInt64, UInt64)] {
        switch self {
        case .capsToEscape: [(Self.capsLock, Self.escape)]
        case .capsToControl: [(Self.capsLock, Self.leftControl)]
        case .swapOptionCommand: [(Self.leftOption, Self.leftCommand), (Self.leftCommand, Self.leftOption),
                                  (Self.rightOption, Self.rightCommand), (Self.rightCommand, Self.rightOption)]
        case .rightCommandToOption: [(Self.rightCommand, Self.rightOption)]
        case .sectionToGrave: [(Self.nonUSBackslash, Self.grave)]
        }
    }

    /// The JSON `hidutil property --set` takes. Later remaps win on a shared source key.
    public static func json(_ remaps: [KeyRemap]) -> String {
        json(pairs: remaps.flatMap(\.pairs))
    }
}
