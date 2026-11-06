import Foundation

public struct ProcessExit: Equatable, Sendable, CustomStringConvertible {
    public var code: Int32?
    public var signal: Int32?

    public init(code: Int32? = nil, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }

    public var description: String {
        if let signal { return "signal \(signal)" }
        return "exit code \(code.map(String.init) ?? "unknown")"
    }
}

/// Where a session was when it failed. The same symptom needs different advice
/// before and after the handshake.
public enum MCPStage: String, Equatable, Sendable {
    case launch
    case initialize
    case request
}

public enum MCPClientError: Error, Equatable, Sendable {
    // Turning the config into something to launch or call.
    case missingVariables([String])
    case invalidURL(String)
    case commandNotFound(command: String, searchedPath: [String])
    case commandNotExecutable(path: String)

    // stdio servers.
    case launchFailed(command: String, detail: String)
    case processExited(ProcessExit, stderrTail: [String], stage: MCPStage)
    /// The server wrote something other than JSON-RPC to stdout.
    case invalidServerOutput(line: String, stage: MCPStage)
    case messageTooLarge(bytes: Int)

    // HTTP and SSE servers.
    case httpStatus(code: Int, url: String, body: String?, stage: MCPStage)
    /// `code` is the `URLError` code.
    case network(code: Int, url: String, detail: String)
    /// A 401 that stored credentials could not fix. `challenge` is the raw `WWW-Authenticate` header.
    case authorizationRequired(url: String, challenge: String?)
    case sessionExpired(url: String)

    // The protocol.
    case timedOut(method: String, seconds: Int)
    case rpcError(method: String, code: Int, message: String, data: String?)
    case malformedResponse(method: String, detail: String)
    case unsupportedProtocolVersion(String)
    /// The server did not declare the capability (`tools`, `resources`, `prompts`).
    case capabilityMissing(String)
    case connectionClosed(detail: String?)
    case notConnected
    case cancelled

    case oauth(OAuthFailure)

    /// Tool or prompt arguments that do not match what the server asked for.
    case invalidArguments(String)
}

public enum OAuthFailure: Equatable, Sendable {
    case discoveryFailed(url: String, detail: String)
    /// The authorization server has no dynamic client registration endpoint.
    case registrationUnsupported(issuer: String)
    case registrationFailed(status: Int?, detail: String)
    /// An authorization or token endpoint that is not HTTPS (loopback hosts excepted).
    case insecureEndpoint(String)
    case callbackServerFailed(String)
    case browserTimedOut(seconds: Int)
    /// The authorization server redirected back with `error=…`.
    case denied(error: String, description: String?)
    case stateMismatch
    case tokenRequestFailed(status: Int?, error: String?, description: String?)
    case refreshFailed(String)
    case credentialStore(String)
}

/// What the UI shows for a failure: a short title, one plain sentence or two,
/// concrete fixes, and the technical text for anyone who wants it.
public struct HelpfulError: Equatable, Sendable {
    public var title: String
    public var message: String
    public var suggestions: [String]
    public var details: String?
    /// Signing in is the fix, so the UI offers a Sign in button.
    public var offersSignIn: Bool
    /// Adding or changing a variable is the fix, so the UI points at the Environment tab.
    public var offersEnvironment: Bool

    public init(title: String, message: String, suggestions: [String] = [], details: String? = nil,
                offersSignIn: Bool = false, offersEnvironment: Bool = false) {
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.details = details
        self.offersSignIn = offersSignIn
        self.offersEnvironment = offersEnvironment
    }
}

extension MCPClientError: LocalizedError {
    public var errorDescription: String? {
        let help = helpful
        return "\(help.title). \(help.message)"
    }
}
