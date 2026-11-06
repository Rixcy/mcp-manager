import Foundation

public enum LogFormatting {
    public static let maxDetailBytes = 32_768

    static let redactedValue = "[redacted]"

    static let secretKeys: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "access_token", "refresh_token", "id_token",
        "client_secret", "code_verifier", "password", "api_key", "apikey", "x-api-key", "secret",
    ]

    /// Shorter base64 strings are kept: they are cheap and sometimes the point of the message.
    static let base64Threshold = 256

    /// Compact JSON with secrets redacted, base64 payloads elided, capped at `maxDetailBytes`.
    public static func detail(_ value: JSONValue) -> String {
        capped(redacted(value).jsonString())
    }

    /// Plain text (stderr lines, HTTP bodies) capped at `maxDetailBytes`.
    public static func detail(text: String) -> String {
        capped(text)
    }

    public static func redacted(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(items):
            return .array(items.map(redacted))
        case let .object(members):
            let type = members["type"]?.stringValue
            var result: [String: JSONValue] = [:]
            for (key, member) in members {
                if secretKeys.contains(key.lowercased()) {
                    result[key] = .string(redactedValue)
                } else if let text = member.stringValue, text.utf8.count > base64Threshold,
                          key == "blob" || (key == "data" && (type == "image" || type == "audio")) {
                    result[key] = .string(omitted(base64: text))
                } else {
                    result[key] = redacted(member)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    /// Header values for logs and the UI, with credentials replaced.
    public static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = isSecretHeader(name) ? redactedValue : value
        }
        return result
    }

    static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["authorization", "proxy-authorization", "cookie"].contains(lower) { return true }
        return ["token", "secret", "key", "auth", "password"].contains { lower.contains($0) }
    }

    private static func omitted(base64 text: String) -> String {
        let decodedBytes = Double(text.utf8.count) * 3 / 4
        return "[\(max(1, Int((decodedBytes / 1024).rounded()))) KB base64 omitted]"
    }

    /// Cuts on a character boundary so the result is always valid UTF-8 and never splits an emoji.
    static func capped(_ text: String, limit: Int = maxDetailBytes) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: limit)
        while end > utf8.startIndex, end.samePosition(in: text) == nil {
            end = utf8.index(before: end)
        }
        let kept = utf8.distance(from: utf8.startIndex, to: end)
        return String(text[..<end]) + "… [\(total - kept) more bytes]"
    }
}
