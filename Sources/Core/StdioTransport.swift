import Foundation

// Placeholder until T-02 lands the stdio transport; signatures are the contract.

public enum MCPChildProcesses {
    /// Signals every stdio server process group this process started. Safe to call while quitting.
    public static func terminateAll() {}
}
