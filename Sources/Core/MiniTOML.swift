import Foundation

/// A TOML value. Dates and other values MCP Manager never reads are kept as
/// their raw text.
indirect enum TOMLValue: Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
    case opaque(String)

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var table: [String: TOMLValue]? {
        if case let .table(t) = self { return t }
        return nil
    }

    var array: [TOMLValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// Scalars as text, for string maps (`env`, headers) written with numbers or bools.
    var scalarText: String? {
        switch self {
        case let .string(s): return s
        case let .integer(i): return String(i)
        case let .float(d): return String(d)
        case let .bool(b): return String(b)
        case let .opaque(s): return s
        case .array, .table: return nil
        }
    }
}

/// Where a header or key/value sits in the source, so edits can rewrite text
/// in place instead of re-serialising the whole file.
struct TOMLStatement: Equatable {
    enum Kind: Equatable { case table, arrayTable, keyValue }

    var kind: Kind
    /// Table path for headers; full key path (section + key) for key/values.
    var path: [String]
    /// The table a key/value belongs to (`[]` for the root).
    var section: [String]
    var firstLine: Int
    /// Last line of the statement; for a header, the last line of its section's content.
    var lastLine: Int
    /// UTF-8 column range of the (dotted) key on `firstLine`.
    var keyStart: Int
    var keyEnd: Int

    var isHeader: Bool { kind != .keyValue }

    func hasPrefix(_ prefix: [String]) -> Bool {
        path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix
    }
}

struct TOMLDocument {
    var root: [String: TOMLValue]
    var statements: [TOMLStatement]
    /// Errors in sections MCP Manager does not read; parsing resumed on the next line.
    var skippedErrors: [String]
}

/// Enough TOML for Codex's config: every value type, dotted and quoted keys,
/// tables and inline tables. Errors outside `mcp_servers` are skipped line by
/// line so an odd unrelated setting never hides the servers.
enum MiniTOML {
    static func parse(_ text: String, path: String) throws -> TOMLDocument {
        var parser = Parser(bytes: Array(text.utf8))
        do {
            try parser.run()
        } catch let error as Parser.Failure {
            throw MCPManagerError.parse(path: path, detail: "line \(error.line + 1): \(error.message)")
        }
        return TOMLDocument(root: parser.root, statements: parser.finishedStatements(), skippedErrors: parser.skipped)
    }

    static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy(Parser.isBareKeyByte)
    }

    /// A key as TOML source: bare when possible, else a basic string.
    static func renderKey(_ key: String) -> String {
        isBareKey(key) ? key : quote(key)
    }

    static func renderPath(_ path: [String]) -> String {
        path.map(renderKey).joined(separator: ".")
    }

    /// A TOML basic string literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

private struct Parser {
    struct Failure: Error {
        var line: Int
        var message: String
    }

    let b: [UInt8]
    var i = 0
    var line = 0
    var root: [String: TOMLValue] = [:]
    var statements: [TOMLStatement] = []
    var skipped: [String] = []
    var section: [String] = []
    var sectionIsArray = false

    init(bytes: [UInt8]) {
        b = bytes
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    static func isBareKeyByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
    }

    private var atEnd: Bool { i >= b.count }
    private func peek(_ offset: Int = 0) -> UInt8? { i + offset < b.count ? b[i + offset] : nil }

    private mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where i < b.count {
            if b[i] == 0x0A { line += 1 }
            i += 1
        }
    }

    private func fail(_ message: String) -> Failure { Failure(line: line, message: message) }

    private mutating func skipSpaces() {
        while let c = peek(), c == 0x20 || c == 0x09 { advance() }
    }

    private mutating func skipComment() {
        guard peek() == 0x23 else { return }
        while let c = peek(), c != 0x0A { advance() }
    }

    /// Whitespace, newlines and comments between statements or array items.
    private mutating func skipTrivia() {
        while let c = peek() {
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                advance()
            } else if c == 0x23 {
                skipComment()
            } else {
                break
            }
        }
    }

    private func lineStart(of index: Int) -> Int {
        var j = index
        while j > 0, b[j - 1] != 0x0A { j -= 1 }
        return j
    }

    private func lineText(at index: Int) -> String {
        let start = lineStart(of: index)
        var end = start
        while end < b.count, b[end] != 0x0A { end += 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    mutating func run() throws {
        while true {
            skipTrivia()
            guard !atEnd else { return }
            let start = i
            let startLine = line
            let sectionBefore = section
            let isHeader = b[i] == 0x5B
            do {
                if isHeader { try parseHeader() } else { try parseKeyValue() }
                try expectLineEnd()
            } catch let failure as Failure {
                let inMCP = (sectionBefore.first == "mcp_servers" && !isHeader)
                    || lineText(at: start).contains("mcp_servers")
                if inMCP { throw failure }
                skipped.append("line \(startLine + 1): \(failure.message)")
                if isHeader {
                    // Its keys must not count as content of the previous section.
                    statements.append(TOMLStatement(kind: .arrayTable, path: [], section: [],
                                                    firstLine: startLine, lastLine: startLine,
                                                    keyStart: 0, keyEnd: 0))
                    section = []
                    sectionIsArray = true
                }
                while let c = peek(), c != 0x0A { advance() }
            }
        }
    }

    private mutating func expectLineEnd() throws {
        skipSpaces()
        skipComment()
        if atEnd { return }
        if peek() == 0x0D, peek(1) == 0x0A { advance(2); return }
        if peek() == 0x0A { advance(); return }
        throw fail("unexpected text after value")
    }

    private mutating func parseHeader() throws {
        let headerLine = line
        let isArray = peek(1) == 0x5B
        advance(isArray ? 2 : 1)
        skipSpaces()
        let keyStart = i - lineStart(of: i)
        let (path, keyEndIndex) = try parseKey()
        let keyEnd = keyEndIndex - lineStart(of: keyEndIndex)
        skipSpaces()
        guard peek() == 0x5D else { throw fail("expected ] to close table header") }
        advance()
        if isArray {
            guard peek() == 0x5D else { throw fail("expected ]] to close array table header") }
            advance()
        }
        statements.append(TOMLStatement(kind: isArray ? .arrayTable : .table, path: path, section: path,
                                        firstLine: headerLine, lastLine: headerLine,
                                        keyStart: keyStart, keyEnd: keyEnd))
        section = path
        sectionIsArray = isArray
        if !isArray { ensureTable(path) }
    }

    private mutating func parseKeyValue() throws {
        let firstLine = line
        let keyStart = i - lineStart(of: i)
        let (key, keyEndIndex) = try parseKey()
        let keyEnd = keyEndIndex - lineStart(of: keyEndIndex)
        skipSpaces()
        guard peek() == 0x3D else { throw fail("expected = after key") }
        advance()
        skipSpaces()
        let value = try parseValue()
        statements.append(TOMLStatement(kind: .keyValue, path: section + key, section: section,
                                        firstLine: firstLine, lastLine: line,
                                        keyStart: keyStart, keyEnd: keyEnd))
        if !sectionIsArray { Self.insert(value, at: (section + key)[...], into: &root) }
    }

    /// A dotted key; returns the segments and the byte index just past the last segment.
    private mutating func parseKey() throws -> ([String], Int) {
        var parts: [String] = []
        var end = i
        while true {
            skipSpaces()
            guard let c = peek() else { throw fail("expected key") }
            if c == 0x22 {
                parts.append(try parseBasicString())
            } else if c == 0x27 {
                parts.append(try parseLiteralString())
            } else if Self.isBareKeyByte(c) {
                let start = i
                while let d = peek(), Self.isBareKeyByte(d) { advance() }
                parts.append(String(decoding: b[start..<i], as: UTF8.self))
            } else {
                throw fail("expected key")
            }
            end = i
            skipSpaces()
            guard peek() == 0x2E else { break }
            advance()
        }
        return (parts, end)
    }

    private mutating func parseValue() throws -> TOMLValue {
        guard let c = peek() else { throw fail("expected value") }
        switch c {
        case 0x22:
            if peek(1) == 0x22, peek(2) == 0x22 { return .string(try parseMultilineBasicString()) }
            return .string(try parseBasicString())
        case 0x27:
            if peek(1) == 0x27, peek(2) == 0x27 { return .string(try parseMultilineLiteralString()) }
            return .string(try parseLiteralString())
        case 0x5B:
            return try parseArray()
        case 0x7B:
            return try parseInlineTable()
        default:
            return try parseScalarToken()
        }
    }

    private mutating func parseArray() throws -> TOMLValue {
        advance()
        var items: [TOMLValue] = []
        while true {
            skipTrivia()
            guard let c = peek() else { throw fail("unterminated array") }
            if c == 0x5D { advance(); return .array(items) }
            items.append(try parseValue())
            skipTrivia()
            if peek() == 0x2C {
                advance()
            } else if peek() == 0x5D {
                advance()
                return .array(items)
            } else {
                throw fail("expected , or ] in array")
            }
        }
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        advance()
        var table: [String: TOMLValue] = [:]
        while true {
            skipTrivia()
            guard let c = peek() else { throw fail("unterminated inline table") }
            if c == 0x7D { advance(); return .table(table) }
            let (key, _) = try parseKey()
            skipSpaces()
            guard peek() == 0x3D else { throw fail("expected = in inline table") }
            advance()
            skipSpaces()
            Self.insert(try parseValue(), at: key[...], into: &table)
            skipTrivia()
            if peek() == 0x2C {
                advance()
            } else if peek() == 0x7D {
                advance()
                return .table(table)
            } else {
                throw fail("expected , or } in inline table")
            }
        }
    }

    private static func isTokenByte(_ c: UInt8) -> Bool {
        isBareKeyByte(c) || c == 0x2B || c == 0x2E || c == 0x3A
    }

    private mutating func parseScalarToken() throws -> TOMLValue {
        let start = i
        while let c = peek(), Self.isTokenByte(c) { advance() }
        var token = String(decoding: b[start..<i], as: UTF8.self)
        // Local date-times may separate date and time with a space.
        if token.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           peek() == 0x20, let next = peek(1), next >= 0x30, next <= 0x39 {
            advance()
            let timeStart = i
            while let c = peek(), Self.isTokenByte(c) { advance() }
            token += " " + String(decoding: b[timeStart..<i], as: UTF8.self)
        }
        if token.isEmpty { throw fail("expected value") }
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        let digits = token.replacingOccurrences(of: "_", with: "")
        if ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(token) {
            if token.hasSuffix("nan") { return .float(.nan) }
            return .float(token.hasPrefix("-") ? -.infinity : .infinity)
        }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            guard let value = Int64(digits.dropFirst(2), radix: radix) else { throw fail("invalid integer \(token)") }
            return .integer(value)
        }
        if token.range(of: #"^[+-]?\d[\d_]*$"#, options: .regularExpression) != nil {
            return Int64(digits).map(TOMLValue.integer) ?? .opaque(token)
        }
        if token.range(of: #"^[+-]?\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d[\d_]*)?$"#, options: .regularExpression) != nil,
           let value = Double(digits) {
            return .float(value)
        }
        if token.range(of: #"^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}"#, options: .regularExpression) != nil {
            return .opaque(token)
        }
        throw fail("unsupported value \(token)")
    }

    // MARK: Strings

    private mutating func parseBasicString() throws -> String {
        advance()
        var out: [UInt8] = []
        while true {
            guard let c = peek(), c != 0x0A else { throw fail("unterminated string") }
            advance()
            if c == 0x22 { break }
            if c == 0x5C { try appendEscape(into: &out) } else { out.append(c) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseMultilineBasicString() throws -> String {
        advance(3)
        skipLeadingNewline()
        var out: [UInt8] = []
        while true {
            guard let c = peek() else { throw fail("unterminated multi-line string") }
            if c == 0x22, peek(1) == 0x22, peek(2) == 0x22 {
                // Up to two quotes may sit directly before the closing delimiter.
                var extra = 0
                while extra < 2, peek(3 + extra) == 0x22 { extra += 1 }
                out.append(contentsOf: Array(repeating: 0x22, count: extra))
                advance(3 + extra)
                break
            }
            advance()
            if c == 0x5C {
                if let n = peek(), n == 0x20 || n == 0x09 || n == 0x0A || n == 0x0D {
                    while let w = peek(), w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D { advance() }
                } else {
                    try appendEscape(into: &out)
                }
            } else {
                out.append(c)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        let start = i
        while let c = peek(), c != 0x27 {
            if c == 0x0A { throw fail("unterminated string") }
            advance()
        }
        guard peek() == 0x27 else { throw fail("unterminated string") }
        let s = String(decoding: b[start..<i], as: UTF8.self)
        advance()
        return s
    }

    private mutating func parseMultilineLiteralString() throws -> String {
        advance(3)
        skipLeadingNewline()
        let start = i
        while !(peek() == 0x27 && peek(1) == 0x27 && peek(2) == 0x27) {
            guard !atEnd else { throw fail("unterminated multi-line string") }
            advance()
        }
        var extra = 0
        while extra < 2, peek(3 + extra) == 0x27 { extra += 1 }
        let s = String(decoding: b[start..<(i + extra)], as: UTF8.self)
        advance(3 + extra)
        return s
    }

    private mutating func skipLeadingNewline() {
        if peek() == 0x0A { advance() } else if peek() == 0x0D, peek(1) == 0x0A { advance(2) }
    }

    private mutating func appendEscape(into out: inout [UInt8]) throws {
        guard let e = peek() else { throw fail("unterminated escape") }
        advance()
        switch e {
        case 0x62: out.append(0x08)
        case 0x74: out.append(0x09)
        case 0x6E: out.append(0x0A)
        case 0x66: out.append(0x0C)
        case 0x72: out.append(0x0D)
        case 0x65: out.append(0x1B)
        case 0x22: out.append(0x22)
        case 0x5C: out.append(0x5C)
        case 0x75, 0x55:
            let count = e == 0x75 ? 4 : 8
            guard i + count <= b.count,
                  let value = UInt32(String(decoding: b[i..<(i + count)], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(value) else { throw fail("invalid unicode escape") }
            advance(count)
            out.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw fail("invalid escape \\\(Character(Unicode.Scalar(e)))")
        }
    }

    // MARK: Tables

    static func insert(_ value: TOMLValue, at path: ArraySlice<String>, into table: inout [String: TOMLValue]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            table[first] = value
            return
        }
        // Detach the child first so it is uniquely referenced and mutates in place.
        var child = table.removeValue(forKey: first)?.table ?? [:]
        insert(value, at: path.dropFirst(), into: &child)
        table[first] = .table(child)
    }

    private mutating func ensureTable(_ path: [String]) {
        Self.ensure(path[...], in: &root)
    }

    private static func ensure(_ path: ArraySlice<String>, in table: inout [String: TOMLValue]) {
        guard let first = path.first else { return }
        var child = table.removeValue(forKey: first)?.table ?? [:]
        ensure(path.dropFirst(), in: &child)
        table[first] = .table(child)
    }

    /// Statements with each header's `lastLine` extended over its section's content.
    func finishedStatements() -> [TOMLStatement] {
        var result = statements
        var header: Int?
        for index in result.indices {
            if result[index].isHeader {
                header = index
            } else if let h = header {
                result[h].lastLine = max(result[h].lastLine, result[index].lastLine)
            }
        }
        return result
    }
}
