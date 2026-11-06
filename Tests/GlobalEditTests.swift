import Foundation

private let editClaudeJSON = #"""
{
  "theme": "dark",
  "mcpServers": {
    "shared": { "type": "stdio", "command": "/bin/old", "args": ["--a"], "env": { "K": "1" } },
    "remote": { "type": "http", "url": "https://r.example/mcp", "oauth": { "clientId": "abc", "callbackPort": 9000 } },
    "taken": { "command": "/bin/taken" }
  }
}
"""#

private let editCodexTOML = """
# codex
[mcp_servers.shared]
command = "/bin/old"
args = ["--a"]
enabled = false
startup_timeout_sec = 45

[mcp_servers.shared.env]
K = "1"

[mcp_servers.other]
command = "/bin/other"

"""

private func withEditHome(_ body: (MCPManager, ConfigPaths) throws -> Void) throws {
    try withTempHome { home in
        let paths = ConfigPaths(home: home)
        try writeFile(paths.claudeJSON, editClaudeJSON)
        try writeFile(paths.codexTOML, editCodexTOML)
        try body(MCPManager(paths: paths), paths)
    }
}

private func backupNames(_ paths: ConfigPaths) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: paths.backupDir.path)) ?? []).sorted()
}

private func global(_ manager: MCPManager, _ name: String) throws -> GlobalServer {
    try require(try MCPManager(paths: manager.paths).loadGlobal().first { $0.name == name }, "\(name) missing after reload")
}

func runGlobalEditTests() {
    test("updateGlobal: writes the new config to both clients and both re-read equal") {
        try withEditHome { manager, _ in
            let config = MCPServerConfig(transport: .stdio(command: "/bin/new", args: ["--b", "c"], env: ["K": "2", "L": "3"]))
            let report = try manager.updateGlobal("shared", to: "shared", config: config)

            expectEqual(report, WriteReport(written: [.claude, .codex]))
            let server = try global(manager, "shared")
            expectEqual(server.claude?.transport, config.transport)
            expectEqual(server.codex?.transport, config.transport)
        }
    }

    test("updateGlobal: a new name renames the server in every client that has it") {
        try withEditHome { manager, _ in
            let config = MCPServerConfig(transport: .stdio(command: "/bin/new", args: [], env: [:]))
            try manager.updateGlobal("shared", to: "renamed", config: config)

            let names = try manager.loadGlobal().map(\.name)
            expectEqual(names, ["other", "remote", "renamed", "taken"])
            expectEqual(try global(manager, "renamed").clients, [.claude, .codex])
        }
    }

    test("updateGlobal: Codex keeps enabled = false and unmodelled keys") {
        try withEditHome { manager, paths in
            let config = MCPServerConfig(transport: .stdio(command: "/bin/new", args: [], env: ["K": "9"]))
            try manager.updateGlobal("shared", to: "shared", config: config)

            expectEqual(try global(manager, "shared").codex?.enabled, false)
            let text = try readText(paths.codexTOML)
            expectTrue(text.contains("startup_timeout_sec = 45"), "startup_timeout_sec was dropped:\n\(text)")
            expectTrue(text.contains("[mcp_servers.other]\ncommand = \"/bin/other\""), "sibling server changed:\n\(text)")
            expectTrue(text.hasPrefix("# codex\n"), "leading comment lost:\n\(text)")
        }
    }

    test("updateGlobal: Claude-only server keeps its oauth block and other top-level keys") {
        try withEditHome { manager, paths in
            let config = MCPServerConfig(transport: .http(url: "https://r2.example/mcp", headers: ["X-Team": "a"]))
            let report = try manager.updateGlobal("remote", to: "remote", config: config)

            expectEqual(report.written, [.claude])
            let root = try readJSON(paths.claudeJSON)
            expectEqual(root["theme"] as? String, "dark")
            let remote = try require((root["mcpServers"] as? [String: Any])?["remote"] as? [String: Any], "remote missing")
            expectEqual(remote["url"] as? String, "https://r2.example/mcp")
            expectEqual((remote["oauth"] as? [String: Any])?["clientId"] as? String, "abc")
            expectEqual(try global(manager, "remote").claude?.oauth, MCPOAuthHints(clientID: "abc", callbackPort: 9000))
            expectEqual(try readText(paths.codexTOML), editCodexTOML)
        }
    }

    test("updateGlobal: an SSE config for a server Claude alone holds is written") {
        try withEditHome { manager, _ in
            let sse = MCPServerConfig(transport: .sse(url: "https://r.example/sse", headers: [:]))
            try manager.updateGlobal("remote", to: "remote", config: sse)
            expectEqual(try global(manager, "remote").claude?.transport, sse.transport)
        }
    }

    test("updateGlobal: name clash, unknown server, bad name and SSE with Codex write nothing") {
        try withEditHome { manager, paths in
            let claudeBefore = try Data(contentsOf: paths.claudeJSON)
            let codexBefore = try Data(contentsOf: paths.codexTOML)
            let stdio = MCPServerConfig(transport: .stdio(command: "/x", args: [], env: [:]))

            expectThrows(MCPManagerError.nameTaken(name: "taken", client: .claude)) {
                try manager.updateGlobal("shared", to: "taken", config: stdio)
            }
            expectThrows(MCPManagerError.nameTaken(name: "other", client: .codex)) {
                try manager.updateGlobal("shared", to: "other", config: stdio)
            }
            expectThrows(MCPManagerError.notFound(name: "ghost")) {
                try manager.updateGlobal("ghost", to: "ghost", config: stdio)
            }
            expectThrows(MCPManagerError.invalidName("bad name")) {
                try manager.updateGlobal("shared", to: "bad name", config: stdio)
            }
            expectThrows(MCPManagerError.io(path: paths.codexTOML.path, detail: CodexConfigStore.sseSkipReason)) {
                try manager.updateGlobal("shared", to: "shared",
                                         config: MCPServerConfig(transport: .sse(url: "https://s/sse", headers: [:])))
            }

            expectEqual(try Data(contentsOf: paths.claudeJSON), claudeBefore)
            expectEqual(try Data(contentsOf: paths.codexTOML), codexBefore)
            expectEqual(backupNames(paths), [])
        }
    }

    test("updateGlobal: a client whose settings differ from the edited copy only takes the new name") {
        try withTempHome { home in
            let paths = ConfigPaths(home: home)
            try writeFile(paths.claudeJSON, editClaudeJSON)
            try writeFile(paths.codexTOML, editCodexTOML.replacingOccurrences(of: #"args = ["--a"]"#, with: #"args = ["--codex-only"]"#))
            let manager = MCPManager(paths: paths)
            let original = try require(try global(manager, "shared").claude, "Claude copy missing")
            let edited = MCPServerConfig(transport: .stdio(command: "/bin/new", args: ["--a"], env: ["K": "1"]))

            let report = try manager.updateGlobal("shared", to: "renamed", config: edited, editedFrom: original)

            expectEqual(report.written, [.claude, .codex])
            expectEqual(report.skipped.map(\.client), [.codex])
            let server = try global(manager, "renamed")
            expectEqual(server.claude?.transport, edited.transport)
            expectEqual(server.codex?.transport, .stdio(command: "/bin/old", args: ["--codex-only"], env: ["K": "1"]))
        }
    }
}
