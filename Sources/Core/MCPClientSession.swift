import Foundation

/// One connection to one server. Reconnecting means a new session.
public actor MCPClientSession {
    public nonisolated let events: AsyncStream<MCPSessionEvent>
    private let eventsContinuation: AsyncStream<MCPSessionEvent>.Continuation

    public private(set) var initializeResult: MCPInitializeResult?

    private let launch: ResolvedLaunch
    private let log: MCPLogSink
    private let auth: MCPAuthProvider?
    private let timeouts: MCPTimeouts

    private enum Phase {
        case idle, connecting, connected, ended
    }

    private var phase = Phase.idle
    private var everConnected = false
    private var transport: MCPClientTransport?
    private var endError: MCPClientError?
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var progressTokens: [String: Int] = [:]
    /// Requests MCP Manager stopped waiting for, so their late answers are expected rather than suspicious.
    private var abandoned: [Int: String] = [:]

    private static let maxPages = 100

    private struct PendingRequest {
        var method: String
        var started: ContinuousClock.Instant
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>
        var progressToken: String?
        var onProgress: (@Sendable (MCPProgress) -> Void)?
    }

    public init(launch: ResolvedLaunch, log: MCPLogSink, auth: MCPAuthProvider? = nil, timeouts: MCPTimeouts = .standard) {
        self.launch = launch
        self.log = log
        self.auth = auth
        self.timeouts = timeouts
        (events, eventsContinuation) = AsyncStream.makeStream()
    }

    deinit {
        transport?.closeInBackground()
    }

    public var transportInfo: MCPTransportInfo { transport?.info ?? MCPTransportInfo() }

    /// Launches or opens the transport and runs the `initialize` handshake.
    public func connect() async throws -> MCPInitializeResult {
        switch phase {
        case .idle:
            break
        case .connected:
            if let initializeResult { return initializeResult }
            throw MCPClientError.notConnected
        case .connecting:
            throw MCPClientError.notConnected
        case .ended:
            throw unavailable()
        }
        phase = .connecting
        let started = ContinuousClock.now
        let transport = MCPClientTransports.make(for: launch, log: log, auth: auth)
        self.transport = transport
        Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                await self.receive(event)
            }
        }

        do {
            try await transport.start(budget: timeouts.initialize)
            try stillConnecting()
            let remaining = timeouts.initialize - (ContinuousClock.now - started)
            let raw = try await request("initialize", params: MCPClientIdentity.initializeParams,
                                        timeout: max(remaining, .zero),
                                        displaySeconds: TransportTime.displaySeconds(timeouts.initialize))
            let result = try MCPInitializeResult.decode(raw)
            guard MCPProtocolVersion.supported.contains(result.protocolVersion) else {
                throw MCPClientError.unsupportedProtocolVersion(result.protocolVersion)
            }
            try stillConnecting()
            transport.handshakeCompleted(protocolVersion: result.protocolVersion)
            initializeResult = result
            phase = .connected
            everConnected = true
            notify("notifications/initialized")
            let version = result.serverInfo.version.isEmpty ? "" : " \(result.serverInfo.version)"
            log.record(.event, "Connected to \(result.serverInfo.name)\(version) (protocol \(result.protocolVersion))", detail: nil)
            return result
        } catch {
            let failure = Self.clientError(error)
            await shutDown(failure)
            throw failure
        }
    }

    /// Every page of `tools/list`.
    public func listTools() async throws -> [MCPTool] {
        try await listAll("tools/list", capability: "tools", declared: \.tools, page: MCPTool.page)
    }

    /// Cancelling the calling task sends `notifications/cancelled` and throws `cancelled`.
    public func callTool(name: String, arguments: [String: JSONValue],
                         onProgress: (@Sendable (MCPProgress) -> Void)? = nil) async throws -> MCPToolResult {
        let params: JSONValue = ["name": .string(name), "arguments": .object(arguments)]
        let result = try await request("tools/call", params: params, timeout: timeouts.toolCall, onProgress: onProgress)
        return try MCPToolResult.decode(result)
    }

    public func listResources() async throws -> [MCPResource] {
        try await listAll("resources/list", capability: "resources", declared: \.resources, page: MCPResource.page)
    }

    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await listAll("resources/templates/list", capability: "resources", declared: \.resources,
                          page: MCPResourceTemplate.page)
    }

    public func readResource(uri: String) async throws -> [MCPResourceContents] {
        let result = try await request("resources/read", params: ["uri": .string(uri)], timeout: timeouts.request)
        return try MCPResource.contents(result)
    }

    public func listPrompts() async throws -> [MCPPrompt] {
        try await listAll("prompts/list", capability: "prompts", declared: \.prompts, page: MCPPrompt.page)
    }

    public func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult {
        let params: JSONValue = ["name": .string(name), "arguments": .object(arguments.mapValues(JSONValue.string))]
        return try MCPPromptResult.decode(try await request("prompts/get", params: params, timeout: timeouts.request))
    }

    /// Round-trip time.
    public func ping() async throws -> Duration {
        let started = ContinuousClock.now
        _ = try await request("ping", params: nil, timeout: timeouts.request)
        return ContinuousClock.now - started
    }

    /// Ends the connection; a stdio server's whole process group is stopped.
    public func close() async {
        await shutDown(nil)
        // Waits for a shutdown already under way after the server ended the connection itself.
        await transport?.close()
    }

    // MARK: Requests

    private func request(_ method: String, params: JSONValue?, timeout: Duration, displaySeconds: Int? = nil,
                         onProgress: (@Sendable (MCPProgress) -> Void)? = nil) async throws -> JSONValue {
        let handshake = method == "initialize" && phase == .connecting
        guard let transport, phase == .connected || handshake else { throw unavailable() }
        guard !Task.isCancelled else { throw MCPClientError.cancelled }

        let id = nextRequestID
        nextRequestID += 1
        var params = params
        var progressToken: String?
        if onProgress != nil {
            let token = "mcp-manager-\(id)"
            progressToken = token
            progressTokens[token] = id
            var members = params?.objectValue ?? [:]
            var meta = members["_meta"]?.objectValue ?? [:]
            meta["progressToken"] = .string(token)
            members["_meta"] = .object(meta)
            params = .object(members)
        }
        let message = JSONRPCMessage.request(id: .int(id), method: method, params: params)
        let seconds = displaySeconds ?? TransportTime.displaySeconds(timeout)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(id, seconds: seconds)
                }
                pending[id] = PendingRequest(method: method, started: .now, continuation: continuation, timer: timer,
                                             progressToken: progressToken, onProgress: onProgress)
                transmit(message, via: transport) { [weak self] error in
                    Task { await self?.complete(id, with: .failure(error)) }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.requestCancelledByCaller(id) }
        }
    }

    private func complete(_ id: Int, with outcome: Result<JSONValue, MCPClientError>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        if let token = entry.progressToken { progressTokens[token] = nil }
        switch outcome {
        case let .success(value): entry.continuation.resume(returning: value)
        case let .failure(error): entry.continuation.resume(throwing: error)
        }
    }

    private func requestTimedOut(_ id: Int, seconds: Int) {
        guard let entry = pending[id] else { return }
        var error = MCPClientError.timedOut(method: entry.method, seconds: seconds)
        if entry.method == "initialize" {
            // The spec forbids cancelling initialize; the failed connect tears the connection down instead.
            if let explanation = transport?.initializeTimeoutExplanation() { error = explanation }
        } else {
            abandon(id, method: entry.method, reason: "Timed out after \(seconds) s")
        }
        log.record(.warning, "\(entry.method) #\(id) timed out after \(seconds) s", detail: nil)
        complete(id, with: .failure(error))
    }

    private func requestCancelledByCaller(_ id: Int) {
        guard let entry = pending[id] else { return }
        if entry.method != "initialize" { abandon(id, method: entry.method, reason: "Cancelled in MCP Manager") }
        complete(id, with: .failure(.cancelled))
    }

    private func abandon(_ id: Int, method: String, reason: String) {
        if abandoned.count >= 100 { abandoned.removeAll() }
        abandoned[id] = method
        notify("notifications/cancelled", params: ["requestId": .int(id), "reason": .string(reason)])
    }

    private func listAll<Item: Equatable & Sendable>(
        _ method: String, capability: String, declared: KeyPath<MCPServerCapabilities, Bool>,
        page decode: (JSONValue) throws -> MCPPage<Item>
    ) async throws -> [Item] {
        guard phase == .connected, let initializeResult else { throw unavailable() }
        guard initializeResult.capabilities[keyPath: declared] else { throw MCPClientError.capabilityMissing(capability) }
        var items: [Item] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0 ..< Self.maxPages {
            let params: JSONValue? = cursor.map { ["cursor": .string($0)] }
            let page = try decode(try await request(method, params: params, timeout: timeouts.request))
            items += page.items
            guard let next = page.nextCursor else { return items }
            guard seenCursors.insert(next).inserted else {
                log.record(.warning, "\(method) sent the same cursor twice; stopped after \(items.count) items", detail: nil)
                return items
            }
            cursor = next
        }
        log.record(.warning, "\(method) still had more after \(Self.maxPages) pages; stopped after \(items.count) items",
                   detail: nil)
        return items
    }

    // MARK: Messages

    private func transmit(_ message: JSONRPCMessage, via transport: MCPClientTransport,
                          onFailure: @escaping @Sendable (MCPClientError) -> Void) {
        log.record(.outgoing, Self.outgoingSummary(message), detail: LogFormatting.detail(message.json))
        transport.send(message, onFailure: onFailure)
    }

    private func notify(_ method: String, params: JSONValue? = nil) {
        guard let transport else { return }
        transmit(.notification(method: method, params: params), via: transport) { [log] error in
            log.record(.warning, "Could not send \(method)", detail: LogFormatting.detail(text: String(describing: error)))
        }
    }

    private static func outgoingSummary(_ message: JSONRPCMessage) -> String {
        switch message {
        case let .request(id, method, _): return "→ \(method) \(id)"
        case let .notification(method, _): return "→ \(method)"
        case let .response(id, _): return "→ result \(id)"
        case let .errorResponse(id, _): return "→ error \(id.map(\.description) ?? "#null")"
        }
    }

    /// Called by one consumer task per connection, so messages are handled strictly in arrival order.
    private func receive(_ event: TransportEvent) async {
        switch event {
        case let .message(message): handle(message)
        case let .ended(error): await shutDown(error)
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        let detail = LogFormatting.detail(message.json)
        switch message {
        case let .response(id, result):
            guard let number = Self.number(id), let entry = pending[number] else {
                unmatched(id, detail: detail)
                return
            }
            log.record(.incoming, "← \(entry.method) \(id) · \(TransportTime.milliseconds(.now - entry.started)) ms", detail: detail)
            complete(number, with: .success(result))

        case let .errorResponse(id, error):
            guard let id else {
                log.record(.incoming, "← error \(error.code) \(error.message)", detail: detail)
                log.record(.warning, "The server reported an error that is not tied to a request", detail: nil)
                return
            }
            guard let number = Self.number(id), let entry = pending[number] else {
                unmatched(id, detail: detail)
                return
            }
            log.record(.incoming, "← \(entry.method) \(id) error \(error.code) \(error.message)", detail: detail)
            let data = error.data.flatMap { $0.isNull ? nil : $0.jsonString() }
            complete(number, with: .failure(.rpcError(method: entry.method, code: error.code, message: error.message, data: data)))

        case let .request(id, method, _):
            log.record(.incoming, "← \(method) \(id)", detail: detail)
            answer(id, method: method)

        case let .notification(method, params):
            log.record(.incoming, "← \(method)", detail: detail)
            handleNotification(method, params: params)
        }
    }

    private func unmatched(_ id: JSONRPCID, detail: String) {
        if let number = Self.number(id), let method = abandoned.removeValue(forKey: number) {
            log.record(.incoming, "← \(method) \(id) · arrived after MCP Manager stopped waiting", detail: detail)
            return
        }
        log.record(.incoming, "← response \(id)", detail: detail)
        log.record(.warning, "The server answered request \(id), which is not waiting for an answer", detail: nil)
    }

    private func answer(_ id: JSONRPCID, method: String) {
        guard let transport else { return }
        let reply: JSONRPCMessage
        switch method {
        case "ping":
            reply = .response(id: id, result: [:])
        case "roots/list":
            reply = .response(id: id, result: ["roots": []])
        default:
            log.record(.warning, "Declined \(method) from the server: MCP Manager does not support it", detail: nil)
            reply = .errorResponse(id: id, error: JSONRPCError(code: JSONRPCError.methodNotFound,
                                                               message: "MCP Manager does not support \(method)"))
        }
        transmit(reply, via: transport) { [log] error in
            log.record(.warning, "Could not answer \(method)", detail: LogFormatting.detail(text: String(describing: error)))
        }
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        switch method {
        case "notifications/message":
            logServerMessage(params)
        case "notifications/tools/list_changed":
            eventsContinuation.yield(.toolsChanged)
        case "notifications/resources/list_changed":
            eventsContinuation.yield(.resourcesChanged)
        case "notifications/prompts/list_changed":
            eventsContinuation.yield(.promptsChanged)
        case "notifications/progress":
            deliverProgress(params)
        default:
            break
        }
    }

    private func logServerMessage(_ params: JSONValue?) {
        let level = params?["level"]?.stringValue ?? "info"
        let kind: MCPLogEntry.Kind
        switch level {
        case "error", "critical", "alert", "emergency": kind = .error
        case "warning": kind = .warning
        default: kind = .event
        }
        let data = params?["data"] ?? .null
        let redacted = LogFormatting.redacted(data)
        let source = params?["logger"]?.stringValue.map { " (\($0))" } ?? ""
        log.record(kind, TransportLog.clip("Server \(level)\(source): \(redacted.stringValue ?? redacted.jsonString())"),
                   detail: LogFormatting.detail(data))
    }

    private func deliverProgress(_ params: JSONValue?) {
        guard let params, let tokenValue = params["progressToken"],
              let token = tokenValue.stringValue ?? tokenValue.intValue.map(String.init),
              let id = progressTokens[token], let handler = pending[id]?.onProgress,
              let progress = params["progress"]?.doubleValue else { return }
        handler(MCPProgress(progress: progress, total: params["total"]?.doubleValue, message: params["message"]?.stringValue))
    }

    // MARK: Lifecycle

    /// `error` is nil when MCP Manager closed the connection.
    private func shutDown(_ error: MCPClientError?) async {
        guard phase != .ended else { return }
        let wasConnected = phase == .connected
        phase = .ended
        endError = error
        let failure = error ?? .connectionClosed(detail: nil)
        for id in Array(pending.keys) { complete(id, with: .failure(failure)) }
        progressTokens.removeAll()
        if let error {
            log.record(.error, "\(wasConnected ? "Disconnected" : "Could not connect"): \(error.helpful.title)",
                       detail: LogFormatting.detail(text: String(describing: error)))
        } else {
            log.record(.event, "Closed the connection", detail: nil)
        }
        eventsContinuation.yield(.closed(error))
        eventsContinuation.finish()
        await transport?.close()
    }

    private func stillConnecting() throws {
        guard phase == .connecting else { throw endError ?? MCPClientError.connectionClosed(detail: nil) }
    }

    /// What a call made outside a live connection throws.
    private func unavailable() -> MCPClientError {
        guard everConnected, phase == .ended else { return .notConnected }
        return endError ?? .connectionClosed(detail: nil)
    }

    private static func clientError(_ error: Error) -> MCPClientError {
        if let error = error as? MCPClientError { return error }
        if error is CancellationError { return .cancelled }
        return .connectionClosed(detail: error.localizedDescription)
    }

    private static func number(_ id: JSONRPCID) -> Int? {
        if case let .int(number) = id { return number }
        return nil
    }
}
