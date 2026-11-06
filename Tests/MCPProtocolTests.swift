import Foundation

private func decodeOne(_ text: String) throws -> JSONRPCMessage {
    let messages = try JSONRPCMessage.decode(Data(text.utf8))
    guard messages.count == 1 else { throw TestFailure(description: "expected 1 message, got \(messages.count)") }
    return messages[0]
}

private func malformedMethod(_ body: () throws -> Void) -> String? {
    do {
        try body()
    } catch let MCPClientError.malformedResponse(method, _) {
        return method
    } catch {
        fail("expected malformedResponse, got \(error)")
    }
    return nil
}

func runMCPProtocolTests() {
    test("JSON-RPC: decodes requests, notifications, results and errors") {
        expectEqual(try decodeOne(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#), .request(id: .int(7), method: "ping", params: nil))
        expectEqual(try decodeOne(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#),
                    .notification(method: "notifications/progress", params: ["progress": 1]))
        expectEqual(try decodeOne(#"{"jsonrpc":"2.0","id":"a","result":{}}"#), .response(id: .string("a"), result: [:]))
        expectEqual(try decodeOne(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#),
                    .errorResponse(id: nil, error: JSONRPCError(code: -32700, message: "Parse error")))
    }

    test("JSON-RPC: a batch decodes to every message; garbage is rejected with a reason") {
        let batch = try JSONRPCMessage.decode(Data(#"[{"jsonrpc":"2.0","id":1,"result":1},{"jsonrpc":"2.0","method":"x"}]"#.utf8))
        expectEqual(batch.count, 2)
        for bad in ["Server listening on 3000", "[]", "42", #"{"jsonrpc":"1.0","id":1,"result":1}"#, #"{"jsonrpc":"2.0","result":1}"#] {
            do {
                _ = try JSONRPCMessage.decode(Data(bad.utf8))
                fail("accepted \(bad)")
            } catch let error as JSONRPCDecodingError {
                expectTrue(!error.description.isEmpty, "no reason for \(bad)")
            }
        }
    }

    test("JSON-RPC: encodes one line, omitting absent params") {
        let request = JSONRPCMessage.request(id: .int(1), method: "tools/list", params: nil)
        expectEqual(String(decoding: request.encoded(), as: UTF8.self), #"{"id":1,"jsonrpc":"2.0","method":"tools/list"}"#)
        let error = JSONRPCMessage.errorResponse(id: .int(2), error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "nope"))
        expectEqual(try decodeOne(String(decoding: error.encoded(), as: UTF8.self)), error)
    }

    test("initialize: reads version, capabilities, server info and instructions") {
        let result = try MCPInitializeResult.decode([
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": ["listChanged": true], "logging": [:]],
            "serverInfo": ["name": "demo", "version": "1.2.0", "title": "Demo"],
            "instructions": "Call search first.",
        ])
        expectEqual(result.protocolVersion, "2025-06-18")
        expectEqual(result.serverInfo, MCPImplementation(name: "demo", version: "1.2.0", title: "Demo"))
        expectTrue(result.capabilities.tools && result.capabilities.toolsListChanged && result.capabilities.logging,
                   "capabilities lost: \(result.capabilities)")
        expectTrue(!result.capabilities.resources && !result.capabilities.prompts, "undeclared capabilities set")
        expectEqual(result.instructions, "Call search first.")
        expectEqual(malformedMethod { _ = try MCPInitializeResult.decode(["capabilities": [:]]) }, "initialize")
    }

    test("tools/list: decodes tools and keeps only a non-empty cursor") {
        let page = try MCPTool.page([
            "tools": [
                ["name": "search", "description": "Find things", "inputSchema": ["type": "object", "required": ["q"]],
                 "annotations": ["readOnlyHint": true, "title": "Search"]],
                ["name": "bare"],
            ],
            "nextCursor": "",
        ])
        expectEqual(page.nextCursor, nil)
        expectEqual(page.items.map(\.name), ["search", "bare"])
        expectEqual(page.items[0].displayTitle, "Search")
        expectEqual(page.items[0].annotations.readOnlyHint, true)
        expectEqual(page.items[1].inputSchema, ["type": "object"])
        expectEqual(try MCPTool.page(["tools": [], "nextCursor": "p2"]).nextCursor, "p2")
        expectEqual(malformedMethod { _ = try MCPTool.page(["tools": [["description": "nameless"]]]) }, "tools/list")
    }

    test("tools/call: decodes every content type and keeps unknown ones") {
        let result = try MCPToolResult.decode([
            "content": [
                ["type": "text", "text": "hello"],
                ["type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"],
                ["type": "resource_link", "uri": "file:///a.txt", "name": "a.txt"],
                ["type": "resource", "resource": ["uri": "mem://x", "text": "inline", "mimeType": "text/plain"]],
                ["type": "hologram", "beam": 1],
            ],
            "structuredContent": ["count": 2],
            "isError": true,
        ])
        expectEqual(result.content, [
            .text("hello"),
            .image(data: "iVBORw0KGgo=", mimeType: "image/png"),
            .resourceLink(MCPResourceLink(uri: "file:///a.txt", name: "a.txt")),
            .resource(MCPResourceContents(uri: "mem://x", mimeType: "text/plain", text: "inline")),
            .unknown(["type": "hologram", "beam": 1]),
        ])
        expectEqual(result.structuredContent, ["count": 2])
        expectTrue(result.isError, "isError lost")
    }

    test("tools/call: a 2024-11-05 toolResult becomes text; missing content is malformed") {
        expectEqual(try MCPToolResult.decode(["toolResult": ["ok": true]]).content, [.text("{\n  \"ok\": true\n}")])
        expectEqual(malformedMethod { _ = try MCPToolResult.decode(["isError": false]) }, "tools/call")
    }

    test("resources, templates and prompts decode with their arguments") {
        let resources = try MCPResource.page(["resources": [["uri": "file:///r", "name": "r", "size": 12]]]).items
        expectEqual(resources, [MCPResource(uri: "file:///r", name: "r", size: 12)])
        let contents = try MCPResource.contents(["contents": [["uri": "file:///r", "blob": "AAE="]]])
        expectEqual(contents, [MCPResourceContents(uri: "file:///r", blob: "AAE=")])
        let templates = try MCPResourceTemplate.page(["resourceTemplates": [["uriTemplate": "db://{table}", "name": "table"]]]).items
        expectEqual(templates.map(\.uriTemplate), ["db://{table}"])
        let prompts = try MCPPrompt.page(["prompts": [["name": "review", "arguments": [["name": "file", "required": true], ["name": "tone"]]]]]).items
        expectEqual(prompts[0].arguments, [MCPPromptArgument(name: "file", required: true), MCPPromptArgument(name: "tone")])
        let got = try MCPPromptResult.decode(["messages": [["role": "user", "content": ["type": "text", "text": "Review a.swift"]]]])
        expectEqual(got.messages, [MCPPromptMessage(role: "user", content: .text("Review a.swift"))])
    }

    test("progress: fraction is clamped and needs a positive total") {
        expectEqual(MCPProgress(progress: 5, total: 10).fraction, 0.5)
        expectEqual(MCPProgress(progress: 12, total: 10).fraction, 1)
        expectEqual(MCPProgress(progress: 3).fraction, nil)
        expectEqual(MCPProgress(progress: 3, total: 0).fraction, nil)
    }

    test("server target: keys, labels and log names for global and project entries") {
        let config = MCPServerConfig(transport: .stdio(command: "npx", args: [], env: [:]))
        let global = try require(MCPServerTarget.global(GlobalServer(name: "linear", claude: config, codex: config)), "no target")
        expectEqual(global.key, "global/linear")
        expectEqual(global.locationLabel, "Global · Claude and Codex")
        expectEqual(global.logFileName, "global-linear.jsonl")
        expectEqual(global.projectPath, nil)

        let entry = MCPEntry(name: "play wright", client: .claude, scope: .claudeProject(project: "/p/reels"), config: config,
                             sourcePath: "/p/reels/.mcp.json")
        let project = MCPServerTarget.project(entry)
        expectEqual(project.key, "project/claude/mcp-json//p/reels/.mcp.json/play wright")
        expectEqual(project.locationLabel, "reels · .mcp.json")
        expectEqual(project.projectPath, "/p/reels")
        // Log file names must not change between releases, or old logs are orphaned.
        expectEqual(project.logFileName, "reels-play_wright-\(MCPServerTarget.shortHash(project.key)).jsonl")
        expectEqual(MCPServerTarget.shortHash("project/claude/mcp-json//p/reels/.mcp.json/play wright"), "79709794")
        expectTrue(MCPServerTarget.shortHash("a") != MCPServerTarget.shortHash("b"), "hash ignores input")
    }
}
