import Foundation

// Placeholder until T-03 lands the stores; signatures are the contract.

/// All credentials in one 0600 JSON file. Used by tests and fixture homes.
public final class FileCredentialStore: OAuthCredentialStore, @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func credential(for resource: String) throws -> OAuthCredential? { nil }
    public func save(_ credential: OAuthCredential) throws {}
    public func deleteCredential(for resource: String) throws {}
}

/// All credentials in one generic-password item in the login keychain.
public final class KeychainCredentialStore: OAuthCredentialStore, @unchecked Sendable {
    public let service: String

    public init(service: String = "com.rickbooth.mcp-manager.oauth") {
        self.service = service
    }

    public func credential(for resource: String) throws -> OAuthCredential? { nil }
    public func save(_ credential: OAuthCredential) throws {}
    public func deleteCredential(for resource: String) throws {}
}

public enum OAuthCredentialStores {
    /// The keychain for the real home, a file in the support folder otherwise.
    public static func standard(for paths: ConfigPaths) -> OAuthCredentialStore {
        paths.usesKeychain ? KeychainCredentialStore() : FileCredentialStore(url: paths.oauthCredentialsFile)
    }
}
