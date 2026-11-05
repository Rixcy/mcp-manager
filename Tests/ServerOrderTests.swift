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

    test("remove: a removed server loses its place, so adding it again puts it on top") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            try manager.remove(name: "alpha")
            expectEqual(try names(manager), ["gamma", "Beta"])
            try manager.add(name: "alpha", config: stdio)
            expectEqual(try names(manager), ["alpha", "gamma", "Beta"])
        }
    }

    test("remove: taking a server out of one client keeps its place") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "Beta", "alpha"])
            try manager.remove(name: "Beta", from: [.claude])
            expectEqual(try names(manager), ["gamma", "Beta", "alpha"])
        }
    }

    test("rememberGlobalOrder: pins new servers on top without undoing a newer saved order") {
        try withOrderHome { manager, _ in
            try manager.saveGlobalOrder(["gamma", "alpha", "Beta"])
            // A refresh that read the configs before the user's reorder was saved.
            manager.rememberGlobalOrder(["Beta", "alpha", "gamma"])
            expectEqual(try names(manager), ["gamma", "alpha", "Beta"])

            try manager.add(name: "delta", config: stdio)
            manager.rememberGlobalOrder(try names(manager))
            try manager.add(name: "epsilon", config: stdio)
            expectEqual(try names(manager), ["epsilon", "delta", "gamma", "alpha", "Beta"])
        }
    }

    test("loadGlobal: an unreadable order file falls back to the added order") {
        try withOrderHome { manager, paths in
            try writeFile(paths.serverOrderFile, "not json")
            expectEqual(try names(manager), ["Beta", "alpha", "gamma"])
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
            try manager.rename("Beta", to: "zeta")
            expectEqual(try names(manager), ["gamma", "alpha", "zeta"])
        }
    }

    test("ServerOrder.moving: dragging up lands before the target, dragging down lands after it") {
        expectEqual(ServerOrder.moving("c", onto: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
        expectEqual(ServerOrder.moving("a", onto: "c", in: ["a", "b", "c"]), ["b", "c", "a"])
        expectEqual(ServerOrder.moving("b", onto: "b", in: ["a", "b", "c"]), ["a", "b", "c"])
        expectEqual(ServerOrder.moving("x", onto: "a", in: ["a", "b"]), ["a", "b"])
    }
}
