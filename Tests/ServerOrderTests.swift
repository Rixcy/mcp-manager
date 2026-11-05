import Foundation

private let orderClaudeJSON = #"{"mcpServers": {"gamma": {"command": "/g"}, "Beta": {"type": "http", "url": "https://b"}}}"#
private let orderCodexTOML = "[mcp_servers.alpha]\ncommand = \"/a\"\n\n[mcp_servers.Beta]\nurl = \"https://b2\"\n"
private let stdio = MCPServerConfig(transport: .stdio(command: "/bin/tool", args: [], env: [:]))

private func withOrderHome(_ body: (MCPManager, ConfigPaths) throws -> Void) throws {
    try withTempHome { home in
        let paths = ConfigPaths(home: home)
        try writeFile(paths.claudeJSON, orderClaudeJSON)
        try writeFile(paths.codexTOML, orderCodexTOML)
        try body(MCPManager(paths: paths), paths)
    }
}

private func names(_ manager: MCPManager) throws -> [String] {
    try MCPManager(paths: manager.paths).loadGlobal().map(\.name)
}

func runServerOrderTests() {
    test("loadGlobal: with no saved order, newest Codex entry first, then Claude-only names") {
        try withOrderHome { manager, _ in
            expectEqual(try names(manager), ["Beta", "alpha", "gamma"])
        }
    }

    test("loadGlobal: a saved order survives reloads") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            expectEqual(try names(manager), ["gamma", "alpha", "Beta"])
        }
    }

    test("loadGlobal: a server missing from the saved order goes on top") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            try manager.add(name: "delta", config: stdio)
            expectEqual(try names(manager), ["delta", "gamma", "alpha", "Beta"])
        }
    }

    test("saveGlobalOrder: names no longer configured are ignored, and a re-added one returns on top") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            try manager.remove(name: "alpha")
            try manager.saveGlobalOrder(try names(manager))
            try manager.add(name: "alpha", config: stdio)
            expectEqual(try names(manager), ["alpha", "gamma", "Beta"])
        }
    }

    test("updateGlobal: a renamed server keeps its place") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            try manager.updateGlobal("alpha", to: "omega", config: stdio)
            expectEqual(try names(manager), ["gamma", "omega", "Beta"])
        }
    }

    test("rename: a renamed server keeps its place") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            try manager.rename("gamma", to: "zeta")
            expectEqual(try names(manager), ["zeta", "alpha", "Beta"])
        }
    }

    test("ServerOrder.moving: dragging up lands before the target, dragging down lands after it") {
        expectEqual(ServerOrder.moving("c", onto: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
        expectEqual(ServerOrder.moving("a", onto: "c", in: ["a", "b", "c"]), ["b", "c", "a"])
        expectEqual(ServerOrder.moving("b", onto: "b", in: ["a", "b", "c"]), ["a", "b", "c"])
        expectEqual(ServerOrder.moving("x", onto: "a", in: ["a", "b"]), ["a", "b"])
    }
}
