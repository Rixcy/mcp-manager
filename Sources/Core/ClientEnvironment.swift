import Foundation

// Placeholder until T-04 lands shell resolution, expansion and the variable
// store; signatures are the contract.

/// The environment a terminal would give the server. GUI apps start with a
/// bare PATH and none of the user's exported keys.
public struct ShellEnvironment: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Read from this login shell.
        case loginShell(String)
        /// The login shell could not be read; the app's own environment plus common tool folders.
        case fallback(reason: String)
    }

    public var variables: [String: String]
    public var source: Source

    public init(variables: [String: String], source: Source) {
        self.variables = variables
        self.source = source
    }

    public static func resolve(shell: String? = nil, timeout: Duration = .seconds(10),
                               base: [String: String] = ProcessInfo.processInfo.environment) async -> ShellEnvironment {
        ShellEnvironment(variables: base, source: .fallback(reason: "not implemented"))
    }
}

public enum VariableExpansion {
    /// Expands `${VAR}` and `${VAR:-default}`. Names with no value and no default are appended to `missing`.
    public static func expand(_ text: String, using variables: [String: String], missing: inout [String]) -> String {
        text
    }

    /// Variables the config needs from the environment: `${VAR}` references
    /// without a default, and the bearer token variable.
    public static func requiredNames(in config: MCPServerConfig) -> [String] {
        []
    }
}

public enum LaunchResolver {
    /// Expands variables and finds the command. Variables come from the shell,
    /// then the config's own env, then `variables`, later ones winning.
    /// Throws `missingVariables`, `commandNotFound`, `commandNotExecutable` or `invalidURL`.
    public static func resolve(_ target: MCPServerTarget, shell: ShellEnvironment, variables: [ClientVariable],
                               homeDirectory: String) throws -> ResolvedLaunch {
        switch target.config.transport {
        case let .stdio(command, args, env):
            return ResolvedLaunch(target: .stdio(executable: command, arguments: args, environment: shell.variables.merging(env) { $1 },
                                                 workingDirectory: target.projectPath ?? homeDirectory),
                                  displayName: ([command] + args).joined(separator: " "))
        case let .http(url, headers):
            guard let parsed = URL(string: url) else { throw MCPClientError.invalidURL(url) }
            return ResolvedLaunch(target: .streamableHTTP(url: parsed, headers: headers), displayName: url)
        case let .sse(url, headers):
            guard let parsed = URL(string: url) else { throw MCPClientError.invalidURL(url) }
            return ResolvedLaunch(target: .sse(url: parsed, headers: headers), displayName: url)
        }
    }

    /// Absolute path for `command`: itself when it contains a slash, else the first match on `searchPath`.
    public static func findExecutable(_ command: String, searchPath: String?, workingDirectory: String?) -> String? {
        nil
    }
}

/// Per-server variables the user adds in MCP Manager, stored 0600.
public struct ClientVariableStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func variables(for key: String) throws -> [ClientVariable] {
        []
    }

    public func setVariables(_ variables: [ClientVariable], for key: String) throws {}
}
