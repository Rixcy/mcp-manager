import Foundation

/// Every file MCP Manager touches, rooted at one home directory so tests and
/// fixture runs never see the real configs.
public struct ConfigPaths: Equatable, Sendable {
    public var home: URL
    /// Claude user config: `<home>/.claude.json`.
    public var claudeJSON: URL
    /// Codex global config: `<CODEX_HOME or home/.codex>/config.toml`.
    public var codexTOML: URL
    /// Timestamped copies taken before every write.
    public var backupDir: URL
    /// MCP Manager's own state: client variables and, off the keychain, OAuth credentials.
    public var supportDir: URL
    /// One JSONL log per server the client connects to.
    public var logsDir: URL
    /// OAuth tokens go to the login keychain only for the real home, so tests
    /// and fixture runs never prompt for or touch it.
    public var usesKeychain: Bool

    public init(home: URL, claudeJSON: URL? = nil, codexTOML: URL? = nil, backupDir: URL? = nil,
                usesKeychain: Bool = false) {
        self.home = home
        self.claudeJSON = claudeJSON ?? home.appendingPathComponent(".claude.json")
        self.codexTOML = codexTOML ?? home.appendingPathComponent(".codex/config.toml")
        supportDir = home.appendingPathComponent("Library/Application Support/MCP Manager")
        self.backupDir = backupDir ?? supportDir.appendingPathComponent("Backups")
        logsDir = home.appendingPathComponent("Library/Logs/MCP Manager")
        self.usesKeychain = usesKeychain
    }

    public var clientVariablesFile: URL { supportDir.appendingPathComponent("client-variables.json") }
    public var oauthCredentialsFile: URL { supportDir.appendingPathComponent("oauth-credentials.json") }
    public var serverOrderFile: URL { supportDir.appendingPathComponent("server-order.json") }

    /// Real paths. `MCP_MANAGER_HOME` swaps in a fixture home (used for screenshots);
    /// `CODEX_HOME` is honoured like Codex itself does.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfigPaths {
        let fixture = environment["MCP_MANAGER_HOME"].map { URL(fileURLWithPath: $0) }
        let home = fixture ?? FileManager.default.homeDirectoryForCurrentUser
        let codex = fixture == nil
            ? environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("config.toml") }
            : nil
        return ConfigPaths(home: home, codexTOML: codex, usesKeychain: fixture == nil)
    }
}
