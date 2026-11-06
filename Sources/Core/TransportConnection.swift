import Foundation

/// What a transport hands its session, strictly in arrival order.
enum TransportEvent: Sendable {
    case message(JSONRPCMessage)
    /// The connection ended without MCP Manager closing it. Nothing follows.
    case ended(MCPClientError)
}

/// One way of exchanging JSON-RPC messages with a server. A session owns exactly one.
protocol MCPClientTransport: AnyObject, Sendable {
    var events: AsyncStream<TransportEvent> { get }
    var info: MCPTransportInfo { get }

    /// Launches or opens the connection. `budget` bounds any wait on the server.
    func start(budget: Duration) async throws

    /// Queues `message` without waiting for the server. Messages reach the server in
    /// the order they were queued, except that Streamable HTTP requests may overlap.
    /// `onFailure` reports a message that could not be delivered.
    func send(_ message: JSONRPCMessage, onFailure: @escaping @Sendable (MCPClientError) -> Void)

    /// After this, failures belong to the request stage and HTTP sends the negotiated version.
    func handshakeCompleted(protocolVersion: String)

    /// A likelier cause than "timed out" for an `initialize` that never got an answer.
    func initializeTimeoutExplanation() -> MCPClientError?

    /// Stops the connection and waits until it is down. Safe to call more than once.
    func close() async

    /// Starts `close()` without waiting, for an owner that is going away.
    func closeInBackground()
}

enum MCPClientTransports {
    static func make(for launch: ResolvedLaunch, log: MCPLogSink, auth: MCPAuthProvider?) -> MCPClientTransport {
        switch launch.target {
        case let .stdio(executable, arguments, environment, workingDirectory):
            return StdioTransport(executable: executable, arguments: arguments, environment: environment,
                                  workingDirectory: workingDirectory, displayName: launch.displayName, log: log)
        case let .streamableHTTP(url, headers):
            return StreamableHTTPTransport(url: url, headers: headers, auth: auth, log: log)
        case let .sse(url, headers):
            return LegacySSETransport(url: url, headers: headers, auth: auth, log: log)
        }
    }
}

enum TransportLimits {
    /// One message, or one unterminated line or event, so a runaway server cannot exhaust memory.
    static let maxMessageBytes = 32 * 1024 * 1024
}

/// A value that arrives once and may be awaited by any number of tasks or threads.
final class TransportOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    var isResolved: Bool {
        lock.withLock { result != nil }
    }

    /// The first result wins; returns false when one had already arrived.
    @discardableResult
    func resolve(_ outcome: Result<Value, Error>) -> Bool {
        let waiting: [CheckedContinuation<Value, Error>]? = lock.withLock {
            guard result == nil else { return nil }
            result = outcome
            defer { waiters = [] }
            return waiters
        }
        guard let waiting else { return false }
        for waiter in waiting { waiter.resume(with: outcome) }
        return true
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Value, Error>? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

enum TransportTime {
    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Whole seconds for messages; a sub-second budget reads "1 s", never "0 s".
    static func displaySeconds(_ duration: Duration) -> Int {
        max(1, Int(seconds(duration).rounded()))
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int((seconds(duration) * 1000).rounded())
    }
}

enum TransportLog {
    static func clip(_ text: String, _ limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    /// The URL without query, fragment or user info, which can carry API keys.
    static func url(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return (components.string ?? url.absoluteString) + (hadQuery ? "?…" : "")
    }
}
