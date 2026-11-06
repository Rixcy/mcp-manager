import Foundation

/// One configured server the client can connect to: a global MCP or one
/// project entry, with the identity its logs, variables and session hang off.
public struct MCPServerTarget: Identifiable, Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        case global(clients: [MCPClient])
        case project(MCPEntry)
    }

    public var name: String
    /// For a global server in both clients this is Claude's config.
    public var config: MCPServerConfig
    public var origin: Origin

    public init(name: String, config: MCPServerConfig, origin: Origin) {
        self.name = name
        self.config = config
        self.origin = origin
    }

    public static func global(_ server: GlobalServer) -> MCPServerTarget? {
        guard let config = server.primaryConfig else { return nil }
        return MCPServerTarget(name: server.name, config: config, origin: .global(clients: server.clients))
    }

    public static func project(_ entry: MCPEntry) -> MCPServerTarget {
        MCPServerTarget(name: entry.name, config: entry.config, origin: .project(entry))
    }

    /// Stable across launches; keys variables, logs and live sessions.
    public var key: String {
        switch origin {
        case .global:
            return "global/\(name)"
        case let .project(entry):
            return "project/\(entry.client.rawValue)/\(Self.scopeTag(entry.scope))/\(entry.sourcePath)/\(name)"
        }
    }

    public var id: String { key }

    /// Directory a stdio server starts in: the project for project entries, else nil (the home directory).
    public var projectPath: String? {
        guard case let .project(entry) = origin else { return nil }
        switch entry.scope {
        case let .claudeLocal(project), let .claudeProject(project), let .codexProject(project): return project
        case .global: return nil
        }
    }

    /// "Global · Claude and Codex", "reels · .mcp.json".
    public var locationLabel: String {
        switch origin {
        case let .global(clients):
            let names = clients.map(\.displayName)
            return "Global · " + (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "")
        case let .project(entry):
            let project = projectPath.map { ($0 as NSString).lastPathComponent } ?? "project"
            switch entry.scope {
            case .claudeLocal: return "\(project) · Claude local"
            case .claudeProject: return "\(project) · .mcp.json"
            case .codexProject: return "\(project) · Codex project"
            case .global: return project
            }
        }
    }

    /// Unique per target and safe as a file name.
    public var logFileName: String {
        switch origin {
        case .global:
            return "global-\(Self.fileSafe(name)).jsonl"
        case .project:
            let project = projectPath.map { ($0 as NSString).lastPathComponent } ?? "project"
            return "\(Self.fileSafe(project))-\(Self.fileSafe(name))-\(Self.shortHash(key)).jsonl"
        }
    }

    private static func scopeTag(_ scope: MCPScope) -> String {
        switch scope {
        case .global: return "global"
        case .claudeLocal: return "local"
        case .claudeProject: return "mcp-json"
        case .codexProject: return "codex"
        }
    }

    static func fileSafe(_ text: String) -> String {
        let safe = String(text.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == ".")
                ? Character(scalar) : "_"
        })
        return safe.isEmpty ? "_" : String(safe.prefix(60))
    }

    /// FNV-1a, because `hashValue` changes between launches.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(String(hash, radix: 16).suffix(8))
    }
}

/// What the client launches or calls once variables are expanded and the command is found.
public struct ResolvedLaunch: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case stdio(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?)
        case streamableHTTP(url: URL, headers: [String: String])
        case sse(url: URL, headers: [String: String])
    }

    public var target: Target
    /// Command line or URL for logs and errors. Never holds env or header values.
    public var displayName: String

    public init(target: Target, displayName: String) {
        self.target = target
        self.displayName = displayName
    }
}

/// A variable the user added in MCP Manager for one server. Applied on connect,
/// never written to Claude or Codex config.
public struct ClientVariable: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

public struct MCPLogEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A JSON-RPC message MCP Manager sent.
        case outgoing
        /// A JSON-RPC message the server sent.
        case incoming
        /// A line the server wrote to stderr.
        case stderr
        /// Connection lifecycle: launched, connected, closed, HTTP status.
        case event
        case warning
        case error
    }

    public var id: UInt64
    public var time: Date
    public var kind: Kind
    public var summary: String
    /// Compact JSON or text, already redacted and size-capped by the producer.
    public var detail: String?

    public init(id: UInt64 = MCPLogEntry.nextID(), time: Date = Date(), kind: Kind, summary: String, detail: String? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }

    private static let idLock = NSLock()
    nonisolated(unsafe) private static var lastID: UInt64 = 0

    /// Unique across every log in the process, so entries reloaded from disk
    /// never share an id with live ones in the same list.
    public static func nextID() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }
        lastID += 1
        return lastID
    }
}

/// Where a session's log entries go. Producers pass details through
/// `LogFormatting` first so secrets and huge payloads never reach a sink.
public protocol MCPLogSink: AnyObject, Sendable {
    func record(_ kind: MCPLogEntry.Kind, _ summary: String, detail: String?)
}

/// Keeps entries in memory; for tests and anything that needs no file.
public final class MCPMemoryLog: MCPLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MCPLogEntry] = []

    public init() {}

    public func record(_ kind: MCPLogEntry.Kind, _ summary: String, detail: String?) {
        let entry = MCPLogEntry(kind: kind, summary: summary, detail: detail)
        lock.lock()
        defer { lock.unlock() }
        stored.append(entry)
    }

    public var entries: [MCPLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Supplies the Authorization header for HTTP and SSE requests.
public protocol MCPAuthProvider: Sendable {
    /// The full header value (`Bearer …`), or nil to send none.
    func authorizationHeader(for url: URL) async throws -> String?
    /// Called once after a 401. Return true when new credentials make a retry worthwhile.
    func handleUnauthorized(url: URL, challenge: String?) async -> Bool
}

public struct MCPTimeouts: Equatable, Sendable {
    /// Launch plus the `initialize` handshake; `npx` may download a package first.
    public var initialize: Duration
    public var request: Duration
    public var toolCall: Duration

    public init(initialize: Duration, request: Duration, toolCall: Duration) {
        self.initialize = initialize
        self.request = request
        self.toolCall = toolCall
    }

    public static let standard = MCPTimeouts(initialize: .seconds(60), request: .seconds(30), toolCall: .seconds(300))
}

public enum MCPSessionEvent: Equatable, Sendable {
    case toolsChanged
    case resourcesChanged
    case promptsChanged
    /// The connection ended. Nil when MCP Manager closed it.
    case closed(MCPClientError?)
}

/// Facts about a live connection for the Info tab.
public struct MCPTransportInfo: Equatable, Sendable {
    public var processID: Int32?
    public var sessionID: String?
    public var endpoint: String?

    public init(processID: Int32? = nil, sessionID: String? = nil, endpoint: String? = nil) {
        self.processID = processID
        self.sessionID = sessionID
        self.endpoint = endpoint
    }
}
