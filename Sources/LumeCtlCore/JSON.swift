import Foundation

/// A JSON value with ordered object keys.
///
/// lumectl's JSON Lines are read by people as often as by `jq`, and a record
/// that starts with `t` and `type` scans far better than one sorted
/// alphabetically — which is all `JSONSerialization` offers.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool {
        lhs.encoded == rhs.encoded
    }

    /// Compact single-line encoding (one record per line).
    public var encoded: String {
        var output = ""
        write(to: &output)
        return output
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            // JSON has no NaN or infinity; a missing measurement is null.
            if value.isFinite {
                output += String(format: "%.3f", value)
            } else {
                output += "null"
            }
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let values):
            output += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 { output += "," }
                value.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { output += "," }
                Self.writeString(member.0, to: &output)
                output += ":"
                member.1.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

extension JSON {
    /// `nil` becomes `null`, so optional fields keep their key.
    static func optional(_ value: Double?) -> JSON { value.map(JSON.double) ?? .null }
    static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
}
