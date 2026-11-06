import Foundation

/// One property of every kind the form models, with `required` out of alphabetical order.
private let everyKindSchema: JSONValue = [
    "type": "object",
    "required": ["query", "limit", "missing-from-properties", "mode"],
    "properties": [
        "query": ["type": "string", "title": "Search query", "description": "What to look for"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
        "mode": ["enum": ["fast", "slow"]],
        "ratio": ["type": "number", "minimum": 0.5, "maximum": 2],
        "verbose": ["type": "boolean"],
        "tags": ["type": "array", "items": ["type": "string"]],
        "filter": ["type": "object"],
        "points": ["type": "array", "items": ["type": "integer"]],
        "either": ["anyOf": [["type": "string"], ["type": "integer"]]],
        "nullable": ["type": ["string", "null"], "format": "date"],
        "level": ["enum": [1, 2, 3]],
        "fixed": ["const": "v1"],
        "anything": [:],
        "weird": ["type": "unicorn"],
        "union": ["type": ["string", "integer"]],
    ],
]

private func schema() -> ToolSchema { ToolSchema(inputSchema: everyKindSchema) }

private func field(_ name: String) throws -> ToolSchema.Field {
    try require(schema().fields.first { $0.name == name }, "no field \(name)")
}

private func errors(_ result: Result<[String: JSONValue], ToolSchema.FieldErrors>) -> [String: String] {
    if case let .failure(errors) = result { return errors.messages }
    return [:]
}

private func success(_ result: Result<[String: JSONValue], ToolSchema.FieldErrors>) throws -> [String: JSONValue] {
    switch result {
    case let .success(arguments): return arguments
    case let .failure(errors): throw TestFailure(description: "expected arguments, got errors \(errors.messages)")
    }
}

/// The smallest values that satisfy the required fields.
private let requiredFilled = ["query": "cats", "limit": "5", "mode": "fast"]

func runToolSchemaTests() {
    test("ToolSchema: required fields first in schema order, then the rest alphabetically") {
        expectEqual(schema().fields.map(\.name), [
            "query", "limit", "mode",
            "anything", "either", "filter", "fixed", "level", "nullable", "points", "ratio", "tags", "union", "verbose", "weird",
        ])
        expectEqual(schema().fields.filter(\.required).map(\.name), ["query", "limit", "mode"])
    }

    test("ToolSchema: each property maps to its kind") {
        let kinds = Dictionary(uniqueKeysWithValues: schema().fields.map { ($0.name, $0.kind) })
        expectEqual(kinds["query"], .string(format: nil))
        expectEqual(kinds["nullable"], .string(format: "date"))
        expectEqual(kinds["limit"], .integer)
        expectEqual(kinds["ratio"], .number)
        expectEqual(kinds["verbose"], .boolean)
        expectEqual(kinds["mode"], .choice(["fast", "slow"]))
        expectEqual(kinds["level"], .choice([1, 2, 3]))
        expectEqual(kinds["fixed"], .choice(["v1"]))
        expectEqual(kinds["tags"], .stringArray)
        expectEqual(kinds["filter"], .json(expected: "object"))
        expectEqual(kinds["points"], .json(expected: "array"))
        expectEqual(kinds["either"], .json(expected: nil))
        expectEqual(kinds["anything"], .json(expected: nil))
        expectEqual(kinds["weird"], .json(expected: nil))
        expectEqual(kinds["union"], .json(expected: nil))
    }

    test("ToolSchema: keeps title, description, default and bounds") {
        let query = try field("query")
        expectEqual(query.label, "Search query")
        expectEqual(query.description, "What to look for")
        let limit = try field("limit")
        expectEqual(limit.label, "limit")
        expectEqual(limit.defaultValue, 10)
        expectEqual(limit.minimum, 1)
        expectEqual(limit.maximum, 50)
        expectEqual(limit.placeholder, "Default: 10")
    }

    test("ToolSchema: no properties means no fields and no arguments") {
        for inputSchema: JSONValue in [["type": "object"], ["type": "object", "properties": [:]], .null] {
            let empty = ToolSchema(inputSchema: inputSchema)
            expectTrue(empty.takesNoArguments, "\(inputSchema) should take no arguments")
            expectEqual(try success(empty.arguments(from: ["stray": "x"])), [:])
        }
    }

    test("ToolSchema: typed texts become typed JSON and empty optional fields are omitted") {
        var values = requiredFilled
        values["ratio"] = "1.5"
        values["tags"] = "red\n\n  blue  \n"
        values["filter"] = #"{"a": [1, true]}"#
        values["level"] = "2"
        values["fixed"] = "v1"
        values["nullable"] = "2025-01-01"
        values["either"] = "7"
        values["weird"] = ""
        let arguments = try success(schema().arguments(from: values))
        expectEqual(arguments, [
            "query": "cats", "limit": 5, "mode": "fast", "ratio": 1.5, "tags": ["red", "blue"],
            "filter": ["a": [1, true]], "level": 2, "fixed": "v1", "nullable": "2025-01-01", "either": 7,
        ])
    }

    test("ToolSchema: a whole-number value in a number field is sent as an integer") {
        var values = requiredFilled
        values["ratio"] = "2"
        expectEqual(try success(schema().arguments(from: values))["ratio"], .int(2))
    }

    test("ToolSchema: strings are sent exactly as typed, spaces included") {
        let arguments = try success(schema().arguments(from: ["query": "  two words ", "limit": "1", "mode": "slow"]))
        expectEqual(arguments["query"], "  two words ")
    }

    test("ToolSchema: missing required fields each say Required") {
        expectEqual(errors(schema().arguments(from: [:])), ["query": "Required", "limit": "Required", "mode": "Required"])
        expectEqual(errors(schema().arguments(from: ["query": "x", "limit": "   ", "mode": ""])),
                    ["limit": "Required", "mode": "Required"])
    }

    test("ToolSchema: integers must be whole numbers within bounds") {
        let cases: [(String, String)] = [
            ("abc", "Enter a whole number."), ("2.5", "Enter a whole number."),
            ("0", "Must be at least 1."), ("51", "Must be at most 50."),
        ]
        for (text, message) in cases {
            var values = requiredFilled
            values["limit"] = text
            expectEqual(errors(schema().arguments(from: values)), ["limit": message], "limit = \(text)")
        }
        var edge = requiredFilled
        edge["limit"] = "50"
        expectEqual(try success(schema().arguments(from: edge))["limit"], 50)
    }

    test("ToolSchema: numbers must parse and respect fractional bounds") {
        let cases: [(String, String)] = [("lots", "Enter a number."), ("0.25", "Must be at least 0.5."), ("2.5", "Must be at most 2.")]
        for (text, message) in cases {
            var values = requiredFilled
            values["ratio"] = text
            expectEqual(errors(schema().arguments(from: values)), ["ratio": message], "ratio = \(text)")
        }
    }

    test("ToolSchema: enum values must match an option") {
        var values = requiredFilled
        values["mode"] = "medium"
        values["level"] = "4"
        expectEqual(errors(schema().arguments(from: values)),
                    ["mode": "Choose one of: fast, slow", "level": "Choose one of: 1, 2, 3"])
    }

    test("ToolSchema: JSON fields must parse and be the declared shape") {
        var values = requiredFilled
        values["filter"] = "{not json"
        values["points"] = #"{"a": 1}"#
        let messages = errors(schema().arguments(from: values))
        expectTrue(messages["filter"]?.hasPrefix("Not valid JSON") == true, "filter: \(messages["filter"] ?? "nil")")
        expectEqual(messages["points"], "Enter a JSON array, not an object.")
        values["points"] = "[1, 2]"
        values["filter"] = "[]"
        expectEqual(errors(schema().arguments(from: values)), ["filter": "Enter a JSON object, not an array."])
    }

    test("ToolSchema: optional booleans are tri-state, required ones start false and must be set") {
        let optional = ToolSchema(inputSchema: ["properties": ["flag": ["type": "boolean"]]])
        expectEqual(try success(optional.arguments(from: [:])), [:])
        expectEqual(try success(optional.arguments(from: ["flag": "true"])), ["flag": true])
        expectEqual(try success(optional.arguments(from: ["flag": "false"])), ["flag": false])
        expectEqual(errors(optional.arguments(from: ["flag": "yes"])), ["flag": "Choose true or false."])

        let required = ToolSchema(inputSchema: ["properties": ["flag": ["type": "boolean"]], "required": ["flag"]])
        expectEqual(required.initialValues, ["flag": "false"])
        expectEqual(try success(required.arguments(from: required.initialValues)), ["flag": false])
        expectEqual(errors(required.arguments(from: [:])), ["flag": "Required"])
    }

    test("ToolSchema: a required array of strings needs at least one item") {
        let required = ToolSchema(inputSchema: ["properties": ["ids": ["type": "array", "items": ["type": "string"]]],
                                                "required": ["ids"]])
        expectEqual(errors(required.arguments(from: ["ids": "\n  \n"])), ["ids": "Required"])
    }

    test("ToolSchema: initial values prefill required defaults only") {
        expectEqual(schema().initialValues, ["limit": "10"])
    }

    test("ToolSchema: values(from:) round-trips every kind through arguments(from:)") {
        let arguments: [String: JSONValue] = [
            "query": "multi\nline", "limit": 5, "mode": "slow", "ratio": 0.75, "verbose": false, "tags": ["a", "b c"],
            "filter": ["nested": ["x": [1, 2]]], "points": [3, 4], "either": "text", "nullable": "2025-02-02",
            "level": 3, "fixed": "v1", "anything": [true, nil], "weird": 1.5, "union": 9,
        ]
        let values = schema().values(from: arguments)
        expectEqual(values["verbose"], "false")
        expectEqual(values["tags"], "a\nb c")
        expectEqual(values["level"], "3")
        expectEqual(try success(schema().arguments(from: values)), arguments)
    }

    test("ToolSchema: values(from:) leaves out unknown arguments, which unknownNames reports") {
        let arguments: [String: JSONValue] = ["query": "q", "limit": 2, "mode": "fast", "extra": 1, "another": "x"]
        expectEqual(schema().values(from: arguments), ["query": "q", "limit": "2", "mode": "fast"])
        expectEqual(schema().unknownNames(in: arguments), ["another", "extra"])
    }

    test("ToolSchema: JSON-mode text must be an object, blank means no arguments") {
        expectEqual(try success(ToolSchema.arguments(fromJSON: "  \n")), [:])
        expectEqual(try success(ToolSchema.arguments(fromJSON: #"{"a": 1}"#)), ["a": 1])
        expectEqual(errors(ToolSchema.arguments(fromJSON: "[1]")),
                    ["": "Arguments must be a JSON object, like {\"name\": \"value\"}."])
        expectTrue(errors(ToolSchema.arguments(fromJSON: "{")).first?.value.hasPrefix("Not valid JSON") == true,
                   "broken JSON should say so")
    }
}
