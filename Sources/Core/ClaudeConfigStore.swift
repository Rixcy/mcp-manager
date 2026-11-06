import Foundation

/// Claude Code's `~/.claude.json` (and the same `mcpServers` shape in a
/// project's `.mcp.json`). Writes touch only `mcpServers` and keep every
/// other key Claude Code stores there.
struct ClaudeConfigStore {
    let url: URL
    let io: FileIO

    func readRoot() throws -> [String: Any]? {
        guard let data = try io.read(url) else { return nil }
        return try Self.parseRoot(data, path: url.path)
    }

    func servers() throws -> [String: MCPServerConfig] {
        Self.servers(in: try readRoot()?["mcpServers"])
    }

    func projectKeys() throws -> [String] {
        guard let projects = try readRoot()?["projects"] as? [String: Any] else { return [] }
        return Array(projects.keys)
    }

    /// Local-scope servers for `project`, matching the `projects` key after standardizing it.
    func localServers(project: String) throws -> [String: MCPServerConfig] {
        guard let projects = try readRoot()?["projects"] as? [String: Any] else { return [:] }
        let target = ProjectIndex.standardize(project)
        for (key, value) in projects where ProjectIndex.standardize(key) == target {
            return Self.servers(in: (value as? [String: Any])?["mcpServers"])
        }
        return [:]
    }

    func add(name: String, config: MCPServerConfig) throws {
        try editServers { servers in
            if servers[name] != nil { throw MCPManagerError.nameTaken(name: name, client: .claude) }
            servers[name] = Self.entryObject(for: config)
        }
    }

    /// `project` targets that project's local-scope `mcpServers` instead of the top-level one.
    func remove(name: String, project: String? = nil) throws {
        try editServers(project: project) { servers in
            guard servers.removeValue(forKey: name) != nil else { throw MCPManagerError.notFound(name: name) }
        }
    }

    /// Replaces the modelled keys of `name` with `config`, keeping keys MCP
    /// Manager does not model (such as `oauth`), and renames it to `newName`.
    func update(name: String, to newName: String, config: MCPServerConfig, project: String? = nil) throws {
        try editServers(project: project) { servers in
            guard let old = servers[name] else { throw MCPManagerError.notFound(name: name) }
            if newName != name, servers[newName] != nil { throw MCPManagerError.nameTaken(name: newName, client: .claude) }
            var entry = (old as? [String: Any] ?? [:]).filter { !Self.modelledKeys.contains($0.key) }
            entry.merge(Self.entryObject(for: config)) { _, new in new }
            servers.removeValue(forKey: name)
            servers[newName] = entry
        }
    }

    func rename(_ oldName: String, to newName: String) throws {
        try editServers { servers in
            if servers[newName] != nil { throw MCPManagerError.nameTaken(name: newName, client: .claude) }
            guard let entry = servers.removeValue(forKey: oldName) else { throw MCPManagerError.notFound(name: oldName) }
            servers[newName] = entry
        }
    }

    private func editServers(project: String? = nil, _ change: (inout [String: Any]) throws -> Void) throws {
        try io.modify(url) { data in
            var root = try data.map { try Self.parseRoot($0, path: url.path) } ?? [:]
            if let project {
                var projects = root["projects"] as? [String: Any] ?? [:]
                let target = ProjectIndex.standardize(project)
                let key = projects.keys.first { ProjectIndex.standardize($0) == target } ?? project
                var projectEntry = projects[key] as? [String: Any] ?? [:]
                var servers = projectEntry["mcpServers"] as? [String: Any] ?? [:]
                try change(&servers)
                projectEntry["mcpServers"] = servers
                projects[key] = projectEntry
                root["projects"] = projects
            } else {
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                try change(&servers)
                root["mcpServers"] = servers
            }
            do {
                return try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            } catch {
                throw MCPManagerError.io(path: url.path, detail: error.localizedDescription)
            }
        }
    }

    // MARK: Format

    /// Keys `entryObject(for:)` writes; everything else in an entry is kept on update.
    static let modelledKeys: Set<String> = ["type", "command", "args", "env", "url", "headers"]

    static func parseRoot(_ data: Data, path: String) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw MCPManagerError.parse(path: path, detail: (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                                            ?? error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw MCPManagerError.parse(path: path, detail: "top level is not a JSON object")
        }
        return root
    }

    static func servers(in value: Any?) -> [String: MCPServerConfig] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: MCPServerConfig] = [:]
        for (name, entry) in dict {
            if let entry = entry as? [String: Any], let config = config(from: entry) { result[name] = config }
        }
        return result
    }

    static func config(from entry: [String: Any]) -> MCPServerConfig? {
        let type = (entry["type"] as? String)?.lowercased()
        if type == "http" || type == "sse" || (type == nil && entry["command"] == nil && entry["url"] != nil) {
            guard let url = entry["url"] as? String else { return nil }
            var headers = stringMap(entry["headers"])
            var bearer: String?
            if let key = headers.keys.first(where: { $0.lowercased() == "authorization" }),
               let variable = bearerVariable(headers[key]!) {
                bearer = variable
                headers.removeValue(forKey: key)
            }
            let transport: MCPTransport = type == "sse" ? .sse(url: url, headers: headers) : .http(url: url, headers: headers)
            return MCPServerConfig(transport: transport, bearerTokenEnvVar: bearer)
        }
        guard let command = entry["command"] as? String else { return nil }
        let args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        return MCPServerConfig(transport: .stdio(command: command, args: args, env: stringMap(entry["env"])))
    }

    /// `VAR` from a header value of exactly `Bearer ${VAR}`.
    static func bearerVariable(_ header: String) -> String? {
        guard let match = header.range(of: #"^Bearer \$\{[A-Za-z_][A-Za-z0-9_]*\}$"#, options: .regularExpression) else {
            return nil
        }
        return String(header[match].dropFirst("Bearer ${".count).dropLast())
    }

    static func entryObject(for config: MCPServerConfig) -> [String: Any] {
        switch config.transport {
        case let .stdio(command, args, env):
            return ["type": "stdio", "command": command, "args": args, "env": env]
        case let .http(url, headers), let .sse(url, headers):
            var headers = headers
            if let variable = config.bearerTokenEnvVar {
                headers["Authorization"] = "Bearer ${\(variable)}"
            }
            var entry: [String: Any] = ["type": config.transport.kindLabel, "url": url]
            if !headers.isEmpty { entry["headers"] = headers }
            return entry
        }
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.compactMapValues { value in
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return nil
        }
    }
}
