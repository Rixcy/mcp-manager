import Foundation

func runMCPLogFileTests() {
    runLogFileWriteTests()
    runLogFileRotationTests()
    runLogFormattingTests()
}

private final class EntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MCPLogEntry] = []

    func add(_ entry: MCPLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(entry)
    }

    var entries: [MCPLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func diskLines(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

private func lineObject(_ line: String) throws -> [String: Any] {
    try require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not a JSON object: \(line)")
}

private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
}

// MARK: Writing

private func runLogFileWriteTests() {
    test("log file: onEntry sees entries at once, the disk only after the flush interval") {
        try withTempHome { home in
            let url = home.appendingPathComponent("logs/global-linear.jsonl")
            let collector = EntryCollector()
            let log = MCPLogFile(url: url, flushInterval: 0.3, onEntry: { collector.add($0) })
            log.record(.outgoing, "→ tools/call #3", detail: "{\"name\":\"search\"}")
            log.record(.stderr, "starting up", detail: nil)
            expectEqual(collector.entries.map(\.summary), ["→ tools/call #3", "starting up"])
            expectEqual(diskLines(url), [], "nothing is written before the flush interval")

            Thread.sleep(forTimeInterval: 0.8)
            let lines = diskLines(url)
            expectEqual(lines.count, 2)
            let first = try lineObject(try require(lines.first, "first line"))
            expectEqual(first["k"] as? String, "outgoing")
            expectEqual(first["s"] as? String, "→ tools/call #3")
            expectEqual(first["d"] as? String, "{\"name\":\"search\"}")
            let stamp = try require(first["t"] as? String, "timestamp")
            expectTrue(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression) != nil,
                       "timestamp is ISO 8601 UTC with milliseconds: \(stamp)")
            let second = try lineObject(lines[1])
            expectTrue(second["d"] == nil, "a nil detail is omitted, not written as null")
            expectTrue(lines[0].hasPrefix("{\"t\":"), "keys keep the documented order: \(lines[0])")

            expectEqual(mode(url.path), 0o600)
            expectEqual(mode(url.deletingLastPathComponent().path), 0o700)
            log.close()
        }
    }

    test("log file: flush() writes everything recorded before it") {
        try withTempHome { home in
            let url = home.appendingPathComponent("a.jsonl")
            let log = MCPLogFile(url: url, flushInterval: 60)
            for index in 0..<5 { log.record(.event, "event \(index)", detail: nil) }
            log.flush()
            expectEqual(diskLines(url).count, 5)
            log.close()
        }
    }

    test("log file: 64 KB of pending entries is written without waiting for the timer") {
        try withTempHome { home in
            let url = home.appendingPathComponent("big.jsonl")
            let log = MCPLogFile(url: url, flushInterval: 60)
            let detail = String(repeating: "x", count: 1024)
            for index in 0..<80 { log.record(.incoming, "chunk \(index)", detail: detail) }
            Thread.sleep(forTimeInterval: 0.3)
            expectTrue(diskLines(url).count >= 60, "expected a size-triggered flush, found \(diskLines(url).count) lines")
            log.close()
        }
    }

    test("log file: after close, entries reach onEntry but not the disk") {
        try withTempHome { home in
            let url = home.appendingPathComponent("closed.jsonl")
            let collector = EntryCollector()
            let log = MCPLogFile(url: url, flushInterval: 60, onEntry: { collector.add($0) })
            log.record(.event, "before", detail: nil)
            log.close()
            expectEqual(diskLines(url).count, 1, "close flushes")
            log.record(.event, "after", detail: nil)
            log.flush()
            expectEqual(diskLines(url).count, 1)
            expectEqual(collector.entries.map(\.summary), ["before", "after"])
        }
    }

    test("log file: writing continues into a new file after clear") {
        try withTempHome { home in
            let url = home.appendingPathComponent("cleared.jsonl")
            let log = MCPLogFile(url: url, flushInterval: 60)
            log.record(.event, "old", detail: nil)
            log.flush()
            try MCPLogFile.clear(url: url)
            log.record(.event, "new", detail: nil)
            log.flush()
            expectEqual(MCPLogFile.readTail(url: url, limit: 10).map(\.summary), ["new"])
            log.close()
        }
    }

    test("log file: 10,000 records are buffered, not written one by one") {
        try withTempHome { home in
            let url = home.appendingPathComponent("busy.jsonl")
            let log = MCPLogFile(url: url, maxBytes: 50_000_000)
            let started = Date()
            for index in 0..<10_000 {
                log.record(.incoming, "← notifications/progress #\(index)", detail: "{\"progress\":\(index)}")
            }
            log.flush()
            let elapsed = Date().timeIntervalSince(started)
            expectTrue(elapsed < 2, "10,000 records took \(elapsed) s")
            expectEqual(diskLines(url).count, 10_000)
            log.close()
        }
    }
}

// MARK: Rotation and reading

private func runLogFileRotationTests() {
    test("log file: rotation keeps keepFiles copies and the newest entries") {
        try withTempHome { home in
            let url = home.appendingPathComponent("global-linear.jsonl")
            let log = MCPLogFile(url: url, maxBytes: 600, keepFiles: 2, flushInterval: 60)
            for index in 0..<60 {
                log.record(.event, "entry \(index)", detail: nil)
                log.flush()
            }
            log.close()
            let names = try FileManager.default.contentsOfDirectory(atPath: home.path).sorted()
            expectEqual(names, ["global-linear.1.jsonl", "global-linear.2.jsonl", "global-linear.jsonl"])
            for name in names {
                let size = try require(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path)[.size] as? Int, "size")
                expectTrue(size <= 600, "\(name) is \(size) bytes, over maxBytes")
            }
            let current = diskLines(url).compactMap { try? lineObject($0)["s"] as? String }
            expectEqual(current.last, "entry 59")

            let all = MCPLogFile.readTail(url: url, limit: 1000).map(\.summary)
            expectTrue(all.count < 60, "old entries were rotated away")
            expectEqual(all, (60 - all.count..<60).map { "entry \($0)" }, "every kept entry, oldest first, none skipped")

            // Spans the current file and the newest rotated copy.
            let spanning = MCPLogFile.readTail(url: url, limit: current.count + 2).map(\.summary)
            expectEqual(spanning, (58 - current.count..<60).map { "entry \($0)" })
        }
    }

    test("log file: readTail skips malformed and partial lines and assigns fresh ids") {
        try withTempHome { home in
            let url = home.appendingPathComponent("tail.jsonl")
            let rotated = home.appendingPathComponent("tail.1.jsonl")
            try writeFile(rotated, """
            {"t":"2026-11-06T09:33:44.000Z","k":"event","s":"launched"}

            """)
            try writeFile(url, """
            {"t":"2026-11-06T09:33:45.738Z","k":"outgoing","s":"→ initialize #1","d":"{}"}
            this is not json
            {"t":"2026-11-06T09:33:45.900Z","k":"mystery","s":"unknown kind"}
            {"t":"2026-11-06T09:33:46.001Z","k":"incoming","s":"← initialize #1"}
            {"t":"2026-11-06T09:33:46.5
            """)
            let entries = MCPLogFile.readTail(url: url, limit: 10)
            expectEqual(entries.map(\.summary), ["launched", "→ initialize #1", "← initialize #1"])
            expectEqual(entries.map(\.kind), [.event, .outgoing, .incoming])
            expectEqual(entries[1].detail, "{}")
            expectEqual(entries[0].detail, nil)
            let expectedTime = try require(ISO8601DateFormatter().date(from: "2026-11-06T09:33:45Z"), "date")
            expectEqual((entries[1].time.timeIntervalSince(expectedTime) * 1000).rounded(), 738)
            let ids = entries.map(\.id)
            expectEqual(ids, ids.sorted(), "ids ascend oldest first")
            expectEqual(Set(ids).count, ids.count)
            let again = MCPLogFile.readTail(url: url, limit: 10)
            expectTrue(Set(again.map(\.id)).isDisjoint(with: ids), "each read gets fresh ids")
            expectEqual(MCPLogFile.readTail(url: url, limit: 2).map(\.summary), ["→ initialize #1", "← initialize #1"])
        }
    }

    test("log file: readTail reads only the tail of a large file") {
        try withTempHome { home in
            let url = home.appendingPathComponent("huge.jsonl")
            let padding = String(repeating: "p", count: 900)
            var text = ""
            for index in 0..<1500 {
                text += "{\"t\":\"2026-11-06T09:00:00.000Z\",\"k\":\"event\",\"s\":\"line \(index)\",\"d\":\"\(padding)\"}\n"
            }
            try writeFile(url, text)
            let entries = MCPLogFile.readTail(url: url, limit: 5000)
            expectTrue(entries.count < 1500 && entries.count > 400, "read \(entries.count) entries from a ~1.4 MB file")
            expectEqual(entries.last?.summary, "line 1499")
            expectEqual(entries.first?.summary, "line \(1500 - entries.count)", "the first, partial line in the window is skipped")
        }
    }

    test("log file: clear removes the log and every rotated copy") {
        try withTempHome { home in
            let url = home.appendingPathComponent("x.jsonl")
            for name in ["x.jsonl", "x.1.jsonl", "x.2.jsonl", "x.5.jsonl"] {
                try writeFile(home.appendingPathComponent(name), "{}\n")
            }
            try writeFile(home.appendingPathComponent("x.backup.jsonl"), "keep")
            try writeFile(home.appendingPathComponent("y.1.jsonl"), "keep")
            try MCPLogFile.clear(url: url)
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(), ["x.backup.jsonl", "y.1.jsonl"])
            try MCPLogFile.clear(url: url)
            expectEqual(MCPLogFile.readTail(url: url, limit: 10), [])
        }
    }
}

// MARK: Formatting

private func runLogFormattingTests() {
    test("log formatting: plain text loses bearer tokens and well-known key formats") {
        let line = "auth Bearer eyJhbGciOi.abc-123 key=sk-ant-api03-AbCdEf123456 gh=ghp_0123456789abcdefABCDEF pat=github_pat_11AAAA_bbbb slack=xoxb-1234-5678-abcd ok"
        let detail = LogFormatting.detail(text: line)
        for secret in ["eyJhbGciOi", "sk-ant-api03", "ghp_0123", "github_pat_11", "xoxb-1234"] {
            expectTrue(!detail.contains(secret), "detail leaks \(secret): \(detail)")
        }
        expectTrue(detail.hasPrefix("auth Bearer [redacted] key=[redacted]"), detail)
        expectTrue(detail.hasSuffix(" ok"), detail)
        expectEqual(LogFormatting.detail(text: "Listening on port 3000"), "Listening on port 3000")
    }

    test("log formatting: token-like keys are redacted, counts and lookalikes are kept") {
        let message: JSONValue = [
            "token": "ghp_abc", "accessToken": "at-1", "github_token": "gh-2", "private_key": "pk-3",
            "session_token": "st-4", "bearer": "b-5", "stripe_key": "sk-6",
            "max_tokens": 100, "keyword": "open", "keys": "a,b",
        ]
        let redacted = LogFormatting.redacted(message)
        for key in ["token", "accessToken", "github_token", "private_key", "session_token", "bearer", "stripe_key"] {
            expectEqual(redacted[key], "[redacted]", key)
        }
        expectEqual(redacted["max_tokens"], 100)
        expectEqual(redacted["keyword"], "open")
        expectEqual(redacted["keys"], "a,b")
    }

    test("log formatting: secrets are redacted at any depth, case-insensitively") {
        let message: JSONValue = [
            "method": "tools/call",
            "params": [
                "headers": ["Authorization": "Bearer abc", "X-API-Key": "key-1", "Accept": "application/json"],
                "arguments": ["password": "hunter2", "query": "open issues", "nested": [["Access_Token": "tok", "SECRET": "s"]]],
            ],
            "result": ["refresh_token": ["any": "shape"], "client_secret": nil],
        ]
        let redacted = LogFormatting.redacted(message)
        expectEqual(redacted["params"]?["headers"]?["Authorization"], "[redacted]")
        expectEqual(redacted["params"]?["headers"]?["X-API-Key"], "[redacted]")
        expectEqual(redacted["params"]?["headers"]?["Accept"], "application/json")
        expectEqual(redacted["params"]?["arguments"]?["password"], "[redacted]")
        expectEqual(redacted["params"]?["arguments"]?["query"], "open issues")
        let nested = redacted["params"]?["arguments"]?["nested"]?.arrayValue?.first
        expectEqual(nested?["Access_Token"], "[redacted]")
        expectEqual(nested?["SECRET"], "[redacted]")
        expectEqual(redacted["result"]?["refresh_token"], "[redacted]")
        expectEqual(redacted["method"], "tools/call")

        let detail = LogFormatting.detail(message)
        for secret in ["abc", "key-1", "hunter2", "tok\"", "shape"] {
            expectTrue(!detail.contains(secret), "detail leaks \(secret): \(detail)")
        }
        expectTrue(detail.contains("open issues") && !detail.contains("\n"), "detail is compact JSON with content kept")
    }

    test("log formatting: large base64 images, audio and blobs are elided") {
        let image = String(repeating: "A", count: 4096)
        let message: JSONValue = [
            "content": [
                ["type": "image", "data": .string(image), "mimeType": "image/png"],
                ["type": "audio", "data": .string(String(repeating: "B", count: 2048))],
                ["type": "text", "data": .string(image)],
                ["type": "image", "data": "c2hvcnQ="],
            ],
            "resource": ["uri": "file:///a.bin", "blob": .string(String(repeating: "C", count: 1400))],
        ]
        let redacted = LogFormatting.redacted(message)
        let content = redacted["content"]?.arrayValue ?? []
        expectEqual(content.count, 4)
        expectEqual(content.first?["data"], "[3 KB base64 omitted]", "4096 base64 characters decode to 3 KB")
        expectEqual(content.first?["mimeType"], "image/png")
        expectEqual(content.dropFirst().first?["data"]?.stringValue?.hasSuffix("KB base64 omitted]"), true)
        expectEqual(content.dropFirst(2).first?["data"]?.stringValue, image, "text content is not base64")
        expectEqual(content.last?["data"], "c2hvcnQ=", "short payloads are kept")
        expectEqual(redacted["resource"]?["blob"], "[1 KB base64 omitted]")
        expectEqual(redacted["resource"]?["uri"], "file:///a.bin")
    }

    test("log formatting: details are capped on a character boundary") {
        let limit = LogFormatting.maxDetailBytes
        let short = "plain stderr line"
        expectEqual(LogFormatting.detail(text: short), short)

        // "é" is two bytes and straddles the limit, so it must be dropped whole.
        let accented = String(repeating: "a", count: limit - 1) + "é" + "tail"
        let cappedAccent = LogFormatting.detail(text: accented)
        expectTrue(cappedAccent.hasPrefix(String(repeating: "a", count: limit - 1) + "…"), "cut before the split character")
        expectTrue(cappedAccent.hasSuffix("[6 more bytes]"), "suffix counts the dropped bytes: \(cappedAccent.suffix(30))")

        let emoji = String(repeating: "b", count: limit - 2) + "👩‍💻" + String(repeating: "z", count: 100)
        let cappedEmoji = LogFormatting.detail(text: emoji)
        let kept = try require(cappedEmoji.components(separatedBy: "…").first, "prefix")
        expectEqual(kept, String(repeating: "b", count: limit - 2), "a multi-scalar emoji is never split")
        expectTrue(cappedEmoji.hasSuffix("[\(emoji.utf8.count - (limit - 2)) more bytes]"), "suffix: \(cappedEmoji.suffix(30))")

        let big: JSONValue = ["text": .string(String(repeating: "x", count: limit * 2))]
        let cappedJSON = LogFormatting.detail(big)
        let jsonPrefix = try require(cappedJSON.components(separatedBy: "… [").first, "prefix")
        expectEqual(jsonPrefix.utf8.count, limit)
        expectTrue(cappedJSON.hasSuffix("[\(big.jsonString().utf8.count - limit) more bytes]"), "suffix: \(cappedJSON.suffix(30))")
    }

    test("log formatting: credential headers are redacted, others kept") {
        let headers = [
            "Authorization": "Bearer abc", "proxy-authorization": "Basic x", "Cookie": "sid=1", "X-Auth-Token": "t",
            "X-Api-Key": "k", "Client-Secret": "s", "X-Password": "p", "Accept": "text/event-stream",
            "Mcp-Session-Id": "session-1", "User-Agent": "MCP Manager",
        ]
        let redacted = LogFormatting.redactedHeaders(headers)
        for name in ["Authorization", "proxy-authorization", "Cookie", "X-Auth-Token", "X-Api-Key", "Client-Secret", "X-Password"] {
            expectEqual(redacted[name], "[redacted]", name)
        }
        for name in ["Accept", "Mcp-Session-Id", "User-Agent"] {
            expectEqual(redacted[name], headers[name], name)
        }
    }
}
