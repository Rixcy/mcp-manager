import Foundation

/// A JSON document as a value, so MCP payloads can cross actors and be compared.
public enum JSONValue: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        do {
            return JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw JSONParseError(description: detail)
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Converts `JSONSerialization` output. Booleans arrive as `NSNumber`, so
    /// they are told apart from numbers by their CF type, not by casting.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number is NSDecimalNumber {
                let double = number.doubleValue
                self = Int(exactly: double).map(JSONValue.int) ?? .double(double)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(Int.max) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }

    /// Compact output has no line breaks, which stdio framing depends on.
    public func encoded(pretty: Bool = false) -> Data {
        Data(jsonString(pretty: pretty).utf8)
    }

    public func jsonString(pretty: Bool = false) -> String {
        var out = ""
        write(to: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(to out: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .int(value):
            out += String(value)
        case let .double(value):
            // JSON has no NaN or infinity.
            guard value.isFinite else { out += "null"; return }
            if value == value.rounded(), abs(value) < 1e15 {
                out += String(Int(value))
            } else {
                out += "\(value)"
            }
        case let .string(value):
            Self.writeString(value, to: &out)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                item.write(to: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case let .object(members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                Self.writeString(key, to: &out)
                out += pretty ? ": " : ":"
                members[key]!.write(to: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}":
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// The `JSONSerialization` equivalent, for APIs that take `Any`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return NSNumber(value: value)
        case let .int(value): return NSNumber(value: value)
        case let .double(value): return value.isFinite ? NSNumber(value: value) : NSNull()
        case let .string(value): return value
        case let .array(items): return items.map(\.anyValue)
        case let .object(members): return members.mapValues(\.anyValue)
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// Whole doubles count, since some servers send `5.0` for an integer.
    public var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int(exactly: value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(members) = self { return members }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Name used in validation messages: "string", "object", …
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
