import Foundation

private func withManager(claude: String? = nil, codex: String? = nil,
                         _ body: (MCPManager, ConfigPaths) throws -> Void) throws {
    try withTempHome { home in
        let paths = ConfigPaths(home: home)
        if let claude { try writeFile(paths.claudeJSON, claude) }
        if let codex { try writeFile(paths.codexTOML, codex) }
        try body(MCPManager(paths: paths), paths)
    }
}

private func backups(_ paths: ConfigPaths, _ basename: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.backupDir.path)) ?? [])
        .filter { FileIO.isBackupName($0, for: basename) }
        .sorted()
}

private let stdioConfig = MCPServerConfig(transport: .stdio(command: "/bin/tool", args: ["--flag"], env: ["K": "v"]))

func runMCPManagerTests() {
    test("loadGlobal: merges both clients by name") {
        let claude = #"{"mcpServers": {"gamma": {"command": "/g"}, "Beta": {"type": "http", "url": "https://b"}}}"#
        let codex = "[mcp_servers.alpha]\ncommand = \"/a\"\n[mcp_servers.Beta]\nurl = \"https://b2\"\n"
        try withManager(claude: claude, codex: codex) { manager, _ in
            let servers = Dictionary(uniqueKeysWithValues: try manager.loadGlobal().map { ($0.name, $0) })
            expectEqual(servers.keys.sorted(), ["Beta", "alpha", "gamma"])
            expectEqual(servers["Beta"]?.claude?.transport, .http(url: "https://b", headers: [:]))
            expectEqual(servers["Beta"]?.codex?.transport, .http(url: "https://b2", headers: [:]))
            expectEqual(servers["alpha"]?.clients, [.codex])
            expectEqual(servers["gamma"]?.clients, [.claude])
        }
    }

    test("loadGlobal: missing config files mean no servers, not an error") {
        try withManager { manager, _ in
            expectEqual(try manager.loadGlobal(), [])
        }
    }

    test("add: writes the server to both files") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            let report = try manager.add(name: "tool", config: stdioConfig)
            expectEqual(report, WriteReport(written: [.claude, .codex]))
            let reread = MCPManager(paths: paths)
            let server = try require(try reread.loadGlobal().first { $0.name == "tool" }, "tool missing")
            expectEqual(server.claude, stdioConfig)
            expectEqual(server.codex, stdioConfig)
        }
    }

    test("add: a name taken in either client writes nothing anywhere") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            let claudeBefore = try Data(contentsOf: paths.claudeJSON)
            let codexBefore = try Data(contentsOf: paths.codexTOML)
            expectThrows(MCPManagerError.nameTaken(name: "linear", client: .codex)) {
                try manager.add(name: "linear", config: stdioConfig)
            }
            expectThrows(MCPManagerError.nameTaken(name: "figma", client: .claude)) {
                try manager.add(name: "figma", config: stdioConfig)
            }
            expectEqual(try Data(contentsOf: paths.claudeJSON), claudeBefore)
            expectEqual(try Data(contentsOf: paths.codexTOML), codexBefore)
            expectEqual(backups(paths, ".claude.json") + backups(paths, "config.toml"), [])
        }
    }

    test("add: SSE goes to Claude and skips Codex with a reason") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            let sse = MCPServerConfig(transport: .sse(url: "https://s/sse", headers: [:]))
            let report = try manager.add(name: "stream", config: sse)
            expectEqual(report, WriteReport(written: [.claude], skipped: [.init(client: .codex, reason: "Codex has no SSE transport")]))
            expectEqual(try readText(paths.codexTOML), sampleCodexTOML)
            expectEqual(try manager.loadGlobal().first { $0.name == "stream" }?.claude, sse)
        }
    }

    test("add: invalid names are rejected before touching disk") {
        try withManager { manager, paths in
            expectThrows(MCPManagerError.invalidName("bad.name")) { try manager.add(name: "bad.name", config: stdioConfig) }
            expectTrue(!FileManager.default.fileExists(atPath: paths.claudeJSON.path), "Claude file was created")
            expectTrue(!FileManager.default.fileExists(atPath: paths.codexTOML.path), "Codex file was created")
        }
    }

    test("validateName: messages for empty, too long and bad characters") {
        expectEqual(MCPManager.validateName(""), "Enter a name.")
        expectEqual(MCPManager.validateName(String(repeating: "a", count: 65)), "Use 64 characters or fewer.")
        expectEqual(MCPManager.validateName("has space"), "Use only letters, digits, - and _.")
        expectEqual(MCPManager.validateName("café"), "Use only letters, digits, - and _.")
        expectEqual(MCPManager.validateName(String(repeating: "a", count: 64)), nil)
        expectEqual(MCPManager.validateName("Abc-1_z"), nil)
    }

    test("remove: removes from each client that has it; notFound when none do") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            _ = try manager.add(name: "both", config: stdioConfig)
            expectEqual(try manager.remove(name: "both"), WriteReport(written: [.claude, .codex]))
            expectEqual(try manager.remove(name: "linear"), WriteReport(written: [.codex]))
            expectEqual(try readText(paths.codexTOML), sampleCodexTOML.replacingOccurrences(
                of: "[mcp_servers.linear]\nurl = \"https://mcp.linear.app/mcp\"\n", with: ""))
            expectThrows(MCPManagerError.notFound(name: "linear")) { try manager.remove(name: "linear") }
            expectEqual(try manager.loadGlobal().map(\.name).contains("both"), false)
        }
    }

    test("rename: renames in both clients; nameTaken and notFound leave files alone") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            _ = try manager.add(name: "old", config: stdioConfig)
            expectEqual(try manager.rename("old", to: "new"), WriteReport(written: [.claude, .codex]))
            let server = try require(try manager.loadGlobal().first { $0.name == "new" }, "new missing")
            expectEqual(server.clients, [.claude, .codex])

            let claudeBefore = try Data(contentsOf: paths.claudeJSON)
            let codexBefore = try Data(contentsOf: paths.codexTOML)
            expectThrows(MCPManagerError.nameTaken(name: "figma", client: .claude)) { try manager.rename("new", to: "figma") }
            expectThrows(MCPManagerError.notFound(name: "ghost")) { try manager.rename("ghost", to: "spirit") }
            expectThrows(MCPManagerError.invalidName("no way")) { try manager.rename("new", to: "no way") }
            expectEqual(try Data(contentsOf: paths.claudeJSON), claudeBefore)
            expectEqual(try Data(contentsOf: paths.codexTOML), codexBefore)
        }
    }

    test("sync: Codex-only server is copied to Claude, bearer becomes a header") {
        let codex = "[mcp_servers.gh]\nurl = \"https://gh.example/mcp\"\nbearer_token_env_var = \"GH_TOKEN\"\n"
        try withManager(claude: sampleClaudeJSON, codex: codex) { manager, paths in
            expectEqual(try manager.sync(name: "gh"), WriteReport(written: [.claude]))
            let entry = (try readJSON(paths.claudeJSON)["mcpServers"] as? [String: Any])?["gh"] as? [String: Any]
            expectEqual((entry?["headers"] as? [String: String])?["Authorization"], "Bearer ${GH_TOKEN}")
            let server = try require(try manager.loadGlobal().first { $0.name == "gh" }, "gh missing")
            expectEqual(server.claude, server.codex)
            expectEqual(try readText(paths.codexTOML), codex)
        }
    }

    test("sync: Claude SSE server reports the Codex skip; unknown name is notFound") {
        try withManager(claude: sampleClaudeJSON) { manager, paths in
            expectEqual(try manager.sync(name: "events"),
                        WriteReport(skipped: [.init(client: .codex, reason: "Codex has no SSE transport")]))
            expectTrue(!FileManager.default.fileExists(atPath: paths.codexTOML.path), "Codex file was created")
            expectThrows(MCPManagerError.notFound(name: "ghost")) { try manager.sync(name: "ghost") }
        }
    }

    test("backups: every write copies the old file first, keeping the newest 20") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            try FileManager.default.createDirectory(at: paths.backupDir, withIntermediateDirectories: true)
            let seeded = (0..<25).map { String(format: "20200101-000000-%03d-config.toml", $0) }
            for name in seeded { try writeFile(paths.backupDir.appendingPathComponent(name), "old") }
            try writeFile(paths.backupDir.appendingPathComponent("20200101-000000-000-.claude.json"), "{}")

            try manager.remove(name: "linear", from: [.codex])

            let kept = backups(paths, "config.toml")
            expectEqual(kept.count, 20)
            expectEqual(Array(kept.prefix(19)), Array(seeded.suffix(19)), "oldest backups should be pruned first")
            let newest = try require(kept.last, "no backups")
            expectTrue(!seeded.contains(newest), "no new backup was written")
            expectEqual(try readText(paths.backupDir.appendingPathComponent(newest)), sampleCodexTOML)
            expectEqual(backups(paths, ".claude.json"), ["20200101-000000-000-.claude.json"])
        }
    }

    test("writes keep the original file permissions") {
        try withManager(claude: sampleClaudeJSON, codex: sampleCodexTOML) { manager, paths in
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: paths.claudeJSON.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: paths.codexTOML.path)
            _ = try manager.add(name: "tool", config: stdioConfig)
            let claudeMode = try FileManager.default.attributesOfItem(atPath: paths.claudeJSON.path)[.posixPermissions] as? Int
            let codexMode = try FileManager.default.attributesOfItem(atPath: paths.codexTOML.path)[.posixPermissions] as? Int
            expectEqual(claudeMode, 0o640)
            expectEqual(codexMode, 0o604)
        }
    }

    test("concurrency: a change between read and replace is re-read and the edit re-applied") {
        try withManager(claude: sampleClaudeJSON) { manager, paths in
            var attempts: [Int] = []
            manager.fileIO.beforeReplace = { url, attempt in
                attempts.append(attempt)
                guard attempt == 1 else { return }
                // Claude Code rewriting the file while we edit it.
                var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
                root["numStartups"] = 413
                try? JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)
            }
            _ = try manager.add(name: "tool", config: stdioConfig, to: [.claude])
            expectEqual(attempts, [1, 2])
            let root = try readJSON(paths.claudeJSON)
            expectEqual(root["numStartups"] as? Int, 413)
            expectTrue((root["mcpServers"] as? [String: Any])?["tool"] != nil, "edit was not re-applied")
        }
    }

    test("concurrency: a file that keeps changing fails after 3 attempts without writing") {
        try withManager(codex: sampleCodexTOML) { manager, paths in
            var attempts = 0
            manager.fileIO.beforeReplace = { url, _ in
                attempts += 1
                try? Data((sampleCodexTOML + "# touch \(attempts)\n").utf8).write(to: url)
            }
            expectThrows(MCPManagerError.concurrentModification(path: paths.codexTOML.path)) {
                try manager.add(name: "tool", config: stdioConfig, to: [.codex])
            }
            expectEqual(attempts, 3)
            expectEqual(try readText(paths.codexTOML), sampleCodexTOML + "# touch 3\n")
        }
    }
}
