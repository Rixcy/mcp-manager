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

    var orderStore: ServerOrderStore { ServerOrderStore(url: paths.serverOrderFile) }

    /// Global servers from both clients, merged by name, in the saved order with
    /// servers it does not list yet on top. Before anything is saved, Codex's
    /// file order (newest last) is the best record of when each was added.
    public func loadGlobal() throws -> [GlobalServer] {
        let claude = try claudeStore.servers()
        let codex = try codexStore.servers()
        let names = Set(claude.keys).union(codex.keys)
        let saved = (try? orderStore.global()) ?? []
        let fallback = try codexStore.serverNamesInFileOrder().reversed()
        return ServerOrder.arrange(names, saved: saved, fallback: Array(fallback))
            .map { GlobalServer(name: $0, claude: claude[$0], codex: codex[$0]) }
    }

    /// Saves the order the global list shows, top first.
    public func saveGlobalOrder(_ names: [String]) throws {
        try orderStore.setGlobal(names)
    }

    /// The list order is cosmetic, so failing to carry it over must not fail
    /// a rename that already reached the configs.
    private func carryOrder(from oldName: String, to newName: String) {
        try? orderStore.renameGlobal(oldName, to: newName)
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
        carryOrder(from: oldName, to: newName)
        return WriteReport(written: holders)
    }

    /// Replaces the global server's config (and optionally its name) in every
    /// client that has it. Each client keeps its own `enabled` value and the keys
    /// MCP Manager does not model. Everything is checked before anything is written.
    @discardableResult
    /// `editedFrom` is the config the editor started from. A client whose own settings
    /// differ from it only takes the new name, so saving Claude's copy never overwrites
    /// different settings that Codex keeps for the same server.
    public func updateGlobal(_ name: String, to newName: String, config: MCPServerConfig,
                             editedFrom original: MCPServerConfig? = nil) throws -> WriteReport {
        if Self.validateName(newName) != nil { throw MCPManagerError.invalidName(newName) }
        let holders = try MCPClient.allCases.filter { try names(in: $0).contains(name) }
        guard !holders.isEmpty else { throw MCPManagerError.notFound(name: name) }
        if newName != name {
            for client in holders where try names(in: client).contains(newName) {
                throw MCPManagerError.nameTaken(name: newName, client: client)
            }
        }
        let current = try loadGlobal().first { $0.name == name }
        let differing = holders.filter { client in
            guard let original, let own = current?.config(for: client) else { return false }
            return own.transport != original.transport || own.bearerTokenEnvVar != original.bearerTokenEnvVar
        }
        if holders.contains(.codex), !differing.contains(.codex), case .sse = config.transport {
            throw MCPManagerError.io(path: paths.codexTOML.path, detail: CodexConfigStore.sseSkipReason)
        }
        var report = WriteReport()
        for client in holders {
            if differing.contains(client) {
                if newName != name {
                    switch client {
                    case .claude: try claudeStore.rename(name, to: newName)
                    case .codex: try codexStore.rename(name, to: newName)
                    }
                    report.written.append(client)
                }
                let kept = newName != name ? "only its name changed" : "it was left unchanged"
                report.skipped.append(.init(client: client, reason: "\(client.displayName) has different settings for this MCP, so \(kept)"))
                continue
            }
            var own = config
            own.enabled = current?.config(for: client)?.enabled ?? true
            switch client {
            case .claude: try claudeStore.update(name: name, to: newName, config: own)
            case .codex: try codexStore.update(name: name, to: newName, config: own)
            }
            report.written.append(client)
        }
        carryOrder(from: name, to: newName)
        return report
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
