import Foundation

/// One challenge from a `WWW-Authenticate` header (RFC 9110 §11.6.1).
public struct WWWAuthenticateChallenge: Equatable, Sendable {
    public var scheme: String
    /// Auth-param names are lowercased; quoted values are unescaped.
    public var parameters: [String: String]
    public var token68: String?

    public init(scheme: String, parameters: [String: String] = [:], token68: String? = nil) {
        self.scheme = scheme
        self.parameters = parameters
        self.token68 = token68
    }

    public static func parse(_ header: String) -> [WWWAuthenticateChallenge] {
        var scanner = HeaderScanner(header)
        var challenges: [WWWAuthenticateChallenge] = []
        while true {
            scanner.skip(HeaderScanner.isSeparator)
            if scanner.atEnd { break }
            guard let scheme = scanner.token() else {
                scanner.advance()
                continue
            }
            var challenge = WWWAuthenticateChallenge(scheme: scheme)
            scanner.skip(HeaderScanner.isSpace)
            if let token68 = scanner.token68() {
                challenge.token68 = token68
            } else {
                while let (name, value) = scanner.authParam() {
                    if challenge.parameters[name] == nil { challenge.parameters[name] = value }
                }
            }
            challenges.append(challenge)
        }
        return challenges
    }

    /// The Bearer challenge's parameters, or the first challenge's when none is Bearer.
    public static func bearerParameters(_ header: String?) -> [String: String] {
        guard let header else { return [:] }
        let challenges = parse(header)
        let bearer = challenges.first { $0.scheme.caseInsensitiveCompare("Bearer") == .orderedSame } ?? challenges.first
        return bearer?.parameters ?? [:]
    }
}

private struct HeaderScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var atEnd: Bool { index >= scalars.count }
    private var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }
    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool { isSpace(scalar) || scalar == "," }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
    }

    private static func isToken68Character(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "-._~+/".unicodeScalars.contains(scalar)
    }

    mutating func advance() { index += 1 }

    mutating func skip(_ predicate: (Unicode.Scalar) -> Bool) {
        while let scalar = current, predicate(scalar) { index += 1 }
    }

    mutating func token() -> String? {
        var text = ""
        while let scalar = current, Self.isTokenCharacter(scalar) {
            text.unicodeScalars.append(scalar)
            index += 1
        }
        return text.isEmpty ? nil : text
    }

    /// A token68 credential stands alone: it must run to a comma or the end.
    mutating func token68() -> String? {
        let start = index
        var text = ""
        while let scalar = current, Self.isToken68Character(scalar) {
            text.unicodeScalars.append(scalar)
            index += 1
        }
        guard !text.isEmpty else { return nil }
        while current == "=" {
            text.append("=")
            index += 1
        }
        let end = index
        skip(Self.isSpace)
        if atEnd || current == "," {
            index = end
            return text
        }
        index = start
        return nil
    }

    /// `name=value`, or nil (position unchanged) when the next token starts another challenge.
    mutating func authParam() -> (String, String)? {
        let start = index
        skip(Self.isSeparator)
        guard let name = token() else {
            index = start
            return nil
        }
        skip(Self.isSpace)
        guard current == "=" else {
            index = start
            return nil
        }
        index += 1
        skip(Self.isSpace)
        let value = current == "\"" ? quotedString() : unquotedValue()
        return (name.lowercased(), value)
    }

    private mutating func quotedString() -> String {
        index += 1
        var text = ""
        while let scalar = current {
            index += 1
            if scalar == "\"" { return text }
            if scalar == "\\", let escaped = current {
                text.unicodeScalars.append(escaped)
                index += 1
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// Lenient on purpose: some servers send URLs unquoted.
    private mutating func unquotedValue() -> String {
        var text = ""
        while let scalar = current, !Self.isSeparator(scalar) {
            text.unicodeScalars.append(scalar)
            index += 1
        }
        return text
    }
}

/// RFC 9728 protected resource metadata.
struct ProtectedResourceMetadata: Equatable {
    var url: URL
    var authorizationServers: [String]
    var scopesSupported: [String]
}

/// RFC 8414 authorization server metadata, or the 2025-03-26 default endpoints.
struct AuthorizationServerMetadata: Equatable {
    var issuer: String
    /// Nil when no metadata document was found and the default endpoints are in use.
    var metadataURL: URL?
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var codeChallengeMethodsSupported: [String]?
}

struct OAuthDiscovery {
    let http: OAuthHTTP

    /// The advertised URL first, then the RFC 9728 well-known locations for the server's path and its root.
    static func protectedResourceMetadataURLs(serverURL: URL, advertised: String?) -> [URL] {
        var urls: [URL] = []
        if let advertised, let url = URL(string: advertised), url.scheme != nil, url.host != nil {
            urls.append(url)
        }
        let origin = Self.origin(of: serverURL)
        let path = canonicalPath(serverURL)
        if !path.isEmpty, let url = URL(string: origin + "/.well-known/oauth-protected-resource" + path) {
            urls.append(url)
        }
        if let url = URL(string: origin + "/.well-known/oauth-protected-resource") {
            urls.append(url)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// RFC 8414 §3.1 inserts the well-known segment before the issuer's path;
    /// OpenID Connect Discovery appends it, so both orders are tried.
    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        let origin = Self.origin(of: issuer)
        let path = canonicalPath(issuer)
        let candidates = path.isEmpty
            ? [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"]
            : [origin + "/.well-known/oauth-authorization-server" + path,
               origin + "/.well-known/openid-configuration" + path,
               origin + path + "/.well-known/openid-configuration"]
        return candidates.compactMap(URL.init(string:))
    }

    /// `scheme://host[:port]`, lowercased, default port dropped.
    static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.percentEncodedHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost?.lowercased()
        if let port = url.port, !Self.isDefaultPort(port, scheme: components.scheme) {
            components.port = port
        }
        return components.string ?? ""
    }

    static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// The percent-encoded path without trailing slashes; empty for the root.
    static func canonicalPath(_ url: URL) -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// HTTPS, or plain HTTP to this machine.
    static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return isLoopbackHost(url.host)
        default: return false
        }
    }

    /// Nil when no candidate answers with a JSON object (the 2025-03-26 case).
    func protectedResource(serverURL: URL, advertised: String?) async throws -> ProtectedResourceMetadata? {
        for url in Self.protectedResourceMetadataURLs(serverURL: serverURL, advertised: advertised) {
            guard let document = try await http.getJSONObject(url) else { continue }
            let servers = document["authorization_servers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !servers.isEmpty else {
                throw MCPClientError.oauth(.discoveryFailed(
                    url: url.absoluteString, detail: "The protected resource metadata lists no authorization servers."))
            }
            let scopes = document["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ProtectedResourceMetadata(url: url, authorizationServers: servers, scopesSupported: scopes)
        }
        return nil
    }

    /// With `defaultsAt`, a missing document means the default endpoints under that origin (2025-03-26).
    func authorizationServer(issuer: String, defaultsAt origin: String?) async throws -> AuthorizationServerMetadata {
        guard let issuerURL = URL(string: issuer), issuerURL.scheme != nil, issuerURL.host != nil else {
            throw MCPClientError.oauth(.discoveryFailed(url: issuer, detail: "The authorization server address is not a valid URL."))
        }
        let candidates = Self.authorizationServerMetadataURLs(issuer: issuerURL)
        for url in candidates {
            guard let document = try await http.getJSONObject(url) else { continue }
            return try Self.authorizationServerMetadata(document, from: url, issuer: issuer)
        }
        if let origin, let authorize = URL(string: origin + "/authorize"), let token = URL(string: origin + "/token") {
            return AuthorizationServerMetadata(issuer: origin, metadataURL: nil, authorizationEndpoint: authorize,
                                               tokenEndpoint: token, registrationEndpoint: URL(string: origin + "/register"),
                                               codeChallengeMethodsSupported: nil)
        }
        let tried = candidates.map(\.absoluteString).joined(separator: ", ")
        throw MCPClientError.oauth(.discoveryFailed(
            url: issuer, detail: "The authorization server publishes no OAuth metadata. Tried \(tried)."))
    }

    static func authorizationServerMetadata(_ document: [String: JSONValue], from url: URL,
                                            issuer: String) throws -> AuthorizationServerMetadata {
        func endpoint(_ name: String) -> URL? {
            guard let text = document[name]?.stringValue, let url = URL(string: text), url.scheme != nil, url.host != nil
            else { return nil }
            return url
        }
        guard let authorize = endpoint("authorization_endpoint") else {
            throw MCPClientError.oauth(.discoveryFailed(url: url.absoluteString,
                                                        detail: "The authorization server metadata has no authorization_endpoint."))
        }
        guard let token = endpoint("token_endpoint") else {
            throw MCPClientError.oauth(.discoveryFailed(url: url.absoluteString,
                                                        detail: "The authorization server metadata has no token_endpoint."))
        }
        return AuthorizationServerMetadata(
            issuer: document["issuer"]?.stringValue ?? issuer, metadataURL: url, authorizationEndpoint: authorize,
            tokenEndpoint: token, registrationEndpoint: endpoint("registration_endpoint"),
            codeChallengeMethodsSupported: document["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue))
    }

    /// MCP requires PKCE with S256 and HTTPS endpoints (loopback excepted).
    static func validate(_ server: AuthorizationServerMetadata) throws {
        if let methods = server.codeChallengeMethodsSupported, !methods.contains("S256") {
            let offered = methods.isEmpty ? "none" : methods.joined(separator: ", ")
            throw MCPClientError.oauth(.discoveryFailed(
                url: server.metadataURL?.absoluteString ?? server.issuer,
                detail: "The authorization server does not support S256 PKCE, which MCP sign-in requires (it offers: \(offered))."))
        }
        if let issuer = URL(string: server.issuer), issuer.scheme != nil, !isSecure(issuer) {
            throw MCPClientError.oauth(.insecureEndpoint(server.issuer))
        }
        for endpoint in [server.authorizationEndpoint, server.tokenEndpoint] + [server.registrationEndpoint].compactMap({ $0 })
        where !isSecure(endpoint) {
            throw MCPClientError.oauth(.insecureEndpoint(endpoint.absoluteString))
        }
    }
}

/// Small JSON-over-HTTP helper that maps transport failures to `MCPClientError`.
struct OAuthHTTP: Sendable {
    struct Response {
        var status: Int
        var data: Data

        var isSuccess: Bool { (200..<300).contains(status) }

        var jsonObject: [String: JSONValue]? {
            (try? JSONValue.parse(data))?.objectValue
        }

        /// The body for error messages: short, single line.
        var bodySnippet: String? {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
                .components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    /// Ephemeral, so no cookies or cached metadata carry over between sign-ins.
    static let shared: OAuthHTTP = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return OAuthHTTP(session: URLSession(configuration: configuration))
    }()

    let session: URLSession

    /// The JSON object at `url`, or nil for any non-2xx answer or a body that is not a JSON object
    /// (many servers answer unknown paths with an HTML page and 200).
    func getJSONObject(_ url: URL) async throws -> [String: JSONValue]? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPProtocolVersion.requested, forHTTPHeaderField: "MCP-Protocol-Version")
        let response = try await send(request)
        return response.isSuccess ? response.jsonObject : nil
    }

    func postJSON(_ url: URL, _ body: JSONValue) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body.encoded()
        return try await send(request)
    }

    func postForm(_ url: URL, _ fields: [(String, String)], headers: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(fields.map { "\(Self.formEncode($0))=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            return Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw MCPClientError.cancelled }
            throw MCPClientError.network(code: error.code.rawValue, url: Self.withoutQuery(request.url),
                                         detail: error.localizedDescription)
        } catch is CancellationError {
            throw MCPClientError.cancelled
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but RFC 3986 unreserved characters, which is
    /// safe both in form bodies and in query strings.
    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// For logs and errors: never the query, which can carry codes and state.
    static func withoutQuery(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? ""
    }
}
