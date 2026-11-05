import AppKit
import SwiftUI

let mainWindowID = "main"

@main
struct MCPManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onOpenURL { _ in NSApp.activate(ignoringOtherApps: true) }
                .background(WindowReader { DesktopMode.enter($0) })
                .onDisappear { DesktopMode.leave() }
        }
        // `mcp-manager open` sends mcp-manager://open; claiming it here opens
        // this window instead of a stray new scene.
        .handlesExternalEvents(matching: ["open"])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(model: model)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button("Search Projects") { model.searchProjects() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

/// The app lives in the menu bar, and becomes a regular app with a Dock icon,
/// app menu and ⌘-Tab entry only while its window is open.
@MainActor
enum DesktopMode {
    private static var watched: Set<ObjectIdentifier> = []

    static func enter(_ window: NSWindow?) {
        guard let window else { return }
        // onDisappear is not reliable when a single Window scene closes.
        if watched.insert(ObjectIdentifier(window)).inserted {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in
                MainActor.assumeIsolated { leave() }
            }
        }
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // The app menu only appears once the app is activated after the policy change.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    static func leave() {
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the app again from Finder, Spotlight or Launchpad shows its window,
    /// through the same URL `mcp-manager open` uses.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Returning true lets AppKit restore a minimised window itself.
        let minimised = sender.windows.contains(where: \.isMiniaturized)
        if !flag, !minimised, let url = URL(string: "mcp-manager://open") {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

private struct SettingsCommand: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            model.route = .settings
            openWindow.mainWindow()
        }
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
