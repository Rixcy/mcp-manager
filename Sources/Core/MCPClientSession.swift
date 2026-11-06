import Foundation

// Placeholder until T-02 lands the transports; signatures are the contract.

/// One connection to one server. Reconnecting means a new session.
public actor MCPClientSession {
    public nonisolated let events: AsyncStream<MCPSessionEvent>
    private let eventsContinuation: AsyncStream<MCPSessionEvent>.Continuation

    public private(set) var initializeResult: MCPInitializeResult?

    public init(launch: ResolvedLaunch, log: MCPLogSink, auth: MCPAuthProvider? = nil, timeouts: MCPTimeouts = .standard) {
        (events, eventsContinuation) = AsyncStream.makeStream()
    }

    public var transportInfo: MCPTransportInfo { MCPTransportInfo() }

    /// Launches or opens the transport and runs the `initialize` handshake.
    public func connect() async throws -> MCPInitializeResult { throw MCPClientError.notConnected }

    /// Every page of `tools/list`.
    public func listTools() async throws -> [MCPTool] { throw MCPClientError.notConnected }

    /// Cancelling the calling task sends `notifications/cancelled` and throws `cancelled`.
    public func callTool(name: String, arguments: [String: JSONValue],
                         onProgress: (@Sendable (MCPProgress) -> Void)? = nil) async throws -> MCPToolResult {
        throw MCPClientError.notConnected
    }

    public func listResources() async throws -> [MCPResource] { throw MCPClientError.notConnected }
    public func listResourceTemplates() async throws -> [MCPResourceTemplate] { throw MCPClientError.notConnected }
    public func readResource(uri: String) async throws -> [MCPResourceContents] { throw MCPClientError.notConnected }
    public func listPrompts() async throws -> [MCPPrompt] { throw MCPClientError.notConnected }
    public func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        throw MCPClientError.notConnected
    }

    /// Round-trip time.
    public func ping() async throws -> Duration { throw MCPClientError.notConnected }

    /// Ends the connection; a stdio server's whole process group is stopped.
    public func close() async {
        eventsContinuation.yield(.closed(nil))
        eventsContinuation.finish()
    }
}
