import Foundation

/// App preferences kept in UserDefaults, shared by the Settings page and the views that use them.
enum Preferences {
    static let newServerTransportKey = "newServerTransport"

    /// The transport a new MCP starts on: whichever the last one was added with, HTTP until then.
    static var newServerTransport: ServerEditorSheet.Kind {
        get { UserDefaults.standard.string(forKey: newServerTransportKey).flatMap(ServerEditorSheet.Kind.init) ?? .http }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: newServerTransportKey) }
    }
}
