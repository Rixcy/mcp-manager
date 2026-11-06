import AppKit
import SwiftUI

enum Route: Hashable {
    case globals
    case project(String)
}

@MainActor
final class AppModel: ObservableObject {
    let manager: MCPManager
    var paths: ConfigPaths { manager.paths }

    @Published private(set) var globals: [GlobalServer] = []
    @Published private(set) var projects: [ProjectRef] = []
    @Published private(set) var hasLoaded = false
    /// Failure reading the global configs; distinct from `lastError`, which reports a user action.
    @Published private(set) var loadError: String?

    @Published var route: Route? = .globals {
        didSet { if route != oldValue { routeChanged() } }
    }
    @Published private(set) var selectedProject: ProjectRef?
    @Published private(set) var projectEntries: [MCPEntry] = []
    @Published private(set) var projectError: String?
    @Published private(set) var isLoadingProject = false

    @Published var lastError: String? { didSet { announce(lastError) } }
    @Published var lastNotice: String? { didSet { announce(lastNotice) } }
    @Published private(set) var isWriting = false
    @Published var isAddingServer = false

    private var watchers: [FileWatcher] = []
    private var refreshTask: Task<Void, Never>?
    private var keyWindowObserver: NSObjectProtocol?

    init(manager: MCPManager = MCPManager(paths: .live())) {
        self.manager = manager
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watchers = [manager.paths.claudeJSON, manager.paths.codexTOML].map { FileWatcher(url: $0, onChange: onChange) }
        // Opening the menu bar popover or focusing the window makes one of our windows key.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in onChange() }
        scheduleRefresh(delay: .zero)
    }

    // MARK: Loading

    func scheduleRefresh(delay: Duration = .milliseconds(250)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        let manager = self.manager
        let (loaded, projects) = await Task.detached(priority: .userInitiated) {
            (Result { try manager.loadGlobal() }, manager.projects())
        }.value
        switch loaded {
        case let .success(servers):
            globals = servers
            loadError = nil
        case let .failure(error):
            loadError = Self.message(error)
        }
        self.projects = projects
        hasLoaded = true
        if let project = selectedProject {
            await loadEntries(for: project)
        }
    }

    func rankedProjects(_ query: String) -> [ProjectRef] {
        FuzzyMatcher.rank(projects, query: query.trimmingCharacters(in: .whitespaces))
    }

    func open(_ project: ProjectRef) {
        route = .project(project.path)
    }

    private func routeChanged() {
        guard case let .project(path) = route else {
            selectedProject = nil
            projectEntries = []
            projectError = nil
            return
        }
        let project = projects.first { $0.path == path } ?? ProjectRef(path: path)
        selectedProject = project
        projectEntries = []
        projectError = nil
        Task { await loadEntries(for: project) }
    }

    private func loadEntries(for project: ProjectRef) async {
        isLoadingProject = true
        let manager = self.manager
        let result = await Task.detached(priority: .userInitiated) {
            Result { try manager.projectMCPs(project) }
        }.value
        guard selectedProject == project else { return }
        isLoadingProject = false
        switch result {
        case let .success(entries):
            projectEntries = entries
            projectError = nil
        case let .failure(error):
            projectEntries = []
            projectError = Self.message(error)
        }
    }

    // MARK: Writes

    /// Throws so the editor sheet can show the failure inline.
    func add(name: String, config: MCPServerConfig, to clients: Set<MCPClient>) async throws {
        let report = try await write { try $0.add(name: name, config: config, to: clients) }
        lastNotice = Self.describe(report, done: "Added \(name) to", nothing: "Nothing was added for \(name).")
    }

    func rename(_ oldName: String, to newName: String) async throws {
        let report = try await write { try $0.rename(oldName, to: newName) }
        lastNotice = Self.describe(report, done: "Renamed \(oldName) to \(newName) in", nothing: "\(oldName) was not renamed.")
    }

    func remove(_ name: String, from clients: Set<MCPClient>) async {
        do {
            let report = try await write { try $0.remove(name: name, from: clients) }
            lastNotice = Self.describe(report, done: "Removed \(name) from", nothing: "Nothing was removed for \(name).")
        } catch {
            fail(error)
        }
    }

    func removeProjectEntry(_ entry: MCPEntry) async {
        do {
            _ = try await write { try $0.removeProjectEntry(entry); return WriteReport(written: [entry.client]) }
            lastNotice = "Removed \(entry.name) from \(abbreviate(URL(fileURLWithPath: entry.sourcePath)))."
        } catch {
            fail(error)
        }
    }

    /// Throws so the editor sheet can show the failure inline.
    func updateProjectEntry(_ entry: MCPEntry, name: String, config: MCPServerConfig) async throws {
        _ = try await write { try $0.updateProjectEntry(entry, name: name, config: config); return WriteReport(written: [entry.client]) }
        lastNotice = "Saved \(name) in \(abbreviate(URL(fileURLWithPath: entry.sourcePath)))."
    }

    func sync(_ name: String) async {
        do {
            let report = try await write { try $0.sync(name: name) }
            lastNotice = Self.describe(report, done: "Synced \(name) to", nothing: "\(name) was not synced.")
        } catch {
            fail(error)
        }
    }

    private func write(_ work: @escaping @Sendable (MCPManager) throws -> WriteReport) async throws -> WriteReport {
        isWriting = true
        lastError = nil
        lastNotice = nil
        defer { isWriting = false }
        let manager = self.manager
        let report = try await Task.detached(priority: .userInitiated) { try work(manager) }.value
        await refresh()
        return report
    }

    private func fail(_ error: Error) {
        lastNotice = nil
        lastError = Self.message(error)
    }

    // MARK: Messages

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func describe(_ report: WriteReport, done: String, nothing: String) -> String {
        var parts = [report.written.isEmpty ? nothing : "\(done) \(clientList(report.written))."]
        parts += report.skipped.map { "\($0.client.displayName) skipped: \($0.reason)" }
        return parts.joined(separator: " ")
    }

    private func announce(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Watches one file for writes and atomic replaces. A replace swaps the inode,
/// so the source is re-armed on delete/rename; a missing file is retried.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.rickbooth.mcp-manager.watch")
    private var source: DispatchSourceFileSystemObject?
    private var wasMissing = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { self.arm() }
    }

    deinit {
        source?.cancel()
    }

    private func arm() {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            wasMissing = true
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.arm() }
            return
        }
        if wasMissing {
            wasMissing = false
            onChange()
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            let events = source.data
            self.onChange()
            if events.contains(.delete) || events.contains(.rename) {
                self.arm()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }
}
