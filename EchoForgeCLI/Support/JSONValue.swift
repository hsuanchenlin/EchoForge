import Foundation

/// A JSON document with the key order the author wrote.
///
/// `JSONSerialization` takes a dictionary, and a dictionary has no order, so
/// the same command would emit its keys in a different sequence between runs.
/// That is fine for a parser and miserable for the thing `--json` exists for:
/// a shell script reading `echoforge status` with `jq`, a diff between two
/// runs, a fixture in a test. Key order here is the order it is written in, and
/// `CLIJSONShapeTests` is what keeps it from drifting.
///
/// Every value is serialised by this file rather than by `Encodable`, because
/// the shapes are small, heterogeneous and deliberately hand-designed - an
/// `Encodable` struct per response would be more code and would still not fix
/// the ordering.
indirect enum JSONValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// A string, or `null` when there is nothing to say.
    ///
    /// The distinction is load-bearing across this tool: `null` means "not
    /// known" or "not stored", and is never used where `false` or `""` would be
    /// the truth. See `echoforge status`, whose whole contract is that
    /// unavailable and false are different answers.
    static func string(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }

    static func int(_ value: Int?) -> JSONValue {
        value.map { JSONValue.int($0) } ?? .null
    }

    /// An ISO 8601 instant, which is the only date format this tool emits in
    /// JSON. The human-readable rendering is the text output's business.
    static func date(_ value: Date?) -> JSONValue {
        guard let value else { return .null }
        return .string(ISO8601DateFormatter.cliFormatter.string(from: value))
    }
}

extension ISO8601DateFormatter {
    /// Fixed to UTC with fractional seconds off, so two machines in different
    /// time zones produce the same string for the same instant.
    static let cliFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension JSONValue {

    /// Pretty-printed with two-space indentation and a trailing newline.
    ///
    /// Pretty rather than compact because the first reader of any of this is a
    /// person at a terminal deciding whether the shape is what they want to
    /// script against; `jq` does not care either way.
    var serialized: String {
        render(indent: 0) + "\n"
    }

    private func render(indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let innerPad = String(repeating: " ", count: indent + 2)
        switch self {
        case .string(let value):
            return JSONValue.quote(value)
        case .int(let value):
            return String(value)
        case .double(let value):
            // Whole doubles are still written with a decimal point, so a
            // consumer's type inference does not flip between runs.
            return value == value.rounded() && abs(value) < 1e15
                ? String(format: "%.1f", value)
                : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            let body = values
                .map { innerPad + $0.render(indent: indent + 2) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs
                .map { innerPad + JSONValue.quote($0.key) + ": " + $0.value.render(indent: indent + 2) }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    /// JSON string escaping, including the control characters below 0x20 that a
    /// transcript can genuinely contain.
    static func quote(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
