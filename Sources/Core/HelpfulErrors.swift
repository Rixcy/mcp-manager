import Foundation

extension MCPClientError {
    public var helpful: HelpfulError {
        switch self {
        case let .missingVariables(names):
            return HelpfulCatalogue.missingVariables(names)
        case let .invalidURL(url):
            var suggestions = ["Edit the URL so it starts with https:// (or http:// for a local server) and includes a host, for example https://example.com/mcp."]
            if url.contains("${") {
                suggestions.append("Check that the variables in the URL expand to a full address.")
            }
            return HelpfulError(title: "Invalid server URL",
                                message: "“\(url)” is not a usable http:// or https:// URL.",
                                suggestions: suggestions, details: url)
        case let .commandNotFound(command, searchedPath):
            return HelpfulCatalogue.commandNotFound(command, searchedPath: searchedPath)
        case let .commandNotExecutable(path):
            return HelpfulError(
                title: "Command can't be run",
                message: "\(path) exists, but it isn't an executable file.",
                suggestions: [
                    "If it's a script, make it executable: run `chmod +x \(path)` in Terminal.",
                    "Or run it through its interpreter: set the command to node, python3 or bash and put \(path) first in the arguments.",
                ],
                details: path)
        case let .launchFailed(command, detail):
            return HelpfulError(
                title: "Server failed to start",
                message: "MCP Manager couldn't start \(command): \(detail).",
                suggestions: ["Check that the same command runs in Terminal.", "Open Logs for the full launch output."],
                details: detail)
        case let .processExited(exit, stderrTail, stage):
            return HelpfulCatalogue.processExited(exit, stderrTail: stderrTail, stage: stage)
        case let .invalidServerOutput(line, _):
            let quoted = line.count > 200 ? String(line.prefix(200)) + "…" : line
            return HelpfulError(
                title: "Server printed non-JSON output",
                message: "The server wrote “\(quoted)” to stdout. stdout is reserved for JSON-RPC messages; logs and banners belong on stderr.",
                suggestions: [
                    "Check the server's docs for a quiet, --stdio or log-level option and add it to the arguments.",
                    "If you maintain the server, send log output to stderr (console.error in Node, print(..., file=sys.stderr) in Python).",
                ],
                details: line)
        case let .messageTooLarge(bytes):
            return HelpfulError(
                title: "Message too large",
                message: "The server sent a \(HelpfulCatalogue.byteSize(bytes)) message, more than MCP Manager accepts.",
                suggestions: ["Ask for less at once: narrow the query, or use the tool's paging or limit arguments."],
                details: "\(bytes) bytes")
        case let .httpStatus(code, url, body, _):
            return HelpfulCatalogue.httpStatus(code, url: url, body: body)
        case let .network(code, url, detail):
            return HelpfulCatalogue.network(code, url: url, detail: detail)
        case let .authorizationRequired(url, challenge):
            let host = HelpfulCatalogue.hostLabel(url)
            let invalidToken = challenge?.range(of: #"error\s*=\s*"?invalid_token"#, options: [.regularExpression, .caseInsensitive]) != nil
            return HelpfulError(
                title: "Sign-in required",
                message: invalidToken
                    ? "\(host) rejected the saved credentials (invalid_token). Sign in again to get new ones."
                    : "\(host) needs you to sign in before MCP Manager can connect.",
                suggestions: [
                    "Click Sign in to authorize MCP Manager in your browser.",
                    "If the server takes an API key instead, add an Authorization header to the config or set its bearer token variable under Environment.",
                ],
                details: challenge.map { "WWW-Authenticate: \($0)" },
                offersSignIn: true)
        case let .sessionExpired(url):
            return HelpfulError(
                title: "Session expired",
                message: "\(HelpfulCatalogue.hostLabel(url)) ended the MCP session.",
                suggestions: ["Reconnect to start a new session."],
                details: url)
        case let .timedOut(method, seconds):
            return HelpfulCatalogue.timedOut(method, seconds: seconds)
        case let .rpcError(method, code, message, data):
            return HelpfulCatalogue.rpcError(method, code: code, message: message, data: data)
        case let .malformedResponse(method, detail):
            return HelpfulError(
                title: "Unexpected response",
                message: "The server's answer to \(method) doesn't match the MCP specification.",
                suggestions: ["Update the server to its latest version.", "Open Logs to see the raw response."],
                details: detail)
        case let .unsupportedProtocolVersion(version):
            let supported = MCPProtocolVersion.supported.sorted().joined(separator: ", ")
            return HelpfulError(
                title: "Unsupported protocol version",
                message: "The server uses MCP protocol version \(version). MCP Manager supports \(supported).",
                suggestions: ["Update the server (or MCP Manager) so both support the same protocol version."],
                details: "Server: \(version)\nSupported: \(supported)")
        case let .capabilityMissing(capability):
            return HelpfulError(title: "No \(capability)", message: "This server doesn't offer \(capability).")
        case let .connectionClosed(detail):
            return HelpfulError(
                title: "Connection closed",
                message: "The connection to the server closed unexpectedly.",
                suggestions: ["Reconnect.", "Open Logs to see the last messages before it closed."],
                details: detail)
        case .notConnected:
            return HelpfulError(title: "Not connected", message: "This server isn't connected.",
                                suggestions: ["Click Connect, then try again."])
        case .cancelled:
            return HelpfulError(title: "Cancelled", message: "The request was cancelled before it finished.")
        case let .oauth(failure):
            return failure.helpful
        case let .invalidArguments(detail):
            return HelpfulError(
                title: "Invalid arguments",
                message: detail,
                suggestions: ["Check the arguments against the input schema and try again."])
        }
    }
}

extension OAuthFailure {
    public var helpful: HelpfulError {
        switch self {
        case let .discoveryFailed(url, detail):
            return HelpfulError(
                title: "Couldn't find sign-in details",
                message: "MCP Manager couldn't read the OAuth metadata for \(HelpfulCatalogue.hostLabel(url)).",
                suggestions: [
                    "Check that the server URL is right.",
                    "If the server takes an API key instead of OAuth, add it as a header or set its bearer token variable under Environment.",
                ],
                details: "\(url)\n\(detail)")
        case let .registrationUnsupported(issuer):
            return HelpfulError(
                title: "Server needs a registered client",
                message: "\(issuer) doesn't let apps register themselves, so MCP Manager needs an OAuth client ID to sign in.",
                suggestions: [
                    "If Claude Code can sign in to this server, add the same client to the server's Claude config: \"oauth\": {\"clientId\": \"…\", \"callbackPort\": …}.",
                    "Otherwise register an OAuth app with the provider, using http://localhost:<port>/callback as the redirect URL, and add its client ID and port the same way.",
                ],
                details: "Issuer: \(issuer)")
        case let .registrationFailed(status, detail):
            return HelpfulError(
                title: "Client registration failed",
                message: "The authorization server refused to register MCP Manager as an OAuth client\(status.map { " (HTTP \($0))" } ?? "").",
                suggestions: [
                    "Sign in again; if it keeps failing, add a pre-registered client (oauth.clientId and oauth.callbackPort) to the server's Claude config.",
                ],
                details: detail,
                offersSignIn: true)
        case let .insecureEndpoint(url):
            return HelpfulError(
                title: "Insecure sign-in endpoint",
                message: "The server's OAuth endpoint \(url) isn't HTTPS, so MCP Manager won't send credentials to it.",
                suggestions: ["Ask the server's maintainers to serve OAuth over HTTPS. Plain HTTP is only allowed for localhost."],
                details: url)
        case let .callbackServerFailed(detail):
            var suggestions: [String]
            if let port = HelpfulCatalogue.port(in: detail) {
                suggestions = [
                    "Port \(port) is probably in use by another app, often another sign-in in progress (Claude Code uses the same port). Finish or close it, then sign in again.",
                    "Or set a different oauth.callbackPort in the server's Claude config, if the provider allows it.",
                ]
            } else {
                suggestions = ["Sign in again. If it keeps failing, another app may be using the callback port."]
            }
            return HelpfulError(
                title: "Sign-in callback couldn't start",
                message: "MCP Manager couldn't listen for the browser's sign-in callback: \(detail).",
                suggestions: suggestions,
                details: detail,
                offersSignIn: true)
        case let .browserTimedOut(seconds):
            return HelpfulError(
                title: "Sign-in timed out",
                message: "The browser didn't return from sign-in within \(HelpfulCatalogue.duration(seconds)).",
                suggestions: ["Click Sign in to try again, and finish signing in in the browser window that opens."],
                offersSignIn: true)
        case let .denied(error, description):
            let reason = description.map { "\(error): \($0)" } ?? error
            return HelpfulError(
                title: "Sign-in denied",
                message: "The authorization server didn't grant access (\(reason)).",
                suggestions: [error == "access_denied"
                    ? "Access was declined in the browser. Sign in again and approve the request."
                    : "Sign in again. If it keeps failing, check that your account has access to this server."],
                details: reason,
                offersSignIn: true)
        case .stateMismatch:
            return HelpfulError(
                title: "Sign-in response didn't match",
                message: "The browser returned a sign-in response that doesn't belong to this attempt, so MCP Manager ignored it.",
                suggestions: ["Sign in again and finish only in the newest browser tab."],
                offersSignIn: true)
        case let .tokenRequestFailed(status, error, description):
            let parts = [status.map { "HTTP \($0)" }, error, description].compactMap { $0 }
            let reason = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
            return HelpfulError(
                title: "Couldn't get an access token",
                message: "The token endpoint refused the request\(reason).",
                suggestions: [error == "invalid_grant"
                    ? "The sign-in code expired or was already used. Sign in again."
                    : "Sign in again. If it keeps failing, the server's OAuth setup may be broken; check with its maintainers."],
                details: parts.isEmpty ? nil : parts.joined(separator: "\n"),
                offersSignIn: true)
        case let .refreshFailed(detail):
            return HelpfulError(
                title: "Sign-in expired",
                message: "MCP Manager couldn't refresh the saved access token, so you need to sign in again.",
                suggestions: ["Click Sign in."],
                details: detail,
                offersSignIn: true)
        case let .credentialStore(detail):
            return HelpfulError(
                title: "Keychain error",
                message: "MCP Manager couldn't read or save sign-in credentials in the Keychain: \(detail).",
                suggestions: [
                    "Unlock the login keychain in Keychain Access, then try again.",
                    "If you clicked Deny on a Keychain prompt, connect again and click Allow.",
                ],
                details: detail)
        }
    }
}

extension HelpfulError {
    /// Any error the client can hit, including config errors from `MCPManagerError`.
    public init(_ error: Error) {
        switch error {
        case let client as MCPClientError:
            self = client.helpful
        case is CancellationError:
            self = MCPClientError.cancelled.helpful
        case let urlError as URLError:
            let url = urlError.failingURL?.absoluteString
                ?? (urlError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
            self = MCPClientError.network(code: urlError.code.rawValue, url: url, detail: urlError.localizedDescription).helpful
        case let config as MCPManagerError:
            self.init(title: "Config error", message: config.errorDescription ?? String(describing: config))
        default:
            self.init(title: "Something went wrong",
                      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// The longer mappings, kept out of the switch so each case reads on its own.
enum HelpfulCatalogue {
    static func missingVariables(_ names: [String]) -> HelpfulError {
        let references = names.map { "${\($0)}" }
        let list = listed(references)
        let single = names.count == 1
        return HelpfulError(
            title: single ? "Missing variable" : "Missing variables",
            message: single
                ? "This server's config uses \(list), but it isn't set in MCP Manager or your shell environment."
                : "This server's config uses \(list), but they aren't set in MCP Manager or your shell environment.",
            suggestions: [
                "Add \(list) under Environment for this server.",
                "Or export \(single ? "it" : "them") in your shell startup file (for example ~/.zshrc), then reload the shell environment.",
            ],
            details: references.joined(separator: "\n"),
            offersEnvironment: true)
    }

    static func commandNotFound(_ command: String, searchedPath: [String]) -> HelpfulError {
        let name = (command as NSString).lastPathComponent
        if searchedPath.isEmpty {
            return HelpfulError(
                title: "Command not found",
                message: "Nothing exists at \(command).",
                suggestions: ["Check the path, or run `which \(name)` in Terminal and use the full path it prints."],
                details: command,
                offersEnvironment: true)
        }
        var suggestions = ["Run `which \(name)` in Terminal and use the full path it prints as the command."]
        if let hint = installHint(name) { suggestions.append(hint) }
        suggestions.append("If you changed PATH in your shell startup file, reload the shell environment, or set PATH under Environment for this server.")
        return HelpfulError(
            title: "Command not found",
            message: "MCP Manager couldn't find “\(command)” on your PATH. Apps opened from the Dock or Finder don't inherit the PATH your terminal uses, so MCP Manager reads it from your login shell, and \(command) isn't in any of those folders.",
            suggestions: suggestions,
            details: "Searched PATH:\n" + searchedPath.joined(separator: "\n"),
            offersEnvironment: true)
    }

    static func installHint(_ command: String) -> String? {
        switch command {
        case "npx", "node", "npm":
            return "\(command) comes with Node.js. Install Node.js from nodejs.org or with `brew install node`."
        case "uvx", "uv":
            return "\(command) comes with uv. Install it with `brew install uv`."
        case "docker":
            return "Install Docker Desktop and open it once so the docker command is set up."
        case "bunx", "bun":
            return "\(command) comes with Bun. Install it with `brew install oven-sh/bun/bun` or from bun.sh."
        case "deno":
            return "Install Deno with `brew install deno`."
        case "python3", "python", "pip3", "pip":
            return "Install Python 3 with `brew install python`, or run `xcode-select --install` for Apple's python3."
        default:
            return nil
        }
    }

    static func processExited(_ exit: ProcessExit, stderrTail: [String], stage: MCPStage) -> HelpfulError {
        let startup = stage != .request
        let how = exit.signal.map { "was killed by \(signalName($0))" } ?? exit.code.map { "exited with code \($0)" } ?? "exited"
        let printed = stderrTail.isEmpty ? " It printed nothing to stderr." : ""
        let message = startup
            ? "The server process \(how) before it finished connecting.\(printed)"
            : "The server process \(how) while MCP Manager was waiting for a response.\(printed)"
        var suggestions: [String] = []
        var offersEnvironment = false
        if let hint = stderrHint(stderrTail.joined(separator: "\n"), exit: exit) {
            suggestions.append(hint.text)
            offersEnvironment = hint.offersEnvironment
        }
        suggestions.append(startup
            ? "Run the same command in Terminal to see the full error."
            : "Reconnect. If it keeps stopping, run the command in Terminal to see why.")
        suggestions.append("Open Logs for everything the server printed.")
        return HelpfulError(
            title: startup ? "Server exited during startup" : "Server stopped",
            message: message,
            suggestions: suggestions,
            details: stderrTail.isEmpty ? nil : stderrTail.joined(separator: "\n"),
            offersEnvironment: offersEnvironment)
    }

    private static func stderrHint(_ tail: String, exit: ProcessExit) -> (text: String, offersEnvironment: Bool)? {
        func matches(_ pattern: String) -> Bool {
            tail.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if matches(#"cannot find module|modulenotfounderror|no module named|missing module|module not found"#) {
            return ("The server is missing a dependency. Reinstall it (for npx servers, delete ~/.npm/_npx; for Python servers, reinstall the package) and connect again.", false)
        }
        if matches(#"eaddrinuse|address already in use"#) {
            return ("The server tried to open a port that is already in use. Quit whatever is using it (`lsof -i :<port>` shows it), or configure the server to use another port.", false)
        }
        if matches(#"npm (err!|error) (code )?e?404|\be404\b|is not in (this|the npm) registry|package not found|404 not found - get"#) {
            return ("npm couldn't find the package. Check the package name and version in the arguments.", false)
        }
        if matches(#"api[ _-]?key|access[ _-]?token|auth[ _-]?token|bearer token|(missing|invalid|no) token|token (is )?(required|missing|not set)|unauthori[sz]ed|credentials?\b"#) {
            return ("The server says it is missing credentials. Add the API key or token it needs under Environment for this server.", true)
        }
        if matches(#"command not found"#) {
            return ("The server tried to run a program that isn't on its PATH. Install that program, or add its folder to PATH under Environment for this server.", true)
        }
        if let signal = exit.signal {
            return ("The process was killed by \(signalName(signal)). If you didn't stop it, it may have crashed or run out of memory.", false)
        }
        return nil
    }

    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
                                      SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV", SIGKILL: "SIGKILL",
                                      SIGPIPE: "SIGPIPE", SIGTERM: "SIGTERM"]
        return names[signal].map { "signal \(signal) (\($0))" } ?? "signal \(signal)"
    }

    static func httpStatus(_ code: Int, url: String, body: String?) -> HelpfulError {
        let host = hostLabel(url)
        let endsInSSE = (URL(string: url)?.path ?? url).hasSuffix("/sse")
        let sseHint = "This URL ends in /sse, which usually means an SSE server. Change this server's transport to SSE."
        let title: String
        var suggestions: [String]
        var offersSignIn = false
        switch code {
        case 400:
            title = "Bad request (HTTP 400)"
            suggestions = ["Check the URL and headers in the config; some servers need a specific header or query parameter.",
                           "Open Logs to see the server's explanation."]
        case 401:
            title = "Unauthorized (HTTP 401)"
            suggestions = ["Sign in, or check the API key or token in the config."]
            offersSignIn = true
        case 403:
            title = "Access denied (HTTP 403)"
            suggestions = ["Your credentials were accepted but don't allow this. Check the account's or token's permissions or scopes, then sign in again if needed."]
        case 404:
            title = "Endpoint not found (HTTP 404)"
            suggestions = endsInSSE ? [sseHint] : ["Check the path in the URL; MCP endpoints usually end in /mcp."]
        case 405:
            title = "Method not allowed (HTTP 405)"
            suggestions = endsInSSE
                ? [sseHint]
                : ["The server doesn't accept MCP requests at this URL. Check that it's the MCP endpoint, which usually ends in /mcp."]
        case 406, 415:
            title = "Request format rejected (HTTP \(code))"
            suggestions = ["The server didn't accept the request's content type, so it may not speak Streamable HTTP. Check the URL is the MCP endpoint, or try the SSE transport."]
        case 408:
            title = "Request timed out (HTTP 408)"
            suggestions = ["Try again. If it keeps happening, the server may be overloaded."]
        case 429:
            title = "Rate limited (HTTP 429)"
            suggestions = ["You've hit the server's rate limit. Wait a minute, then try again."]
        case 500...599:
            title = "Server error (HTTP \(code))"
            suggestions = ["The server failed while handling the request; this is on the server's side. Try again later, or check the service's status page.",
                           "Open Logs for the response body."]
        default:
            title = "Unexpected HTTP \(code)"
            suggestions = ["Open Logs for the response body."]
        }
        let statusText = HTTPURLResponse.localizedString(forStatusCode: code)
        return HelpfulError(
            title: title,
            message: "\(host) answered \(url) with HTTP \(code) (\(statusText)).",
            suggestions: suggestions,
            details: body.flatMap { $0.isEmpty ? nil : "Response body:\n\(LogFormatting.detail(text: $0))" },
            offersSignIn: offersSignIn)
    }

    static func network(_ code: Int, url: String, detail: String) -> HelpfulError {
        let parsed = URL(string: url)
        let host = parsed?.host ?? ""
        let hostName = host.isEmpty ? "the server" : host
        let port = parsed?.port ?? (parsed?.scheme?.lowercased() == "http" ? 80 : 443)
        let endpoint = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let details = "\(detail) (URLError \(code))\(url.isEmpty ? "" : "\n\(url)")"
        let urlCode = URLError.Code(rawValue: code)
        switch urlCode {
        case .cannotFindHost, .dnsLookupFailed:
            return HelpfulError(
                title: "Server not found",
                message: "MCP Manager couldn't find the host \(hostName).",
                suggestions: ["Check the URL for typos.", "If the server is on a company network, connect to the VPN first."],
                details: details)
        case .cannotConnectToHost:
            if ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) {
                return HelpfulError(
                    title: "Local server isn't running",
                    message: "Nothing is listening on \(endpoint).",
                    suggestions: ["Start the local server, then connect again.", "Check that it listens on port \(port)."],
                    details: details)
            }
            return HelpfulError(
                title: "Couldn't connect",
                message: host.isEmpty ? "The server refused the connection." : "\(endpoint) refused the connection.",
                suggestions: ["Check that the server is running and the port in the URL is right.",
                              "If it's on a company network, connect to the VPN first."],
                details: details)
        case .timedOut:
            return HelpfulError(
                title: "Connection timed out",
                message: "\(hostName) didn't respond in time.",
                suggestions: ["Check your network or VPN connection, then try again.", "The server may be overloaded; try again in a minute."],
                details: details)
        case .notConnectedToInternet:
            return HelpfulError(
                title: "You're offline",
                message: "This Mac isn't connected to the internet, so MCP Manager can't reach \(hostName).",
                suggestions: ["Reconnect to a network, then try again."],
                details: details)
        case .networkConnectionLost:
            return HelpfulError(
                title: "Connection lost",
                message: "The connection to \(hostName) dropped partway through the request.",
                suggestions: ["Try again."],
                details: details)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return HelpfulError(
                title: "Secure connection failed",
                message: "MCP Manager couldn't make a trusted HTTPS connection to \(hostName).",
                suggestions: [
                    "If the server uses a self-signed or company certificate, trust it in Keychain Access, then try again.",
                    "Check that this Mac's date and time are correct.",
                ],
                details: details)
        case .appTransportSecurityRequiresSecureConnection:
            return HelpfulError(
                title: "Plain HTTP blocked",
                message: "macOS blocked the plain http:// connection to \(hostName).",
                suggestions: ["Use https:// if the server supports it. Plain HTTP only works for local servers (localhost or 127.0.0.1)."],
                details: details)
        case .cancelled:
            return MCPClientError.cancelled.helpful
        default:
            return HelpfulError(
                title: "Network error",
                message: "MCP Manager couldn't reach \(hostName): \(detail)",
                suggestions: ["Check your network connection and the URL, then try again."],
                details: details)
        }
    }

    static func timedOut(_ method: String, seconds: Int) -> HelpfulError {
        switch method {
        case "initialize":
            return HelpfulError(
                title: "Server didn't respond",
                message: "The server didn't answer initialize within \(duration(seconds)).",
                suggestions: [
                    "The first run of an npx or uvx server downloads packages and can be slow. Connect again once it finishes.",
                    "Open Logs to see what the server printed.",
                    "Make sure the server speaks this transport: a stdio server must read JSON-RPC on stdin, and an HTTP URL must be the MCP endpoint.",
                ])
        case "tools/call":
            return HelpfulError(
                title: "Tool call timed out",
                message: "The tool didn't finish within \(duration(seconds)), so MCP Manager asked the server to cancel it.",
                suggestions: ["Try again with a smaller input.", "Open Logs to see whether the server is still working."])
        default:
            return HelpfulError(
                title: "Request timed out",
                message: "The server didn't answer \(method) within \(duration(seconds)).",
                suggestions: ["Open Logs to see what the server is doing.", "Reconnect if the server seems stuck."])
        }
    }

    static func rpcError(_ method: String, code: Int, message: String, data: String?) -> HelpfulError {
        let details = "JSON-RPC error \(code): \(message)" + (data.map { "\nData: \($0)" } ?? "")
        switch code {
        case -32601:
            return HelpfulError(
                title: "Not supported",
                message: "The server doesn't support \(method).",
                suggestions: ["Nothing to fix on your side: this server doesn't implement that request."],
                details: details)
        case -32602:
            return HelpfulError(
                title: "Invalid arguments",
                message: "The server rejected the arguments for \(method): \(message)",
                suggestions: ["Check the arguments against the input schema, then try again."],
                details: details)
        case -32002:
            return HelpfulError(
                title: "Resource not found",
                message: "The server couldn't find that resource: \(message)",
                suggestions: ["Refresh the resource list; the resource may have moved or been deleted."],
                details: details)
        case -32603, -32099...(-32000):
            return HelpfulError(
                title: "Server error",
                message: "The server hit an error handling \(method): \(message)",
                suggestions: ["Open Logs for the server's own output.",
                              "Try again. If it keeps failing, report it to the server's maintainers."],
                details: details)
        default:
            return HelpfulError(
                title: "Request failed",
                message: "\(method) failed with error \(code): \(message)",
                suggestions: ["Open Logs for the full exchange."],
                details: details)
        }
    }

    // MARK: Formatting

    static func hostLabel(_ url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return url.isEmpty ? "The server" : url }
        return host
    }

    static func port(in text: String) -> Int? {
        guard let range = text.range(of: #"(?:port\s*|:)(\d{2,5})\b"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return Int(text[range].filter(\.isNumber))
    }

    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func duration(_ seconds: Int) -> String {
        guard seconds >= 120, seconds % 60 == 0 else { return "\(seconds) s" }
        return "\(seconds / 60) minutes"
    }

    static func byteSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes)-byte"
    }
}
