import Foundation

// Placeholder until T-04 lands redaction and size caps; signatures are the contract.

public enum LogFormatting {
    public static let maxDetailBytes = 32_768

    /// Compact JSON with secrets redacted, base64 payloads elided, capped at `maxDetailBytes`.
    public static func detail(_ value: JSONValue) -> String {
        value.jsonString()
    }

    /// Plain text (stderr lines, HTTP bodies) capped at `maxDetailBytes`.
    public static func detail(text: String) -> String {
        text
    }

    public static func redacted(_ value: JSONValue) -> JSONValue {
        value
    }

    /// Header values for logs and the UI, with credentials replaced.
    public static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers
    }
}
