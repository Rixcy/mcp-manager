import Foundation

/// A project with one MCP in each project-level source, plus a global server
/// and an unrelated top-level key that edits must leave alone.
private struct ProjectFixture {
    let paths: ConfigPaths
    let project: URL
    var mcpJSON: URL { project.appendingPathComponent(".mcp.json") }
    var codexTOML: URL { project.appendingPathComponent(".codex/config.toml") }
    var ref: ProjectRef { ProjectRef(path: project.path) }
    var manager: MCPManager { MCPManager(paths: paths) }

    init(home: URL) throws {
        paths = ConfigPaths(home: home)
        project = home.appendingPathComponent("Projects/app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claude: [String: Any] = [
            "numStartups": 7,
            "mcpServers": ["global-one": ["command": "/g"]],
            "projects": [project.path: [
                "allowedTools": ["Bash"],
                "mcpServers": [
                    "local-db": ["type": "http", "url": "https://db/mcp", "oauth": ["clientId": "abc"]],
                    "local-other": ["type": "stdio", "command": "/other", "args": [], "env": [:]],
                ],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: claude).write(to: paths.claudeJSON)
        try writeFile(mcpJSON, #"{"mcpServers": {"shared": {"type": "http", "url": "https://shared/mcp"}, "keep": {"command": "/k"}}}"#)
        try writeFile(codexTOML, """
        # project codex config
        [mcp_servers.cx]
        command = "/cx"
        args = ["--a"]
        startup_timeout_sec = 30

        [mcp_servers.cx.env]
        TOKEN = "t"

        [mcp_servers.cx.tools.search]
        approval = "never"

        [mcp_servers.after]
        command = "/after"

        """)
    }

    func entry(_ name: String) throws -> MCPEntry {
        try require(try manager.projectMCPs(ref).first { $0.name == name }, "no project entry \(name)")
    }

    func localServers() throws -> [String: Any] {
        let root = try readJSON(paths.claudeJSON)
        let projects = try require(root["projects"] as? [String: Any], "projects missing")
        let entry = try require(projects[project.path] as? [String: Any], "project key missing")
        return try require(entry["mcpServers"] as? [String: Any], "local mcpServers missing")
    }
}

func runProjectEditTests() {
    test("removeProjectEntry: Claude local scope removes only that project's entry") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            try f.manager.removeProjectEntry(try f.entry("local-db"))

            expectEqual(try f.localServers().keys.sorted(), ["local-other"])
            let root = try readJSON(f.paths.claudeJSON)
            expectEqual((root["mcpServers"] as? [String: Any])?.keys.sorted(), ["global-one"])
            expectEqual(root["numStartups"] as? Int, 7)
            let projectEntry = (root["projects"] as? [String: Any])?[f.project.path] as? [String: Any]
            expectEqual(projectEntry?["allowedTools"] as? [String], ["Bash"])
        }
    }

    test("removeProjectEntry: .mcp.json and Codex project entries leave their siblings") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            try f.manager.removeProjectEntry(try f.entry("shared"))
            try f.manager.removeProjectEntry(try f.entry("cx"))

            expectEqual((try readJSON(f.mcpJSON)["mcpServers"] as? [String: Any])?.keys.sorted(), ["keep"])
            expectEqual(try readText(f.codexTOML), """
            # project codex config

            [mcp_servers.after]
            command = "/after"

            """)
            expectEqual(try f.manager.projectMCPs(f.ref).map(\.name), ["local-db", "local-other", "keep", "after"])
        }
    }

    test("removeProjectEntry: an entry already gone throws notFound") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            let entry = try f.entry("local-other")
            try f.manager.removeProjectEntry(entry)
            expectThrows(MCPManagerError.notFound(name: "local-other")) { try f.manager.removeProjectEntry(entry) }
        }
    }

    test("updateProjectEntry: Claude local rename + new URL keeps keys MCP Manager doesn't model") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            let config = MCPServerConfig(transport: .http(url: "https://db2/mcp", headers: [:]), bearerTokenEnvVar: "DB_TOKEN")
            try f.manager.updateProjectEntry(try f.entry("local-db"), name: "db", config: config)

            let servers = try f.localServers()
            expectEqual(servers.keys.sorted(), ["db", "local-other"])
            let db = try require(servers["db"] as? [String: Any], "db missing")
            expectEqual(db["url"] as? String, "https://db2/mcp")
            expectEqual((db["headers"] as? [String: String])?["Authorization"], "Bearer ${DB_TOKEN}")
            expectEqual((db["oauth"] as? [String: String])?["clientId"], "abc")
            var reread = config
            reread.oauth = MCPOAuthHints(clientID: "abc")
            expectEqual(try f.entry("db").config, reread)
        }
    }

    test("updateProjectEntry: .mcp.json switches transport and drops the old transport's keys") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            try f.manager.updateProjectEntry(try f.entry("shared"), name: "shared",
                                             config: MCPServerConfig(transport: .stdio(command: "npx", args: ["-y", "s"], env: [:])))
            let shared = try require((try readJSON(f.mcpJSON)["mcpServers"] as? [String: Any])?["shared"] as? [String: Any],
                                     "shared missing")
            expectEqual(shared["command"] as? String, "npx")
            expectTrue(shared["url"] == nil, "old url should be gone, got \(shared)")
        }
    }

    test("updateProjectEntry: Codex edits in place, keeps unknown keys and sub-tables, renames them") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            let config = MCPServerConfig(transport: .stdio(command: "/cx2", args: [], env: ["TOKEN": "u"]))
            try f.manager.updateProjectEntry(try f.entry("cx"), name: "cx-new", config: config)

            expectEqual(try readText(f.codexTOML), """
            # project codex config
            [mcp_servers.cx-new]
            command = "/cx2"
            args = []
            startup_timeout_sec = 30
            [mcp_servers.cx-new.env]
            TOKEN = "u"
            [mcp_servers.cx-new.tools.search]
            approval = "never"

            [mcp_servers.after]
            command = "/after"

            """)
            expectEqual(try f.entry("cx-new").config, config)
        }
    }

    test("updateProjectEntry: Codex keeps a disabled entry disabled") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            try writeFile(f.codexTOML, "[mcp_servers.off]\ncommand = \"/off\"\nenabled = false\n")
            var config = try f.entry("off").config
            config.transport = .stdio(command: "/on", args: [], env: [:])
            try f.manager.updateProjectEntry(try f.entry("off"), name: "off", config: config)
            expectEqual(try f.entry("off").config.enabled, false)
            expectEqual(try f.entry("off").config.transport.summary, "/on")
        }
    }

    test("updateProjectEntry: a taken name, a bad name or SSE for Codex throws and writes nothing") {
        try withTempHome { home in
            let f = try ProjectFixture(home: home)
            let claudeBefore = try readText(f.paths.claudeJSON)
            let codexBefore = try readText(f.codexTOML)
            let stdio = MCPServerConfig(transport: .stdio(command: "/x", args: [], env: [:]))

            expectThrows(MCPManagerError.nameTaken(name: "local-other", client: .claude)) {
                try f.manager.updateProjectEntry(try f.entry("local-db"), name: "local-other", config: stdio)
            }
            expectThrows(MCPManagerError.nameTaken(name: "after", client: .codex)) {
                try f.manager.updateProjectEntry(try f.entry("cx"), name: "after", config: stdio)
            }
            expectThrows(MCPManagerError.invalidName("bad name")) {
                try f.manager.updateProjectEntry(try f.entry("cx"), name: "bad name", config: stdio)
            }
            expectThrows(MCPManagerError.io(path: f.codexTOML.path, detail: CodexConfigStore.sseSkipReason)) {
                try f.manager.updateProjectEntry(try f.entry("cx"), name: "cx",
                                                 config: MCPServerConfig(transport: .sse(url: "https://s", headers: [:])))
            }
            expectEqual(try readText(f.paths.claudeJSON), claudeBefore)
            expectEqual(try readText(f.codexTOML), codexBefore)
        }
    }
}
