import Foundation

struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

private var passedCount = 0
private var failedNames: [String] = []
private var currentFailures: [String] = []

func test(_ name: String, _ body: () throws -> Void) {
    currentFailures = []
    do {
        try body()
    } catch {
        currentFailures.append("threw \(error)")
    }
    if currentFailures.isEmpty {
        passedCount += 1
        print("PASS  \(name)")
    } else {
        failedNames.append(name)
        print("FAIL  \(name)")
        for failure in currentFailures { print("      \(failure)") }
    }
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    currentFailures.append("\(file):\(line): \(message)")
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    guard actual != expected else { return }
    let note = message.isEmpty ? "" : " (\(message))"
    fail("expected\(note)\n--- expected\n\(expected)\n--- actual\n\(actual)", file: file, line: line)
}

func expectTrue(_ condition: Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    if !condition { fail(message, file: file, line: line) }
}

func expectThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #fileID, line: UInt = #line,
                                        _ body: () throws -> Void) {
    do {
        try body()
        fail("expected \(expected) to be thrown, nothing was", file: file, line: line)
    } catch let error as E {
        if error != expected { fail("expected \(expected), got \(error)", file: file, line: line) }
    } catch {
        fail("expected \(expected), got \(error)", file: file, line: line)
    }
}

/// Unwraps or fails the test.
func require<T>(_ value: T?, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line): \(message)") }
    return value
}

/// A throwaway home directory, deleted afterwards.
func withTempHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-manager-tests-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home)
}

func writeFile(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func readText(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

func readJSON(_ url: URL) throws -> [String: Any] {
    try require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(url.path) is not a JSON object")
}

func finishTests() -> Never {
    print("\n\(passedCount) passed, \(failedNames.count) failed")
    if !failedNames.isEmpty {
        for name in failedNames { print("  failed: \(name)") }
        exit(1)
    }
    exit(0)
}
