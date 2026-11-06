import Foundation

private let integrationTimeouts = MCPTimeouts(initialize: .seconds(10), request: .seconds(5), toolCall: .seconds(5))

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-manager-client-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func firstText(_ result: MCPToolResult) throws -> String {
    guard case let .text(text)? = result.content.first else {
        throw TestFailure(description: "expected text content, got \(result.content)")
    }
    return text
}

/// Slices built separately (config resolution, session, log file, OAuth) working as the app wires them.
func runClientIntegrationTests() {
    testAsync("client: a project's stdio server starts in its project with config and added variables", timeout: 30) {
        let project = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let config = MCPServerConfig(transport: .stdio(command: fixturePython,
                                                       args: [fixturePath("mcp_fixture_server.py"), "--stdio"],
                                                       env: ["FIXTURE_MARKER": "${DEMO_MARKER}"]))
        let entry = MCPEntry(name: "fixture", client: .claude, scope: .claudeProject(project: project.path), config: config,
                             sourcePath: project.appendingPathComponent(".mcp.json").path)
        let shell = ShellEnvironment(variables: ["PATH": "/usr/bin:/bin", "HOME": project.path], source: .loginShell("/bin/zsh"))
        let launch = try LaunchResolver.resolve(.project(entry), shell: shell,
                                                variables: [ClientVariable(name: "DEMO_MARKER", value: "set in MCP Manager")],
                                                homeDirectory: NSHomeDirectory())
        let logURL = project.appendingPathComponent("Logs/\(MCPServerTarget.project(entry).logFileName)")
        let log = MCPLogFile(url: logURL)
        let session = MCPClientSession(launch: launch, log: log, timeouts: integrationTimeouts)
        _ = try await session.connect()

        let info = try JSONValue.parse(try firstText(try await session.callTool(name: "launch_info", arguments: [:])))
        expectEqual(info["marker"], "set in MCP Manager")
        // The process reports /private/var where Foundation shortens it to /var.
        let cwd = try require(info["cwd"]?.stringValue, "launch_info has no cwd")
        expectEqual(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path, project.path)

        _ = try await session.callTool(name: "echo", arguments: ["message": "hello from the log test", "password": "hunter2"])
        await session.close()
        log.flush()
        let written = try readText(logURL)
        expectTrue(written.contains("hello from the log test"), "the call is not in the log file")
        expectTrue(!written.contains("hunter2"), "a password argument reached the log file")
        expectTrue(written.contains(#""k":"outgoing""#) && written.contains("→ tools/call"), "no outgoing tools/call entry")
        expectTrue(written.contains("Connected to fixture"), "no connected event")
    }

    testAsync("client: an OAuth server answers 401, then lists tools once signed in through the browser", timeout: 30) {
        let server = try FixtureServer(script: "oauth_fixture_server.py")
        defer { server.stop() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = server.baseURL.appendingPathComponent("mcp")
        let target = MCPServerTarget(name: "secured", config: MCPServerConfig(transport: .http(url: url.absoluteString, headers: [:])),
                                     origin: .global(clients: [.claude]))
        let launch = try LaunchResolver.resolve(target, shell: ShellEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")),
                                                variables: [], homeDirectory: directory.path)
        let oauth = OAuthClient(store: FileCredentialStore(url: directory.appendingPathComponent("oauth.json")),
                                callbackTimeout: .seconds(10))
        let auth = OAuthAuthProvider(client: oauth)

        let first = MCPClientSession(launch: launch, log: MCPMemoryLog(), auth: auth, timeouts: integrationTimeouts)
        let refused = await thrownError { _ = try await first.connect() }
        guard case let MCPClientError.authorizationRequired(_, challenge)? = refused as? MCPClientError else {
            throw TestFailure(description: "expected authorizationRequired, got \(String(describing: refused))")
        }
        expectTrue(HelpfulError(refused!).offersSignIn, "a 401 should offer Sign in")

        let browser = URLSession(configuration: .ephemeral)
        _ = try await oauth.signIn(serverURL: url, challenge: challenge, hints: nil) { authorize in
            _ = try await browser.data(from: authorize)
        }
        let second = MCPClientSession(launch: launch, log: MCPMemoryLog(), auth: auth, timeouts: integrationTimeouts)
        let initialized = try await second.connect()
        expectEqual(initialized.serverInfo.name, "oauth-fixture")
        expectEqual(try await second.listTools().map(\.name), ["whoami"])
        await second.close()
    }
}
