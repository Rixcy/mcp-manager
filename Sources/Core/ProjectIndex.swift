import Foundation

/// Project discovery and per-project MCP sources.
struct ProjectIndex {
    let paths: ConfigPaths
    let claude: ClaudeConfigStore
    let codex: CodexConfigStore
    let io: FileIO

    static func standardize(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// Unreadable configs contribute nothing rather than hiding the other client's projects.
    func projects() -> [ProjectRef] {
        let keys = ((try? claude.projectKeys()) ?? []) + ((try? codex.projectKeys()) ?? [])
        var seen = Set<String>()
        var result: [ProjectRef] = []
        for key in keys {
            let path = Self.standardize(key)
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            result.append(ProjectRef(path: path))
        }
        return result.sorted { a, b in
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            return byName == .orderedSame ? a.path < b.path : byName == .orderedAscending
        }
    }

    func projectMCPs(_ project: ProjectRef) throws -> [MCPEntry] {
        let projectPath = Self.standardize(project.path)
        let projectURL = URL(fileURLWithPath: projectPath)
        var entries: [MCPEntry] = []

        func append(_ servers: [String: MCPServerConfig], client: MCPClient, scope: MCPScope, source: URL) {
            for name in servers.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                entries.append(MCPEntry(name: name, client: client, scope: scope, config: servers[name]!,
                                        sourcePath: source.path))
            }
        }

        append(try claude.localServers(project: projectPath), client: .claude,
               scope: .claudeLocal(project: projectPath), source: paths.claudeJSON)

        let mcpJSON = projectURL.appendingPathComponent(".mcp.json")
        if let data = try io.read(mcpJSON) {
            let root = try ClaudeConfigStore.parseRoot(data, path: mcpJSON.path)
            append(ClaudeConfigStore.servers(in: root["mcpServers"]), client: .claude,
                   scope: .claudeProject(project: projectPath), source: mcpJSON)
        }

        // For the home directory this is the global Codex file, already shown as global.
        let codexTOML = projectURL.appendingPathComponent(".codex/config.toml")
        if codexTOML.resolvingSymlinksInPath().path != paths.codexTOML.resolvingSymlinksInPath().path {
            let projectCodex = CodexConfigStore(url: codexTOML, io: io)
            append(try projectCodex.servers(), client: .codex,
                   scope: .codexProject(project: projectPath), source: codexTOML)
        }
        return entries
    }
}
