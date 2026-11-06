import Foundation

/// The Codex config shape seen in the wild, used across the TOML and Codex tests.
let sampleCodexTOML = """
model = "gpt-5"
[mcp_servers.node_repl]
command = "/Applications/Codex.app/Contents/Resources/node_repl"
args = ["--x", "y"]
startup_timeout_sec = 120
[mcp_servers.node_repl.env]
FOO = "bar"
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"
[mcp_servers.pencil]
command = "/x"
args = []
enabled = false
[mcp_servers."quoted.name"]
url = "http://localhost:3001/mcp"
http_headers = { "X-Key" = "v" }
bearer_token_env_var = "TOKEN_VAR"
[projects."/Users/me/Projects/foo"]
trust_level = "trusted"
[plugins."documents@openai"]
enabled = true

"""

func runMiniTOMLTests() {
    test("TOML: sample config yields all four servers with transports, env, enabled and bearer") {
        let doc = try MiniTOML.parse(sampleCodexTOML, path: "config.toml")
        let servers = CodexConfigStore.servers(in: doc)
        expectEqual(servers.keys.sorted(), ["linear", "node_repl", "pencil", "quoted.name"])
        expectEqual(servers["node_repl"], MCPServerConfig(transport: .stdio(
            command: "/Applications/Codex.app/Contents/Resources/node_repl", args: ["--x", "y"], env: ["FOO": "bar"])))
        expectEqual(servers["linear"], MCPServerConfig(transport: .http(url: "https://mcp.linear.app/mcp", headers: [:])))
        expectEqual(servers["pencil"], MCPServerConfig(transport: .stdio(command: "/x", args: [], env: [:]), enabled: false))
        expectEqual(servers["quoted.name"], MCPServerConfig(
            transport: .http(url: "http://localhost:3001/mcp", headers: ["X-Key": "v"]), bearerTokenEnvVar: "TOKEN_VAR"))
        expectEqual(doc.root["projects"]?.table?.keys.sorted(), ["/Users/me/Projects/foo"])
        expectEqual(doc.root["mcp_servers"]?.table?["node_repl"]?.table?["startup_timeout_sec"], .integer(120))
    }

    test("TOML: multi-line arrays, comments, inline env, literal strings and escapes") {
        let text = #"""
        # leading comment
        [mcp_servers.multi]   # trailing comment on header
        command = 'C:\tools\run.exe'
        args = [
          "--a",   # comment inside array
          'lit "q"',
          "tab\there \u00e9 \"quoted\" back\\slash",
        ]
        env = { A = "1", "B.C" = 'two', N = 3 }
        note = """
        multi
        line"""
        """#
        let doc = try MiniTOML.parse(text, path: "config.toml")
        let config = try require(CodexConfigStore.servers(in: doc)["multi"], "multi missing")
        expectEqual(config.transport, .stdio(
            command: #"C:\tools\run.exe"#,
            args: ["--a", #"lit "q""#, "tab\there é \"quoted\" back\\slash"],
            env: ["A": "1", "B.C": "two", "N": "3"]))
        expectEqual(doc.root["mcp_servers"]?.table?["multi"]?.table?["note"], .string("multi\nline"))
    }

    test("TOML: scalar types, dates and arrays of tables do not break parsing") {
        let text = """
        when = 1979-05-27T07:32:00Z
        local = 1979-05-27 07:32:00
        hex = 0xFF
        big = 1_000
        pi = 3.14
        exp = -2e3
        flag = true
        [[profiles.list]]
        name = "a"
        [[profiles.list]]
        name = "b"
        [mcp_servers.after]
        url = "http://x"
        """
        let doc = try MiniTOML.parse(text, path: "config.toml")
        expectEqual(doc.root["when"], .opaque("1979-05-27T07:32:00Z"))
        expectEqual(doc.root["local"], .opaque("1979-05-27 07:32:00"))
        expectEqual(doc.root["hex"], .integer(255))
        expectEqual(doc.root["big"], .integer(1000))
        expectEqual(doc.root["pi"], .float(3.14))
        expectEqual(doc.root["exp"], .float(-2000))
        expectEqual(doc.root["flag"], .bool(true))
        expectEqual(Array(CodexConfigStore.servers(in: doc).keys), ["after"])
        expectEqual(doc.skippedErrors, [])
    }

    test("TOML: a broken line in an unrelated table is skipped, servers still read") {
        let text = """
        [tui]
        theme = ???
        [mcp_servers.ok]
        command = "/bin/ok"
        """
        let doc = try MiniTOML.parse(text, path: "config.toml")
        expectEqual(CodexConfigStore.servers(in: doc)["ok"]?.transport, .stdio(command: "/bin/ok", args: [], env: [:]))
        expectEqual(doc.skippedErrors.count, 1)
    }

    test("TOML: a broken line inside mcp_servers throws a parse error with the path") {
        let text = """
        [mcp_servers.bad]
        command = "/bin/x
        """
        expectThrows(MCPManagerError.parse(path: "/p/config.toml", detail: "line 2: unterminated string")) {
            _ = try MiniTOML.parse(text, path: "/p/config.toml")
        }
    }

    test("TOML: keys are quoted only when they are not bare") {
        expectEqual(MiniTOML.renderPath(["mcp_servers", "plain-name_1"]), "mcp_servers.plain-name_1")
        expectEqual(MiniTOML.renderPath(["mcp_servers", "a.b"]), #"mcp_servers."a.b""#)
        let tricky = "q\"uote\\back\nline\u{01}"
        let doc = try MiniTOML.parse("k = \(MiniTOML.quote(tricky))\n", path: "x")
        expectEqual(doc.root["k"], .string(tricky))
    }
}
