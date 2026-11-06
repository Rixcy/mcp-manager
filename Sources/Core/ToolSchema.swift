import Foundation

/// A form for a tool's arguments, derived from its `inputSchema`. Field values
/// are the texts the user types; `arguments(from:)` and `values(from:)` convert
/// between those texts and the JSON the tool receives.
public struct ToolSchema: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case string(format: String?)
        /// `enum` or `const`. Options are kept as JSON because enums are not always strings.
        case choice([JSONValue])
        case integer
        case number
        /// Optional booleans are tri-state: empty text means unset.
        case boolean
        /// One item per line.
        case stringArray
        /// Objects, non-string arrays, `anyOf`/`oneOf`/`allOf`, and anything without one clear type.
        case json(expected: String?)
    }

    public struct Field: Identifiable, Equatable, Sendable {
        public var name: String
        public var kind: Kind
        public var title: String?
        public var description: String?
        public var defaultValue: JSONValue?
        public var minimum: Double?
        public var maximum: Double?
        public var required: Bool

        public var id: String { name }
        public var label: String { title ?? name }

        /// The text a choice option is shown and typed as.
        /// An empty-string option reads `""` so it stays distinct from an unset field, whose text is empty.
        public static func optionText(_ option: JSONValue) -> String {
            if option == .string("") { return "\"\"" }
            return option.stringValue ?? option.jsonString()
        }

        /// Placeholder hint: the default, else a short description of the expected input.
        public var placeholder: String {
            if let defaultValue { return "Default: " + Self.text(for: defaultValue, kind: kind) }
            switch kind {
            case let .string(format): return format ?? ""
            case .choice: return "Choose one"
            case .integer: return "Whole number"
            case .number: return "Number"
            case .boolean: return ""
            case .stringArray: return "One item per line"
            case let .json(expected): return expected.map { "JSON \($0)" } ?? "JSON"
            }
        }

        static func text(for value: JSONValue, kind: Kind) -> String {
            switch (kind, value) {
            case let (.string, .string(text)): return text
            case (.choice, _): return optionText(value)
            case let (.boolean, .bool(flag)): return flag ? "true" : "false"
            case let (.stringArray, .array(items)):
                return items.map { $0.stringValue ?? $0.jsonString() }.joined(separator: "\n")
            case (.json, _): return value.jsonString(pretty: true)
            default: return value.stringValue ?? value.jsonString()
            }
        }
    }

    public struct FieldErrors: Error, Equatable, Sendable {
        /// Field name to the message shown under it.
        public var messages: [String: String]

        public init(_ messages: [String: String]) {
            self.messages = messages
        }
    }

    public var fields: [Field]

    public init(fields: [Field]) {
        self.fields = fields
    }

    public init(inputSchema: JSONValue) {
        let properties = inputSchema["properties"]?.objectValue ?? [:]
        let requiredList = (inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        var order: [String] = []
        for name in requiredList where properties[name] != nil && !order.contains(name) {
            order.append(name)
        }
        order += properties.keys.filter { !order.contains($0) }.sorted()
        let required = Set(requiredList)
        fields = order.map { name in
            let property = properties[name] ?? .object([:])
            return Field(name: name, kind: Self.kind(of: property), title: property["title"]?.stringValue,
                         description: property["description"]?.stringValue, defaultValue: property["default"],
                         minimum: property["minimum"]?.doubleValue, maximum: property["maximum"]?.doubleValue,
                         required: required.contains(name))
        }
    }

    public var takesNoArguments: Bool { fields.isEmpty }

    /// Texts a fresh form starts with. Required fields start at their default so
    /// the user sees what will be sent; a required boolean with no default starts false.
    public var initialValues: [String: String] {
        var values: [String: String] = [:]
        for field in fields where field.required {
            if let defaultValue = field.defaultValue {
                values[field.name] = Field.text(for: defaultValue, kind: field.kind)
            } else if field.kind == .boolean {
                values[field.name] = "false"
            }
        }
        return values
    }

    /// Argument names the schema does not describe; they only travel in JSON mode.
    public func unknownNames(in arguments: [String: JSONValue]) -> [String] {
        let known = Set(fields.map(\.name))
        return arguments.keys.filter { !known.contains($0) }.sorted()
    }

    public func arguments(from values: [String: String]) -> Result<[String: JSONValue], FieldErrors> {
        var arguments: [String: JSONValue] = [:]
        var errors: [String: String] = [:]
        for field in fields {
            switch Self.convert(values[field.name] ?? "", for: field) {
            case let .success(value?): arguments[field.name] = value
            case .success(nil): break
            case let .failure(message): errors[field.name] = message.text
            }
        }
        return errors.isEmpty ? .success(arguments) : .failure(FieldErrors(errors))
    }

    public func values(from arguments: [String: JSONValue]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            if let value = arguments[field.name] {
                values[field.name] = Field.text(for: value, kind: field.kind)
            }
        }
        return values
    }

    /// Parses JSON-mode text. Blank text means no arguments.
    public static func arguments(fromJSON text: String) -> Result<[String: JSONValue], FieldErrors> {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success([:]) }
        do {
            guard let object = try JSONValue.parse(text).objectValue else {
                return .failure(FieldErrors(["": "Arguments must be a JSON object, like {\"name\": \"value\"}."]))
            }
            return .success(object)
        } catch {
            return .failure(FieldErrors(["": "Not valid JSON: \(error)"]))
        }
    }

    // MARK: Conversion

    private struct Message: Error {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private static func convert(_ raw: String, for field: Field) -> Result<JSONValue?, Message> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty: Bool
        switch field.kind {
        case .string: isEmpty = raw.isEmpty
        default: isEmpty = trimmed.isEmpty
        }
        if isEmpty {
            return field.required ? .failure(Message("Required")) : .success(nil)
        }
        switch field.kind {
        case .string:
            return .success(.string(raw))
        case let .choice(options):
            guard let option = options.first(where: { Field.optionText($0) == trimmed }) else {
                return .failure(Message("Choose one of: " + options.map(Field.optionText).joined(separator: ", ")))
            }
            return .success(option)
        case .integer:
            guard let number = Int(trimmed) else { return .failure(Message("Enter a whole number.")) }
            return bounded(Double(number), field).map { _ -> JSONValue? in .int(number) }
        case .number:
            guard let number = Double(trimmed), number.isFinite else { return .failure(Message("Enter a number.")) }
            let value: JSONValue = Int(exactly: number).map(JSONValue.int) ?? .double(number)
            return bounded(number, field).map { _ -> JSONValue? in value }
        case .boolean:
            switch trimmed.lowercased() {
            case "true": return .success(.bool(true))
            case "false": return .success(.bool(false))
            default: return .failure(Message("Choose true or false."))
            }
        case .stringArray:
            let items = raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .success(.array(items.map(JSONValue.string)))
        case let .json(expected):
            let value: JSONValue
            do {
                value = try JSONValue.parse(trimmed)
            } catch {
                return .failure(Message("Not valid JSON: \(error)"))
            }
            if let expected, !matches(value, type: expected) {
                return .failure(Message("Enter a JSON \(expected), not \(article(value.typeName)) \(value.typeName)."))
            }
            return .success(value)
        }
    }

    private static func bounded(_ number: Double, _ field: Field) -> Result<Void, Message> {
        if let minimum = field.minimum, number < minimum { return .failure(Message("Must be at least \(format(minimum)).")) }
        if let maximum = field.maximum, number > maximum { return .failure(Message("Must be at most \(format(maximum)).")) }
        return .success(())
    }

    private static func format(_ number: Double) -> String {
        JSONValue.double(number).jsonString()
    }

    private static func article(_ word: String) -> String {
        word.first.map { "aeiou".contains($0) } == true ? "an" : "a"
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch type {
        case "object": return value.objectValue != nil
        case "array": return value.arrayValue != nil
        default: return true
        }
    }

    // MARK: Kinds

    static func kind(of property: JSONValue) -> Kind {
        if let options = property["enum"]?.arrayValue, !options.isEmpty {
            return .choice(options.filter { !$0.isNull })
        }
        if let constant = property["const"] {
            return .choice([constant])
        }
        if ["anyOf", "oneOf", "allOf"].contains(where: { property[$0] != nil }) {
            return .json(expected: nil)
        }
        switch singleType(of: property) {
        case "string": return .string(format: property["format"]?.stringValue)
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array":
            if singleType(of: property["items"] ?? .null) == "string", property["items"]?["enum"] == nil {
                return .stringArray
            }
            return .json(expected: "array")
        case "object": return .json(expected: "object")
        default: return .json(expected: nil)
        }
    }

    /// `"type": ["string", "null"]` reads as string; any other union has no single type.
    private static func singleType(of property: JSONValue) -> String? {
        switch property["type"] {
        case let .string(type)?:
            return type
        case let .array(types)?:
            let named = types.compactMap(\.stringValue).filter { $0 != "null" }
            return named.count == 1 ? named[0] : nil
        default:
            return nil
        }
    }
}
