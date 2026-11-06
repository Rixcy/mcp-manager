import AppKit
import SwiftUI

// Built by bin/capture together with Sources/Core and Sources/App (minus @main).

let usage = "usage: capture <fixture-home> <out-dir> <light,dark> <scene>... (scenes: \(CaptureScene.allCases.map(\.rawValue).joined(separator: ", ")))"

enum CaptureScene: String, CaseIterable {
    case globals, project, server
}

struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let fixtureHome = URL(fileURLWithPath: arguments[0])
let outputDir = URL(fileURLWithPath: arguments[1])
let appearances = arguments[2].split(separator: ",").map(String.init)
let scenes = arguments.dropFirst(3).map { name -> CaptureScene in
    guard let scene = CaptureScene(rawValue: name) else {
        FileHandle.standardError.write(Data("capture: unknown scene \(name)\n\(usage)\n".utf8))
        exit(2)
    }
    return scene
}

let app = NSApplication.shared
// No Dock icon or menu bar.
app.setActivationPolicy(.accessory)

/// Never key or main, so it cannot take focus or keystrokes from the user.
final class BackgroundWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private func onScreenWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

private func layer(_ info: [String: Any]) -> Int { info[kCGWindowLayer as String] as? Int ?? 0 }
private func owner(_ info: [String: Any]) -> pid_t { info[kCGWindowOwnerPID as String] as? pid_t ?? 0 }

/// The lowest layer any other app draws in, normally the desktop wallpaper.
/// The window server's own backstop sits below it and is skipped.
private func lowestVisibleLayer() -> Int {
    let others = onScreenWindows().filter {
        owner($0) != getpid() && ($0[kCGWindowOwnerName as String] as? String) != "Window Server"
    }
    return others.map(layer).min() ?? Int(CGWindowLevelForKey(.desktopWindow))
}

@MainActor
final class Capture {
    let model = AppModel(manager: MCPManager(paths: ConfigPaths(home: fixtureHome)))
    let window: BackgroundWindow
    private let wallpaperLayer = lowestVisibleLayer()

    init() {
        // The window server still composites the window, which Liquid Glass and
        // vibrancy need (cacheDisplay draws the sidebar blank), but one layer
        // below the wallpaper nothing of it shows on any display.
        window = BackgroundWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: wallpaperLayer - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient, .canJoinAllSpaces]
        window.contentView = NSHostingView(rootView: MainWindow().environmentObject(model).tint(Theme.accent))
    }

    func run() async throws {
        window.orderFrontRegardless()
        try await until("the window server to list the window") {
            onScreenWindows().contains { owner($0) == getpid() }
        }
        try assertHidden()
        try await until("configs to load") { self.model.hasLoaded }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for scene in scenes {
            try await show(scene)
            for appearance in appearances {
                window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                try await settle()
                try await shoot("\(scene.rawValue)-\(appearance)")
            }
        }
    }

    private func show(_ scene: CaptureScene) async throws {
        switch scene {
        case .globals:
            model.route = .globals
        case .project:
            guard let reels = model.projects.first(where: { $0.path.hasSuffix("/Projects/reels") }) else {
                throw CaptureFailure(description: "the fixture home has no reels project")
            }
            model.open(reels)
            try await until("the reels project to load") {
                !self.model.isLoadingProject && !self.model.projectEntries.isEmpty
            }
        case .server:
            guard let demo = model.globals.first(where: { $0.name == "demo" }),
                  let target = MCPServerTarget.global(demo) else {
                throw CaptureFailure(description: "the fixture home has no demo server")
            }
            model.inspect(target)
            guard let inspector = model.inspector(forKey: target.key) else {
                throw CaptureFailure(description: "no server page for demo")
            }
            inspector.tab = .tools
            inspector.connect()
            try await until("demo to connect and list tools", timeout: .seconds(30)) {
                inspector.isConnected && !inspector.tools.isEmpty
            }
        }
    }

    /// Fails before anything is captured if the window could be seen or the app took focus.
    private func assertHidden() throws {
        let mine = onScreenWindows().filter { owner($0) == getpid() }
        if let visible = mine.first(where: { layer($0) >= wallpaperLayer }) {
            throw CaptureFailure(description: "window at layer \(layer(visible)) is not below the wallpaper (\(wallpaperLayer))")
        }
        if mine.count != 1 {
            throw CaptureFailure(description: "expected one window, found \(mine.count) (a sheet or alert would show on screen)")
        }
        if app.isActive {
            throw CaptureFailure(description: "the capture app became active and took focus")
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))
        try assertHidden()
    }

    private func shoot(_ name: String) async throws {
        let file = outputDir.appendingPathComponent("\(name).png")
        let screencapture = Process()
        screencapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -l captures the window's own surface, so it works while the window is hidden.
        screencapture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try screencapture.run()
        while screencapture.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard screencapture.terminationStatus == 0 else {
            throw CaptureFailure(description: "screencapture exited \(screencapture.terminationStatus) for \(name); grant Screen Recording to the terminal running it")
        }
        print(file.path)
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CaptureFailure(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

Task { @MainActor in
    var status: Int32 = 0
    do {
        try await Capture().run()
    } catch {
        FileHandle.standardError.write(Data("capture: \(error)\n".utf8))
        status = 1
    }
    MCPChildProcesses.terminateAll()
    exit(status)
}
app.run()
