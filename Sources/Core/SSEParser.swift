import Foundation

struct SSEEvent: Equatable, Sendable {
    /// Nil when the stream gave no `event` field, which means "message".
    var event: String?
    var data: String
    /// The last event id seen on the stream, as the spec defines it.
    var id: String?
}

/// Incremental `text/event-stream` parser following the WHATWG HTML event stream rules.
/// Fed byte by byte because `URLSession`'s line splitting drops the blank lines that end events.
struct SSEParser {
    private(set) var lastEventID: String?
    /// The `retry` field, in milliseconds.
    private(set) var reconnectionTime: Int?

    private let maxBufferedBytes: Int
    private var line: [UInt8] = []
    private var afterCarriageReturn = false
    private var atStreamStart = true
    private var eventType = ""
    private var dataLines: [String] = []
    private var bufferedDataBytes = 0

    init(maxBufferedBytes: Int = TransportLimits.maxMessageBytes) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// Returns the event this byte completes, if any. Throws `messageTooLarge` once one event outgrows the limit.
    mutating func push(_ byte: UInt8) throws -> SSEEvent? {
        if afterCarriageReturn {
            afterCarriageReturn = false
            if byte == 0x0A { return nil }
        }
        switch byte {
        case 0x0A:
            return endLine()
        case 0x0D:
            afterCarriageReturn = true
            return endLine()
        default:
            line.append(byte)
            let buffered = line.count + bufferedDataBytes
            if buffered > maxBufferedBytes { throw MCPClientError.messageTooLarge(bytes: buffered) }
            return nil
        }
    }

    mutating func push<Bytes: Sequence>(_ bytes: Bytes) throws -> [SSEEvent] where Bytes.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = try push(byte) { events.append(event) }
        }
        return events
    }

    /// The stream ended. The spec discards an event without its closing blank line, but some
    /// servers close right after the last `data` line and that answer is still worth delivering.
    mutating func finish() -> SSEEvent? {
        if !line.isEmpty { _ = endLine() }
        afterCarriageReturn = false
        return dispatch()
    }

    private mutating func endLine() -> SSEEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        if bytes.isEmpty { return dispatch() }
        if bytes[0] == UInt8(ascii: ":") { return nil }

        let text = String(decoding: bytes, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines.append(String(value))
            bufferedDataBytes += value.utf8.count + 1
        case "id":
            if !value.contains("\0") { lastEventID = String(value) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) { reconnectionTime = Int(value) }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = ""
            dataLines = []
            bufferedDataBytes = 0
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventType.isEmpty ? nil : eventType, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }
}
