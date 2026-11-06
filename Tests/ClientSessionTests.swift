import Darwin
import Foundation

private let fixtureScript = "mcp_fixture_server.py"
private let fixtureReadyLine = "fixture: ready on stdio"
private let fixtureNoiseBanner = "Fixture server 1.2.0 starting (this line is not JSON)"
private let fixtureToolNames = ["echo", "add", "slow", "fail", "image", "client_replies", "launch_info"]

private let quickTimeouts = MCPTimeouts(initialize: .seconds(5), request: .seconds(3), toolCall: .seconds(5))

private func stdioLaunch(_ flags: [String] = [], environment: [String: String] = [:],
                         workingDirectory: String? = nil) -> ResolvedLaunch {
    let base = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONDONTWRITEBYTECODE": "1"]
    return ResolvedLaunch(
        target: .stdio(executable: fixturePython, arguments: [fixturePath(fixtureScript), "--stdio"] + flags,
                       environment: base.merging(environment) { $1 }, workingDirectory: workingDirectory),
        displayName: (["python3", fixtureScript, "--stdio"] + flags).joined(separator: " "))
}

private func httpLaunch(_ url: URL, headers: [String: String] = [:]) -> ResolvedLaunch {
    ResolvedLaunch(target: .streamableHTTP(url: url, headers: headers), displayName: url.absoluteString)
}

private func sseLaunch(_ url: URL) -> ResolvedLaunch {
    ResolvedLaunch(target: .sse(url: url, headers: [:]), displayName: url.absoluteString)
}

/// A new directory under its real path. `resolvingSymlinksInPath` keeps `/var` where the
/// kernel, and so the server's `getcwd`, reports `/private/var`.
private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-manager-session-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let real = realpath(directory.path, nil) else { return directory }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

private func firstText(_ result: MCPToolResult) -> String? {
    if case let .text(text)? = result.content.first { return text }
    return nil
}

/// The fixture's `client_replies` and `launch_info` tools answer with JSON in a text block.
private func textJSON(_ result: MCPToolResult) throws -> JSONValue {
    try JSONValue.parse(try require(firstText(result), "the tool answered without text"))
}

/// `FixtureServer.stop()` waits with `waitUntilExit()`, which can hang on the cooperative
/// pool that `testAsync` bodies run on, so the fixture is stopped by polling instead.
private func stopFixture(_ server: FixtureServer) {
    let process = server.process
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < killDeadline { usleep(10_000) }
    }
}

private func processGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) != 0 && errno == ESRCH
}

private func eventually(within seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The first matching session event, or nil if none arrives in time. Ends the session's event stream.
private func firstEvent(of session: MCPClientSession, within seconds: Double,
                        where matches: @escaping @Sendable (MCPSessionEvent) -> Bool) async -> MCPSessionEvent? {
    await withTaskGroup(of: MCPSessionEvent?.self) { group in
        group.addTask {
            for await event in session.events where matches(event) { return event }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private let isClosedEvent: @Sendable (MCPSessionEvent) -> Bool = { event in
    if case .closed = event { return true }
    return false
}

private final class Recorder<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Item] = []

    func append(_ item: Item) {
        lock.withLock { stored.append(item) }
    }

    var items: [Item] {
        lock.withLock { stored }
    }
}

/// An auth provider that hands out `header` until a 401 swaps in `headerAfterRefresh`.
private final class FakeAuth: MCPAuthProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var header: String
    private let headerAfterRefresh: String
    private let refreshHelps: Bool
    private var requests = 0
    private var recordedChallenges: [String?] = []

    init(header: String, headerAfterRefresh: String? = nil, refreshHelps: Bool = true) {
        self.header = header
        self.headerAfterRefresh = headerAfterRefresh ?? header
        self.refreshHelps = refreshHelps
    }

    var headerRequests: Int { lock.withLock { requests } }
    var challenges: [String?] { lock.withLock { recordedChallenges } }

    func authorizationHeader(for url: URL) async throws -> String? {
        lock.withLock {
            requests += 1
            return header
        }
    }

    func handleUnauthorized(url: URL, challenge: String?) async -> Bool {
        lock.withLock {
            recordedChallenges.append(challenge)
            header = headerAfterRefresh
            return refreshHelps
        }
    }
}

func runClientSessionTests() {
    testAsync("Client session (stdio): handshake, paged tools, tool results, resources, prompts, ping and launch", timeout: 15) {
        let workingDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        // Libraries in the app can hold descriptors without FD_CLOEXEC; the server must not inherit them.
        let inheritable = open("/dev/null", O_RDONLY)
        defer { Darwin.close(inheritable) }
        let session = MCPClientSession(
            launch: stdioLaunch(environment: ["FIXTURE_MARKER": "from-the-launch"], workingDirectory: workingDirectory.path),
            log: MCPMemoryLog(), timeouts: quickTimeouts)

        let early = await thrownError { _ = try await session.listTools() }
        expectEqual(early as? MCPClientError, .notConnected)

        let result = try await session.connect()
        expectEqual(result.serverInfo, MCPImplementation(name: "fixture", version: "1.2.0", title: "MCP Fixture"))
        expectEqual(result.protocolVersion, "2025-06-18")
        expectEqual(await session.initializeResult, result)

        expectEqual(try await session.listTools().map(\.name), fixtureToolNames)

        let echo = try await session.callTool(name: "echo", arguments: ["message": "hello there"])
        expectEqual(echo, MCPToolResult(content: [.text("hello there")], structuredContent: ["echo": "hello there"]))
        let failed = try await session.callTool(name: "fail", arguments: [:])
        expectTrue(failed.isError, "fail should come back with isError")
        let image = try await session.callTool(name: "image", arguments: [:])
        if case let .image(data, mimeType)? = image.content.first {
            expectEqual(mimeType, "image/png")
            expectEqual(Data(base64Encoded: data).map { Array($0.prefix(8)) }, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        } else {
            fail("expected image content, got \(image.content)")
        }

        expectEqual(try await session.listResources().map(\.uri), ["fixture://readme"])
        expectEqual(try await session.listResourceTemplates().map(\.uriTemplate), ["fixture://notes/{name}"])
        expectEqual(try await session.readResource(uri: "fixture://notes/groceries"),
                    [MCPResourceContents(uri: "fixture://notes/groceries", mimeType: "text/plain", text: "Note groceries")])
        expectEqual(try await session.listPrompts().first?.arguments,
                    [MCPPromptArgument(name: "name", description: "Who to greet", required: true)])
        let prompt = try await session.getPrompt(name: "greet", arguments: ["name": "Ada"])
        expectEqual(prompt.messages, [MCPPromptMessage(role: "user", content: .text("Say hello to Ada."))])
        let missing = await thrownError { _ = try await session.getPrompt(name: "greet", arguments: [:]) }
        expectEqual(missing as? MCPClientError, .rpcError(method: "prompts/get", code: -32602,
                                                          message: "Missing required argument: name",
                                                          data: #"{"argument":"name"}"#))

        let roundTrip = try await session.ping()
        expectTrue(roundTrip < .seconds(2), "ping took \(roundTrip)")

        let launched = try textJSON(try await session.callTool(name: "launch_info", arguments: [:]))
        let pid = try require(await session.transportInfo.processID, "no pid for a stdio session")
        expectEqual(launched["pid"]?.intValue, Int(pid))
        expectEqual(launched["pgid"]?.intValue, Int(pid), "the server should lead its own process group")
        expectEqual(launched["cwd"]?.stringValue, workingDirectory.path)
        expectEqual(launched["marker"]?.stringValue, "from-the-launch")
        expectEqual(launched["inherited_fds"], [], "only stdin, stdout and stderr should be inherited")
        await session.close()

        let afterClose = await thrownError { _ = try await session.ping() }
        expectEqual(afterClose as? MCPClientError, .connectionClosed(detail: nil))
    }

    testAsync("Client session: a list the server did not declare throws capabilityMissing", timeout: 10) {
        let session = MCPClientSession(launch: stdioLaunch(["--no-prompts"]), log: MCPMemoryLog(), timeouts: quickTimeouts)
        _ = try await session.connect()
        let error = await thrownError { _ = try await session.listPrompts() }
        expectEqual(error as? MCPClientError, .capabilityMissing("prompts"))
        await session.close()
    }

    testAsync("Client session (stdio): progress reaches the caller; cancelling the task cancels it on the server", timeout: 15) {
        let session = MCPClientSession(launch: stdioLaunch(), log: MCPMemoryLog(), timeouts: quickTimeouts)
        _ = try await session.connect()

        let updates = Recorder<MCPProgress>()
        let result = try await session.callTool(name: "slow", arguments: ["seconds": 0.4, "steps": 4]) { updates.append($0) }
        expectEqual(firstText(result), "Slept for 0.4 s")
        expectEqual(updates.items.map(\.progress), [1, 2, 3, 4])
        expectEqual(updates.items.last, MCPProgress(progress: 4, total: 4, message: "Step 4 of 4"))

        let started = Recorder<MCPProgress>()
        let call = Task { try await session.callTool(name: "slow", arguments: ["seconds": 5, "steps": 10]) { started.append($0) } }
        expectTrue(await eventually(within: 3) { !started.items.isEmpty }, "slow never reported progress")
        let cancelledAt = ContinuousClock.now
        call.cancel()
        let error = await thrownError { _ = try await call.value }
        let waited = ContinuousClock.now - cancelledAt
        expectEqual(error as? MCPClientError, .cancelled)
        expectTrue(waited < .milliseconds(500), "cancelling took \(waited)")

        let report = try textJSON(try await session.callTool(name: "client_replies", arguments: [:]))
        let cancellations = report["cancellations"]?.arrayValue ?? []
        expectEqual(cancellations.map { $0["tool"] }, ["slow"], "the server should see the cancellation for the running call")
        expectEqual(cancellations.first?["reason"], "Cancelled in MCP Manager")
        await session.close()
    }

    testAsync("Client session (stdio): a tool call past its timeout throws timedOut and cancels it on the server", timeout: 10) {
        let timeouts = MCPTimeouts(initialize: .seconds(5), request: .seconds(3), toolCall: .milliseconds(500))
        let session = MCPClientSession(launch: stdioLaunch(), log: MCPMemoryLog(), timeouts: timeouts)
        _ = try await session.connect()
        let error = await thrownError { _ = try await session.callTool(name: "slow", arguments: ["seconds": 3, "steps": 3]) }
        expectEqual(error as? MCPClientError, .timedOut(method: "tools/call", seconds: 1))

        let report = try textJSON(try await session.callTool(name: "client_replies", arguments: [:]))
        let cancellation = report["cancellations"]?.arrayValue?.first
        expectEqual(cancellation?["tool"], "slow")
        expectEqual(cancellation?["reason"], "Timed out after 1 s")
        await session.close()
    }

    testAsync("Client session (stdio): a server that exits during initialize reports its exit code and stderr", timeout: 10) {
        let session = MCPClientSession(launch: stdioLaunch(["--exit-on-init", "3"]), log: MCPMemoryLog(), timeouts: quickTimeouts)
        let error = await thrownError { _ = try await session.connect() }
        guard case let .processExited(exit, stderrTail, stage)? = error as? MCPClientError else {
            fail("expected processExited, got \(String(describing: error))")
            return
        }
        expectEqual(exit, ProcessExit(code: 3))
        expectEqual(stderrTail, [fixtureReadyLine, "fixture: cannot start, FIXTURE_API_KEY is not set"])
        expectEqual(stage, .initialize)
        let closed = await firstEvent(of: session, within: 1, where: isClosedEvent)
        expectEqual(closed, .closed(error as? MCPClientError))
    }

    testAsync("Client session (stdio): non-JSON on stdout is logged and skipped, or blamed when initialize never answers", timeout: 10) {
        let log = MCPMemoryLog()
        let noisy = MCPClientSession(launch: stdioLaunch(["--stdout-noise"]), log: log, timeouts: quickTimeouts)
        _ = try await noisy.connect()
        let warning = log.entries.first { $0.kind == .warning && $0.summary == "Server wrote non-JSON to stdout" }
        expectEqual(warning?.detail, fixtureNoiseBanner)
        expectEqual(try await noisy.listTools().count, fixtureToolNames.count)
        await noisy.close()

        let short = MCPTimeouts(initialize: .milliseconds(500), request: .seconds(3), toolCall: .seconds(3))
        let silent = MCPClientSession(launch: stdioLaunch(["--stdout-noise", "--never-answer-init"]), log: MCPMemoryLog(),
                                      timeouts: short)
        let error = await thrownError { _ = try await silent.connect() }
        expectEqual(error as? MCPClientError, .invalidServerOutput(line: fixtureNoiseBanner, stage: .initialize))
    }

    testAsync("Client session (stdio): an unsupported protocol version is rejected and the server stopped", timeout: 10) {
        let session = MCPClientSession(launch: stdioLaunch(["--protocol", "1999-01-01"]), log: MCPMemoryLog(), timeouts: quickTimeouts)
        let error = await thrownError { _ = try await session.connect() }
        expectEqual(error as? MCPClientError, .unsupportedProtocolVersion("1999-01-01"))
        let pid = try require(await session.transportInfo.processID, "the server never started")
        expectTrue(await eventually(within: 1) { processGone(pid) }, "server \(pid) still running after the rejection")
    }

    testAsync("Client session (stdio): server requests are answered or declined, and its notifications are surfaced", timeout: 10) {
        let log = MCPMemoryLog()
        let session = MCPClientSession(launch: stdioLaunch(["--server-requests"]), log: log, timeouts: quickTimeouts)
        _ = try await session.connect()
        let changed = await firstEvent(of: session, within: 3) { $0 == .toolsChanged }
        expectEqual(changed, .toolsChanged)

        let replies = try textJSON(try await session.callTool(name: "client_replies", arguments: [:]))["replies"]
        expectEqual(replies?["s1"]?["result"], [:], "ping should be answered with an empty result")
        expectEqual(replies?["s2"]?["error"], ["code": -32601, "message": "MCP Manager does not support sampling/createMessage"])
        expectEqual(replies?["s3"]?["result"], ["roots": []])

        let entries = log.entries
        expectTrue(entries.contains { $0.kind == .incoming && $0.summary == "← sampling/createMessage #s2" },
                   "the server's request should be logged")
        expectTrue(entries.contains { $0.kind == .outgoing && $0.summary == "→ error #s2" }, "the refusal should be logged")
        let serverLog = entries.first { $0.summary.hasPrefix("Server error") }
        expectEqual(serverLog?.kind, .error)
        expectEqual(serverLog?.summary, #"Server error (fixture): {"problem":"disk almost full"}"#)
        await session.close()
    }

    testAsync("Client session (stdio): close() stops the server's whole process group", timeout: 10) {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild.pid")
        let session = MCPClientSession(launch: stdioLaunch(["--spawn-child", pidFile.path]), log: MCPMemoryLog(),
                                       timeouts: quickTimeouts)
        _ = try await session.connect()
        let grandchild = try require(pid_t(try readText(pidFile)), "no grandchild pid")
        expectTrue(kill(grandchild, 0) == 0, "the grandchild should be running before close")
        await session.close()
        expectTrue(await eventually(within: 3) { processGone(grandchild) }, "grandchild \(grandchild) survived close()")
    }

    testAsync("MCPChildProcesses.terminateAll stops every server group at once", timeout: 10) {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild.pid")
        let session = MCPClientSession(launch: stdioLaunch(["--spawn-child", pidFile.path]), log: MCPMemoryLog(),
                                       timeouts: quickTimeouts)
        _ = try await session.connect()
        let server = try require(await session.transportInfo.processID, "no server pid")
        let grandchild = try require(pid_t(try readText(pidFile)), "no grandchild pid")

        let started = Date()
        MCPChildProcesses.terminateAll()
        expectTrue(Date().timeIntervalSince(started) < 1, "terminateAll took \(Date().timeIntervalSince(started)) s")
        expectTrue(await eventually(within: 1) { processGone(server) && processGone(grandchild) },
                   "server \(server) or grandchild \(grandchild) survived terminateAll")
        let closed = await firstEvent(of: session, within: 2, where: isClosedEvent)
        expectEqual(closed, .closed(.processExited(ProcessExit(signal: SIGTERM), stderrTail: [fixtureReadyLine], stage: .request)))
        await session.close()
    }

    testAsync("Client session (stdio): a missing or non-executable command maps to its own error", timeout: 10) {
        let missing = MCPClientSession(
            launch: ResolvedLaunch(target: .stdio(executable: "/nonexistent/mcp-server", arguments: [], environment: [:],
                                                  workingDirectory: nil), displayName: "mcp-server"),
            log: MCPMemoryLog())
        let notFound = await thrownError { _ = try await missing.connect() }
        expectEqual(notFound as? MCPClientError, .commandNotFound(command: "/nonexistent/mcp-server", searchedPath: []))

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.sh")
        try writeFile(script, "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let notExecutable = MCPClientSession(
            launch: ResolvedLaunch(target: .stdio(executable: script.path, arguments: [], environment: [:],
                                                  workingDirectory: nil), displayName: "server.sh"),
            log: MCPMemoryLog())
        let denied = await thrownError { _ = try await notExecutable.connect() }
        expectEqual(denied as? MCPClientError, .commandNotExecutable(path: script.path))
    }

    testAsync("Client session (Streamable HTTP, JSON answers): connect, list and call with session headers", timeout: 15) {
        let server = try FixtureServer(script: fixtureScript, arguments: ["--http", "--json-responses", "--require-session"])
        defer { stopFixture(server) }
        let url = server.baseURL.appendingPathComponent("mcp")
        let log = MCPMemoryLog()
        let session = MCPClientSession(launch: httpLaunch(url), log: log, timeouts: quickTimeouts)
        let result = try await session.connect()
        expectEqual(result.serverInfo.name, "fixture")
        let info = await session.transportInfo
        expectEqual(info.endpoint, url.absoluteString)
        expectTrue(info.sessionID?.isEmpty == false, "the server's Mcp-Session-Id should be kept")
        expectEqual(try await session.listTools().map(\.name), fixtureToolNames)
        expectEqual(firstText(try await session.callTool(name: "add", arguments: ["a": 2, "b": 3])), "5")
        expectTrue(log.entries.contains { $0.kind == .event && $0.summary.hasPrefix("POST \(url.absoluteString) → 200 application/json · ") },
                   "each POST should log its status line")
        await session.close()
    }

    testAsync("Client session (Streamable HTTP, SSE answers): progress arrives before the result", timeout: 15) {
        let server = try FixtureServer(script: fixtureScript, arguments: ["--http", "--require-session"])
        defer { stopFixture(server) }
        let session = MCPClientSession(launch: httpLaunch(server.baseURL.appendingPathComponent("mcp")), log: MCPMemoryLog(),
                                       timeouts: quickTimeouts)
        _ = try await session.connect()
        expectEqual(try await session.listTools().count, fixtureToolNames.count)
        let updates = Recorder<MCPProgress>()
        let result = try await session.callTool(name: "slow", arguments: ["seconds": 0.2, "steps": 2]) { updates.append($0) }
        expectEqual(updates.items.map(\.progress), [1, 2])
        expectEqual(firstText(result), "Slept for 0.2 s")
        _ = try await session.ping()
        await session.close()
    }

    testAsync("Client session (HTTP): 401 needs sign-in; an auth provider's header works; a refresh retries exactly once", timeout: 20) {
        let server = try FixtureServer(script: fixtureScript, arguments: ["--http", "--require-header", "Authorization=Bearer good"])
        defer { stopFixture(server) }
        let url = server.baseURL.appendingPathComponent("mcp")
        let challenge = #"Bearer resource_metadata="http://127.0.0.1:\#(server.port)/.well-known/oauth-protected-resource""#

        let anonymous = MCPClientSession(launch: httpLaunch(url), log: MCPMemoryLog(), timeouts: quickTimeouts)
        let unauthorized = await thrownError { _ = try await anonymous.connect() }
        expectEqual(unauthorized as? MCPClientError, .authorizationRequired(url: url.absoluteString, challenge: challenge))

        let signedIn = FakeAuth(header: "Bearer good")
        let working = MCPClientSession(launch: httpLaunch(url), log: MCPMemoryLog(), auth: signedIn, timeouts: quickTimeouts)
        _ = try await working.connect()
        expectEqual(try await working.listTools().count, fixtureToolNames.count)
        expectEqual(signedIn.challenges.count, 0)
        await working.close()

        let stale = FakeAuth(header: "Bearer stale", headerAfterRefresh: "Bearer good")
        let refreshed = MCPClientSession(launch: httpLaunch(url), log: MCPMemoryLog(), auth: stale, timeouts: quickTimeouts)
        _ = try await refreshed.connect()
        expectEqual(stale.challenges, [challenge])
        await refreshed.close()

        let hopeless = FakeAuth(header: "Bearer stale")
        let failing = MCPClientSession(launch: httpLaunch(url), log: MCPMemoryLog(), auth: hopeless, timeouts: quickTimeouts)
        let stillUnauthorized = await thrownError { _ = try await failing.connect() }
        expectEqual(stillUnauthorized as? MCPClientError, .authorizationRequired(url: url.absoluteString, challenge: challenge))
        expectEqual(hopeless.challenges.count, 1, "a refresh should be tried once")
        expectEqual(hopeless.headerRequests, 2, "the POST should be retried exactly once")

        let ignored = FakeAuth(header: "Bearer stale")
        let configured = MCPClientSession(launch: httpLaunch(url, headers: ["authorization": "Bearer good"]), log: MCPMemoryLog(),
                                          auth: ignored, timeouts: quickTimeouts)
        _ = try await configured.connect()
        expectEqual(ignored.headerRequests, 0, "a configured Authorization header wins over the provider")
        await configured.close()
    }

    testAsync("Client session (HTTP): expired session, error status with body, and a closed port", timeout: 15) {
        let expiring = try FixtureServer(script: fixtureScript, arguments: ["--http", "--expire-session"])
        defer { stopFixture(expiring) }
        let expiringURL = expiring.baseURL.appendingPathComponent("mcp")
        let session = MCPClientSession(launch: httpLaunch(expiringURL), log: MCPMemoryLog(), timeouts: quickTimeouts)
        _ = try await session.connect()
        _ = try await session.listTools()
        let expired = await thrownError { _ = try await session.listTools() }
        expectEqual(expired as? MCPClientError, .sessionExpired(url: expiringURL.absoluteString))
        let closed = await firstEvent(of: session, within: 1, where: isClosedEvent)
        expectEqual(closed, .closed(.sessionExpired(url: expiringURL.absoluteString)))
        let afterwards = await thrownError { _ = try await session.ping() }
        expectEqual(afterwards as? MCPClientError, .sessionExpired(url: expiringURL.absoluteString))

        let broken = try FixtureServer(script: fixtureScript, arguments: ["--http", "--status", "500"])
        defer { stopFixture(broken) }
        let brokenURL = broken.baseURL.appendingPathComponent("mcp")
        let failing = MCPClientSession(launch: httpLaunch(brokenURL), log: MCPMemoryLog(), timeouts: quickTimeouts)
        let status = await thrownError { _ = try await failing.connect() }
        expectEqual(status as? MCPClientError, .httpStatus(code: 500, url: brokenURL.absoluteString,
                                                           body: "fixture says no: status 500", stage: .initialize))

        let gone = try FixtureServer(script: fixtureScript, arguments: ["--http"])
        let goneURL = gone.baseURL.appendingPathComponent("mcp")
        stopFixture(gone)
        let unreachable = MCPClientSession(launch: httpLaunch(goneURL), log: MCPMemoryLog(), timeouts: quickTimeouts)
        let network = await thrownError { _ = try await unreachable.connect() }
        guard case let .network(code, failedURL, _)? = network as? MCPClientError else {
            fail("expected a network error, got \(String(describing: network))")
            return
        }
        expectEqual(code, URLError.Code.cannotConnectToHost.rawValue)
        expectEqual(failedURL, goneURL.absoluteString)
    }

    testAsync("Client session (legacy HTTP+SSE): connect, list and call; an endpoint on another origin is refused", timeout: 15) {
        let server = try FixtureServer(script: fixtureScript, arguments: ["--sse"])
        defer { stopFixture(server) }
        let session = MCPClientSession(launch: sseLaunch(server.baseURL.appendingPathComponent("sse")), log: MCPMemoryLog(),
                                       timeouts: quickTimeouts)
        let result = try await session.connect()
        expectEqual(result.protocolVersion, "2024-11-05")
        expectEqual(try await session.listTools().map(\.name), fixtureToolNames)
        expectEqual(firstText(try await session.callTool(name: "add", arguments: ["a": 2, "b": 3])), "5")
        await session.close()

        let evil = try FixtureServer(script: fixtureScript, arguments: ["--sse", "--evil-endpoint"])
        defer { stopFixture(evil) }
        let tricked = MCPClientSession(launch: sseLaunch(evil.baseURL.appendingPathComponent("sse")), log: MCPMemoryLog(),
                                       timeouts: quickTimeouts)
        let error = await thrownError { _ = try await tricked.connect() }
        guard case .malformedResponse(method: "endpoint", _)? = error as? MCPClientError else {
            fail("expected the endpoint to be refused, got \(String(describing: error))")
            return
        }
    }

    test("SSE parser: CRLF, CR and LF endings, multi-line data, comments, a leading BOM and events without data") {
        var parser = SSEParser()
        let stream = "\u{FEFF}: a comment\r\nevent: endpoint\r\ndata: /messages?id=1\r\n\r\n"
            + "data: line one\rdata:line two\r\r"
            + "id: 7\nretry: 2500\nevent: ping\n\n"
            + "data: last\n\n"
        var events: [SSEEvent] = []
        for byte in Array(stream.utf8) {
            if let event = try parser.push(byte) { events.append(event) }
        }
        expectEqual(events, [
            SSEEvent(event: "endpoint", data: "/messages?id=1", id: nil),
            SSEEvent(event: nil, data: "line one\nline two", id: nil),
            SSEEvent(event: nil, data: "last", id: "7"),
        ])
        expectEqual(parser.reconnectionTime, 2500)
    }

    test("SSE parser: a CRLF split across chunks ends one line, not two") {
        var parser = SSEParser()
        var events = try parser.push(Array("data: a\r".utf8))
        events += try parser.push(Array("\ndata: b\r\n\r\n".utf8))
        expectEqual(events, [SSEEvent(event: nil, data: "a\nb", id: nil)])
    }

    test("SSE parser: a BOM counts only at the start, an unterminated last event still arrives, oversized events throw") {
        var parser = SSEParser()
        expectEqual(try parser.push(Array("data: \u{FEFF}x\n\ndata: tail".utf8)), [SSEEvent(event: nil, data: "\u{FEFF}x", id: nil)])
        expectEqual(parser.finish(), SSEEvent(event: nil, data: "tail", id: nil))

        var small = SSEParser(maxBufferedBytes: 16)
        expectThrows(MCPClientError.messageTooLarge(bytes: 17)) { _ = try small.push(Array("data: 0123456789abcdef\n".utf8)) }
    }

    testAsync("Client session: the log records each message with its id and round-trip time, plus stderr", timeout: 10) {
        let log = MCPMemoryLog()
        let launch = stdioLaunch()
        let session = MCPClientSession(launch: launch, log: log, timeouts: quickTimeouts)
        _ = try await session.connect()
        _ = try await session.callTool(name: "echo", arguments: ["message": "logged"])
        let pid = try require(await session.transportInfo.processID, "no pid")
        expectTrue(await eventually(within: 2) { log.entries.contains { $0.kind == .stderr && $0.summary == fixtureReadyLine } },
                   "the server's stderr line should be logged")
        await session.close()

        let entries = log.entries
        expectTrue(entries.contains { $0.kind == .event && $0.summary == "Started \(launch.displayName) (pid \(pid))" },
                   "the launch should be logged with its pid")
        expectEqual(entries.first { $0.kind == .outgoing }?.summary, "→ initialize #1")
        expectTrue(entries.contains { $0.kind == .outgoing && $0.summary == "→ notifications/initialized" },
                   "notifications/initialized should be logged")
        let sent = try require(entries.first { $0.kind == .outgoing && $0.summary.hasPrefix("→ tools/call #") }, "no tools/call logged")
        let id = sent.summary.dropFirst("→ tools/call ".count)
        expectTrue(sent.detail?.contains(#""method":"tools/call""#) == true, "the request JSON should be the detail")
        let received = entries.first { $0.kind == .incoming && $0.summary.hasPrefix("← tools/call \(id) · ") && $0.summary.hasSuffix(" ms") }
        expectTrue(received?.detail?.contains("logged") == true, "the result for \(id) should be logged with its timing")
        expectTrue(entries.contains { $0.kind == .event && $0.summary == "Connected to fixture 1.2.0 (protocol 2025-06-18)" },
                   "the connected line should be logged")
    }
}
