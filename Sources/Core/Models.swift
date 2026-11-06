import Foundation

/// An agent CLI whose MCP configuration MCP Manager reads and writes.
public enum MCPClient: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public enum MCPTransport: Equatable, Hashable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String])
    /// Claude-only; Codex has no SSE transport.
    case sse(url: String, headers: [String: String])

    public var kindLabel: String {
        switch self {
        case .stdio: return "stdio"
        case .http: return "http"
        case .sse: return "sse"
        }
    }

    /// One-line summary for list rows: the command line or the URL.
    public var summary: String {
        switch self {
        case let .stdio(command, args, _):
            return ([command] + args).joined(separator: " ")
        case let .http(url, _), let .sse(url, _):
            return url
        }
    }
}

public struct MCPServerConfig: Equatable, Hashable, Sendable {
    public var transport: MCPTransport
    /// Codex `bearer_token_env_var`; for Claude it maps to an `Authorization: Bearer ${VAR}` header.
    public var bearerTokenEnvVar: String?
    /// Codex `enabled = false` reads as disabled; Claude entries are always enabled.
    public var enabled: Bool

    public init(transport: MCPTransport, bearerTokenEnvVar: String? = nil, enabled: Bool = true) {
        self.transport = transport
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.enabled = enabled
    }
}

/// Where an MCP entry lives.
public enum MCPScope: Equatable, Hashable, Sendable {
    /// Claude user scope (`~/.claude.json` top-level `mcpServers`) or Codex `~/.codex/config.toml`.
    case global
    /// Claude local scope: `~/.claude.json` `projects[path].mcpServers`.
    case claudeLocal(project: String)
    /// Claude project scope: `<project>/.mcp.json`.
    case claudeProject(project: String)
    /// Codex project layer: `<project>/.codex/config.toml`.
    case codexProject(project: String)

    public var label: String {
        switch self {
        case .global: return "Global"
        case .claudeLocal: return "Claude · local (~/.claude.json)"
        case .claudeProject: return "Claude · project (.mcp.json)"
        case .codexProject: return "Codex · project (.codex/config.toml)"
        }
    }
}

public struct MCPEntry: Identifiable, Equatable, Hashable, Sendable {
    public var name: String
    public var client: MCPClient
    public var scope: MCPScope
    public var config: MCPServerConfig
    /// Absolute path of the file the entry was read from.
    public var sourcePath: String

    public var id: String { "\(client.rawValue)|\(sourcePath)|\(name)|\(scope.label)" }

    public init(name: String, client: MCPClient, scope: MCPScope, config: MCPServerConfig, sourcePath: String) {
        self.name = name
        self.client = client
        self.scope = scope
        self.config = config
        self.sourcePath = sourcePath
    }
}

/// One global server name, merged across clients.
public struct GlobalServer: Identifiable, Equatable, Sendable {
    public var name: String
    public var claude: MCPServerConfig?
    public var codex: MCPServerConfig?

    public var id: String { name }

    public init(name: String, claude: MCPServerConfig?, codex: MCPServerConfig?) {
        self.name = name
        self.claude = claude
        self.codex = codex
    }

    public func config(for client: MCPClient) -> MCPServerConfig? {
        client == .claude ? claude : codex
    }

    public var clients: [MCPClient] { MCPClient.allCases.filter { config(for: $0) != nil } }
    public var missingClients: [MCPClient] { MCPClient.allCases.filter { config(for: $0) == nil } }
    /// The config shown for the row: Claude's when present, else Codex's.
    public var primaryConfig: MCPServerConfig? { claude ?? codex }
}

public struct ProjectRef: Identifiable, Hashable, Sendable {
    /// Absolute, standardized directory path.
    public var path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// `~`-abbreviated path for display.
    public var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    public init(path: String) { self.path = path }
}

public struct WriteReport: Equatable, Sendable {
    public var written: [MCPClient]
    /// Clients left untouched, with the reason shown to the user.
    public var skipped: [Skip]

    public struct Skip: Equatable, Sendable {
        public var client: MCPClient
        public var reason: String
        public init(client: MCPClient, reason: String) { self.client = client; self.reason = reason }
    }

    public init(written: [MCPClient] = [], skipped: [Skip] = []) {
        self.written = written
        self.skipped = skipped
    }
}

public enum MCPManagerError: LocalizedError, Equatable {
    case invalidName(String)
    case nameTaken(name: String, client: MCPClient)
    case notFound(name: String)
    case parse(path: String, detail: String)
    case concurrentModification(path: String)
    case io(path: String, detail: String)
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            return "“\(name)” is not a valid MCP name. Use letters, digits, - or _ (max 64)."
        case let .nameTaken(name, client):
            return "\(client.displayName) already has an MCP called “\(name)”."
        case let .notFound(name):
            return "No MCP called “\(name)”."
        case let .parse(path, detail):
            return "Could not read \(path): \(detail)"
        case let .concurrentModification(path):
            return "\(path) kept changing while saving. Try again."
        case let .io(path, detail):
            return "Could not write \(path): \(detail)"
        case .notImplemented:
            return "Not implemented yet."
        }
    }
}
