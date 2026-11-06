import Foundation

/// The single entry point the app uses. Global writes always target both
/// clients unless told otherwise.
public final class MCPManager: @unchecked Sendable {
    public let paths: ConfigPaths
    /// Shared by every store so tests can hook the write path.
    var fileIO: FileIO

    public init(paths: ConfigPaths) {
        self.paths = paths
        self.fileIO = FileIO(backupDir: paths.backupDir)
    }

    var claudeStore: ClaudeConfigStore { ClaudeConfigStore(url: paths.claudeJSON, io: fileIO) }
    var codexStore: CodexConfigStore { CodexConfigStore(url: paths.codexTOML, io: fileIO) }
    var projectIndex: ProjectIndex { ProjectIndex(paths: paths, claude: claudeStore, codex: codexStore, io: fileIO) }

    /// Global servers from both clients, merged by name, sorted case-insensitively.
    public func loadGlobal() throws -> [GlobalServer] {
        let claude = try claudeStore.servers()
        let codex = try codexStore.servers()
        return Set(claude.keys).union(codex.keys)
            .map { GlobalServer(name: $0, claude: claude[$0], codex: codex[$0]) }
            .sorted { a, b in
                let order = a.name.caseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.name < b.name : order == .orderedAscending
            }
    }

    /// Adds one server to each client in `clients`. Validates the name and checks
    /// every target before writing anything. A client that cannot represent the
    /// transport (Codex + SSE) is skipped with a reason, not an error.
    @discardableResult
    public func add(name: String, config: MCPServerConfig, to clients: Set<MCPClient> = Set(MCPClient.allCases)) throws -> WriteReport {
        if Self.validateName(name) != nil { throw MCPManagerError.invalidName(name) }
        let targets = ordered(clients)
        for client in targets where try names(in: client).contains(name) {
            throw MCPManagerError.nameTaken(name: name, client: client)
        }
        var report = WriteReport()
        for client in targets {
            switch client {
            case .claude:
                try claudeStore.add(name: name, config: config)
            case .codex:
                if case .sse = config.transport {
                    report.skipped.append(.init(client: .codex, reason: CodexConfigStore.sseSkipReason))
                    continue
                }
                try codexStore.add(name: name, config: config)
            }
            report.written.append(client)
        }
        return report
    }

    /// Removes the global server from each client in `clients` that has it.
    @discardableResult
    public func remove(name: String, from clients: Set<MCPClient> = Set(MCPClient.allCases)) throws -> WriteReport {
        let holders = try ordered(clients).filter { try names(in: $0).contains(name) }
        guard !holders.isEmpty else { throw MCPManagerError.notFound(name: name) }
        for client in holders {
            switch client {
            case .claude: try claudeStore.remove(name: name)
            case .codex: try codexStore.remove(name: name)
            }
        }
        return WriteReport(written: holders)
    }

    /// Renames the global server in every client that has it, keeping each
    /// client's full original config (unknown keys included).
    @discardableResult
    public func rename(_ oldName: String, to newName: String) throws -> WriteReport {
        if Self.validateName(newName) != nil { throw MCPManagerError.invalidName(newName) }
        let holders = try MCPClient.allCases.filter { try names(in: $0).contains(oldName) }
        guard !holders.isEmpty else { throw MCPManagerError.notFound(name: oldName) }
        if oldName == newName { return WriteReport() }
        for client in holders where try names(in: client).contains(newName) {
            throw MCPManagerError.nameTaken(name: newName, client: client)
        }
        for client in holders {
            switch client {
            case .claude: try claudeStore.rename(oldName, to: newName)
            case .codex: try codexStore.rename(oldName, to: newName)
            }
        }
        return WriteReport(written: holders)
    }

    /// Copies a server that exists in one client into the clients missing it.
    @discardableResult
    public func sync(name: String) throws -> WriteReport {
        guard let server = try loadGlobal().first(where: { $0.name == name }),
              let source = server.primaryConfig else {
            throw MCPManagerError.notFound(name: name)
        }
        let missing = Set(server.missingClients)
        if missing.isEmpty { return WriteReport() }
        return try add(name: name, config: source, to: missing)
    }

    /// Known project directories (Claude `projects` keys + Codex `projects`
    /// tables) that still exist on disk, sorted by name.
    public func projects() -> [ProjectRef] {
        projectIndex.projects()
    }

    /// Every MCP configured for one project across all project-level sources.
    public func projectMCPs(_ project: ProjectRef) throws -> [MCPEntry] {
        try projectIndex.projectMCPs(project)
    }

    /// Removes one project-level MCP from the file it was read from.
    public func removeProjectEntry(_ entry: MCPEntry) throws {
        switch entry.scope {
        case let .claudeLocal(project):
            try claudeStore.remove(name: entry.name, project: project)
        case .claudeProject:
            try ClaudeConfigStore(url: URL(fileURLWithPath: entry.sourcePath), io: fileIO).remove(name: entry.name)
        case .codexProject:
            try CodexConfigStore(url: URL(fileURLWithPath: entry.sourcePath), io: fileIO).remove(name: entry.name)
        case .global:
            throw MCPManagerError.notFound(name: entry.name)
        }
    }

    /// Replaces one project-level MCP's name and config in its own file, keeping
    /// settings MCP Manager does not model.
    public func updateProjectEntry(_ entry: MCPEntry, name: String, config: MCPServerConfig) throws {
        if Self.validateName(name) != nil { throw MCPManagerError.invalidName(name) }
        switch entry.scope {
        case let .claudeLocal(project):
            try claudeStore.update(name: entry.name, to: name, config: config, project: project)
        case .claudeProject:
            try ClaudeConfigStore(url: URL(fileURLWithPath: entry.sourcePath), io: fileIO)
                .update(name: entry.name, to: name, config: config)
        case .codexProject:
            try CodexConfigStore(url: URL(fileURLWithPath: entry.sourcePath), io: fileIO)
                .update(name: entry.name, to: name, config: config)
        case .global:
            throw MCPManagerError.notFound(name: entry.name)
        }
    }

    /// `nil` when valid, else a message for the field.
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.count > 64 { return "Use 64 characters or fewer." }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
        if !allowed { return "Use only letters, digits, - and _." }
        return nil
    }

    /// Every global name a client has, including entries MCP Manager cannot model,
    /// so add and rename never collide with them.
    func names(in client: MCPClient) throws -> Set<String> {
        switch client {
        case .claude:
            let servers = try claudeStore.readRoot()?["mcpServers"] as? [String: Any] ?? [:]
            return Set(servers.keys)
        case .codex:
            let servers = try codexStore.readDocument()?.root["mcp_servers"]?.table ?? [:]
            return Set(servers.keys)
        }
    }

    private func ordered(_ clients: Set<MCPClient>) -> [MCPClient] {
        MCPClient.allCases.filter(clients.contains)
    }
}
