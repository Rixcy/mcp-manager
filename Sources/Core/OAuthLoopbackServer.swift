import Darwin
import Foundation

/// One-shot HTTP listener for the OAuth loopback redirect (RFC 8252 §7.3).
/// It answers every connection on its own thread until one requests the
/// redirect path, replies with a small page, and stops.
final class OAuthLoopbackServer: @unchecked Sendable {
    /// Turns the callback's query parameters into the page the browser shows.
    typealias Responder = @Sendable ([String: String]) -> (status: Int, html: String)

    let port: Int
    private let path: String
    private let respond: Responder
    private let listeners: [Int32]
    private let wakeRead: Int32
    private let wakeWrite: Int32

    private let lock = NSLock()
    private var outcome: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var socketsClosed = false
    private var wakeSent = false

    private static let maxRequestBytes = 16_384
    private static let maxClients = 16
    /// Browsers open speculative connections they may never use; drop them after this.
    private static let idleClientSeconds: TimeInterval = 10

    /// Listens on 127.0.0.1, and on ::1 too when `includeIPv6` (a `localhost`
    /// redirect may resolve to either). Port 0 picks a free port.
    static func start(port: Int, includeIPv6: Bool, path: String,
                      respond: @escaping Responder) throws -> OAuthLoopbackServer {
        guard (0...Int(UInt16.max)).contains(port) else {
            throw MCPClientError.oauth(.callbackServerFailed("Port \(port) is not a valid port for the sign-in callback."))
        }
        let listeners = try bind(port: UInt16(port), includeIPv6: includeIPv6)
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else {
            let detail = String(cString: strerror(errno))
            listeners.forEach { _ = Darwin.close($0.fd) }
            throw MCPClientError.oauth(.callbackServerFailed("Could not start the sign-in callback listener: \(detail)."))
        }
        let server = OAuthLoopbackServer(port: Int(listeners[0].port), path: path, respond: respond,
                                         listeners: listeners.map(\.fd), wakeRead: pipeEnds[0], wakeWrite: pipeEnds[1])
        let thread = Thread { server.run() }
        thread.name = "OAuth callback listener"
        thread.start()
        return server
    }

    private init(port: Int, path: String, respond: @escaping Responder, listeners: [Int32], wakeRead: Int32, wakeWrite: Int32) {
        self.port = port
        self.path = path
        self.respond = respond
        self.listeners = listeners
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
    }

    /// The callback's query parameters. Throws `browserTimedOut` after
    /// `timeout`, and `cancelled` when the calling task is cancelled.
    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        let (whole, fraction) = timeout.components
        let seconds = Double(whole) + Double(fraction) / 1e18
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(MCPClientError.oauth(.browserTimedOut(seconds: max(1, Int(seconds.rounded(.up)))))))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<[String: String], Error>? = lock.withLock {
                    if let outcome { return outcome }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(MCPClientError.cancelled))
        }
    }

    /// Stops listening. Safe to call more than once and after the callback arrived.
    func stop() {
        finish(.failure(MCPClientError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        wakeListenerThread()
        waiting?.resume(with: result)
    }

    private func wakeListenerThread() {
        lock.withLock {
            guard !socketsClosed, !wakeSent else { return }
            wakeSent = true
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    // MARK: Listener thread

    private struct Client {
        var buffer: [UInt8] = []
        var opened = Date()
    }

    private func run() {
        var clients: [Int32: Client] = [:]
        defer {
            for fd in clients.keys { Darwin.close(fd) }
            lock.withLock {
                socketsClosed = true
                listeners.forEach { _ = Darwin.close($0) }
                Darwin.close(wakeRead)
                Darwin.close(wakeWrite)
            }
        }
        while true {
            let clientFDs = Array(clients.keys)
            var polled = ([wakeRead] + listeners + clientFDs).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), clients.isEmpty ? -1 : 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                let detail = String(cString: strerror(errno))
                finish(.failure(MCPClientError.oauth(.callbackServerFailed(
                    "The sign-in callback listener on port \(port) stopped: \(detail)."))))
                return
            }
            if polled[0].revents != 0 { return }

            for (offset, listener) in listeners.enumerated() where polled[1 + offset].revents != 0 {
                while true {
                    let fd = accept(listener, nil, nil)
                    if fd < 0 { break }
                    guard clients.count < Self.maxClients else {
                        Darwin.close(fd)
                        continue
                    }
                    Self.prepareClientSocket(fd)
                    clients[fd] = Client()
                }
            }

            for (offset, fd) in clientFDs.enumerated() {
                let revents = polled[1 + listeners.count + offset].revents
                if revents == 0 {
                    if let client = clients[fd], Date().timeIntervalSince(client.opened) > Self.idleClientSeconds {
                        Darwin.close(fd)
                        clients[fd] = nil
                    }
                    continue
                }
                guard var client = clients[fd], Self.readAvailable(fd, into: &client.buffer) else {
                    Darwin.close(fd)
                    clients[fd] = nil
                    continue
                }
                guard let requestLine = Self.requestLine(client.buffer) else {
                    if client.buffer.count > Self.maxRequestBytes {
                        Self.reply(fd, status: 431, html: Self.page("The request was too large."))
                        Darwin.close(fd)
                        clients[fd] = nil
                    } else {
                        clients[fd] = client
                    }
                    continue
                }
                clients[fd] = nil
                if handle(requestLine, on: fd) { return }
            }
        }
    }

    /// Replies to one request; true when it was the callback.
    private func handle(_ requestLine: String, on fd: Int32) -> Bool {
        defer { Darwin.close(fd) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            Self.reply(fd, status: 405, html: Self.page("Only GET is supported here."))
            return false
        }
        let target = parts[1]
        let pathPart = target.prefix { $0 != "?" }
        guard pathPart == path else {
            Self.reply(fd, status: 404, html: Self.page("Not found."))
            return false
        }
        let query = target.dropFirst(pathPart.count + 1)
        let parameters = Self.parseQuery(query)
        let page = respond(parameters)
        Self.reply(fd, status: page.status, html: page.html)
        finish(.success(parameters))
        return true
    }

    // MARK: Sockets

    private struct BindError: Error {
        var code: Int32
    }

    private static func bind(port: UInt16, includeIPv6: Bool) throws -> [(fd: Int32, port: UInt16)] {
        // With port 0 the IPv4 port is chosen first and IPv6 must match it,
        // so a port free on one family but taken on the other is retried.
        for _ in 0..<(port == 0 ? 8 : 1) {
            let v4: (fd: Int32, port: UInt16)
            do {
                v4 = try openListener(ipv6: false, port: port)
            } catch let error as BindError {
                let detail = String(cString: strerror(error.code))
                let advice = error.code == EADDRINUSE ? " Another app is using it; quit that app or pick another callback port." : ""
                throw MCPClientError.oauth(.callbackServerFailed(
                    "Could not listen for the sign-in callback on 127.0.0.1 port \(port): \(detail).\(advice)"))
            }
            guard includeIPv6 else { return [v4] }
            do {
                return [v4, try openListener(ipv6: true, port: v4.port)]
            } catch let error as BindError where error.code == EADDRINUSE && port == 0 {
                Darwin.close(v4.fd)
            } catch {
                // No IPv6 loopback, or ::1 held by someone else on a fixed port:
                // browsers fall back to 127.0.0.1, so carry on with IPv4 only.
                return [v4]
            }
        }
        throw MCPClientError.oauth(.callbackServerFailed("Could not find a free port for the sign-in callback on 127.0.0.1 and ::1."))
    }

    private static func openListener(ipv6: Bool, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw BindError(code: errno) }
        var on: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        // Lets a stored redirect port be bound again while the last sign-in's
        // connections sit in TIME_WAIT; an active listener still blocks it.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, optionSize)
        if ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, optionSize) }

        let bound: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw BindError(code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var actual = sockaddr_storage()
        var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
        }
        let boundPort = withUnsafeBytes(of: &actual) { raw -> UInt16 in
            ipv6 ? UInt16(bigEndian: raw.load(as: sockaddr_in6.self).sin6_port)
                : UInt16(bigEndian: raw.load(as: sockaddr_in.self).sin_port)
        }
        return (fd, boundPort)
    }

    private static func prepareClientSocket(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// False when the peer closed or the socket failed.
    private static func readAvailable(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.count > maxRequestBytes { return true }
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    /// The request line once the whole header has arrived. Reading the header
    /// first means closing the socket never discards unread bytes, which would
    /// reset the connection before the browser sees the page.
    private static func requestLine(_ buffer: [UInt8]) -> String? {
        let text = String(decoding: buffer, as: UTF8.self)
        guard text.contains("\r\n\r\n") || text.contains("\n\n") else { return nil }
        return text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reply(_ fd: Int32, status: Int, html: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Error"
        }
        let body = Array(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let bytes = Array(head.utf8) + body
        var offset = 0
        let deadline = Date().addingTimeInterval(2)
        while offset < bytes.count, Date() < deadline {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                var waitFor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&waitFor, 1, 200)
            } else {
                break
            }
        }
        shutdown(fd, SHUT_WR)
    }

    // MARK: Parsing and pages

    /// Form-style query decoding: `+` is a space (RFC 6749 Appendix B).
    static func parseQuery<S: StringProtocol>(_ query: S) -> [String: String] {
        var parameters: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decode(parts[0])
            if parameters[name] == nil {
                parameters[name] = parts.count > 1 ? decode(parts[1]) : ""
            }
        }
        return parameters
    }

    private static func decode<S: StringProtocol>(_ text: S) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func page(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>MCP Manager</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:32em;padding:0 1em;color:#222}\
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}</style></head>
        <body><p>\(escaped)</p></body></html>
        """
    }
}
