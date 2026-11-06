import Darwin
import Foundation

/// A server's log on disk, one JSON object per line.
public final class MCPLogFile: MCPLogSink, @unchecked Sendable {
    public let url: URL
    private let onEntry: (@Sendable (MCPLogEntry) -> Void)?
    private let maxBytes: Int
    private let keepFiles: Int
    private let flushInterval: TimeInterval

    /// Pending bytes that trigger a flush before the timer does.
    static let flushThreshold = 65_536
    /// `readTail` reads at most this much from the end of each file.
    static let tailBytes = 524_288

    private let queue = DispatchQueue(label: "MCP Manager log file")
    // Everything below is touched only on `queue`, or from deinit once no one else can.
    private var pending = Data()
    private var descriptor: Int32 = -1
    private var fileSize = 0
    private var flushScheduled = false
    private var closed = false

    /// `onEntry` sees every entry as it is recorded, on the recording thread.
    public init(url: URL, maxBytes: Int = 2_000_000, keepFiles: Int = 2, flushInterval: TimeInterval = 0.5,
                onEntry: (@Sendable (MCPLogEntry) -> Void)? = nil) {
        self.url = url
        self.onEntry = onEntry
        self.maxBytes = maxBytes
        self.keepFiles = max(0, keepFiles)
        self.flushInterval = flushInterval
    }

    deinit {
        // No queued block holds a strong reference any more, so the state is ours alone;
        // deinit may itself run on `queue`, where a sync would deadlock.
        shutDown()
    }

    public func record(_ kind: MCPLogEntry.Kind, _ summary: String, detail: String?) {
        let entry = MCPLogEntry(kind: kind, summary: summary, detail: detail)
        onEntry?(entry)
        queue.async { self.append(entry) }
    }

    /// Writes everything recorded so far before returning.
    public func flush() {
        queue.sync { writePending() }
    }

    public func close() {
        queue.sync { shutDown() }
    }

    private func append(_ entry: MCPLogEntry) {
        guard !closed else { return }
        pending.append(contentsOf: Self.encode(entry).utf8)
        pending.append(0x0A)
        if pending.count >= Self.flushThreshold {
            writePending()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.writePending()
            }
        }
    }

    private func shutDown() {
        guard !closed else { return }
        writePending()
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        closed = true
    }

    private func writePending() {
        guard !closed, !pending.isEmpty else { return }
        defer { pending.removeAll(keepingCapacity: true) }
        guard openIfNeeded() else { return }
        if fileSize > 0, fileSize + pending.count > maxBytes {
            rotate()
            guard openIfNeeded() else { return }
        }
        let written = pending.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                offset += n
            }
            return offset
        }
        fileSize += written
    }

    /// Opens the log, and reopens it when someone deleted it underneath us (Clear in the UI).
    private func openIfNeeded() -> Bool {
        if descriptor >= 0 {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_nlink > 0 { return true }
            Darwin.close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        var info = stat()
        fileSize = fstat(descriptor, &info) == 0 ? Int(info.st_size) : 0
        return true
    }

    private func rotate() {
        Darwin.close(descriptor)
        descriptor = -1
        let manager = FileManager.default
        if keepFiles == 0 {
            try? manager.removeItem(at: url)
            return
        }
        try? manager.removeItem(at: Self.rotatedURL(url, keepFiles))
        for index in stride(from: keepFiles - 1, through: 1, by: -1) {
            rename(Self.rotatedURL(url, index).path, Self.rotatedURL(url, index + 1).path)
        }
        rename(url.path, Self.rotatedURL(url, 1).path)
    }

    // MARK: Format

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Written by hand so the keys keep the documented `t, k, s, d` order.
    static func encode(_ entry: MCPLogEntry) -> String {
        var line = "{\"t\":\(JSONValue.string(timestampFormatter.string(from: entry.time)).jsonString())"
        line += ",\"k\":\(JSONValue.string(entry.kind.rawValue).jsonString())"
        line += ",\"s\":\(JSONValue.string(entry.summary).jsonString())"
        if let detail = entry.detail {
            line += ",\"d\":\(JSONValue.string(detail).jsonString())"
        }
        return line + "}"
    }

    static func decode(_ line: Data) -> (time: Date, kind: MCPLogEntry.Kind, summary: String, detail: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stamp = object["t"] as? String, let time = timestampFormatter.date(from: stamp),
              let kindName = object["k"] as? String, let kind = MCPLogEntry.Kind(rawValue: kindName),
              let summary = object["s"] as? String else { return nil }
        return (time, kind, summary, object["d"] as? String)
    }

    // MARK: Files

    /// `x.jsonl` → `x.<index>.jsonl`.
    static func rotatedURL(_ url: URL, _ index: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem).\(index)" : "\(stem).\(index).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Indices of the rotated copies on disk, ascending (newest first).
    static func rotatedIndices(_ url: URL) -> [Int] {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem + "."
        let suffix = ext.isEmpty ? "" : "." + ext
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
            let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard middle.allSatisfy(\.isASCII), let index = Int(middle), index > 0 else { return nil }
            return index
        }.sorted()
    }

    /// The newest `limit` entries across the current file and its rotated copies, oldest first.
    public static func readTail(url: URL, limit: Int) -> [MCPLogEntry] {
        guard limit > 0 else { return [] }
        var newestFirstFiles: [[(time: Date, kind: MCPLogEntry.Kind, summary: String, detail: String?)]] = []
        var count = 0
        for file in [url] + rotatedIndices(url).map({ rotatedURL(url, $0) }) {
            let entries = tailEntries(of: file)
            newestFirstFiles.append(entries)
            count += entries.count
            if count >= limit { break }
        }
        let selected = newestFirstFiles.reversed().flatMap { $0 }.suffix(limit)
        return selected.map { MCPLogEntry(time: $0.time, kind: $0.kind, summary: $0.summary, detail: $0.detail) }
    }

    private static func tailEntries(of file: URL) -> [(time: Date, kind: MCPLogEntry.Kind, summary: String, detail: String?)] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // A line with no newline after it is still being written or was cut off.
        lines.removeLast()
        // Reading from the middle of the file starts partway through a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { $0.isEmpty ? nil : decode(Data($0)) }
    }

    /// Deletes the log and its rotated copies.
    public static func clear(url: URL) throws {
        for file in [url] + rotatedIndices(url).map({ rotatedURL(url, $0) }) {
            if unlink(file.path) != 0, errno != ENOENT {
                throw MCPManagerError.io(path: file.path, detail: String(cString: strerror(errno)))
            }
        }
    }
}
