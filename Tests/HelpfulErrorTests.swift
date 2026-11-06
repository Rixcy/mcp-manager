import Foundation

func runHelpfulErrorTests() {
    runConfigErrorTests()
    runProcessErrorTests()
    runHTTPErrorTests()
    runProtocolErrorTests()
    runOAuthErrorTests()
    runCoverageTests()
}

/// Everything a user can read, so assertions don't depend on which field carries a hint.
private func allText(_ help: HelpfulError) -> String {
    ([help.title, help.message] + help.suggestions + [help.details ?? ""]).joined(separator: "\n")
}

private func suggestionText(_ help: HelpfulError) -> String {
    help.suggestions.joined(separator: "\n")
}

private func expectMentions(_ help: HelpfulError, _ fragments: [String], file: StaticString = #fileID, line: UInt = #line) {
    let text = allText(help)
    for fragment in fragments where !text.localizedCaseInsensitiveContains(fragment) {
        fail("expected “\(fragment)” in:\n\(text)", file: file, line: line)
    }
}

// MARK: Config and launch

private func runConfigErrorTests() {
    test("helpful: missing variables are named as ${NAME} and point at Environment") {
        let help = MCPClientError.missingVariables(["LINEAR_API_KEY", "LINEAR_TEAM"]).helpful
        expectTrue(help.message.contains("${LINEAR_API_KEY}") && help.message.contains("${LINEAR_TEAM}"), help.message)
        expectTrue(suggestionText(help).contains("Environment"), "suggests the Environment tab")
        expectTrue(suggestionText(help).contains("shell"), "suggests the shell startup file")
        expectTrue(help.offersEnvironment, "offers Environment")
        expectTrue(!help.offersSignIn, "signing in doesn't set variables")
        expectTrue(MCPClientError.missingVariables(["ONE"]).helpful.title != help.title, "singular and plural titles differ")
    }

    test("helpful: command not found explains the GUI PATH, lists it, and hints at installs") {
        let path = ["/usr/bin", "/bin", "/opt/homebrew/bin"]
        let npx = MCPClientError.commandNotFound(command: "npx", searchedPath: path).helpful
        expectTrue(npx.message.contains("npx"), npx.message)
        expectMentions(npx, ["login shell", "which npx"])
        expectTrue(suggestionText(npx).contains("Node.js"), "npx hint mentions Node.js")
        let details = npx.details ?? ""
        expectTrue(path.allSatisfy { details.contains($0) }, "details list the searched PATH: \(details)")
        expectTrue(npx.offersEnvironment, "PATH is fixable under Environment")

        expectTrue(suggestionText(MCPClientError.commandNotFound(command: "uvx", searchedPath: path).helpful).contains("brew install uv"),
                   "uvx hint")
        expectTrue(suggestionText(MCPClientError.commandNotFound(command: "docker", searchedPath: path).helpful).contains("Docker Desktop"),
                   "docker hint")
        let custom = MCPClientError.commandNotFound(command: "my-server", searchedPath: path).helpful
        expectTrue(!allText(custom).contains("Node.js") && !allText(custom).contains("brew install uv"),
                   "no install hint for an unknown command")

        let absolute = MCPClientError.commandNotFound(command: "/opt/tools/server", searchedPath: []).helpful
        expectTrue(absolute.message.contains("/opt/tools/server"), absolute.message)
        expectTrue(!absolute.message.contains("PATH"), "a full path isn't searched on PATH")
    }

    test("helpful: not executable suggests chmod +x or an interpreter") {
        let help = MCPClientError.commandNotExecutable(path: "/Users/me/server.py").helpful
        expectTrue(help.message.contains("/Users/me/server.py"), help.message)
        expectTrue(suggestionText(help).contains("chmod +x /Users/me/server.py"), "chmod hint")
        expectTrue(suggestionText(help).contains("python3"), "interpreter hint")
    }

    test("helpful: invalid URL quotes the configured URL") {
        let help = MCPClientError.invalidURL("${BASE}/mcp").helpful
        expectTrue(help.message.contains("${BASE}/mcp"), help.message)
        expectTrue(suggestionText(help).contains("https://"), "shows the expected form")
    }
}

// MARK: stdio processes

private func runProcessErrorTests() {
    test("helpful: exits before and after the handshake read differently and carry stderr") {
        let tail = ["Starting server", "Error: Missing API key: set EXAMPLE_API_KEY"]
        let startup = MCPClientError.processExited(ProcessExit(code: 1), stderrTail: tail, stage: .initialize).helpful
        let later = MCPClientError.processExited(ProcessExit(code: 1), stderrTail: tail, stage: .request).helpful
        let launch = MCPClientError.processExited(ProcessExit(code: 1), stderrTail: tail, stage: .launch).helpful
        expectTrue(startup.title != later.title, "startup and request titles differ")
        expectEqual(launch.title, startup.title)
        expectTrue(startup.message.contains("1"), "names the exit code: \(startup.message)")
        expectEqual(startup.details, tail.joined(separator: "\n"))
        expectTrue(startup.offersEnvironment, "a missing API key is fixed under Environment")
        expectTrue(suggestionText(startup).contains("Environment"), "the hint says where")
    }

    test("helpful: stderr patterns produce one targeted hint each") {
        func hint(_ line: String, exit: ProcessExit = ProcessExit(code: 1)) -> HelpfulError {
            MCPClientError.processExited(exit, stderrTail: [line], stage: .launch).helpful
        }
        let module = hint("Error: Cannot find module '@modelcontextprotocol/sdk'")
        expectTrue(suggestionText(module).contains("dependency"), suggestionText(module))
        expectTrue(!module.offersEnvironment, "a missing module isn't fixed by a variable")
        expectTrue(suggestionText(hint("ModuleNotFoundError: No module named 'mcp'")).contains("dependency"), "python module")
        expectTrue(suggestionText(hint("Error: listen EADDRINUSE: address already in use :::3000")).contains("port"), "port in use")
        expectTrue(suggestionText(hint("npm error 404 Not Found - GET https://registry.npmjs.org/@acme%2fmcp")).contains("package"),
                   "npm 404")
        let missingTool = hint("sh: uvx: command not found")
        expectTrue(suggestionText(missingTool).contains("PATH") && missingTool.offersEnvironment, "command inside the server")
        let syntax = hint("SyntaxError: Unexpected token '?'")
        expectTrue(!syntax.offersEnvironment && !suggestionText(syntax).contains("API key"),
                   "a JavaScript syntax error isn't mistaken for a credentials problem")
        let killed = MCPClientError.processExited(ProcessExit(signal: 9), stderrTail: [], stage: .request).helpful
        expectMentions(killed, ["SIGKILL"])
        expectTrue(killed.details == nil, "no stderr, no details")
    }

    test("helpful: non-JSON stdout quotes the line and explains stderr") {
        let help = MCPClientError.invalidServerOutput(line: "Server listening on stdio", stage: .initialize).helpful
        expectTrue(help.message.contains("Server listening on stdio"), help.message)
        expectMentions(help, ["stderr", "quiet"])
    }

    test("helpful: launch failures and oversized messages carry their values") {
        let launch = MCPClientError.launchFailed(command: "/usr/local/bin/srv", detail: "Operation not permitted").helpful
        expectTrue(launch.message.contains("/usr/local/bin/srv") && launch.message.contains("Operation not permitted"), launch.message)
        let large = MCPClientError.messageTooLarge(bytes: 120 * 1_048_576).helpful
        expectTrue(large.message.contains("120.0 MB"), large.message)
    }
}

// MARK: HTTP and network

private func runHTTPErrorTests() {
    test("helpful: HTTP statuses get specific advice and the body in details") {
        let sse404 = MCPClientError.httpStatus(code: 404, url: "https://mcp.example.com/sse", body: "Not Found", stage: .initialize).helpful
        expectTrue(suggestionText(sse404).contains("SSE"), "a /sse URL suggests the SSE transport")
        expectTrue(sse404.message.contains("404"), sse404.message)
        expectEqual(sse404.details?.contains("Not Found"), true)

        let plain404 = MCPClientError.httpStatus(code: 404, url: "https://mcp.example.com/api", body: nil, stage: .initialize).helpful
        expectTrue(suggestionText(plain404).contains("/mcp") && !suggestionText(plain404).contains("SSE"), suggestionText(plain404))
        expectTrue(suggestionText(MCPClientError.httpStatus(code: 405, url: "https://x.dev/sse", body: nil, stage: .initialize).helpful)
            .contains("SSE"), "405 on /sse")
        expectTrue(suggestionText(MCPClientError.httpStatus(code: 429, url: "https://x.dev/mcp", body: nil, stage: .request).helpful)
            .contains("rate limit"), "429")
        let server = MCPClientError.httpStatus(code: 503, url: "https://x.dev/mcp", body: "upstream down", stage: .request).helpful
        expectTrue(server.title.contains("503") && suggestionText(server).contains("server's side"), allText(server))
        expectEqual(server.details?.contains("upstream down"), true)
        expectTrue(MCPClientError.httpStatus(code: 401, url: "https://x.dev/mcp", body: nil, stage: .request).helpful.offersSignIn,
                   "401 offers sign-in")
        let forbidden = MCPClientError.httpStatus(code: 403, url: "https://x.dev/mcp", body: nil, stage: .request).helpful
        expectTrue(suggestionText(forbidden).contains("permissions"), "403")
        expectTrue(suggestionText(MCPClientError.httpStatus(code: 415, url: "https://x.dev/mcp", body: nil, stage: .request).helpful)
            .contains("content type"), "415")
    }

    test("helpful: network errors name the host and port") {
        let local = MCPClientError.network(code: URLError.cannotConnectToHost.rawValue, url: "http://localhost:3001/mcp",
                                           detail: "Could not connect to the server.").helpful
        expectTrue(local.message.contains("localhost:3001"), local.message)
        expectTrue(suggestionText(local).contains("Start the local server"), suggestionText(local))

        let remote = MCPClientError.network(code: URLError.cannotConnectToHost.rawValue, url: "https://mcp.example.com/mcp",
                                            detail: "Could not connect to the server.").helpful
        expectTrue(remote.message.contains("mcp.example.com:443"), remote.message)
        expectTrue(!suggestionText(remote).contains("local server"), "a remote host isn't a local server")

        let dns = MCPClientError.network(code: URLError.cannotFindHost.rawValue, url: "https://mcp.exmaple.com/mcp", detail: "x").helpful
        expectTrue(dns.message.contains("mcp.exmaple.com"), dns.message)
        let tls = MCPClientError.network(code: URLError.serverCertificateUntrusted.rawValue, url: "https://intra.corp/mcp", detail: "x").helpful
        expectMentions(tls, ["certificate", "intra.corp"])
        let ats = MCPClientError.network(code: URLError.appTransportSecurityRequiresSecureConnection.rawValue,
                                         url: "http://mcp.example.com/mcp", detail: "x").helpful
        expectTrue(suggestionText(ats).contains("https://"), "ATS suggests HTTPS")
        let offline = MCPClientError.network(code: URLError.notConnectedToInternet.rawValue, url: "https://a.dev", detail: "x").helpful
        let lost = MCPClientError.network(code: URLError.networkConnectionLost.rawValue, url: "https://a.dev", detail: "x").helpful
        let slow = MCPClientError.network(code: URLError.timedOut.rawValue, url: "https://a.dev", detail: "x").helpful
        expectEqual(Set([offline.title, lost.title, slow.title, tls.title, dns.title]).count, 5, "each failure gets its own title")
    }

    test("helpful: authorization and sessions") {
        let auth = MCPClientError.authorizationRequired(url: "https://mcp.linear.app/mcp", challenge: "Bearer realm=\"linear\"").helpful
        expectTrue(auth.offersSignIn, "offers sign-in")
        expectTrue(auth.message.contains("mcp.linear.app"), auth.message)
        let expired = MCPClientError.authorizationRequired(
            url: "https://mcp.linear.app/mcp", challenge: "Bearer error=\"invalid_token\", error_description=\"expired\"").helpful
        expectTrue(expired.message.contains("again") && expired.message != auth.message, expired.message)
        expectEqual(expired.details?.contains("invalid_token"), true)
        let session = MCPClientError.sessionExpired(url: "https://mcp.linear.app/mcp").helpful
        expectTrue(suggestionText(session).contains("Reconnect"), "reconnect")
    }
}

// MARK: Protocol

private func runProtocolErrorTests() {
    test("helpful: timeouts depend on the method") {
        let initialize = MCPClientError.timedOut(method: "initialize", seconds: 60).helpful
        expectMentions(initialize, ["60 s", "npx", "Logs", "transport"])
        let call = MCPClientError.timedOut(method: "tools/call", seconds: 300).helpful
        expectMentions(call, ["5 minutes", "cancel"])
        let other = MCPClientError.timedOut(method: "resources/read", seconds: 30).helpful
        expectTrue(other.message.contains("resources/read") && other.message.contains("30 s"), other.message)
    }

    test("helpful: JSON-RPC errors map by code and keep data in details") {
        let unsupported = MCPClientError.rpcError(method: "prompts/list", code: -32601, message: "Method not found", data: nil).helpful
        expectTrue(unsupported.title == "Not supported" && unsupported.message.contains("prompts/list"), allText(unsupported))
        let invalid = MCPClientError.rpcError(method: "tools/call", code: -32602, message: "query is required",
                                              data: "{\"field\":\"query\"}").helpful
        expectTrue(invalid.message.contains("query is required"), invalid.message)
        expectEqual(invalid.details?.contains("{\"field\":\"query\"}"), true)
        let resource = MCPClientError.rpcError(method: "resources/read", code: -32002, message: "No such file", data: nil).helpful
        expectTrue(resource.title.contains("Resource"), resource.title)
        let serverTitles = [-32603, -32000, -32050, -32099].map {
            MCPClientError.rpcError(method: "tools/call", code: $0, message: "boom", data: nil).helpful.title
        }
        expectEqual(Set(serverTitles), ["Server error"])
        let generic = MCPClientError.rpcError(method: "tools/call", code: 42, message: "odd", data: nil).helpful
        expectTrue(generic.title != "Server error" && generic.message.contains("42"), allText(generic))
    }

    test("helpful: protocol version, capabilities and cancellation") {
        let version = MCPClientError.unsupportedProtocolVersion("2023-01-01").helpful
        expectTrue(version.message.contains("2023-01-01"), version.message)
        for supported in MCPProtocolVersion.supported {
            expectTrue(version.message.contains(supported), "lists \(supported)")
        }
        expectEqual(MCPClientError.capabilityMissing("tools").helpful.message, "This server doesn't offer tools.")
        expectEqual(HelpfulError(CancellationError()), MCPClientError.cancelled.helpful)
    }
}

// MARK: OAuth

private func runOAuthErrorTests() {
    test("helpful: OAuth failures carry their values and the right action") {
        let unsupported = MCPClientError.oauth(.registrationUnsupported(issuer: "https://auth.example.com")).helpful
        expectMentions(unsupported, ["https://auth.example.com", "clientId", "callbackPort"])
        let callback = OAuthFailure.callbackServerFailed("port 8765: Address already in use").helpful
        expectTrue(suggestionText(callback).contains("8765"), "names the port: \(suggestionText(callback))")
        expectTrue(OAuthFailure.refreshFailed("invalid_grant").helpful.offersSignIn, "refresh failure offers sign-in")
        expectMentions(OAuthFailure.credentialStore("errSecInteractionNotAllowed").helpful, ["Keychain", "errSecInteractionNotAllowed"])
        expectMentions(OAuthFailure.discoveryFailed(url: "https://mcp.example.com/.well-known/oauth-protected-resource",
                                                    detail: "HTTP 404").helpful, ["mcp.example.com", "HTTP 404"])
        expectMentions(OAuthFailure.insecureEndpoint("http://auth.example.com/token").helpful, ["http://auth.example.com/token", "HTTPS"])
        expectMentions(OAuthFailure.browserTimedOut(seconds: 300).helpful, ["5 minutes"])
        expectMentions(OAuthFailure.denied(error: "access_denied", description: "User cancelled").helpful, ["access_denied", "User cancelled"])
        let grant = OAuthFailure.tokenRequestFailed(status: 400, error: "invalid_grant", description: "code expired").helpful
        expectMentions(grant, ["400", "invalid_grant", "code expired"])
        expectTrue(grant.offersSignIn, "signing in again gets a new code")
        expectMentions(OAuthFailure.registrationFailed(status: 403, detail: "registration disabled").helpful, ["403", "registration disabled"])
    }

    test("helpful: HelpfulError(error) maps every error family") {
        let urlError = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://127.0.0.1:4555/mcp")!])
        let network = HelpfulError(urlError)
        expectTrue(network.message.contains("127.0.0.1:4555"), network.message)
        expectTrue(suggestionText(network).contains("Start the local server"), "loopback hint via URLError")

        let config = HelpfulError(MCPManagerError.parse(path: "/Users/me/.claude.json", detail: "line 3"))
        expectEqual(config.title, "Config error")
        expectTrue(config.message.contains("/Users/me/.claude.json") && config.message.contains("line 3"), config.message)

        let other = HelpfulError(NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Disk is on fire"]))
        expectTrue(!other.title.isEmpty && other.message.contains("Disk is on fire"), allText(other))

        let client = HelpfulError(MCPClientError.missingVariables(["TOKEN"]) as Error)
        expectTrue(client.offersEnvironment && client.message.contains("${TOKEN}"), "client errors keep their mapping")
    }
}

// MARK: Coverage

/// Exhaustive, so a new case fails to compile until it is listed below.
private func caseName(_ error: MCPClientError) -> String {
    switch error {
    case .missingVariables: return "missingVariables"
    case .invalidURL: return "invalidURL"
    case .commandNotFound: return "commandNotFound"
    case .commandNotExecutable: return "commandNotExecutable"
    case .launchFailed: return "launchFailed"
    case .processExited: return "processExited"
    case .invalidServerOutput: return "invalidServerOutput"
    case .messageTooLarge: return "messageTooLarge"
    case .httpStatus: return "httpStatus"
    case .network: return "network"
    case .authorizationRequired: return "authorizationRequired"
    case .sessionExpired: return "sessionExpired"
    case .timedOut: return "timedOut"
    case .rpcError: return "rpcError"
    case .malformedResponse: return "malformedResponse"
    case .unsupportedProtocolVersion: return "unsupportedProtocolVersion"
    case .capabilityMissing: return "capabilityMissing"
    case .connectionClosed: return "connectionClosed"
    case .notConnected: return "notConnected"
    case .cancelled: return "cancelled"
    case .oauth: return "oauth"
    case .invalidArguments: return "invalidArguments"
    }
}

private func caseName(_ failure: OAuthFailure) -> String {
    switch failure {
    case .discoveryFailed: return "discoveryFailed"
    case .registrationUnsupported: return "registrationUnsupported"
    case .registrationFailed: return "registrationFailed"
    case .insecureEndpoint: return "insecureEndpoint"
    case .callbackServerFailed: return "callbackServerFailed"
    case .browserTimedOut: return "browserTimedOut"
    case .denied: return "denied"
    case .stateMismatch: return "stateMismatch"
    case .tokenRequestFailed: return "tokenRequestFailed"
    case .refreshFailed: return "refreshFailed"
    case .credentialStore: return "credentialStore"
    }
}

private let representativeOAuthFailures: [OAuthFailure] = [
    .discoveryFailed(url: "https://a.dev/.well-known/oauth-authorization-server", detail: "HTTP 500"),
    .registrationUnsupported(issuer: "https://auth.a.dev"),
    .registrationFailed(status: nil, detail: "connection reset"),
    .insecureEndpoint("http://auth.a.dev/authorize"),
    .callbackServerFailed("bind failed"),
    .browserTimedOut(seconds: 45),
    .denied(error: "server_error", description: nil),
    .stateMismatch,
    .tokenRequestFailed(status: nil, error: nil, description: nil),
    .refreshFailed("HTTP 400"),
    .credentialStore("errSecAuthFailed"),
]

private let representativeClientErrors: [MCPClientError] = [
    .missingVariables(["A"]),
    .invalidURL("not a url"),
    .commandNotFound(command: "npx", searchedPath: ["/usr/bin"]),
    .commandNotExecutable(path: "/tmp/x"),
    .launchFailed(command: "srv", detail: "ENOENT"),
    .processExited(ProcessExit(code: nil, signal: nil), stderrTail: [], stage: .launch),
    .invalidServerOutput(line: "hello", stage: .request),
    .messageTooLarge(bytes: 10),
    .httpStatus(code: 418, url: "https://a.dev/mcp", body: "", stage: .request),
    .network(code: -1, url: "", detail: "unknown"),
    .authorizationRequired(url: "https://a.dev/mcp", challenge: nil),
    .sessionExpired(url: "https://a.dev/mcp"),
    .timedOut(method: "ping", seconds: 5),
    .rpcError(method: "ping", code: -32700, message: "Parse error", data: nil),
    .malformedResponse(method: "tools/list", detail: "missing tools"),
    .unsupportedProtocolVersion("1999-01-01"),
    .capabilityMissing("prompts"),
    .connectionClosed(detail: nil),
    .notConnected,
    .cancelled,
    .oauth(.stateMismatch),
    .invalidArguments("limit must be a number"),
]

private func runCoverageTests() {
    test("helpful: every client error and OAuth failure has a title and a message") {
        let clientCases = Set(representativeClientErrors.map(caseName))
        expectEqual(clientCases.count, 22, "the list covers every MCPClientError case")
        let oauthCases = Set(representativeOAuthFailures.map(caseName))
        expectEqual(oauthCases.count, 11, "the list covers every OAuthFailure case")

        let all = representativeClientErrors + representativeOAuthFailures.map(MCPClientError.oauth)
        for error in all {
            let help = error.helpful
            expectTrue(!help.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(error) has no title")
            expectTrue(!help.message.trimmingCharacters(in: .whitespaces).isEmpty, "\(error) has no message")
            expectTrue(help.title != "Something went wrong", "\(error) falls through to the generic text")
            expectTrue(!(error.errorDescription ?? "").isEmpty, "\(error) has an errorDescription")
        }
    }
}
