import Foundation

/// A trimmed `~/.claude.json`: unrelated keys Claude Code owns, plus servers.
let sampleClaudeJSON = #"""
{
  "numStartups": 412,
  "theme": "dark",
  "tipsHistory": { "memory-command": 7 },
  "projects": {
    "/Users/me/Projects/foo": {
      "allowedTools": [],
      "mcpServers": {
        "local-db": { "type": "stdio", "command": "/bin/db", "args": ["--ro"], "env": {} }
      }
    }
  },
  "mcpServers": {
    "figma": {
      "type": "http",
      "url": "https://mcp.figma.com/mcp",
      "oauth": { "clientId": "abc123", "callbackPort": 8765 }
    },
    "legacy": { "command": "/usr/bin/legacy", "args": ["a"], "env": { "PORT": 8080 } },
    "events": { "type": "sse", "url": "https://e.example/sse", "headers": { "X-A": "1" } },
    "authed": { "type": "http", "url": "https://a.example/mcp", "headers": { "Authorization": "Bearer ${A_TOKEN}", "X-B": "2" } },
    "literal-auth": { "type": "http", "url": "https://l.example/mcp", "headers": { "Authorization": "Bearer abc" } }
  }
}
"""#

private func withClaudeFile(_ text: String?, _ body: (ClaudeConfigStore, URL) throws -> Void) throws {
    try withTempHome { home in
        let url = home.appendingPathComponent(".claude.json")
        if let text { try writeFile(url, text) }
        try body(ClaudeConfigStore(url: url, io: FileIO(backupDir: home.appendingPathComponent("backups"))), url)
    }
}

/// Everything except `mcpServers`, for comparing untouched keys.
private func unrelatedKeys(_ root: [String: Any]) -> NSDictionary {
    var copy = root
    copy.removeValue(forKey: "mcpServers")
    return copy as NSDictionary
}

func runClaudeConfigStoreTests() {
    test("Claude read: stdio without type, sse, http, and bearer header mapping") {
        try withClaudeFile(sampleClaudeJSON) { store, _ in
            let servers = try store.servers()
            expectEqual(servers["legacy"], MCPServerConfig(transport: .stdio(command: "/usr/bin/legacy", args: ["a"], env: ["PORT": "8080"])))
            expectEqual(servers["events"], MCPServerConfig(transport: .sse(url: "https://e.example/sse", headers: ["X-A": "1"])))
            expectEqual(servers["figma"], MCPServerConfig(transport: .http(url: "https://mcp.figma.com/mcp", headers: [:]),
                                                         oauth: MCPOAuthHints(clientID: "abc123", callbackPort: 8765)))
            expectEqual(servers["authed"], MCPServerConfig(
                transport: .http(url: "https://a.example/mcp", headers: ["X-B": "2"]), bearerTokenEnvVar: "A_TOKEN"))
            expectEqual(servers["literal-auth"], MCPServerConfig(
                transport: .http(url: "https://l.example/mcp", headers: ["Authorization": "Bearer abc"])))
            expectEqual(try store.localServers(project: "/Users/me/Projects/foo/")["local-db"]?.transport,
                        .stdio(command: "/bin/db", args: ["--ro"], env: [:]))
        }
    }

    test("Claude add: writes the entry shape and keeps every unrelated key") {
        try withClaudeFile(sampleClaudeJSON) { store, url in
            let before = try readJSON(url)
            try store.add(name: "remote", config: MCPServerConfig(
                transport: .http(url: "https://r.example/mcp", headers: ["X-K": "v"]), bearerTokenEnvVar: "R_TOKEN"))
            try store.add(name: "tool", config: MCPServerConfig(transport: .stdio(command: "npx", args: ["-y", "t"], env: ["A": "1"])))
            let after = try readJSON(url)
            expectTrue(unrelatedKeys(after).isEqual(to: unrelatedKeys(before) as! [AnyHashable: Any]), "unrelated keys changed")
            let servers = try require(after["mcpServers"] as? [String: Any], "mcpServers missing")
            expectTrue((servers["remote"] as? NSDictionary)?.isEqual(to: [
                "type": "http", "url": "https://r.example/mcp",
                "headers": ["X-K": "v", "Authorization": "Bearer ${R_TOKEN}"],
            ]) == true, "remote entry: \(servers["remote"] ?? "nil")")
            expectTrue((servers["tool"] as? NSDictionary)?.isEqual(to: [
                "type": "stdio", "command": "npx", "args": ["-y", "t"], "env": ["A": "1"],
            ]) == true, "tool entry: \(servers["tool"] ?? "nil")")
            expectEqual(servers.count, 7)
            expectTrue(!(try readText(url)).contains(#"\/"#), "slashes were escaped")
        }
    }

    test("Claude rename: moves the original object verbatim, oauth included") {
        try withClaudeFile(sampleClaudeJSON) { store, url in
            let before = try readJSON(url)
            let original = try require((before["mcpServers"] as? [String: Any])?["figma"] as? NSDictionary, "figma missing")
            try store.rename("figma", to: "figma-design")
            let after = try readJSON(url)
            let servers = try require(after["mcpServers"] as? [String: Any], "mcpServers missing")
            expectTrue(servers["figma"] == nil, "old name still present")
            expectTrue((servers["figma-design"] as? NSDictionary)?.isEqual(to: original as! [AnyHashable: Any]) == true,
                       "renamed entry differs: \(servers["figma-design"] ?? "nil")")
            expectTrue(unrelatedKeys(after).isEqual(to: unrelatedKeys(before) as! [AnyHashable: Any]), "unrelated keys changed")
        }
    }

    test("Claude remove: deletes only that server") {
        try withClaudeFile(sampleClaudeJSON) { store, url in
            try store.remove(name: "events")
            let after = try readJSON(url)
            expectEqual((after["mcpServers"] as? [String: Any])?.keys.sorted(), ["authed", "figma", "legacy", "literal-auth"])
            expectEqual(after["numStartups"] as? Int, 412)
            expectThrows(MCPManagerError.notFound(name: "events")) { try store.remove(name: "events") }
        }
    }

    test("Claude add: missing file is created with just mcpServers") {
        try withClaudeFile(nil) { store, url in
            try store.add(name: "s", config: MCPServerConfig(transport: .sse(url: "https://s/sse", headers: [:])))
            let root = try readJSON(url)
            expectEqual(Array(root.keys), ["mcpServers"])
            expectTrue(((root["mcpServers"] as? [String: Any])?["s"] as? NSDictionary)?.isEqual(to: ["type": "sse", "url": "https://s/sse"]) == true,
                       "entry: \(root)")
        }
    }

    test("Claude read: invalid JSON is a parse error naming the file") {
        try withClaudeFile("{ not json") { store, url in
            do {
                _ = try store.servers()
                fail("expected a parse error")
            } catch let MCPManagerError.parse(path, _) {
                expectEqual(path, url.path)
            }
        }
    }
}
