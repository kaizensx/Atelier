import Foundation

/// A JSON value, kept exactly as written. Themes and plugins are validated against it so every
/// error can name the key it is about, which `Codable` cannot do well.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: raw)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// From what `JSONSerialization` or JavaScriptCore's `toObject()` hand back.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let dictionary as [String: Any]: self = .object(dictionary.mapValues { JSONValue(any: $0) })
        case let date as Date: self = .number(date.timeIntervalSince1970 * 1000)
        default: self = .null
        }
    }

    // MARK: Writing

    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    /// Pretty, with sorted keys, so exported themes diff cleanly.
    public func data(pretty: Bool = true) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: any, options: options)
    }

    public func text(pretty: Bool = false) -> String {
        (try? data(pretty: pretty)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { self == .null }

    /// A short description for error messages: `"round"`, `12`, `an object`.
    public var shortDescription: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): "\"\(value.count > 40 ? String(value.prefix(40)) + "…" : value)\""
        case .array: "a list"
        case .object: "an object"
        }
    }
}

/// An RGBA colour from `#RGB`, `#RRGGBB` or `#RRGGBBAA`. Components run 0...1.
public struct ThemeColor: Equatable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init?(hex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let full = hex.count == 6 ? value << 8 | 0xFF : value
        red = Double((full >> 24) & 0xFF) / 255
        green = Double((full >> 16) & 0xFF) / 255
        blue = Double((full >> 8) & 0xFF) / 255
        alpha = Double(full & 0xFF) / 255
    }

    public var hex: String {
        func byte(_ value: Double) -> String { String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 0.999 ? byte(alpha) : "")
    }

    /// Distance in a roughly perceptual space (weighted RGB, "redmean"). Good enough to pick
    /// the nearest named swatch, which is all it is used for.
    public func distance(to other: ThemeColor) -> Double {
        let mean = (red + other.red) / 2
        let dr = red - other.red, dg = green - other.green, db = blue - other.blue
        return ((2 + mean) * dr * dr + 4 * dg * dg + (3 - mean) * db * db).squareRoot()
    }

    /// The key of the swatch nearest this colour.
    public func nearest(_ swatches: [(String, ThemeColor)]) -> String? {
        swatches.min { distance(to: $0.1) < distance(to: $1.1) }?.0
    }

    /// Relative luminance, WCAG style, for deciding light or dark ink.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// `major.minor.patch`, with missing parts read as zero. Pre-release tags are ignored.
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = numbers[0]!
        minor = numbers.count > 1 ? numbers[1]! : 0
        patch = numbers.count > 2 ? numbers[2]! : 0
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Reverse-DNS identifiers: `com.example.midnight-glass`.
public enum ThemeIdentifier {
    public static func isValid(_ id: String) -> Bool {
        guard (3...120).contains(id.count) else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLetter || first.isNumber, !part.hasSuffix("-") else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// A relative path inside a bundle: no leading slash, no `..`, no hidden parts.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }
}
