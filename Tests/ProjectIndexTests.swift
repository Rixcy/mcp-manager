import Foundation

func runProjectIndexTests() {
    test("projects: union of Claude and Codex keys, deduped, existing dirs only, sorted by name") {
        try withTempHome { home in
            let paths = ConfigPaths(home: home)
            let dir = { (rel: String) in home.appendingPathComponent(rel).path }
            for rel in ["Projects/foo", "Projects/bar", "Projects/Alpha", "a/foo"] {
                try FileManager.default.createDirectory(atPath: dir(rel), withIntermediateDirectories: true)
            }
            try writeFile(home.appendingPathComponent("notes.txt"), "not a dir")
            let claudeProjects: [String: Any] = [
                dir("Projects/foo"): [:], dir("Projects/bar") + "/": [:], dir("Projects/gone"): [:],
                home.path: [:], dir("notes.txt"): [:], dir("a/./foo"): [:],
            ]
            try JSONSerialization.data(withJSONObject: ["projects": claudeProjects]).write(to: paths.claudeJSON)
            try writeFile(paths.codexTOML, """
            [projects."\(dir("Projects/bar"))"]
            trust_level = "trusted"
            [projects.'\(dir("Projects/Alpha"))']
            trust_level = "trusted"
            """)
            let projects = MCPManager(paths: paths).projects()
            expectEqual(projects.map(\.path), [
                dir("Projects/Alpha"), dir("Projects/bar"), dir("a/foo"), dir("Projects/foo"), home.path,
            ].sorted { a, b in
                let na = (a as NSString).lastPathComponent, nb = (b as NSString).lastPathComponent
                let order = na.localizedCaseInsensitiveCompare(nb)
                return order == .orderedSame ? a < b : order == .orderedAscending
            })
            expectEqual(projects.map(\.name).prefix(4), ["Alpha", "bar", "foo", "foo"])
        }
    }

    test("projects: an unreadable Codex config still lists Claude projects") {
        try withTempHome { home in
            let paths = ConfigPaths(home: home)
            try JSONSerialization.data(withJSONObject: ["projects": [home.path: [:]]]).write(to: paths.claudeJSON)
            try writeFile(paths.codexTOML, "[mcp_servers.x]\ncommand = \"unterminated\n")
            expectEqual(MCPManager(paths: paths).projects().map(\.path), [home.path])
        }
    }

    test("projectMCPs: Claude local, .mcp.json and .codex/config.toml with scopes and sources") {
        try withTempHome { home in
            let paths = ConfigPaths(home: home)
            let project = home.appendingPathComponent("Projects/app")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let claude: [String: Any] = [
                "mcpServers": ["global-only": ["command": "/g"]],
                "projects": [project.path: ["mcpServers": ["local-db": ["type": "stdio", "command": "/db", "args": [], "env": [:]]]]],
            ]
            try JSONSerialization.data(withJSONObject: claude).write(to: paths.claudeJSON)
            try writeFile(project.appendingPathComponent(".mcp.json"),
                          #"{"mcpServers": {"shared": {"type": "http", "url": "https://shared/mcp"}}}"#)
            try writeFile(project.appendingPathComponent(".codex/config.toml"),
                          "[mcp_servers.cx]\ncommand = \"/cx\"\nenabled = false\n")
            try writeFile(paths.codexTOML, "[mcp_servers.global-codex]\ncommand = \"/gc\"\n")

            let p = project.path
            let entries = try MCPManager(paths: paths).projectMCPs(ProjectRef(path: p))
            expectEqual(entries, [
                MCPEntry(name: "local-db", client: .claude, scope: .claudeLocal(project: p),
                         config: MCPServerConfig(transport: .stdio(command: "/db", args: [], env: [:])),
                         sourcePath: paths.claudeJSON.path),
                MCPEntry(name: "shared", client: .claude, scope: .claudeProject(project: p),
                         config: MCPServerConfig(transport: .http(url: "https://shared/mcp", headers: [:])),
                         sourcePath: project.appendingPathComponent(".mcp.json").path),
                MCPEntry(name: "cx", client: .codex, scope: .codexProject(project: p),
                         config: MCPServerConfig(transport: .stdio(command: "/cx", args: [], env: [:]), enabled: false),
                         sourcePath: project.appendingPathComponent(".codex/config.toml").path),
            ])
        }
    }

    test("projectMCPs: the home project does not repeat the global Codex config") {
        try withTempHome { home in
            let paths = ConfigPaths(home: home)
            try writeFile(paths.codexTOML, "[mcp_servers.global-codex]\ncommand = \"/gc\"\n")
            try writeFile(home.appendingPathComponent(".mcp.json"), #"{"mcpServers": {"h": {"command": "/h"}}}"#)
            let entries = try MCPManager(paths: paths).projectMCPs(ProjectRef(path: home.path))
            expectEqual(entries.map(\.name), ["h"])
        }
    }
}
