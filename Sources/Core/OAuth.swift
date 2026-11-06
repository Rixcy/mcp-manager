import Foundation

// Placeholder until T-03 lands sign-in; signatures are the contract.

public struct OAuthCredential: Codable, Equatable, Sendable {
    /// `OAuthClient.resourceKey(for:)` of the server URL.
    public var resource: String
    public var issuer: String
    public var tokenEndpoint: String
    public var clientID: String
    public var clientSecret: String?
    public var tokenEndpointAuthMethod: String?
    public var redirectURI: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(resource: String, issuer: String, tokenEndpoint: String, clientID: String, clientSecret: String? = nil,
                tokenEndpointAuthMethod: String? = nil, redirectURI: String, accessToken: String,
                refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.resource = resource
        self.issuer = issuer
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.redirectURI = redirectURI
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

public protocol OAuthCredentialStore: Sendable {
    func credential(for resource: String) throws -> OAuthCredential?
    func save(_ credential: OAuthCredential) throws
    func deleteCredential(for resource: String) throws
}

/// MCP authorization: discovery, dynamic client registration, PKCE sign-in
/// through the browser, and refresh.
public final class OAuthClient: @unchecked Sendable {
    public let store: OAuthCredentialStore

    public init(store: OAuthCredentialStore, clientName: String = "MCP Manager", callbackTimeout: Duration = .seconds(300)) {
        self.store = store
    }

    /// Canonical server URL that credentials are filed under: lowercased scheme and host, no query or fragment.
    public static func resourceKey(for url: URL) -> String {
        url.absoluteString
    }

    public func credential(for serverURL: URL) -> OAuthCredential? {
        try? store.credential(for: Self.resourceKey(for: serverURL))
    }

    /// Runs the browser sign-in and stores the result. `challenge` is the 401's
    /// `WWW-Authenticate` header; `hints` is Claude's pre-registered client, if any.
    public func signIn(serverURL: URL, challenge: String?, hints: MCPOAuthHints?,
                       openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> OAuthCredential {
        throw MCPClientError.oauth(.discoveryFailed(url: serverURL.absoluteString, detail: "not implemented"))
    }

    public func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        throw MCPClientError.oauth(.refreshFailed("not implemented"))
    }

    public func signOut(serverURL: URL) throws {
        try store.deleteCredential(for: Self.resourceKey(for: serverURL))
    }
}

/// Sends stored tokens and refreshes them when the server answers 401.
public final class OAuthAuthProvider: MCPAuthProvider, @unchecked Sendable {
    public let client: OAuthClient

    public init(client: OAuthClient) {
        self.client = client
    }

    public func authorizationHeader(for url: URL) async throws -> String? { nil }

    public func handleUnauthorized(url: URL, challenge: String?) async -> Bool { false }
}
