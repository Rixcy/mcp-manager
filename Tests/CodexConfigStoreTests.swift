import Foundation

/// Blank-line-separated style with comments, to prove edits leave them alone.
private let commentedTOML = """
# Codex settings
model = "gpt-5"

# servers below
[mcp_servers.node_repl]
command = "/n"
args = ["--x", "y"]  # inline comment
startup_timeout_sec = 120
[mcp_servers.node_repl.env]
FOO = "bar"

# Linear's hosted MCP
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"

[mcp_servers."quoted.name"]
url = "http://localhost:3001/mcp"
http_headers = { "X-Key" = "v" }

[projects."/Users/me/Projects/foo"]
trust_level = "trusted"
[plugins."documents@openai"]
enabled = true

"""

private func withCodexFile(_ text: String?, _ body: (CodexConfigStore, URL) throws -> Void) throws {
    try withTempHome { home in
        let url = home.appendingPathComponent(".codex/config.toml")
        if let text { try writeFile(url, text) }
        try body(CodexConfigStore(url: url, io: FileIO(backupDir: home.appendingPathComponent("backups"))), url)
    }
}

func runCodexConfigStoreTests() {
    test("Codex remove: drops the server and its env table, every other byte unchanged") {
        try withCodexFile(commentedTOML) { store, url in
            try store.remove(name: "node_repl")
            expectEqual(try readText(url), """
            # Codex settings
            model = "gpt-5"

            # servers below

            # Linear's hosted MCP
            [mcp_servers.linear]
            url = "https://mcp.linear.app/mcp"

            [mcp_servers."quoted.name"]
            url = "http://localhost:3001/mcp"
            http_headers = { "X-Key" = "v" }

            [projects."/Users/me/Projects/foo"]
            trust_level = "trusted"
            [plugins."documents@openai"]
            enabled = true

            """)
        }
    }

    test("Codex remove: quoted name, and the blank lines around it collapse to one") {
        try withCodexFile(commentedTOML) { store, url in
            try store.remove(name: "quoted.name")
            expectEqual(try readText(url), """
            # Codex settings
            model = "gpt-5"

            # servers below
            [mcp_servers.node_repl]
            command = "/n"
            args = ["--x", "y"]  # inline comment
            startup_timeout_sec = 120
            [mcp_servers.node_repl.env]
            FOO = "bar"

            # Linear's hosted MCP
            [mcp_servers.linear]
            url = "https://mcp.linear.app/mcp"

            [projects."/Users/me/Projects/foo"]
            trust_level = "trusted"
            [plugins."documents@openai"]
            enabled = true

            """)
        }
    }

    test("Codex remove: env table split off by a blank line and comment goes with its server") {
        let text = """
        model = "x"

        [mcp_servers.a]
        command = "/a"

        # env for a
        [mcp_servers.a.env]
        K = "v"

        [mcp_servers.b]
        url = "http://b"

        """
        try withCodexFile(text) { store, url in
            try store.remove(name: "a")
            expectEqual(try readText(url), "model = \"x\"\n\n[mcp_servers.b]\nurl = \"http://b\"\n")
        }
    }

    test("Codex remove: unknown name throws notFound and leaves the file alone") {
        try withCodexFile(sampleCodexTOML) { store, url in
            expectThrows(MCPManagerError.notFound(name: "nope")) { try store.remove(name: "nope") }
            expectEqual(try readText(url), sampleCodexTOML)
        }
    }

    test("Codex rename: rewrites only the server and env header lines") {
        try withCodexFile(commentedTOML) { store, url in
            try store.rename("node_repl", to: "repl")
            let expected = commentedTOML
                .replacingOccurrences(of: "[mcp_servers.node_repl]", with: "[mcp_servers.repl]")
                .replacingOccurrences(of: "[mcp_servers.node_repl.env]", with: "[mcp_servers.repl.env]")
            expectEqual(try readText(url), expected)
            expectEqual(try store.servers()["repl"]?.transport,
                        .stdio(command: "/n", args: ["--x", "y"], env: ["FOO": "bar"]))
        }
    }

    test("Codex rename: quoted old name becomes bare; a non-bare new name gets quoted") {
        try withCodexFile(sampleCodexTOML) { store, url in
            try store.rename("quoted.name", to: "local")
            try store.rename("node_repl", to: "a.b")
            let text = try readText(url)
            expectTrue(text.contains("\n[mcp_servers.local]\n"), "quoted header not rewritten:\n\(text)")
            expectTrue(text.contains("\n[mcp_servers.\"a.b\"]\n") && text.contains("\n[mcp_servers.\"a.b\".env]\n"),
                       "new name not quoted:\n\(text)")
            expectEqual(try store.servers().keys.sorted(), ["a.b", "linear", "local", "pencil"])
        }
    }

    test("Codex rename: server defined inline under [mcp_servers] is renamed too") {
        try withCodexFile("[mcp_servers]\nold = { command = \"/o\" }  # keep\n") { store, url in
            try store.rename("old", to: "new")
            expectEqual(try readText(url), "[mcp_servers]\nnew = { command = \"/o\" }  # keep\n")
        }
    }

    test("Codex add: stdio block lands after the last server, before [projects]") {
        try withCodexFile(sampleCodexTOML) { store, url in
            try store.add(name: "fs", config: MCPServerConfig(
                transport: .stdio(command: #"/usr/local/bin/fs "x""#, args: ["--root", #"C:\data"#],
                                  env: ["Z": "last", "API_KEY": "k"]),
                enabled: false))
            let expected = sampleCodexTOML.replacingOccurrences(of: "[projects.", with: #"""
            [mcp_servers.fs]
            command = "/usr/local/bin/fs \"x\""
            args = ["--root", "C:\\data"]
            enabled = false
            [mcp_servers.fs.env]
            API_KEY = "k"
            Z = "last"
            [projects.
            """#)
            expectEqual(try readText(url), expected)
        }
    }

    test("Codex add: http block with headers and bearer, blank-line style kept") {
        try withCodexFile(commentedTOML) { store, url in
            try store.add(name: "remote", config: MCPServerConfig(
                transport: .http(url: "https://r.example/mcp", headers: ["X-Key": "v", "X Custom": "a"]),
                bearerTokenEnvVar: "R_TOKEN"))
            let expected = commentedTOML.replacingOccurrences(of: "http_headers = { \"X-Key\" = \"v\" }\n", with: """
            http_headers = { "X-Key" = "v" }

            [mcp_servers.remote]
            url = "https://r.example/mcp"
            http_headers = { "X Custom" = "a", X-Key = "v" }
            bearer_token_env_var = "R_TOKEN"

            """)
            expectEqual(try readText(url), expected)
            expectEqual(try store.servers()["remote"], MCPServerConfig(
                transport: .http(url: "https://r.example/mcp", headers: ["X-Key": "v", "X Custom": "a"]),
                bearerTokenEnvVar: "R_TOKEN"))
        }
    }

    test("Codex add: file without servers gets the block appended after a blank line") {
        try withCodexFile("model = \"x\"") { store, url in
            try store.add(name: "a", config: MCPServerConfig(transport: .http(url: "http://a", headers: [:])))
            expectEqual(try readText(url), "model = \"x\"\n\n[mcp_servers.a]\nurl = \"http://a\"\n")
        }
    }

    test("Codex add: missing file and directory are created and read back") {
        try withCodexFile(nil) { store, url in
            let config = MCPServerConfig(transport: .stdio(command: "npx", args: ["-y", "pkg"], env: ["K": "v w"]))
            try store.add(name: "new", config: config)
            expectEqual(try readText(url), "[mcp_servers.new]\ncommand = \"npx\"\nargs = [\"-y\", \"pkg\"]\n[mcp_servers.new.env]\nK = \"v w\"\n")
            expectEqual(try store.servers()["new"], config)
        }
    }

    test("Codex add: existing name throws nameTaken") {
        try withCodexFile(sampleCodexTOML) { store, url in
            expectThrows(MCPManagerError.nameTaken(name: "linear", client: .codex)) {
                try store.add(name: "linear", config: MCPServerConfig(transport: .http(url: "http://l", headers: [:])))
            }
            expectEqual(try readText(url), sampleCodexTOML)
        }
    }
}
