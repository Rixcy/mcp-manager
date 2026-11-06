import Foundation

// Placeholder until T-04 lands buffered, rotating writes; signatures are the contract.

/// A server's log on disk, one JSON object per line.
public final class MCPLogFile: MCPLogSink, @unchecked Sendable {
    public let url: URL
    private let onEntry: (@Sendable (MCPLogEntry) -> Void)?

    /// `onEntry` sees every entry as it is recorded, on the recording thread.
    public init(url: URL, maxBytes: Int = 2_000_000, keepFiles: Int = 2, flushInterval: TimeInterval = 0.5,
                onEntry: (@Sendable (MCPLogEntry) -> Void)? = nil) {
        self.url = url
        self.onEntry = onEntry
    }

    public func record(_ kind: MCPLogEntry.Kind, _ summary: String, detail: String?) {
        onEntry?(MCPLogEntry(kind: kind, summary: summary, detail: detail))
    }

    /// Writes everything recorded so far before returning.
    public func flush() {}

    public func close() {}

    /// The newest `limit` entries across the current file and its rotated copies, oldest first.
    public static func readTail(url: URL, limit: Int) -> [MCPLogEntry] {
        []
    }

    /// Deletes the log and its rotated copies.
    public static func clear(url: URL) throws {}
}
