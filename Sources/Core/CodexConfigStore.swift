import Foundation

/// Codex `config.toml`. Reads parse the TOML; writes are textual edits of the
/// affected lines so comments, ordering and unrelated tables survive byte for byte.
struct CodexConfigStore {
    static let sseSkipReason = "Codex has no SSE transport"

    let url: URL
    let io: FileIO

    func readDocument() throws -> TOMLDocument? {
        guard let data = try io.read(url) else { return nil }
        return try MiniTOML.parse(Self.decode(data, path: url.path), path: url.path)
    }

    func servers() throws -> [String: MCPServerConfig] {
        guard let doc = try readDocument() else { return [:] }
        return Self.servers(in: doc)
    }

    /// Server names in the order their tables first appear in the file.
    func serverNamesInFileOrder() throws -> [String] {
        guard let doc = try readDocument() else { return [] }
        var seen = Set<String>()
        return doc.statements.compactMap { statement -> String? in
            guard statement.path.count >= 2, statement.path[0] == "mcp_servers",
                  seen.insert(statement.path[1]).inserted else { return nil }
            return statement.path[1]
        }
    }

    /// Keys of the `[projects."…"]` tables.
    func projectKeys() throws -> [String] {
        guard let doc = try readDocument() else { return [] }
        return doc.root["projects"]?.table.map { Array($0.keys) } ?? []
    }

    func add(name: String, config: MCPServerConfig) throws {
        try edit { text in try Self.adding(name: name, config: config, to: text, path: url.path) }
    }

    func remove(name: String) throws {
        try edit { text in try Self.removing(name: name, from: text, path: url.path) }
    }

    func rename(_ oldName: String, to newName: String) throws {
        try edit { text in try Self.renaming(oldName, to: newName, in: text, path: url.path) }
    }

    func update(name: String, to newName: String, config: MCPServerConfig) throws {
        try edit { text in try Self.updating(name, to: newName, config: config, in: text, path: url.path) }
    }

    private func edit(_ change: (String) throws -> String) throws {
        try io.modify(url) { data in
            let text = try data.map { try Self.decode($0, path: url.path) } ?? ""
            return Data(try change(text).utf8)
        }
    }

    static func decode(_ data: Data, path: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPManagerError.parse(path: path, detail: "not UTF-8 text")
        }
        return text
    }

    // MARK: Reading

    static func servers(in doc: TOMLDocument) -> [String: MCPServerConfig] {
        var result: [String: MCPServerConfig] = [:]
        for (name, value) in doc.root["mcp_servers"]?.table ?? [:] {
            if let table = value.table, let config = config(from: table) { result[name] = config }
        }
        return result
    }

    static func config(from table: [String: TOMLValue]) -> MCPServerConfig? {
        let enabled = table["enabled"]?.bool ?? true
        if let url = table["url"]?.string {
            return MCPServerConfig(transport: .http(url: url, headers: stringMap(table["http_headers"])),
                                   bearerTokenEnvVar: table["bearer_token_env_var"]?.string,
                                   enabled: enabled)
        }
        if let command = table["command"]?.string {
            let args = table["args"]?.array?.compactMap(\.scalarText) ?? []
            return MCPServerConfig(transport: .stdio(command: command, args: args, env: stringMap(table["env"])),
                                   enabled: enabled)
        }
        return nil
    }

    private static func stringMap(_ value: TOMLValue?) -> [String: String] {
        (value?.table ?? [:]).compactMapValues(\.scalarText)
    }

    // MARK: Editing

    private static func serverPrefix(_ name: String) -> [String] { ["mcp_servers", name] }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.isEmpty || trimmed.first == "#" || trimmed == "\r"
    }

    static func adding(name: String, config: MCPServerConfig, to text: String, path: String) throws -> String {
        let doc = try MiniTOML.parse(text, path: path)
        if servers(in: doc)[name] != nil || doc.root["mcp_servers"]?.table?[name] != nil {
            throw MCPManagerError.nameTaken(name: name, client: .codex)
        }
        let block = try serverBlock(name: name, config: config, path: path)
        let headers = doc.statements.filter { $0.isHeader && $0.path.first == "mcp_servers" }
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")

        if let regionEnd = headers.map(\.lastLine).max(), let lastHeader = headers.max(by: { $0.firstLine < $1.firstLine }) {
            // Match the file's style: blank-line-separated blocks get a blank line too.
            let separate = lastHeader.firstLine > 0 && isBlank(lines[lastHeader.firstLine - 1])
            let insertAt = regionEnd + 1
            lines.insert(contentsOf: (separate ? [""] : []) + block + (insertAt == lines.count ? [""] : []), at: insertAt)
        } else {
            if lines.last == "" { lines.removeLast() }
            if let last = lines.last, !isBlank(last) { lines.append("") }
            lines += block + [""]
        }
        return lines.joined(separator: "\n")
    }

    static func serverBlock(name: String, config: MCPServerConfig, path: String) throws -> [String] {
        let header = MiniTOML.renderPath(serverPrefix(name))
        var lines = ["[\(header)]"]
        var envTable: [String: String] = [:]
        switch config.transport {
        case let .stdio(command, args, env):
            lines.append("command = \(MiniTOML.quote(command))")
            lines.append("args = [\(args.map(MiniTOML.quote).joined(separator: ", "))]")
            envTable = env
        case let .http(url, headers):
            lines.append("url = \(MiniTOML.quote(url))")
            if !headers.isEmpty {
                let pairs = headers.keys.sorted().map { "\(MiniTOML.renderKey($0)) = \(MiniTOML.quote(headers[$0]!))" }
                lines.append("http_headers = { \(pairs.joined(separator: ", ")) }")
            }
            if let bearer = config.bearerTokenEnvVar {
                lines.append("bearer_token_env_var = \(MiniTOML.quote(bearer))")
            }
        case .sse:
            throw MCPManagerError.io(path: path, detail: sseSkipReason)
        }
        if !config.enabled { lines.append("enabled = false") }
        if !envTable.isEmpty {
            lines.append("[\(header).env]")
            for key in envTable.keys.sorted() {
                lines.append("\(MiniTOML.renderKey(key)) = \(MiniTOML.quote(envTable[key]!))")
            }
        }
        return lines
    }

    static func removing(name: String, from text: String, path: String) throws -> String {
        let doc = try MiniTOML.parse(text, path: path)
        let prefix = serverPrefix(name)
        var ranges: [ClosedRange<Int>] = []
        for statement in doc.statements where statement.hasPrefix(prefix) {
            if statement.isHeader || !hasPrefix(statement.section, prefix) {
                ranges.append(statement.firstLine...statement.lastLine)
            }
        }
        guard !ranges.isEmpty else { throw MCPManagerError.notFound(name: name) }

        var lines = text.components(separatedBy: "\n")
        // Merge blocks separated only by blank or comment lines (e.g. a server and its `.env` table).
        var merged: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last,
               range.lowerBound <= last.upperBound + 1
                || lines[(last.upperBound + 1)..<range.lowerBound].allSatisfy(isBlankOrComment) {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        for range in merged.reversed() {
            lines.removeSubrange(range)
            collapseBlankRun(in: &lines, at: range.lowerBound)
        }
        return lines.joined(separator: "\n")
    }

    /// After a removal at `junction`, keep at most one blank line there (none at the top of the file).
    private static func collapseBlankRun(in lines: inout [String], at junction: Int) {
        var start = junction
        while start > 0, isBlank(lines[start - 1]) { start -= 1 }
        var end = junction
        while end < lines.count, isBlank(lines[end]) { end += 1 }
        let keep = start == 0 && end < lines.count ? 0 : 1
        if end - start > keep { lines.removeSubrange(start..<(end - keep)) }
    }

    static func renaming(_ oldName: String, to newName: String, in text: String, path: String) throws -> String {
        let doc = try MiniTOML.parse(text, path: path)
        let oldPrefix = serverPrefix(oldName)
        if doc.root["mcp_servers"]?.table?[newName] != nil {
            throw MCPManagerError.nameTaken(name: newName, client: .codex)
        }
        var lines = text.components(separatedBy: "\n")
        var touched = false
        for statement in doc.statements where statement.hasPrefix(oldPrefix) {
            let ownedByServer = !statement.isHeader && hasPrefix(statement.section, oldPrefix)
            if ownedByServer { continue }
            var newPath = statement.path
            newPath[1] = newName
            let keyPath = statement.isHeader ? newPath : Array(newPath.dropFirst(statement.section.count))
            var bytes = Array(lines[statement.firstLine].utf8)
            bytes.replaceSubrange(statement.keyStart..<statement.keyEnd, with: Array(MiniTOML.renderPath(keyPath).utf8))
            lines[statement.firstLine] = String(decoding: bytes, as: UTF8.self)
            touched = true
        }
        guard touched else { throw MCPManagerError.notFound(name: oldName) }
        return lines.joined(separator: "\n")
    }

    /// Keys `serverBlock` writes; any other key or sub-table of the server is carried over on update.
    private static let modelledKeys: Set<String> = ["command", "args", "env", "url", "http_headers", "bearer_token_env_var", "enabled"]

    /// Rewrites the server's block where it stands. Unmodelled keys of its own
    /// table and its other sub-tables (e.g. `tools`) are kept verbatim.
    static func updating(_ oldName: String, to newName: String, config: MCPServerConfig,
                         in text: String, path: String) throws -> String {
        if case .sse = config.transport { throw MCPManagerError.io(path: path, detail: sseSkipReason) }
        let renamed = oldName == newName ? text : try renaming(oldName, to: newName, in: text, path: path)
        let doc = try MiniTOML.parse(renamed, path: path)
        let prefix = serverPrefix(newName)
        var lines = renamed.components(separatedBy: "\n")

        var ranges: [ClosedRange<Int>] = []
        var keptKeys: [String] = []
        var keptTables: [String] = []
        for statement in doc.statements where statement.hasPrefix(prefix) {
            let ownedByServer = !statement.isHeader && hasPrefix(statement.section, prefix)
            let key = statement.path.count > prefix.count ? statement.path[prefix.count] : nil
            if ownedByServer {
                if statement.section == prefix, let key, !modelledKeys.contains(key) {
                    keptKeys += lines[statement.firstLine...statement.lastLine]
                }
                continue
            }
            if statement.isHeader, let key, key != "env", statement.path.count > prefix.count {
                keptTables += lines[statement.firstLine...trimmedEnd(statement.firstLine...statement.lastLine, in: lines)]
            } else if !statement.isHeader, let key, !modelledKeys.contains(key) {
                throw MCPManagerError.io(path: path, detail: "\(newName) sets \(key) with a dotted key; edit it in the file")
            }
            ranges.append(statement.firstLine...statement.lastLine)
        }
        guard !ranges.isEmpty else { throw MCPManagerError.notFound(name: oldName) }

        var block = try serverBlock(name: newName, config: config, path: path)
        let envStart = block.dropFirst().firstIndex { $0.hasPrefix("[") } ?? block.count
        block.insert(contentsOf: keptKeys, at: envStart)
        block += keptTables

        // One span from the server's first line to its last, joined across blank and comment lines.
        var merged: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last,
               range.lowerBound <= last.upperBound + 1
                || lines[(last.upperBound + 1)..<range.lowerBound].allSatisfy(isBlankOrComment) {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        for range in merged.dropFirst().reversed() {
            lines.removeSubrange(range)
        }
        let first = merged[0]
        lines.replaceSubrange(first.lowerBound...trimmedEnd(first, in: lines), with: block)
        return lines.joined(separator: "\n")
    }

    /// `range`'s last line with trailing blank lines dropped, so the separator before the next table survives.
    private static func trimmedEnd(_ range: ClosedRange<Int>, in lines: [String]) -> Int {
        var upper = range.upperBound
        while upper > range.lowerBound, isBlank(lines[upper]) { upper -= 1 }
        return upper
    }

    private static func hasPrefix(_ path: [String], _ prefix: [String]) -> Bool {
        path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix
    }
}
