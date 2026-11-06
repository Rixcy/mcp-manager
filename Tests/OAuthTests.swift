import Darwin
import Foundation

private let browserSession = URLSession(configuration: .ephemeral)

/// What the browser does in these tests: GET the authorization URL and follow
/// the fixture's 302 to the loopback listener.
private let followRedirects: @Sendable (URL) async throws -> Void = { url in
    _ = try await browserSession.data(from: url)
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}

private func oauthFixture(_ arguments: [String] = []) throws -> FixtureServer {
    try FixtureServer(script: "oauth_fixture_server.py", arguments: arguments)
}

/// Polls for the exit instead of calling `FixtureServer.stop()`, whose
/// `Process.waitUntilExit()` sometimes never returns on the cooperative pool.
private func shutDown(_ fixture: FixtureServer) async {
    fixture.process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while fixture.process.isRunning, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Runs `body` against a fresh fixture and an empty directory for credentials.
private func withFixture(_ arguments: [String] = [], _ body: (FixtureServer, URL) async throws -> Void) async throws {
    let fixture = try oauthFixture(arguments)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try await body(fixture, directory)
    } catch {
        await shutDown(fixture)
        throw error
    }
    await shutDown(fixture)
}

private func fixtureTest(_ name: String, _ arguments: [String] = [], timeout: TimeInterval = 15,
                         _ body: @escaping @Sendable (FixtureServer, URL) async throws -> Void) {
    testAsync(name, timeout: timeout) { try await withFixture(arguments, body) }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-manager-oauth-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func credentialsFile(in directory: URL) -> URL {
    directory.appendingPathComponent("support/oauth-credentials.json")
}

private func makeClient(_ directory: URL, timeout: Duration = .seconds(5)) -> OAuthClient {
    OAuthClient(store: FileCredentialStore(url: credentialsFile(in: directory)), callbackTimeout: timeout)
}

private func mcpURL(_ fixture: FixtureServer) -> URL {
    fixture.baseURL.appendingPathComponent("mcp")
}

private func fixtureState(_ fixture: FixtureServer) async throws -> JSONValue {
    let (data, _) = try await browserSession.data(from: fixture.baseURL.appendingPathComponent("test/state"))
    return try JSONValue.parse(data)
}

private func refreshGrants(_ fixture: FixtureServer) async throws -> Int? {
    try await fixtureState(fixture)["token_grants"]?["refresh_token"]?.intValue
}

/// POSTs a JSON-RPC request to the fixture's protected endpoint.
private func postMCP(_ fixture: FixtureServer, authorization: String?) async throws -> (status: Int, challenge: String?) {
    var request = URLRequest(url: mcpURL(fixture))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
    let (_, response) = try await browserSession.data(for: request)
    let http = try require(response as? HTTPURLResponse, "not an HTTP response")
    return (http.statusCode, http.value(forHTTPHeaderField: "WWW-Authenticate"))
}

private func signIn(_ fixture: FixtureServer, _ client: OAuthClient, challenge: String? = nil, hints: MCPOAuthHints? = nil,
                    log: MCPLogSink? = nil) async throws -> OAuthCredential {
    try await client.signIn(serverURL: mcpURL(fixture), challenge: challenge, hints: hints, log: log,
                            openBrowser: followRedirects)
}

private func logText(_ log: MCPMemoryLog) -> String {
    log.entries.map { "\($0.summary) \($0.detail ?? "")" }.joined(separator: "\n")
}

/// The port of the redirect URI the sign-in logged before opening the browser.
private func loggedCallbackPort(_ log: MCPMemoryLog) -> Int? {
    log.entries.first { $0.summary == "Waiting for the browser callback" }
        .flatMap { $0.detail }.flatMap(URL.init(string:))?.port
}

private func isListening(_ port: Int) async -> Bool {
    do {
        _ = try await browserSession.data(from: URL(string: "http://127.0.0.1:\(port)/probe")!)
        return true
    } catch {
        return false
    }
}

/// A TCP socket bound to 127.0.0.1; listening when `listen` is set. Port 0 picks a free one.
private func loopbackSocket(port: UInt16 = 0, listen shouldListen: Bool) throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var on: Int32 = 1
    // The port may still be in TIME_WAIT from the sign-in that used it.
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
            bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
        }
    }
    guard fd >= 0, bound, !shouldListen || listen(fd, 1) == 0 else {
        close(fd)
        throw TestFailure(description: "could not bind 127.0.0.1:\(port): \(String(cString: strerror(errno)))")
    }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}

private func freeLoopbackPort() throws -> Int {
    let socket = try loopbackSocket(listen: false)
    close(socket.fd)
    return socket.port
}

private func expectSignInFails(_ arguments: [String], file: StaticString = #fileID, line: UInt = #line,
                               expected: @escaping (FixtureServer) -> MCPClientError) -> @Sendable () async throws -> Void {
    {
        try await withFixture(arguments) { fixture, directory in
            let error = await thrownError(file: file, line: line) { _ = try await signIn(fixture, makeClient(directory)) }
            expectEqual(error as? MCPClientError, expected(fixture), file: file, line: line)
            let saved = try FileCredentialStore(url: credentialsFile(in: directory))
                .credential(for: OAuthClient.resourceKey(for: mcpURL(fixture)))
            expectEqual(saved, nil, "a failed sign-in saved a credential", file: file, line: line)
        }
    }
}

func runOAuthTests() {
    runOAuthParsingTests()
    runCredentialStoreTests()
    runSignInTests()
    runSignInFailureTests()
    runRefreshTests()
}

private func runOAuthParsingTests() {
    test("OAuth: resource keys are canonical server URIs") {
        let cases = [
            "https://MCP.Linear.app:443/mcp/?x=1#f": "https://mcp.linear.app/mcp",
            "HTTP://Example.COM:8080/Path/": "http://example.com:8080/Path",
            "http://127.0.0.1:80/": "http://127.0.0.1/",
            "https://example.com": "https://example.com/",
            "https://example.com/?q=1": "https://example.com/",
            "https://example.com:8443/a/b//": "https://example.com:8443/a/b",
            "https://user:secret@Example.com/mcp": "https://example.com/mcp",
            "http://[::1]:3000/mcp/": "http://[::1]:3000/mcp",
        ]
        for (input, expected) in cases {
            expectEqual(OAuthClient.resourceKey(for: URL(string: input)!), expected, input)
        }
    }

    test("OAuth: challenge parser handles quoted commas, escapes, token68 and several schemes") {
        let quoted = WWWAuthenticateChallenge.parse(
            #"Bearer realm="a, b", error="invalid_token", error_description="say \"hi\", then go""#)
        expectEqual(quoted, [WWWAuthenticateChallenge(scheme: "Bearer", parameters: [
            "realm": "a, b", "error": "invalid_token", "error_description": #"say "hi", then go"#,
        ])])

        let several = WWWAuthenticateChallenge.parse(
            #"Negotiate abc123==, Basic realm="basic", "#
                + #"Bearer Resource_Metadata="https://x.example/.well-known/oauth-protected-resource/mcp", scope="read write", "#
                + #"error=insufficient_scope"#)
        expectEqual(several, [
            WWWAuthenticateChallenge(scheme: "Negotiate", token68: "abc123=="),
            WWWAuthenticateChallenge(scheme: "Basic", parameters: ["realm": "basic"]),
            WWWAuthenticateChallenge(scheme: "Bearer", parameters: [
                "resource_metadata": "https://x.example/.well-known/oauth-protected-resource/mcp",
                "scope": "read write", "error": "insufficient_scope",
            ]),
        ])
        expectEqual(WWWAuthenticateChallenge.bearerParameters(
            #"Basic realm="basic", Bearer scope="read write""#), ["scope": "read write"])
        expectEqual(WWWAuthenticateChallenge.parse("Bearer, Basic realm=\"x\""),
                    [WWWAuthenticateChallenge(scheme: "Bearer"), WWWAuthenticateChallenge(scheme: "Basic", parameters: ["realm": "x"])])
        expectEqual(WWWAuthenticateChallenge.bearerParameters(#"Basic realm="only basic""#), ["realm": "only basic"])
        expectEqual(WWWAuthenticateChallenge.bearerParameters(nil), [:])
    }

    test("OAuth: the PKCE challenge is unpadded base64url SHA-256; verifiers are long, URL-safe and random") {
        // Expected value from Python: base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip(b"=")
        expectEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW-gFWFOEjXk"), "90EpwHQr_xi9uDtjYyz5mq9Z4RekugHRqg5ijpXC3FQ")
        let first = PKCE.randomString(byteCount: 32)
        let second = PKCE.randomString(byteCount: 32)
        expectEqual(first.count, 43)
        expectTrue(first != second, "two verifiers were the same")
        expectTrue(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") },
                   "verifier is not base64url without padding: \(first)")
    }

    testAsync("OAuth: the loopback listener answers ::1 and decodes form-style queries", timeout: 10) {
        let server = try OAuthLoopbackServer.start(port: 0, includeIPv6: true, path: "/callback") { parameters in
            (200, OAuthLoopbackServer.page("got \(parameters["code"] ?? "")"))
        }
        defer { server.stop() }
        let (missing, notFound) = try await browserSession.data(from: URL(string: "http://[::1]:\(server.port)/favicon.ico")!)
        expectEqual((notFound as? HTTPURLResponse)?.statusCode, 404)
        expectTrue(String(decoding: missing, as: UTF8.self).contains("Not found"), "no 404 page")
        let (page, _) = try await browserSession.data(
            from: URL(string: "http://[::1]:\(server.port)/callback?code=a%2Bb%26c&error_description=two+words")!)
        expectTrue(String(decoding: page, as: UTF8.self).contains("got a+b&amp;c"), "page: \(String(decoding: page, as: UTF8.self))")
        let parameters = try await server.waitForCallback(timeout: .seconds(2))
        expectEqual(parameters, ["code": "a+b&c", "error_description": "two words"])
    }
}

private func runCredentialStoreTests() {
    test("OAuth store: a file store round-trips credentials in a 0600 file with ISO 8601 dates") {
        try withTempHome { home in
            let url = home.appendingPathComponent("Support/MCP Manager/oauth-credentials.json")
            expectEqual(try FileCredentialStore(url: url).credential(for: "https://a.example/mcp"), nil)

            let first = OAuthCredential(resource: "https://a.example/mcp", issuer: "https://as.example", tokenEndpoint: "https://as.example/token",
                                        clientID: "client-a", redirectURI: "http://127.0.0.1:5000/callback", accessToken: "at-a",
                                        refreshToken: "rt-a", expiresAt: Date(timeIntervalSince1970: 1_893_553_445), scope: "read")
            let second = OAuthCredential(resource: "https://b.example/", issuer: "https://b.example", tokenEndpoint: "https://b.example/token",
                                         clientID: "client-b", clientSecret: "shh", tokenEndpointAuthMethod: "client_secret_post",
                                         redirectURI: "http://localhost:6000/callback", accessToken: "at-b")
            try FileCredentialStore(url: url).save(first)
            try FileCredentialStore(url: url).save(second)

            let reopened = FileCredentialStore(url: url)
            expectEqual(try reopened.credential(for: first.resource), first)
            expectEqual(try reopened.credential(for: second.resource), second)
            expectEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
            expectEqual(try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
            expectTrue(try readText(url).contains(#""2030-01-02T03:04:05Z""#), "expiry is not stored as ISO 8601:\n\(try readText(url))")

            try reopened.deleteCredential(for: first.resource)
            try reopened.deleteCredential(for: "https://never.example/")
            expectEqual(try FileCredentialStore(url: url).credential(for: first.resource), nil)
            expectEqual(try FileCredentialStore(url: url).credential(for: second.resource), second)
        }
    }

    test("OAuth store: a damaged file is an error and is not overwritten") {
        try withTempHome { home in
            let url = home.appendingPathComponent("oauth-credentials.json")
            try writeFile(url, "{\"https://a.example/\": {\"resource\": ")
            let store = FileCredentialStore(url: url)
            for operation in [{ _ = try store.credential(for: "https://a.example/") },
                              { try store.save(OAuthCredential(resource: "r", issuer: "i", tokenEndpoint: "t", clientID: "c",
                                                               redirectURI: "u", accessToken: "a")) }] {
                do {
                    try operation()
                    fail("a damaged credentials file was accepted")
                } catch MCPClientError.oauth(.credentialStore(let detail)) {
                    expectTrue(detail.contains(url.path) && detail.contains("sign in again"), "unhelpful detail: \(detail)")
                }
            }
            expectEqual(try readText(url), "{\"https://a.example/\": {\"resource\": ")
        }
    }
}

private func runSignInTests() {
    fixtureTest("sign-in: a real 401 leads through discovery, registration and PKCE to a token /mcp accepts") { fixture, directory in

        let unauthorized = try await postMCP(fixture, authorization: nil)
        expectEqual(unauthorized.status, 401)
        let challenge = try require(unauthorized.challenge, "the fixture sent no WWW-Authenticate")
        let log = MCPMemoryLog()
        let pages = Recorder()
        let client = makeClient(directory)
        let credential = try await client.signIn(serverURL: mcpURL(fixture), challenge: challenge, hints: nil, log: log) { url in
            let redirect = try require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:)), "no redirect_uri in \(url)")
            let (_, favicon) = try await browserSession.data(from: URL(string: "/favicon.ico", relativeTo: redirect)!)
            pages.append("favicon \((favicon as? HTTPURLResponse)?.statusCode ?? 0)")
            let (page, _) = try await browserSession.data(from: url)
            pages.append(String(decoding: page, as: UTF8.self))
        }

        let resource = "http://127.0.0.1:\(fixture.port)/mcp"
        expectEqual(credential.resource, resource)
        expectEqual(credential.issuer, "http://127.0.0.1:\(fixture.port)/auth")
        expectEqual(credential.scope, "mcp:read mcp:write")
        expectTrue(credential.redirectURI.hasPrefix("http://127.0.0.1:"), "redirect: \(credential.redirectURI)")
        let file = credentialsFile(in: directory)
        expectEqual(try FileCredentialStore(url: file).credential(for: resource), credential)
        expectEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

        let header = try require(try await OAuthAuthProvider(client: client).authorizationHeader(for: mcpURL(fixture)), "no header")
        expectEqual(try await postMCP(fixture, authorization: header).status, 200)

        let state = try await fixtureState(fixture)
        expectEqual(state["registrations"], .int(1))
        expectEqual(state["pkce_verified"], .int(1))
        expectEqual(state["last_resource"], .string(resource))
        expectEqual(state["last_token_resource"], .string(resource))
        expectEqual(state["last_scope"], .string("mcp:read mcp:write"))
        expectEqual(pages.values.first, "favicon 404")
        expectTrue(pages.values.last?.contains("Signed in to 127.0.0.1. You can close this tab and return to MCP Manager.") == true,
                   "callback page: \(pages.values.last ?? "none")")

        let text = logText(log)
        for expected in ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server/auth",
                         "Registered client \(credential.clientID)", "Opened the browser", "Received the browser callback",
                         "Signed in to 127.0.0.1", "expires at"] {
            expectTrue(text.contains(expected), "log lacks \(expected):\n\(text)")
        }
        for secret in [credential.accessToken, credential.refreshToken ?? "?", "code_challenge", "state=", "code="] {
            expectTrue(!text.contains(secret), "log contains \(secret):\n\(text)")
        }
    }

    testAsync("sign-in: without a challenge the protected resource metadata is found at its well-known URLs", timeout: 15) {
        for (flags, metadataPath) in [([String](), "/.well-known/oauth-protected-resource/mcp"),
                                      (["--prm-root-only"], "/.well-known/oauth-protected-resource")] {
            try await withFixture(flags) { fixture, directory in
                let log = MCPMemoryLog()
                let credential = try await signIn(fixture, makeClient(directory), log: log)
                expectEqual(credential.issuer, "http://127.0.0.1:\(fixture.port)/auth", "\(flags)")
                let found = log.entries.first { $0.summary == "Found protected resource metadata" }?.detail
                expectEqual(found, "http://127.0.0.1:\(fixture.port)\(metadataPath)", "\(flags)")
                expectEqual(try await fixtureState(fixture)["last_scope"], .string("mcp:read mcp:write"), "\(flags)")
            }
        }
    }

    testAsync("sign-in: with no protected resource metadata the server's origin is the authorization server", timeout: 15) {
        for flags in [["--no-prm"], ["--no-prm", "--no-as-metadata"]] {
            try await withFixture(flags) { fixture, directory in
                let challenge = try await postMCP(fixture, authorization: nil).challenge
                let log = MCPMemoryLog()
                let client = makeClient(directory)
                let credential = try await signIn(fixture, client, challenge: challenge, log: log)
                expectEqual(credential.issuer, "http://127.0.0.1:\(fixture.port)", "\(flags)")
                expectEqual(credential.tokenEndpoint, "http://127.0.0.1:\(fixture.port)/token", "\(flags)")
                let header = try await OAuthAuthProvider(client: client).authorizationHeader(for: mcpURL(fixture))
                expectEqual(try await postMCP(fixture, authorization: header).status, 200, "\(flags)")
                let usedDefaults = logText(log).contains("using the default endpoints")
                expectEqual(usedDefaults, flags.contains("--no-as-metadata"), "\(flags):\n\(logText(log))")
            }
        }
    }

    fixtureTest("sign-in: a pre-registered client skips registration and redirects to localhost on its port",
                ["--client-id", "claude-code-client"]) { fixture, directory in
        let port = try freeLoopbackPort()
        let challenge = #"Bearer resource_metadata="http://127.0.0.1:\#(fixture.port)/.well-known/oauth-protected-resource/mcp", scope="mcp:read""#
        let credential = try await signIn(fixture, makeClient(directory), challenge: challenge,
                                          hints: MCPOAuthHints(clientID: "claude-code-client", callbackPort: port))
        expectEqual(credential.clientID, "claude-code-client")
        expectEqual(credential.redirectURI, "http://localhost:\(port)/callback")
        let state = try await fixtureState(fixture)
        expectEqual(state["registrations"], .int(0))
        expectEqual(state["last_redirect_uri"], .string("http://localhost:\(port)/callback"))
        expectEqual(state["last_scope"], .string("mcp:read"), "the challenge's scope should win over scopes_supported")
    }

    fixtureTest("sign-in: a callback port that is taken is an error naming the port",
                ["--client-id", "claude-code-client"]) { fixture, directory in
        let blocker = try loopbackSocket(listen: true)
        defer { close(blocker.fd) }
        let error = await thrownError {
            _ = try await signIn(fixture, makeClient(directory),
                                 hints: MCPOAuthHints(clientID: "claude-code-client", callbackPort: blocker.port))
        }
        guard case let .oauth(.callbackServerFailed(detail))? = error as? MCPClientError else {
            return fail("expected callbackServerFailed, got \(String(describing: error))")
        }
        expectTrue(detail.contains("port \(blocker.port)"), "detail: \(detail)")
        expectEqual(try await fixtureState(fixture)["authorize"], .int(0))
    }

    fixtureTest("sign-in: the next sign-in reuses the registered client unless its port is taken") { fixture, directory in
        let client = makeClient(directory)
        let first = try await signIn(fixture, client)
        let second = try await signIn(fixture, client)
        expectEqual(second.clientID, first.clientID)
        expectEqual(second.redirectURI, first.redirectURI)
        expectTrue(second.accessToken != first.accessToken, "the second sign-in returned the old token")
        expectEqual(try await fixtureState(fixture)["registrations"], .int(1))

        let port = try require(URL(string: second.redirectURI)?.port, "no port in \(second.redirectURI)")
        let blocker = try loopbackSocket(port: UInt16(port), listen: true)
        defer { close(blocker.fd) }
        let third = try await signIn(fixture, client)
        expectTrue(third.clientID != first.clientID && third.redirectURI != first.redirectURI,
                   "reused a client whose redirect port is taken: \(third.redirectURI)")
        expectEqual(try await fixtureState(fixture)["registrations"], .int(2))
    }

    testAsync("sign-in: a client secret is sent with HTTP Basic or in the form, as registered", timeout: 15) {
        for method in ["client_secret_basic", "client_secret_post"] {
            try await withFixture(["--client-auth", method]) { fixture, directory in
                let client = makeClient(directory)
                let credential = try await signIn(fixture, client)
                expectEqual(credential.tokenEndpointAuthMethod, method)
                expectTrue(credential.clientSecret?.isEmpty == false, "the client secret was not kept")
                _ = try await client.refresh(credential)
                let state = try await fixtureState(fixture)
                expectEqual(state["last_client_auth"], .string(method))
                expectEqual(state["token_grants"]?["refresh_token"], .int(1))
            }
        }
    }
}

private func runSignInFailureTests() {
    testAsync("sign-in fails: no registration endpoint", timeout: 10, expectSignInFails(["--no-registration"]) {
        .oauth(.registrationUnsupported(issuer: "http://127.0.0.1:\($0.port)/auth"))
    })

    testAsync("sign-in fails: registration refused, with the server's reason", timeout: 10, expectSignInFails(["--registration-fails"]) { _ in
        .oauth(.registrationFailed(status: 400, detail: "Redirect URIs must use https."))
    })

    testAsync("sign-in fails: the user denies consent", timeout: 10, expectSignInFails(["--deny"]) { _ in
        .oauth(.denied(error: "access_denied", description: "The user denied access"))
    })

    testAsync("sign-in fails: the callback's state does not match", timeout: 10, expectSignInFails(["--bad-state"]) { _ in
        .oauth(.stateMismatch)
    })

    testAsync("sign-in fails: a token endpoint over plain HTTP", timeout: 10, expectSignInFails(["--insecure-token-endpoint"]) { _ in
        .oauth(.insecureEndpoint("http://example.invalid/token"))
    })

    fixtureTest("sign-in fails: an authorization server without S256", ["--no-s256"], timeout: 10) { fixture, directory in
        let error = await thrownError { _ = try await signIn(fixture, makeClient(directory)) }
        guard case let .oauth(.discoveryFailed(url, detail))? = error as? MCPClientError else {
            return fail("expected discoveryFailed, got \(String(describing: error))")
        }
        expectEqual(url, "http://127.0.0.1:\(fixture.port)/.well-known/oauth-authorization-server/auth")
        expectTrue(detail.contains("S256") && detail.contains("plain"), "detail: \(detail)")
        expectEqual(try await fixtureState(fixture)["registrations"], .int(0))
    }

    fixtureTest("sign-in fails: the denial page tells the user what happened", ["--deny"], timeout: 10) { fixture, directory in
        let pages = Recorder()
        _ = await thrownError {
            _ = try await makeClient(directory).signIn(serverURL: mcpURL(fixture), challenge: nil, hints: nil) { url in
                pages.append(String(decoding: try await browserSession.data(from: url).0, as: UTF8.self))
            }
        }
        expectTrue(pages.values.first?.contains("Sign-in to 127.0.0.1 failed: The user denied access (access_denied)") == true,
                   "page: \(pages.values.first ?? "none")")
    }

    fixtureTest("sign-in fails: the browser never comes back, and the listener stops", timeout: 10) { fixture, directory in
        let log = MCPMemoryLog()
        let started = Date()
        let error = await thrownError {
            _ = try await makeClient(directory, timeout: .seconds(1)).signIn(serverURL: mcpURL(fixture), challenge: nil,
                                                                             hints: nil, log: log) { _ in }
        }
        expectEqual(error as? MCPClientError, .oauth(.browserTimedOut(seconds: 1)))
        let elapsed = Date().timeIntervalSince(started)
        expectTrue(elapsed > 0.9 && elapsed < 4, "timed out after \(elapsed) s")
        let port = try require(loggedCallbackPort(log), "no callback port logged:\n\(logText(log))")
        expectTrue(!(await isListening(port)), "the callback listener is still running on \(port)")
    }

    fixtureTest("sign-in fails: cancelling the task stops the listener", timeout: 10) { fixture, directory in
        let log = MCPMemoryLog()
        let client = makeClient(directory, timeout: .seconds(30))
        let task = Task { try await client.signIn(serverURL: mcpURL(fixture), challenge: nil, hints: nil, log: log) { _ in } }
        let deadline = Date().addingTimeInterval(5)
        while !logText(log).contains("Opened the browser"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try require(loggedCallbackPort(log), "sign-in never opened the browser:\n\(logText(log))")
        expectTrue(await isListening(port), "the callback listener was not running before the cancel")
        let cancelled = Date()
        task.cancel()
        let error = await thrownError { _ = try await task.value }
        expectEqual(error as? MCPClientError, .cancelled)
        expectTrue(Date().timeIntervalSince(cancelled) < 2, "cancel took \(Date().timeIntervalSince(cancelled)) s")
        expectTrue(!(await isListening(port)), "the callback listener is still running on \(port)")
    }
}

private func runRefreshTests() {
    fixtureTest("refresh: an expiring token is refreshed before it is sent", ["--expires-in", "1"]) { fixture, directory in
        let client = makeClient(directory)
        let credential = try await signIn(fixture, client)
        let header = try require(try await OAuthAuthProvider(client: client).authorizationHeader(for: mcpURL(fixture)), "no header")
        expectTrue(header != "Bearer \(credential.accessToken)", "the expiring token was sent unrefreshed")
        expectEqual(try await postMCP(fixture, authorization: header).status, 200)
        let stored = try require(client.credential(for: mcpURL(fixture)), "no stored credential")
        expectEqual("Bearer \(stored.accessToken)", header)
        expectTrue(stored.refreshToken != nil && stored.refreshToken != credential.refreshToken, "the rotated refresh token was not saved")
        expectTrue((stored.expiresAt?.timeIntervalSinceNow ?? 0) > 3000, "expiry not updated: \(String(describing: stored.expiresAt))")
        expectEqual(try await refreshGrants(fixture), 1)
    }

    fixtureTest("refresh: the old refresh token is kept when the server returns none", ["--refresh-keeps-token"]) { fixture, directory in
        let client = makeClient(directory)
        let credential = try await signIn(fixture, client)
        let refreshed = try await client.refresh(credential)
        expectTrue(refreshed.accessToken != credential.accessToken, "no new access token")
        expectEqual(refreshed.refreshToken, credential.refreshToken)
        expectEqual(client.credential(for: mcpURL(fixture))?.refreshToken, credential.refreshToken)
        expectTrue(try await client.refresh(refreshed).accessToken != refreshed.accessToken, "the kept refresh token no longer works")
    }

    fixtureTest("refresh: a 401 on a revoked token refreshes, and the new token works") { fixture, directory in
        let client = makeClient(directory)
        let credential = try await signIn(fixture, client)
        var revoke = URLRequest(url: fixture.baseURL.appendingPathComponent("test/revoke"))
        revoke.httpMethod = "POST"
        _ = try await browserSession.data(for: revoke)

        let rejected = try await postMCP(fixture, authorization: "Bearer \(credential.accessToken)")
        expectEqual(rejected.status, 401)
        let provider = OAuthAuthProvider(client: client)
        expectTrue(await provider.handleUnauthorized(url: mcpURL(fixture), challenge: rejected.challenge), "handleUnauthorized returned false")
        let header = try await provider.authorizationHeader(for: mcpURL(fixture))
        expectTrue(header != "Bearer \(credential.accessToken)", "still the revoked token")
        expectEqual(try await postMCP(fixture, authorization: header).status, 200)
    }

    fixtureTest("refresh: a rejected refresh token means sign in again", ["--refresh-fails"]) { fixture, directory in
        let client = makeClient(directory)
        let credential = try await signIn(fixture, client)
        expectTrue(!(await OAuthAuthProvider(client: client).handleUnauthorized(url: mcpURL(fixture), challenge: nil)),
                   "handleUnauthorized returned true after a failed refresh")
        let error = await thrownError { _ = try await client.refresh(credential) }
        guard case let .oauth(.refreshFailed(detail))? = error as? MCPClientError else {
            return fail("expected refreshFailed, got \(String(describing: error))")
        }
        expectTrue(detail.contains("invalid_grant") && detail.contains("Sign in again"), "detail: \(detail)")
        expectEqual(client.credential(for: mcpURL(fixture)), credential)
    }

    fixtureTest("refresh: insufficient scope and missing credentials are not retried") { fixture, directory in
        let client = makeClient(directory)
        _ = try await signIn(fixture, client)
        let provider = OAuthAuthProvider(client: client)
        let scopeChallenge = #"Bearer error="insufficient_scope", scope="mcp:admin""#
        expectTrue(!(await provider.handleUnauthorized(url: mcpURL(fixture), challenge: scopeChallenge)),
                   "insufficient_scope was treated as refreshable")
        expectEqual(try await refreshGrants(fixture), 0)

        let unknown = fixture.baseURL.appendingPathComponent("other")
        expectEqual(try await provider.authorizationHeader(for: unknown), nil)
        expectTrue(!(await provider.handleUnauthorized(url: unknown, challenge: nil)), "no credential, yet a retry was offered")
    }

    fixtureTest("refresh: concurrent requests on an expired token share one refresh",
                ["--expires-in", "1", "--token-delay", "0.3"]) { fixture, directory in
        let client = makeClient(directory)
        let credential = try await signIn(fixture, client)
        let provider = OAuthAuthProvider(client: client)
        async let first = provider.authorizationHeader(for: mcpURL(fixture))
        async let second = provider.authorizationHeader(for: mcpURL(fixture))
        let headers = try await [first, second]
        expectEqual(try await refreshGrants(fixture), 1)
        expectEqual(headers[0], headers[1])
        expectTrue(headers[0] != "Bearer \(credential.accessToken)", "the expired token was sent")
        expectEqual(try await postMCP(fixture, authorization: headers[0]).status, 200)
    }
}
