import Foundation

private final class AsyncOutcome: @unchecked Sendable {
    var error: Error?
}

/// Runs an async test body from the synchronous harness. The body runs off the
/// main thread, so nothing under test may need the main actor.
func testAsync(_ name: String, timeout: TimeInterval = 30, _ body: @escaping @Sendable () async throws -> Void) {
    test(name) {
        let done = DispatchSemaphore(value: 0)
        let outcome = AsyncOutcome()
        let task = Task.detached {
            do { try await body() } catch { outcome.error = error }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw TestFailure(description: "timed out after \(Int(timeout)) s")
        }
        if let error = outcome.error { throw error }
    }
}

/// The error `body` throws; records a failure and returns nil when it returns normally.
func thrownError(file: StaticString = #fileID, line: UInt = #line, _ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        fail("expected an error, nothing was thrown", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

/// Absolute path of a file in `Tests/Fixtures`.
func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
}

/// The Command Line Tools interpreter, so fixtures never depend on Homebrew's Python.
let fixturePython = "/usr/bin/python3"

/// A fixture HTTP server started from `Tests/Fixtures`. The script must print
/// `PORT <n>` as its first stdout line and nothing else to stdout.
final class FixtureServer {
    let process: Process
    let port: Int

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(script: String, arguments: [String] = []) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: fixturePython)
        process.arguments = [fixturePath(script)] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("PORT "), let port = Int(text.dropFirst(5)) else {
            process.terminate()
            throw TestFailure(description: "\(script) did not print PORT <n>; got \(text.debugDescription)")
        }
        self.port = port
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    deinit { stop() }
}
