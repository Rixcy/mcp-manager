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

    public init(home: URL, claudeJSON: URL? = nil, codexTOML: URL? = nil, backupDir: URL? = nil) {
        self.home = home
        self.claudeJSON = claudeJSON ?? home.appendingPathComponent(".claude.json")
        self.codexTOML = codexTOML ?? home.appendingPathComponent(".codex/config.toml")
        self.backupDir = backupDir ?? home.appendingPathComponent("Library/Application Support/MCP Manager/Backups")
    }

    /// Real paths. `MCP_MANAGER_HOME` swaps in a fixture home (used for screenshots);
    /// `CODEX_HOME` is honoured like Codex itself does.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfigPaths {
        let home = environment["MCP_MANAGER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let codex = environment["MCP_MANAGER_HOME"] == nil
            ? environment["CODEX_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("config.toml") }
            : nil
        return ConfigPaths(home: home, codexTOML: codex)
    }
}
