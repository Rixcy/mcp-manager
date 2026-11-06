import Foundation

/// What both HTTP transports share: configured headers, Authorization, one retry after
/// a 401 the auth provider can fix, error mapping and status logging.
final class HTTPExchange: @unchecked Sendable {
    let serverURL: URL
    let headers: [String: String]
    let auth: MCPAuthProvider?
    let log: MCPLogSink
    let session: URLSession

    static let errorBodyLimit = 2048

    init(serverURL: URL, headers: [String: String], auth: MCPAuthProvider?, log: MCPLogSink) {
        self.serverURL = serverURL
        self.headers = headers
        self.auth = auth
        self.log = log
        let configuration = URLSessionConfiguration.ephemeral
        // The session enforces its own per-request timeouts; URLSession's would cut off
        // long tool calls and quiet event streams.
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// A configured Authorization header wins over the auth provider's.
    var hasConfiguredAuthorization: Bool {
        headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    func authorizationHeader() async throws -> String? {
        guard !hasConfiguredAuthorization, let auth else { return nil }
        do {
            return try await auth.authorizationHeader(for: serverURL)
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw MCPClientError.oauth(.credentialStore(error.localizedDescription))
        }
    }

    func makeRequest(_ method: String, _ url: URL, body: Data?, accept: String?,
                     extraHeaders: [String: String]) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let authorization = try await authorizationHeader() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends one request and returns once the status line and headers are in.
    func open(_ method: String, _ url: URL, body: Data?, accept: String,
              extraHeaders: [String: String] = [:]) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var retried = false
        while true {
            let request = try await makeRequest(method, url, body: body, accept: accept, extraHeaders: extraHeaders)
            let started = ContinuousClock.now
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                throw Self.mapped(error, url: url)
            }
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw MCPClientError.malformedResponse(method: method, detail: "The answer from \(url.absoluteString) is not HTTP.")
            }
            logStatus(method, url, http, elapsed: ContinuousClock.now - started)
            guard http.statusCode == 401 else { return (bytes, http) }
            bytes.task.cancel()
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            if !retried, !hasConfiguredAuthorization, let auth,
               await auth.handleUnauthorized(url: serverURL, challenge: challenge) {
                retried = true
                continue
            }
            throw MCPClientError.authorizationRequired(url: serverURL.absoluteString, challenge: challenge)
        }
    }

    func logStatus(_ method: String, _ url: URL, _ response: HTTPURLResponse, elapsed: Duration) {
        let type = response.mimeType.map { " \($0)" } ?? ""
        log.record(.event, "\(method) \(TransportLog.url(url)) → \(response.statusCode)\(type) · \(TransportTime.milliseconds(elapsed)) ms",
                   detail: nil)
    }

    static func mapped(_ error: Error, url: URL) -> MCPClientError {
        switch error {
        case let error as MCPClientError:
            return error
        case let error as URLError where error.code == .cancelled:
            return .connectionClosed(detail: nil)
        case let error as URLError:
            return .network(code: error.code.rawValue, url: url.absoluteString, detail: error.localizedDescription)
        case is CancellationError:
            return .cancelled
        default:
            return .network(code: URLError.Code.unknown.rawValue, url: url.absoluteString, detail: error.localizedDescription)
        }
    }

    /// The start of a body for error messages; nil when there is none.
    static func readText(_ bytes: URLSession.AsyncBytes, limit: Int = errorBodyLimit) async -> String? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {}
        bytes.task.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func readAll(_ bytes: URLSession.AsyncBytes, url: URL) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > TransportLimits.maxMessageBytes {
                    bytes.task.cancel()
                    throw MCPClientError.messageTooLarge(bytes: data.count)
                }
            }
        } catch {
            throw mapped(error, url: url)
        }
        return data
    }
}

fileprivate extension JSONRPCMessage {
    var requestID: JSONRPCID? {
        if case let .request(id, _, _) = self { return id }
        return nil
    }

    func answers(_ id: JSONRPCID) -> Bool {
        switch self {
        case let .response(answered, _): return answered == id
        case let .errorResponse(answered, _): return answered == id
        case .request, .notification: return false
        }
    }
}

/// MCP 2025-06-18 Streamable HTTP: every client message is a POST; answers come back as
/// JSON or as an event stream on that POST. The optional GET stream and resumption are not used.
final class StreamableHTTPTransport: MCPClientTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let url: URL
    private let exchange: HTTPExchange
    private let log: MCPLogSink

    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var handshakeDone = false
    private var closed = false
    private var ended = false
    private var orderedTail: Task<Void, Never>?

    init(url: URL, headers: [String: String], auth: MCPAuthProvider?, log: MCPLogSink) {
        self.url = url
        self.log = log
        exchange = HTTPExchange(serverURL: url, headers: headers, auth: auth, log: log)
        (events, continuation) = AsyncStream.makeStream()
    }

    var info: MCPTransportInfo {
        lock.withLock { MCPTransportInfo(sessionID: sessionID, endpoint: url.absoluteString) }
    }

    func start(budget: Duration) async throws {
        log.record(.event, "Connecting to \(TransportLog.url(url)) (Streamable HTTP)", detail: nil)
    }

    func send(_ message: JSONRPCMessage, onFailure: @escaping @Sendable (MCPClientError) -> Void) {
        lock.withLock {
            let previous = orderedTail
            let task = Task { [self] in
                // Requests may overlap, but none may overtake an earlier notification such as notifications/initialized.
                await previous?.value
                guard !isClosed else { return }
                do {
                    try await post(message)
                } catch {
                    if !isClosed { onFailure(HTTPExchange.mapped(error, url: url)) }
                }
            }
            if message.requestID == nil { orderedTail = task }
        }
    }

    func handshakeCompleted(protocolVersion: String) {
        lock.withLock {
            handshakeDone = true
            self.protocolVersion = protocolVersion
        }
    }

    func initializeTimeoutExplanation() -> MCPClientError? { nil }

    func close() async {
        let (firstClose, sessionID, version) = lock.withLock { () -> (Bool, String?, String?) in
            defer { closed = true }
            return (!closed, self.sessionID, protocolVersion)
        }
        guard firstClose else { return }
        continuation.finish()
        if let sessionID {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.deleteSession(sessionID, version: version) }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
        }
        exchange.session.invalidateAndCancel()
    }

    func closeInBackground() {
        Task { await close() }
    }

    private var isClosed: Bool {
        lock.withLock { closed }
    }

    private func post(_ message: JSONRPCMessage) async throws {
        let (sessionID, version, stage) = lock.withLock {
            (self.sessionID, protocolVersion, handshakeDone ? MCPStage.request : .initialize)
        }
        var extra: [String: String] = [:]
        if let sessionID { extra["Mcp-Session-Id"] = sessionID }
        if let version { extra["MCP-Protocol-Version"] = version }
        let (bytes, response) = try await exchange.open("POST", url, body: message.encoded(),
                                                        accept: "application/json, text/event-stream", extraHeaders: extra)
        let method = message.method ?? "message"
        if message.method == "initialize", let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty {
            lock.withLock { self.sessionID = assigned }
            log.record(.event, "Server assigned a session id", detail: nil)
        }

        switch response.statusCode {
        case 404 where sessionID != nil:
            bytes.task.cancel()
            let error = MCPClientError.sessionExpired(url: url.absoluteString)
            reportEnd(error)
            throw error
        case 200 ..< 300:
            break
        default:
            let body = await HTTPExchange.readText(bytes)
            throw MCPClientError.httpStatus(code: response.statusCode, url: url.absoluteString, body: body, stage: stage)
        }

        switch response.mimeType?.lowercased() {
        case "text/event-stream":
            try await readEventStream(bytes, answering: message.requestID, method: method)
        case "application/json":
            let data = try await HTTPExchange.readAll(bytes, url: url)
            try deliverJSON(data, answering: message.requestID, method: method)
        default:
            bytes.task.cancel()
            if message.requestID != nil {
                throw MCPClientError.malformedResponse(method: method,
                                                       detail: "The server answered HTTP \(response.statusCode) without a JSON-RPC response.")
            }
        }
    }

    private func deliverJSON(_ data: Data, answering id: JSONRPCID?, method: String) throws {
        guard data.contains(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else {
            if id != nil { throw MCPClientError.malformedResponse(method: method, detail: "The server sent an empty JSON body.") }
            return
        }
        let messages: [JSONRPCMessage]
        do {
            messages = try JSONRPCMessage.decode(data)
        } catch {
            throw MCPClientError.malformedResponse(method: method, detail: "The server's JSON is not JSON-RPC: \(error)")
        }
        var answered = false
        for message in messages {
            continuation.yield(.message(message))
            if let id, message.answers(id) { answered = true }
        }
        if let id, !answered {
            throw MCPClientError.malformedResponse(method: method, detail: "The server's answer has no response for request \(id).")
        }
    }

    private func readEventStream(_ bytes: URLSession.AsyncBytes, answering id: JSONRPCID?, method: String) async throws {
        defer { bytes.task.cancel() }
        var parser = SSEParser()
        var answered = false
        do {
            for try await byte in bytes {
                guard let event = try parser.push(byte) else { continue }
                if deliver(event, answering: id) {
                    answered = true
                    break
                }
            }
            if !answered, let event = parser.finish() { answered = deliver(event, answering: id) }
        } catch {
            if isClosed { return }
            throw HTTPExchange.mapped(error, url: url)
        }
        if id != nil, !answered, !isClosed {
            throw MCPClientError.connectionClosed(detail: "The server ended the response stream before answering \(method).")
        }
    }

    /// True when the event carried the response to `id`.
    private func deliver(_ event: SSEEvent, answering id: JSONRPCID?) -> Bool {
        guard event.event == nil || event.event == "message" else { return false }
        do {
            var answered = false
            for message in try JSONRPCMessage.decode(Data(event.data.utf8)) {
                continuation.yield(.message(message))
                if let id, message.answers(id) { answered = true }
            }
            return answered
        } catch {
            log.record(.warning, "Server sent an event that is not JSON-RPC", detail: LogFormatting.detail(text: event.data))
            return false
        }
    }

    private func reportEnd(_ error: MCPClientError) {
        let first = lock.withLock {
            defer { ended = true }
            return !ended && !closed
        }
        guard first else { return }
        continuation.yield(.ended(error))
        continuation.finish()
    }

    private func deleteSession(_ id: String, version: String?) async {
        var extra = ["Mcp-Session-Id": id]
        if let version { extra["MCP-Protocol-Version"] = version }
        guard var request = try? await exchange.makeRequest("DELETE", url, body: nil, accept: nil, extraHeaders: extra) else { return }
        request.timeoutInterval = 2
        let started = ContinuousClock.now
        guard let (_, response) = try? await exchange.session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        exchange.logStatus("DELETE", url, http, elapsed: ContinuousClock.now - started)
    }
}

/// The MCP 2024-11-05 HTTP+SSE transport: a long-lived GET event stream carries every
/// server message, and its first `endpoint` event names where to POST client messages.
final class LegacySSETransport: MCPClientTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let url: URL
    private let exchange: HTTPExchange
    private let log: MCPLogSink
    private let endpointReady = TransportOneShot<URL>()

    private let lock = NSLock()
    private var endpoint: URL?
    private var handshakeDone = false
    private var closed = false
    private var ended = false
    private var reader: Task<Void, Never>?
    private var tail: Task<Void, Never>?

    init(url: URL, headers: [String: String], auth: MCPAuthProvider?, log: MCPLogSink) {
        self.url = url
        self.log = log
        exchange = HTTPExchange(serverURL: url, headers: headers, auth: auth, log: log)
        (events, continuation) = AsyncStream.makeStream()
    }

    var info: MCPTransportInfo {
        MCPTransportInfo(endpoint: url.absoluteString)
    }

    func start(budget: Duration) async throws {
        log.record(.event, "Connecting to \(TransportLog.url(url)) (HTTP+SSE)", detail: nil)
        let reader = Task { [self] in await readEvents() }
        lock.withLock { self.reader = reader }
        let seconds = TransportTime.displaySeconds(budget)
        let timer = Task { [endpointReady] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            endpointReady.resolve(.failure(MCPClientError.timedOut(method: "initialize", seconds: seconds)))
        }
        defer { timer.cancel() }
        _ = try await withTaskCancellationHandler {
            try await endpointReady.value()
        } onCancel: { [endpointReady] in
            endpointReady.resolve(.failure(MCPClientError.cancelled))
        }
    }

    func send(_ message: JSONRPCMessage, onFailure: @escaping @Sendable (MCPClientError) -> Void) {
        lock.withLock {
            let previous = tail
            // Every POST is answered at once with 202, so strict ordering costs nothing here.
            tail = Task { [self] in
                await previous?.value
                guard !isClosed else { return }
                do {
                    try await post(message)
                } catch {
                    if !isClosed { onFailure(HTTPExchange.mapped(error, url: url)) }
                }
            }
        }
    }

    func handshakeCompleted(protocolVersion: String) {
        lock.withLock { handshakeDone = true }
    }

    func initializeTimeoutExplanation() -> MCPClientError? { nil }

    func close() async {
        let (firstClose, reader) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            defer { closed = true }
            return (!closed, self.reader)
        }
        guard firstClose else { return }
        continuation.finish()
        endpointReady.resolve(.failure(MCPClientError.connectionClosed(detail: nil)))
        reader?.cancel()
        exchange.session.invalidateAndCancel()
    }

    func closeInBackground() {
        Task { await close() }
    }

    private var isClosed: Bool {
        lock.withLock { closed }
    }

    private func readEvents() async {
        do {
            let (bytes, response) = try await exchange.open("GET", url, body: nil, accept: "text/event-stream")
            guard response.statusCode == 200 else {
                let body = await HTTPExchange.readText(bytes)
                throw MCPClientError.httpStatus(code: response.statusCode, url: url.absoluteString, body: body, stage: .initialize)
            }
            guard response.mimeType?.lowercased() == "text/event-stream" else {
                bytes.task.cancel()
                throw MCPClientError.malformedResponse(
                    method: "endpoint",
                    detail: "The server answered with \(response.mimeType ?? "no content type"), not an event stream.")
            }
            var parser = SSEParser()
            for try await byte in bytes {
                if let event = try parser.push(byte) { try handle(event) }
            }
            if let event = parser.finish() { try handle(event) }
            throw MCPClientError.connectionClosed(detail: "The server closed the event stream")
        } catch {
            fail(HTTPExchange.mapped(error, url: url))
        }
    }

    private func handle(_ event: SSEEvent) throws {
        switch event.event ?? "message" {
        case "endpoint":
            guard !endpointReady.isResolved else { return }
            let text = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = URL(string: text, relativeTo: url)?.absoluteURL else {
                throw MCPClientError.malformedResponse(method: "endpoint", detail: "The endpoint event is not a URL: \(text)")
            }
            guard Self.sameOrigin(resolved, url) else {
                throw MCPClientError.malformedResponse(
                    method: "endpoint",
                    detail: "The server asked for messages to be sent to \(Self.origin(resolved)), "
                        + "a different origin from \(Self.origin(url)). MCP Manager only sends messages to the server it connected to.")
            }
            lock.withLock { endpoint = resolved }
            log.record(.event, "Server sent its message endpoint \(TransportLog.url(resolved))", detail: nil)
            endpointReady.resolve(.success(resolved))
        case "message":
            do {
                for message in try JSONRPCMessage.decode(Data(event.data.utf8)) {
                    continuation.yield(.message(message))
                }
            } catch {
                log.record(.warning, "Server sent an event that is not JSON-RPC", detail: LogFormatting.detail(text: event.data))
            }
        default:
            break
        }
    }

    private func post(_ message: JSONRPCMessage) async throws {
        let (endpoint, stage) = lock.withLock { (self.endpoint, handshakeDone ? MCPStage.request : .initialize) }
        guard let endpoint else { throw MCPClientError.connectionClosed(detail: nil) }
        let (bytes, response) = try await exchange.open("POST", endpoint, body: message.encoded(),
                                                        accept: "application/json, text/event-stream")
        guard (200 ..< 300).contains(response.statusCode) else {
            let body = await HTTPExchange.readText(bytes)
            throw MCPClientError.httpStatus(code: response.statusCode, url: endpoint.absoluteString, body: body, stage: stage)
        }
        bytes.task.cancel()
    }

    private func fail(_ error: MCPClientError) {
        guard !isClosed else { return }
        // Before the endpoint arrives the failure belongs to start(); afterwards it ends the connection.
        if endpointReady.resolve(.failure(error)) { return }
        let first = lock.withLock {
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        continuation.yield(.ended(error))
        continuation.finish()
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
            && effectivePort(a) == effectivePort(b)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func origin(_ url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "")://\(url.host(percentEncoded: false) ?? "")\(port)"
    }
}
