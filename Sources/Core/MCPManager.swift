import Foundation

/// The single entry point the app uses. Global writes always target both
/// clients unless told otherwise.
public final class MCPManager: @unchecked Sendable {
    public let paths: ConfigPaths

    public init(paths: ConfigPaths) {
        self.paths = paths
    }

    /// Global servers from both clients, merged by name, sorted case-insensitively.
    public func loadGlobal() throws -> [GlobalServer] {
        throw MCPManagerError.notImplemented
    }

    /// Adds one server to each client in `clients`. Validates the name and checks
    /// every target before writing anything. A client that cannot represent the
    /// transport (Codex + SSE) is skipped with a reason, not an error.
    @discardableResult
    public func add(name: String, config: MCPServerConfig, to clients: Set<MCPClient> = Set(MCPClient.allCases)) throws -> WriteReport {
        throw MCPManagerError.notImplemented
    }

    /// Removes the global server from each client in `clients` that has it.
    @discardableResult
    public func remove(name: String, from clients: Set<MCPClient> = Set(MCPClient.allCases)) throws -> WriteReport {
        throw MCPManagerError.notImplemented
    }

    /// Renames the global server in every client that has it, keeping each
    /// client's full original config (unknown keys included).
    @discardableResult
    public func rename(_ oldName: String, to newName: String) throws -> WriteReport {
        throw MCPManagerError.notImplemented
    }

    /// Copies a server that exists in one client into the clients missing it.
    @discardableResult
    public func sync(name: String) throws -> WriteReport {
        throw MCPManagerError.notImplemented
    }

    /// Known project directories (Claude `projects` keys + Codex `projects`
    /// tables) that still exist on disk, sorted by name.
    public func projects() -> [ProjectRef] {
        []
    }

    /// Every MCP configured for one project across all project-level sources.
    public func projectMCPs(_ project: ProjectRef) throws -> [MCPEntry] {
        throw MCPManagerError.notImplemented
    }

    /// `nil` when valid, else a message for the field.
    public static func validateName(_ name: String) -> String? {
        nil
    }
}

public enum FuzzyMatcher {
    /// Score for a query against a candidate; `nil` means no match. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        nil
    }

    /// Projects matching `query`, best first. An empty query returns all projects unchanged.
    public static func rank(_ projects: [ProjectRef], query: String) -> [ProjectRef] {
        projects
    }
}
