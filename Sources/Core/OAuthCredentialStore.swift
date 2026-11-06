import Foundation
import Security

/// All credentials in one 0600 JSON file. Used by tests and fixture homes.
public final class FileCredentialStore: OAuthCredentialStore, @unchecked Sendable {
    public let url: URL

    /// Process-wide, because `OAuthCredentialStores.standard(for:)` hands out a
    /// new store per call and every one of them rewrites the same file.
    private static let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func credential(for resource: String) throws -> OAuthCredential? {
        try Self.lock.withLock { try load()[resource] }
    }

    public func save(_ credential: OAuthCredential) throws {
        try Self.lock.withLock {
            var credentials = try load()
            credentials[credential.resource] = credential
            try write(credentials)
        }
    }

    public func deleteCredential(for resource: String) throws {
        try Self.lock.withLock {
            var credentials = try load()
            guard credentials.removeValue(forKey: resource) != nil else { return }
            try write(credentials)
        }
    }

    private func load() throws -> [String: OAuthCredential] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            throw MCPClientError.oauth(.credentialStore("Could not read \(url.path): \(error.localizedDescription)"))
        }
        return try OAuthCredentialCoding.decode(data, source: url.path)
    }

    private func write(_ credentials: [String: OAuthCredential]) throws {
        let data = try OAuthCredentialCoding.encode(credentials)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileIO(backupDir: directory).atomicWrite(data, to: url, permissions: 0o600)
        } catch let error as MCPManagerError {
            throw MCPClientError.oauth(.credentialStore(error.errorDescription ?? "Could not write \(url.path)"))
        } catch {
            throw MCPClientError.oauth(.credentialStore("Could not write \(url.path): \(error.localizedDescription)"))
        }
    }
}

/// All credentials in one generic-password item in the login keychain.
/// One item rather than one per server, so a rebuilt and re-signed app asks
/// for keychain access at most once.
public final class KeychainCredentialStore: OAuthCredentialStore, @unchecked Sendable {
    public let service: String

    private static let account = "credentials"
    private static let lock = NSLock()

    public init(service: String = "com.rickbooth.mcp-manager.oauth") {
        self.service = service
    }

    public func credential(for resource: String) throws -> OAuthCredential? {
        try Self.lock.withLock { try load()[resource] }
    }

    public func save(_ credential: OAuthCredential) throws {
        try Self.lock.withLock {
            var credentials = try load()
            credentials[credential.resource] = credential
            try write(credentials)
        }
    }

    public func deleteCredential(for resource: String) throws {
        try Self.lock.withLock {
            var credentials = try load()
            guard credentials.removeValue(forKey: resource) != nil else { return }
            try write(credentials)
        }
    }

    private var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    private func load() throws -> [String: OAuthCredential] {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw Self.keychainError(status) }
        guard let data = item as? Data else {
            throw MCPClientError.oauth(.credentialStore("The keychain item for \(service) holds no data."))
        }
        return try OAuthCredentialCoding.decode(data, source: "the keychain item for \(service)")
    }

    private func write(_ credentials: [String: OAuthCredential]) throws {
        let data = try OAuthCredentialCoding.encode(credentials)
        let status = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.keychainError(status) }
        var item = itemQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MCP Manager OAuth credentials"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.keychainError(added) }
    }

    private static func keychainError(_ status: OSStatus) -> MCPClientError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return .oauth(.credentialStore("Keychain error \(status): \(message)"))
    }
}

public enum OAuthCredentialStores {
    /// The keychain for the real home, a file in the support folder otherwise.
    public static func standard(for paths: ConfigPaths) -> OAuthCredentialStore {
        paths.usesKeychain ? KeychainCredentialStore() : FileCredentialStore(url: paths.oauthCredentialsFile)
    }
}

/// The `{resourceKey: credential}` JSON both stores hold.
enum OAuthCredentialCoding {
    static func encode(_ credentials: [String: OAuthCredential]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(credentials)
        } catch {
            throw MCPClientError.oauth(.credentialStore("Could not encode the OAuth credentials: \(error.localizedDescription)"))
        }
    }

    static func decode(_ data: Data, source: String) throws -> [String: OAuthCredential] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: OAuthCredential].self, from: data)
        } catch {
            throw MCPClientError.oauth(.credentialStore(
                "The OAuth credentials in \(source) are damaged (\(describe(error))). Delete them and sign in again."))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context): return context.debugDescription
        case let DecodingError.keyNotFound(key, _): return "missing \(key.stringValue)"
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            return "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        default: return error.localizedDescription
        }
    }
}
