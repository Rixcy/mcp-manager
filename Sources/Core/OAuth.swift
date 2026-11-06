import CryptoKit
import Foundation
import Security

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
    public let clientName: String
    public let callbackTimeout: Duration
    private let http = OAuthHTTP.shared

    public init(store: OAuthCredentialStore, clientName: String = "MCP Manager", callbackTimeout: Duration = .seconds(300)) {
        self.store = store
        self.clientName = clientName
        self.callbackTimeout = callbackTimeout
    }

    /// Canonical server URL that credentials are filed under, and the RFC 8707
    /// `resource` sent to the authorization server: lowercased scheme and host,
    /// no default port, query, fragment or trailing slash (the root keeps its `/`).
    public static func resourceKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        if let port = components.port, OAuthDiscovery.isDefaultPort(port, scheme: components.scheme) {
            components.port = nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let path = OAuthDiscovery.canonicalPath(url)
        components.percentEncodedPath = path.isEmpty ? "/" : path
        return components.string ?? url.absoluteString
    }

    public func credential(for serverURL: URL) -> OAuthCredential? {
        try? store.credential(for: Self.resourceKey(for: serverURL))
    }

    /// Runs the browser sign-in and stores the result. `challenge` is the 401's
    /// `WWW-Authenticate` header; `hints` is Claude's pre-registered client, if any.
    /// Each step is recorded in `log` without tokens, codes or secrets.
    public func signIn(serverURL: URL, challenge: String?, hints: MCPOAuthHints?, log: MCPLogSink? = nil,
                       openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> OAuthCredential {
        do {
            return try await performSignIn(serverURL: serverURL, challenge: challenge, hints: hints, log: log,
                                           openBrowser: openBrowser)
        } catch {
            if Task.isCancelled || error is CancellationError { throw MCPClientError.cancelled }
            throw error
        }
    }

    public func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw MCPClientError.oauth(.refreshFailed("There is no refresh token for \(credential.resource). Sign in again."))
        }
        guard let endpoint = URL(string: credential.tokenEndpoint) else {
            throw MCPClientError.oauth(.refreshFailed("The saved token endpoint \(credential.tokenEndpoint) is not a valid URL. Sign in again."))
        }
        let client = RegisteredClient(id: credential.clientID, secret: credential.clientSecret,
                                      authMethod: credential.tokenEndpointAuthMethod, redirectURI: credential.redirectURI)
        let response = try await requestToken(at: endpoint, client: client, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("resource", credential.resource),
        ])
        guard let tokens = TokenResponse(response) else {
            throw MCPClientError.oauth(.refreshFailed(Self.refreshFailureDetail(response)))
        }
        var refreshed = credential
        refreshed.accessToken = tokens.accessToken
        refreshed.refreshToken = tokens.refreshToken ?? refreshToken
        refreshed.expiresAt = tokens.expiresAt
        refreshed.scope = tokens.scope ?? credential.scope
        try store.save(refreshed)
        return refreshed
    }

    public func signOut(serverURL: URL) throws {
        try store.deleteCredential(for: Self.resourceKey(for: serverURL))
    }

    // MARK: Sign-in

    private func performSignIn(serverURL: URL, challenge: String?, hints: MCPOAuthHints?, log: MCPLogSink?,
                               openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> OAuthCredential {
        let resource = Self.resourceKey(for: serverURL)
        let challengeParameters = WWWAuthenticateChallenge.bearerParameters(challenge)
        var scope = challengeParameters["scope"].flatMap { $0.isEmpty ? nil : $0 }
        let discovery = OAuthDiscovery(http: http)

        let server: AuthorizationServerMetadata
        if let metadata = try await discovery.protectedResource(serverURL: serverURL,
                                                                advertised: challengeParameters["resource_metadata"]) {
            log?.record(.event, "Found protected resource metadata", detail: metadata.url.absoluteString)
            if scope == nil, !metadata.scopesSupported.isEmpty {
                scope = metadata.scopesSupported.joined(separator: " ")
            }
            server = try await discovery.authorizationServer(issuer: metadata.authorizationServers[0], defaultsAt: nil)
        } else {
            let origin = OAuthDiscovery.origin(of: serverURL)
            log?.record(.event, "No protected resource metadata; using the server's own origin as the authorization server",
                        detail: origin)
            server = try await discovery.authorizationServer(issuer: origin, defaultsAt: origin)
        }
        if let metadataURL = server.metadataURL {
            log?.record(.event, "Found authorization server metadata for \(server.issuer)", detail: metadataURL.absoluteString)
        } else {
            log?.record(.event, "No authorization server metadata; using the default endpoints",
                        detail: "\(server.issuer)/authorize, /token and /register")
        }
        try OAuthDiscovery.validate(server)

        let verifier = PKCE.randomString(byteCount: 32)
        let state = PKCE.randomString(byteCount: 32)
        let respond = Self.callbackPage(host: serverURL.host ?? resource, state: state)
        let (client, listener) = try await prepareClient(resource: resource, server: server, hints: hints, log: log,
                                                         respond: respond)
        defer { listener.stop() }
        log?.record(.event, "Waiting for the browser callback", detail: client.redirectURI)

        var fields = [
            ("response_type", "code"),
            ("client_id", client.id),
            ("redirect_uri", client.redirectURI),
            ("code_challenge", PKCE.challenge(for: verifier)),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("resource", resource),
        ]
        if let scope { fields.append(("scope", scope)) }
        let authorizationURL = try Self.authorizationURL(server.authorizationEndpoint, fields)

        try await openBrowser(authorizationURL)
        log?.record(.event, "Opened the browser to sign in", detail: OAuthHTTP.withoutQuery(server.authorizationEndpoint))

        let callback = try await listener.waitForCallback(timeout: callbackTimeout)
        listener.stop()
        log?.record(.event, "Received the browser callback", detail: nil)
        if let error = callback["error"] {
            throw MCPClientError.oauth(.denied(error: error, description: callback["error_description"]))
        }
        guard callback["state"] == state else { throw MCPClientError.oauth(.stateMismatch) }
        guard let code = callback["code"], !code.isEmpty else {
            throw MCPClientError.oauth(.tokenRequestFailed(
                status: nil, error: nil, description: "The authorization server redirected back without an authorization code."))
        }

        let response = try await requestToken(at: server.tokenEndpoint, client: client, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", client.redirectURI),
            ("code_verifier", verifier),
            ("resource", resource),
        ])
        guard let tokens = TokenResponse(response) else {
            let body = response.jsonObject
            let fallback = body == nil ? response.bodySnippet
                : response.isSuccess ? "The token response has no access_token." : nil
            throw MCPClientError.oauth(.tokenRequestFailed(
                status: response.status, error: body?["error"]?.stringValue,
                description: body?["error_description"]?.stringValue ?? fallback))
        }

        let credential = OAuthCredential(
            resource: resource, issuer: server.issuer, tokenEndpoint: server.tokenEndpoint.absoluteString,
            clientID: client.id, clientSecret: client.secret, tokenEndpointAuthMethod: client.authMethod,
            redirectURI: client.redirectURI, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt, scope: tokens.scope ?? scope)
        try store.save(credential)
        let expiry = credential.expiresAt.map { "The access token expires at \(ISO8601DateFormatter().string(from: $0))." }
            ?? "The access token has no expiry."
        log?.record(.event, "Signed in to \(serverURL.host ?? resource)",
                    detail: expiry + (credential.refreshToken == nil ? " There is no refresh token." : ""))
        return credential
    }

    /// Picks the client and starts the callback listener, which must be
    /// listening before the browser opens and whose port the redirect names.
    private func prepareClient(resource: String, server: AuthorizationServerMetadata, hints: MCPOAuthHints?,
                               log: MCPLogSink?, respond: @escaping OAuthLoopbackServer.Responder)
        async throws -> (RegisteredClient, OAuthLoopbackServer) {
        if let clientID = hints?.clientID, !clientID.isEmpty {
            let listener = try OAuthLoopbackServer.start(port: hints?.callbackPort ?? 0, includeIPv6: true,
                                                         path: "/callback", respond: respond)
            log?.record(.event, "Using the pre-registered client \(clientID)", detail: nil)
            return (RegisteredClient(id: clientID, secret: nil, authMethod: nil,
                                     redirectURI: "http://localhost:\(listener.port)/callback"), listener)
        }

        if let stored = try? store.credential(for: resource), stored.issuer == server.issuer,
           let redirect = URL(string: stored.redirectURI), OAuthDiscovery.isLoopbackHost(redirect.host),
           let port = redirect.port, hints?.callbackPort == nil || hints?.callbackPort == port,
           let listener = try? OAuthLoopbackServer.start(port: port, includeIPv6: redirect.host == "localhost",
                                                         path: redirect.path.isEmpty ? "/" : redirect.path, respond: respond) {
            log?.record(.event, "Reusing client \(stored.clientID) from the last sign-in", detail: nil)
            return (RegisteredClient(id: stored.clientID, secret: stored.clientSecret,
                                     authMethod: stored.tokenEndpointAuthMethod, redirectURI: stored.redirectURI), listener)
        }

        guard let registrationEndpoint = server.registrationEndpoint else {
            throw MCPClientError.oauth(.registrationUnsupported(issuer: server.issuer))
        }
        // Claude's `callbackPort` setting means the redirect must use that fixed port, in Claude's `localhost` form.
        let fixedPort = hints?.callbackPort
        let listener = try OAuthLoopbackServer.start(port: fixedPort ?? 0, includeIPv6: fixedPort != nil,
                                                     path: "/callback", respond: respond)
        do {
            let host = fixedPort == nil ? "127.0.0.1" : "localhost"
            let client = try await register(at: registrationEndpoint, redirectURI: "http://\(host):\(listener.port)/callback")
            log?.record(.event, "Registered client \(client.id)", detail: OAuthHTTP.withoutQuery(registrationEndpoint))
            return (client, listener)
        } catch {
            listener.stop()
            throw error
        }
    }

    /// RFC 7591 dynamic client registration as a public client.
    private func register(at endpoint: URL, redirectURI: String) async throws -> RegisteredClient {
        let response = try await http.postJSON(endpoint, [
            "client_name": .string(clientName),
            "redirect_uris": [.string(redirectURI)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let body = response.jsonObject
        guard response.isSuccess else {
            let detail = body?["error_description"]?.stringValue ?? body?["error"]?.stringValue
                ?? response.bodySnippet ?? "The registration endpoint answered HTTP \(response.status)."
            throw MCPClientError.oauth(.registrationFailed(status: response.status, detail: detail))
        }
        guard let clientID = body?["client_id"]?.stringValue, !clientID.isEmpty else {
            throw MCPClientError.oauth(.registrationFailed(status: response.status,
                                                          detail: "The registration response has no client_id."))
        }
        return RegisteredClient(id: clientID, secret: body?["client_secret"]?.stringValue,
                                authMethod: body?["token_endpoint_auth_method"]?.stringValue, redirectURI: redirectURI)
    }

    /// A form-encoded token request with RFC 6749 §2.3.1 client authentication.
    private func requestToken(at endpoint: URL, client: RegisteredClient,
                              fields: [(String, String)]) async throws -> OAuthHTTP.Response {
        var fields = fields + [("client_id", client.id)]
        var headers: [String: String] = [:]
        if let secret = client.secret, !secret.isEmpty {
            switch client.authMethod ?? "client_secret_basic" {
            case "client_secret_post":
                fields.append(("client_secret", secret))
            case "client_secret_basic":
                let pair = "\(OAuthHTTP.formEncode(client.id)):\(OAuthHTTP.formEncode(secret))"
                headers["Authorization"] = "Basic " + Data(pair.utf8).base64EncodedString()
            default:
                break
            }
        }
        return try await http.postForm(endpoint, fields, headers: headers)
    }

    private static func authorizationURL(_ endpoint: URL, _ fields: [(String, String)]) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MCPClientError.oauth(.discoveryFailed(url: endpoint.absoluteString,
                                                        detail: "The authorization endpoint is not a valid URL."))
        }
        let added = fields.map { "\(OAuthHTTP.formEncode($0))=\(OAuthHTTP.formEncode($1))" }.joined(separator: "&")
        components.percentEncodedQuery = [components.percentEncodedQuery, added].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: "&")
        guard let url = components.url else {
            throw MCPClientError.oauth(.discoveryFailed(url: endpoint.absoluteString,
                                                        detail: "Could not build the authorization URL."))
        }
        return url
    }

    private static func callbackPage(host: String, state: String) -> OAuthLoopbackServer.Responder {
        { parameters in
            if let error = parameters["error"] {
                let reason = parameters["error_description"].map { "\($0) (\(error))" } ?? error
                return (400, OAuthLoopbackServer.page("Sign-in to \(host) failed: \(reason). Return to MCP Manager and try again."))
            }
            guard parameters["state"] == state else {
                return (400, OAuthLoopbackServer.page(
                    "Sign-in to \(host) failed: this response does not belong to the sign-in MCP Manager started. "
                        + "Return to MCP Manager and try again."))
            }
            guard parameters["code"]?.isEmpty == false else {
                return (400, OAuthLoopbackServer.page(
                    "Sign-in to \(host) failed: the authorization server sent no authorization code. Return to MCP Manager and try again."))
            }
            return (200, OAuthLoopbackServer.page("Signed in to \(host). You can close this tab and return to MCP Manager."))
        }
    }

    private static func refreshFailureDetail(_ response: OAuthHTTP.Response) -> String {
        let body = response.jsonObject
        let error = body?["error"]?.stringValue
        let description = body?["error_description"]?.stringValue
        let reason = [error, description].compactMap { $0 }.joined(separator: ": ")
        if (400..<500).contains(response.status) {
            return "The authorization server refused to refresh the token"
                + (reason.isEmpty ? " (HTTP \(response.status))" : " (\(reason))") + ". Sign in again."
        }
        if response.isSuccess {
            return "The token response has no access_token. Sign in again."
        }
        return "The authorization server answered HTTP \(response.status) when refreshing the token"
            + (reason.isEmpty ? "" : " (\(reason))") + ". Try again later, or sign in again."
    }
}

/// The client identity a sign-in or refresh authenticates as.
struct RegisteredClient: Equatable {
    var id: String
    var secret: String?
    var authMethod: String?
    var redirectURI: String
}

struct TokenResponse: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var scope: String?

    /// Whole seconds, so a credential reads back from its ISO 8601 store unchanged.
    var expiresAt: Date? {
        expiresIn.map { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + $0).rounded(.down)) }
    }

    /// Nil unless the response is a 2xx JSON object with an `access_token`.
    init?(_ response: OAuthHTTP.Response) {
        guard response.isSuccess, let body = response.jsonObject,
              let accessToken = body["access_token"]?.stringValue, !accessToken.isEmpty else { return nil }
        self.accessToken = accessToken
        refreshToken = body["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // Some servers send expires_in as a string.
        expiresIn = body["expires_in"]?.doubleValue ?? body["expires_in"]?.stringValue.flatMap(Double.init)
        scope = body["scope"]?.stringValue
    }
}

/// RFC 7636 proof key with the S256 method.
enum PKCE {
    /// URL-safe base64 of `byteCount` random bytes; 32 bytes give the 43 characters RFC 7636 asks for.
    static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Sends stored tokens and refreshes them when the server answers 401.
public final class OAuthAuthProvider: MCPAuthProvider, @unchecked Sendable {
    public let client: OAuthClient

    private let lock = NSLock()
    private var refreshes: [String: Task<OAuthCredential, Error>] = [:]

    /// Refresh this long before expiry so a request never leaves with a token about to lapse.
    static let refreshMargin: TimeInterval = 60

    public init(client: OAuthClient) {
        self.client = client
    }

    public func authorizationHeader(for url: URL) async throws -> String? {
        guard let credential = try client.store.credential(for: OAuthClient.resourceKey(for: url)) else { return nil }
        guard Self.isExpiring(credential), credential.refreshToken != nil else { return "Bearer \(credential.accessToken)" }
        do {
            return "Bearer \(try await refreshOnce(credential).accessToken)"
        } catch {
            // The old token still goes out: the server's 401 then reaches
            // handleUnauthorized, and the user is offered Sign in.
            return "Bearer \(credential.accessToken)"
        }
    }

    public func handleUnauthorized(url: URL, challenge: String?) async -> Bool {
        // A token without the right scope is not fixed by refreshing it.
        if WWWAuthenticateChallenge.bearerParameters(challenge)["error"]?.lowercased() == "insufficient_scope" { return false }
        guard let credential = try? client.store.credential(for: OAuthClient.resourceKey(for: url)),
              credential.refreshToken != nil else { return false }
        return (try? await refreshOnce(credential)) != nil
    }

    static func isExpiring(_ credential: OAuthCredential) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < refreshMargin
    }

    /// One refresh per resource at a time; later callers join it. Refresh
    /// tokens are often single-use, so a second parallel refresh would fail.
    private func refreshOnce(_ seen: OAuthCredential) async throws -> OAuthCredential {
        let resource = seen.resource
        let task: Task<OAuthCredential, Error> = lock.withLock {
            if let running = refreshes[resource] { return running }
            let task = Task { [client] in
                defer { self.lock.withLock { self.refreshes[resource] = nil } }
                guard let latest = try client.store.credential(for: resource) else {
                    throw MCPClientError.oauth(.refreshFailed("Signed out of \(resource)."))
                }
                // Another caller refreshed after `seen` was read.
                if latest.accessToken != seen.accessToken, !Self.isExpiring(latest) { return latest }
                return try await client.refresh(latest)
            }
            refreshes[resource] = task
            return task
        }
        return try await task.value
    }
}
