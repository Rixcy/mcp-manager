import Foundation

func runClientEnvironmentTests() {
    runShellEnvironmentTests()
    runVariableExpansionTests()
    runLaunchResolverTests()
    runClientVariableStoreTests()
}

private func makeExecutable(_ url: URL, _ script: String) throws {
    try writeFile(url, script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-manager-env-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fallbackReason(_ environment: ShellEnvironment) -> String? {
    if case let .fallback(reason) = environment.source { return reason }
    return nil
}

// MARK: Shell environment

private func runShellEnvironmentTests() {
    testAsync("shell env: reads exported keys from the login shell, ignoring rc noise", timeout: 10) {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("fake-zsh")
        // Refuses anything but `-l -i -c <command>`, prints banners like a noisy
        // .zshrc, and exits non-zero after the command, which must still count.
        try makeExecutable(shell, """
        #!/bin/sh
        [ "$1" = "-l" ] && [ "$2" = "-i" ] && [ "$3" = "-c" ] || exit 3
        echo "Last login: Fri Nov  6 on ttys001"
        printf 'oh-my-zsh banner without newline'
        export FAKE_TOKEN=tok-123
        export MULTI='a=b=c
        second line'
        /bin/sh -c "$4"
        echo "goodbye from .zlogout"
        exit 7
        """)
        let base = ["HOME": dir.path, "PATH": "/usr/bin:/bin", "FROM_BASE": "kept"]
        let environment = await ShellEnvironment.resolve(shell: shell.path, timeout: .seconds(5), base: base)
        expectEqual(environment.source, .loginShell(shell.path))
        expectEqual(environment.variables["FAKE_TOKEN"], "tok-123")
        expectEqual(environment.variables["MULTI"], "a=b=c\nsecond line")
        expectEqual(environment.variables["FROM_BASE"], "kept", "the shell starts from the base environment")
        expectEqual(environment.variables["PATH"], "/usr/bin:/bin")
        for dropped in ["PWD", "OLDPWD", "SHLVL", "_"] {
            expectTrue(environment.variables[dropped] == nil, "\(dropped) should be dropped")
        }
    }

    testAsync("shell env: uses SHELL from the base environment when no shell is given", timeout: 10) {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("base-shell")
        try makeExecutable(shell, "#!/bin/sh\nexport PICKED=yes\nexec /bin/sh -c \"$4\"\n")
        let environment = await ShellEnvironment.resolve(
            timeout: .seconds(5), base: ["HOME": dir.path, "PATH": "/usr/bin:/bin", "SHELL": shell.path])
        expectEqual(environment.source, .loginShell(shell.path))
        expectEqual(environment.variables["PICKED"], "yes")
    }

    testAsync("shell env: a shell that hangs falls back within the timeout and extends PATH", timeout: 10) {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in [".local/bin", ".cargo/bin"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let shell = home.appendingPathComponent("slow-zsh")
        try makeExecutable(shell, "#!/bin/sh\nsleep 5\n")
        let local = home.appendingPathComponent(".local/bin").path
        let cargo = home.appendingPathComponent(".cargo/bin").path
        let started = Date()
        let environment = await ShellEnvironment.resolve(
            shell: shell.path, timeout: .seconds(1), base: ["HOME": home.path, "PATH": "/usr/bin:/bin:\(local)", "KEEP": "1"])
        let elapsed = Date().timeIntervalSince(started)
        expectTrue(elapsed < 2.5, "fallback took \(elapsed) s")
        let reason = try require(fallbackReason(environment), "expected a fallback, got \(environment.source)")
        expectTrue(reason.contains("slow-zsh") && reason.contains("1 s"), "reason should name the shell and timeout: \(reason)")
        expectEqual(environment.variables["KEEP"], "1")
        let entries = (environment.variables["PATH"] ?? "").split(separator: ":").map(String.init)
        expectEqual(Array(entries.prefix(3)), ["/usr/bin", "/bin", local])
        expectEqual(entries.filter { $0 == local }.count, 1, "existing entries are not repeated")
        expectTrue(entries.contains(cargo), "existing tool folders are added: \(entries)")
        expectTrue(!entries.contains(home.appendingPathComponent(".bun/bin").path), "missing folders are not added")
    }

    testAsync("shell env: a missing shell falls back with a reason", timeout: 10) {
        let environment = await ShellEnvironment.resolve(
            shell: "/nonexistent/zsh", timeout: .seconds(1), base: ["HOME": "/nonexistent", "PATH": "/usr/bin:/bin"])
        let reason = try require(fallbackReason(environment), "expected a fallback")
        expectTrue(reason.contains("/nonexistent/zsh"), "reason should name the path: \(reason)")
        expectTrue((environment.variables["PATH"] ?? "").hasPrefix("/usr/bin:/bin"), "base PATH is kept")
    }

    testAsync("shell env: a shell that never prints the environment falls back", timeout: 10) {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("broken-sh")
        try makeExecutable(shell, "#!/bin/sh\necho 'rc file error'\nexit 1\n")
        let environment = await ShellEnvironment.resolve(shell: shell.path, timeout: .seconds(5),
                                                         base: ["HOME": dir.path, "PATH": "/usr/bin:/bin"])
        expectTrue(fallbackReason(environment) != nil, "expected a fallback, got \(environment.source)")
    }
}

// MARK: Expansion

private func runVariableExpansionTests() {
    test("expansion: values, defaults and empty values") {
        let variables = ["HOST": "example.com", "EMPTY": "", "PORT": "8080"]
        var missing: [String] = []
        expectEqual(VariableExpansion.expand("https://${HOST}:${PORT}/mcp", using: variables, missing: &missing),
                    "https://example.com:8080/mcp")
        expectEqual(VariableExpansion.expand("${UNSET:-http://x:1/y}", using: variables, missing: &missing), "http://x:1/y")
        expectEqual(VariableExpansion.expand("${HOST:-other}", using: variables, missing: &missing), "example.com")
        expectEqual(VariableExpansion.expand("[${EMPTY:-fallback}]", using: variables, missing: &missing), "[fallback]")
        expectEqual(VariableExpansion.expand("[${EMPTY}]", using: variables, missing: &missing), "[]")
        expectEqual(missing, [], "empty and defaulted variables are not missing")
    }

    test("expansion: unbraced, unterminated and empty references stay literal") {
        var missing: [String] = []
        let variables = ["HOME": "/Users/me"]
        expectEqual(VariableExpansion.expand("$HOME/bin", using: variables, missing: &missing), "$HOME/bin")
        expectEqual(VariableExpansion.expand("a ${HOME", using: variables, missing: &missing), "a ${HOME")
        expectEqual(VariableExpansion.expand("${} and ${HOME}", using: variables, missing: &missing), "${} and /Users/me")
        expectEqual(missing, [])
    }

    test("expansion: missing names are reported once each, in order of first use") {
        var missing = ["ALREADY"]
        let result = VariableExpansion.expand("${B}-${A}-${B}-${ALREADY}-${C:-c}", using: [:], missing: &missing)
        expectEqual(result, "----c")
        expectEqual(missing, ["ALREADY", "B", "A"])
    }

    test("expansion: requiredNames lists references without defaults and the bearer variable") {
        let stdio = MCPServerConfig(transport: .stdio(
            command: "${BIN_DIR}/server", args: ["--key", "${API_KEY}", "${LEVEL:-info}"],
            env: ["B_TOKEN": "${TOKEN}", "A_KEY": "${API_KEY}"]))
        expectEqual(VariableExpansion.requiredNames(in: stdio), ["BIN_DIR", "API_KEY", "TOKEN"])

        let http = MCPServerConfig(transport: .http(url: "https://${HOST}/mcp", headers: ["X-Key": "${HEADER_KEY}"]),
                                   bearerTokenEnvVar: "BEARER")
        expectEqual(VariableExpansion.requiredNames(in: http), ["HOST", "HEADER_KEY", "BEARER"])

        let duplicate = MCPServerConfig(transport: .sse(url: "https://x.dev/${TOKEN}", headers: [:]), bearerTokenEnvVar: "TOKEN")
        expectEqual(VariableExpansion.requiredNames(in: duplicate), ["TOKEN"])
    }
}

// MARK: Resolver

private func stdioTarget(_ command: String, args: [String] = [], env: [String: String] = [:],
                         project: String? = nil) -> MCPServerTarget {
    let config = MCPServerConfig(transport: .stdio(command: command, args: args, env: env))
    guard let project else { return MCPServerTarget(name: "test", config: config, origin: .global(clients: [.claude])) }
    let entry = MCPEntry(name: "test", client: .claude, scope: .claudeProject(project: project), config: config,
                         sourcePath: "\(project)/.mcp.json")
    return .project(entry)
}

private func httpTarget(_ url: String, headers: [String: String] = [:], bearer: String? = nil, sse: Bool = false) -> MCPServerTarget {
    let transport: MCPTransport = sse ? .sse(url: url, headers: headers) : .http(url: url, headers: headers)
    return MCPServerTarget(name: "remote", config: MCPServerConfig(transport: transport, bearerTokenEnvVar: bearer),
                           origin: .global(clients: [.claude]))
}

private func stdioParts(_ launch: ResolvedLaunch) throws
    -> (executable: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
    guard case let .stdio(executable, arguments, environment, workingDirectory) = launch.target else {
        throw TestFailure(description: "expected a stdio launch, got \(launch.target)")
    }
    return (executable, arguments, environment, workingDirectory)
}

private func httpParts(_ launch: ResolvedLaunch) throws -> (url: URL, headers: [String: String], sse: Bool) {
    switch launch.target {
    case let .streamableHTTP(url, headers): return (url, headers, false)
    case let .sse(url, headers): return (url, headers, true)
    case .stdio: throw TestFailure(description: "expected an HTTP launch")
    }
}

private func runLaunchResolverTests() {
    test("resolver: environment precedence is shell, then config env, then client variables") {
        try withTempHome { home in
            let bin = home.appendingPathComponent("bin")
            try makeExecutable(bin.appendingPathComponent("tool"), "#!/bin/sh\n")
            let shell = ShellEnvironment(variables: ["PATH": "/usr/bin", "SHARED": "shell", "BOTH": "shell", "ONLY_SHELL": "s"],
                                         source: .loginShell("/bin/zsh"))
            let target = stdioTarget("tool", args: ["--who", "${SHARED}"],
                                     env: ["SHARED": "config", "BOTH": "config", "DERIVED": "${ONLY_SHELL}-x"])
            let variables = [ClientVariable(name: "SHARED", value: "client"), ClientVariable(name: "", value: "ignored"),
                             ClientVariable(name: "PATH", value: "/usr/bin:\(bin.path)")]
            let launch = try LaunchResolver.resolve(target, shell: shell, variables: variables, homeDirectory: home.path)
            let parts = try stdioParts(launch)
            expectEqual(parts.environment["SHARED"], "client")
            expectEqual(parts.environment["BOTH"], "config")
            expectEqual(parts.environment["ONLY_SHELL"], "s")
            expectEqual(parts.environment["DERIVED"], "s-x")
            expectTrue(parts.environment[""] == nil, "empty names are ignored")
            expectEqual(parts.arguments, ["--who", "client"])
            expectEqual(parts.executable, bin.appendingPathComponent("tool").path,
                        "the command is found on the effective PATH, which a client variable changed")
        }
    }

    test("resolver: working directory is the project when it exists, else home") {
        try withTempHome { home in
            let project = home.appendingPathComponent("reels")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let shell = ShellEnvironment(variables: ["PATH": "/bin"], source: .loginShell("/bin/zsh"))
            let inProject = try LaunchResolver.resolve(stdioTarget("sh", project: project.path), shell: shell,
                                                       variables: [], homeDirectory: home.path)
            expectEqual(try stdioParts(inProject).workingDirectory, project.path)
            expectEqual(try stdioParts(inProject).executable, "/bin/sh")

            let gone = try LaunchResolver.resolve(stdioTarget("sh", project: home.appendingPathComponent("deleted").path),
                                                  shell: shell, variables: [], homeDirectory: home.path)
            expectEqual(try stdioParts(gone).workingDirectory, home.path)
        }
    }

    test("resolver: relative and ~ paths resolve against the working directory and home") {
        try withTempHome { home in
            let project = home.appendingPathComponent("proj")
            try makeExecutable(project.appendingPathComponent("scripts/run.sh"), "#!/bin/sh\n")
            try makeExecutable(home.appendingPathComponent("tools/mine"), "#!/bin/sh\n")
            let shell = ShellEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh"))
            let relative = try LaunchResolver.resolve(stdioTarget("./scripts/run.sh", project: project.path), shell: shell,
                                                      variables: [], homeDirectory: home.path)
            expectEqual(try stdioParts(relative).executable, project.appendingPathComponent("scripts/run.sh").path)
            let tilde = try LaunchResolver.resolve(stdioTarget("~/tools/mine"), shell: shell, variables: [], homeDirectory: home.path)
            expectEqual(try stdioParts(tilde).executable, home.appendingPathComponent("tools/mine").path)
        }
    }

    test("resolver: missing, non-executable and directory commands throw the specific error") {
        try withTempHome { home in
            let shell = ShellEnvironment(variables: ["PATH": "\(home.path)/a:/nowhere/b"], source: .loginShell("/bin/zsh"))
            // An executable name that exists only as a non-executable file on PATH still counts as not found.
            try writeFile(home.appendingPathComponent("a/ghost"), "not executable")
            expectThrows(MCPClientError.commandNotFound(command: "ghost", searchedPath: ["\(home.path)/a", "/nowhere/b"])) {
                _ = try LaunchResolver.resolve(stdioTarget("ghost"), shell: shell, variables: [], homeDirectory: home.path)
            }
            expectThrows(MCPClientError.commandNotFound(command: "./missing.sh", searchedPath: [])) {
                _ = try LaunchResolver.resolve(stdioTarget("./missing.sh"), shell: shell, variables: [], homeDirectory: home.path)
            }
            let plain = home.appendingPathComponent("plain.sh")
            try writeFile(plain, "#!/bin/sh\n")
            expectThrows(MCPClientError.commandNotExecutable(path: plain.path)) {
                _ = try LaunchResolver.resolve(stdioTarget(plain.path), shell: shell, variables: [], homeDirectory: home.path)
            }
            let folder = home.appendingPathComponent("a")
            expectThrows(MCPClientError.commandNotExecutable(path: folder.path)) {
                _ = try LaunchResolver.resolve(stdioTarget("~/a"), shell: shell, variables: [], homeDirectory: home.path)
            }
            expectEqual(LaunchResolver.findExecutable("ghost", searchPath: shell.variables["PATH"], workingDirectory: nil), nil)
            expectEqual(LaunchResolver.findExecutable("sh", searchPath: "/nowhere:/bin", workingDirectory: nil), "/bin/sh")
        }
    }

    test("resolver: display name is the unexpanded command line without env values") {
        try withTempHome { home in
            let shell = ShellEnvironment(variables: ["PATH": "/bin", "TOKEN": "s3cret-value"], source: .loginShell("/bin/zsh"))
            let target = stdioTarget("sh", args: ["-c", "echo hi", "${TOKEN}"], env: ["API_TOKEN": "${TOKEN}"])
            let launch = try LaunchResolver.resolve(target, shell: shell, variables: [], homeDirectory: home.path)
            expectEqual(launch.displayName, "sh -c \"echo hi\" ${TOKEN}")
            expectEqual(try stdioParts(launch).environment["API_TOKEN"], "s3cret-value")
        }
    }

    test("resolver: every missing variable is reported together before command lookup") {
        let shell = ShellEnvironment(variables: ["PATH": "/bin"], source: .loginShell("/bin/zsh"))
        let target = stdioTarget("${BIN}/server", args: ["${KEY}", "${LEVEL:-1}"], env: ["X": "${SECRET}", "Y": "${KEY}"])
        expectThrows(MCPClientError.missingVariables(["BIN", "KEY", "SECRET"])) {
            _ = try LaunchResolver.resolve(target, shell: shell, variables: [], homeDirectory: "/tmp")
        }
        let remote = httpTarget("${HOST}/mcp", headers: ["X-Team": "${TEAM}"], bearer: "TOKEN")
        expectThrows(MCPClientError.missingVariables(["HOST", "TEAM", "TOKEN"])) {
            _ = try LaunchResolver.resolve(remote, shell: shell, variables: [], homeDirectory: "/tmp")
        }
    }

    test("resolver: bearer variable adds an Authorization header unless one is configured") {
        let shell = ShellEnvironment(variables: ["HOST": "mcp.example.com"], source: .loginShell("/bin/zsh"))
        let target = httpTarget("https://${HOST}/mcp", headers: ["X-Team": "core"], bearer: "MY_TOKEN")
        let launch = try LaunchResolver.resolve(target, shell: shell, variables: [ClientVariable(name: "MY_TOKEN", value: "abc")],
                                                homeDirectory: "/tmp")
        let parts = try httpParts(launch)
        expectEqual(parts.url.absoluteString, "https://mcp.example.com/mcp")
        expectEqual(parts.headers, ["X-Team": "core", "Authorization": "Bearer abc"])
        expectEqual(launch.displayName, "https://${HOST}/mcp")
        expectTrue(!parts.sse, "http config resolves to Streamable HTTP")

        let explicit = httpTarget("https://x.dev/sse", headers: ["authorization": "Basic Zm9v"], bearer: "UNSET_TOKEN", sse: true)
        let explicitParts = try httpParts(try LaunchResolver.resolve(explicit, shell: shell, variables: [], homeDirectory: "/tmp"))
        expectEqual(explicitParts.headers, ["authorization": "Basic Zm9v"], "an explicit header wins and the unset variable is not needed")
        expectTrue(explicitParts.sse, "sse config resolves to SSE")
    }

    test("resolver: an invalid URL error never contains expanded secrets") {
        let shell = ShellEnvironment(variables: ["BASE": "sk-live-secret-123"], source: .loginShell("/bin/zsh"))
        for url in ["${BASE}/mcp", "ftp://${BASE}/mcp", "https:///${BASE}"] {
            do {
                _ = try LaunchResolver.resolve(httpTarget(url), shell: shell, variables: [], homeDirectory: "/tmp")
                fail("\(url) should be rejected")
            } catch let error as MCPClientError {
                expectEqual(error, .invalidURL(url))
                expectTrue(!error.helpful.message.contains("sk-live") && !(error.helpful.details ?? "").contains("sk-live"),
                           "the helpful error leaks the secret: \(error.helpful)")
            }
        }
    }
}

// MARK: Variable store

private func runClientVariableStoreTests() {
    test("variable store: round trip, private file, other keys kept, empty list removes the key") {
        try withTempHome { home in
            let url = home.appendingPathComponent("state/variables.json")
            let store = ClientVariableStore(url: url)
            expectEqual(try store.variables(for: "global/linear"), [], "a missing file has no variables")

            let linear = [ClientVariable(name: "LINEAR_API_KEY", value: "lin_123"), ClientVariable(name: "TEAM", value: "core")]
            try store.setVariables(linear, for: "global/linear")
            try ClientVariableStore(url: url).setVariables([ClientVariable(name: "X", value: "1")], for: "project/x")
            expectEqual(try ClientVariableStore(url: url).variables(for: "global/linear"), linear)

            let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            expectEqual(fileMode, 0o600)
            let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
            expectEqual(dirMode, 0o700)
            let stored = try readJSON(url)
            let first = try require((stored["global/linear"] as? [[String: Any]])?.first, "stored list")
            expectEqual(first["id"] as? String, linear[0].id.uuidString)
            expectEqual(first["name"] as? String, "LINEAR_API_KEY")

            try store.setVariables([], for: "global/linear")
            let after = try readJSON(url)
            expectTrue(after["global/linear"] == nil, "an empty list removes the key")
            expectEqual(try store.variables(for: "project/x").map { "\($0.name)=\($0.value)" }, ["X=1"], "other keys are kept")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            expectEqual(leftovers, ["variables.json"], "no temporary files are left behind")
        }
    }

    test("variable store: a corrupt file is a parse error, not an empty list") {
        try withTempHome { home in
            let url = home.appendingPathComponent("variables.json")
            try writeFile(url, "{ not json")
            let store = ClientVariableStore(url: url)
            let attempts: [() throws -> Void] = [{ _ = try store.variables(for: "global/a") },
                                                 { try store.setVariables([], for: "global/a") }]
            for attempt in attempts {
                do {
                    try attempt()
                    fail("expected a parse error")
                } catch let MCPManagerError.parse(path, _) {
                    expectEqual(path, url.path)
                }
            }
            expectEqual(try readText(url), "{ not json", "a failed save leaves the corrupt file for the user to inspect")
        }
    }
}
