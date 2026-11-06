import AppKit
import SwiftUI

let mainWindowID = "main"

@main
struct MCPManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .tint(Theme.accent)
        } label: {
            Image(nsImage: OrcEmblem.menuBarImage)
                .accessibilityLabel("MCP Manager")
        }
        .menuBarExtraStyle(.window)

        Window("MCP Manager", id: mainWindowID) {
            MainWindow()
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowCommand()
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open MCP Manager") { openWindow.mainWindow() }
            .keyboardShortcut(",", modifiers: .command)
    }
}

extension OpenWindowAction {
    /// LSUIElement apps are never frontmost on their own, so the window would
    /// open behind whatever app the user was in.
    @MainActor
    func mainWindow() {
        callAsFunction(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
