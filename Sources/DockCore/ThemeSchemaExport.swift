import Foundation

/// Generates `docs/atelier-theme.schema.json` and the reference tables in `docs/THEMES.md`
/// from the validator's table, so the three can never disagree. Run
/// `ATELIER_WRITE_SCHEMA=1 swift test --filter jsonSchemaMatchesTheTable` to rewrite the schema.
public enum ThemeSchemaExport {
    public static func jsonSchema() -> JSONValue {
        var root = object(ThemeSchema.sections)
        root["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
        root["$id"] = .string("urn:atelier:theme:1")
        root["title"] = .string("Atelier theme")
        root["description"] = .string("atelier-theme.json, format 1. Every section is optional; an absent key leaves that setting as it is. Keys starting with $ or x- are ignored.")
        root["$defs"] = .object(["color": .object([
            "type": .string("string"), "pattern": .string(colorPattern), "description": .string("#RGB, #RRGGBB or #RRGGBBAA"),
        ])])
        return .object(root)
    }

    static let colorPattern = "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"

    private static func object(_ fields: [ThemeSchema.Field]) -> [String: JSONValue] {
        var properties: [String: JSONValue] = [:]
        for field in fields { properties[field.key] = .object(node(field.kind, field.summary)) }
        var out: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties),
            "patternProperties": .object(["^(\\$|x-)": .object([:])]),
        ]
        let required = fields.filter(\.required).map { JSONValue.string($0.key) }
        if !required.isEmpty { out["required"] = .array(required) }
        return out
    }

    private static func node(_ kind: ThemeSchema.Kind, _ summary: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = ["description": .string(summary.replacingOccurrences(of: "`", with: ""))]
        let color: JSONValue = .object(["$ref": .string("#/$defs/color")])
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        switch kind {
        case .string(let max): out["type"] = .string("string"); out["maxLength"] = .number(Double(max))
        case .oneOf(let options): out["enum"] = strings(options)
        case .number(let range):
            out["type"] = .string("number"); out["minimum"] = .number(range.lowerBound); out["maximum"] = .number(range.upperBound)
        case .integer(let range):
            out["type"] = .string("integer"); out["minimum"] = .number(Double(range.lowerBound)); out["maximum"] = .number(Double(range.upperBound))
        case .bool: out["type"] = .string("boolean")
        case .color: out["$ref"] = .string("#/$defs/color")
        case .colorOr(let names): out["anyOf"] = .array([color, .object(["enum": strings(names)])])
        case .colors(let count):
            out["type"] = .string("array"); out["items"] = color
            out["minItems"] = .number(Double(count.lowerBound)); out["maxItems"] = .number(Double(count.upperBound))
        case .presetOrColors(let names, let count):
            out["anyOf"] = .array([.object(["enum": strings(names)]), .object([
                "type": .string("array"), "items": color,
                "minItems": .number(Double(count.lowerBound)), "maxItems": .number(Double(count.upperBound)),
            ])])
        case .file(let types):
            out["type"] = .string("string")
            out["pattern"] = .string("^(?!/)(?!.*(^|/)\\.)[^\\\\]+\\.(" + types.joined(separator: "|") + ")$")
        case .url: out["type"] = .string("string"); out["format"] = .string("uri"); out["pattern"] = .string("^https://")
        case .strings(let count, let length):
            out["type"] = .string("array"); out["maxItems"] = .number(Double(count))
            out["items"] = .object(["type": .string("string"), "maxLength": .number(Double(length))])
        case .object(let fields): out.merge(object(fields)) { first, _ in first }
        }
        return out
    }

    /// Markdown tables for every key, one per section.
    public static func markdown() -> String {
        var text = ""
        table(ThemeSchema.sections, prefix: "", into: &text)
        return text
    }

    private static func table(_ fields: [ThemeSchema.Field], prefix: String, into text: inout String) {
        text += "| Key | Type | Description |\n|---|---|---|\n"
        var nested: [(String, [ThemeSchema.Field])] = []
        for field in fields {
            if case .object(let inner) = field.kind {
                nested.append((prefix + field.key, inner))
                text += "| `\(prefix + field.key)` | object | \(field.summary) See below. |\n"
            } else {
                text += "| `\(prefix + field.key)`\(field.required ? " **required**" : "") | \(type(field.kind)) | \(field.summary) |\n"
            }
        }
        for (name, inner) in nested {
            text += "\n#### `\(name)`\n\n"
            table(inner, prefix: name + ".", into: &text)
        }
    }

    private static func type(_ kind: ThemeSchema.Kind) -> String {
        func names(_ values: [String]) -> String { values.map { "`\($0)`" }.joined(separator: " ") }
        func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
        switch kind {
        case .string(let max): return "text (≤ \(max))"
        case .oneOf(let options): return names(options)
        case .number(let range): return "number \(number(range.lowerBound))…\(number(range.upperBound))"
        case .integer(let range): return "integer \(range.lowerBound)…\(range.upperBound)"
        case .bool: return "true / false"
        case .color: return "colour"
        case .colorOr(let options): return "colour, or " + names(options)
        case .colors(let count): return "\(count.lowerBound) colours"
        case .presetOrColors(let options, let count): return names(options) + ", or a list of \(count.lowerBound) colours"
        case .file(let types): return "bundle path (" + types.joined(separator: ", ") + ")"
        case .url: return "https link"
        case .strings(let count, let length): return "list of ≤ \(count) texts (≤ \(length))"
        case .object: return "object"
        }
    }
}
