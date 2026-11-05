import AppKit
import SwiftUI

enum Route: Hashable {
    case globals
    case project(String)
    /// A server page, by `MCPServerTarget.key`.
    case server(String)
    case settings
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

    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// The sidebar's project search replaces the Projects heading while open.
    @Published var isSearchingProjects = false
    @Published var projectQuery = ""
    /// Bumped to move keyboard focus into the project search field.
    @Published private(set) var projectSearchFocus = 0

    func searchProjects() {
        sidebarVisibility = .all
        isSearchingProjects = true
        projectSearchFocus += 1
    }

    /// Live server pages by target key, kept while navigating so sessions survive page changes.
    @Published private(set) var inspectors: [String: InspectorModel] = [:]
    /// Keys in the order the servers were first opened, for the sidebar.
    @Published private(set) var inspectorOrder: [String] = []
    /// Where each server page's Back button goes.
    private var returnRoutes: [String: Route] = [:]

    @Published private(set) var shell: ShellEnvironment?
    @Published private(set) var isResolvingShell = false
    private var shellTask: Task<ShellEnvironment, Never>?

    let oauth: OAuthClient

    private var watchers: [FileWatcher] = []
    private var refreshTask: Task<Void, Never>?
    private var keyWindowObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init(manager: MCPManager = MCPManager(paths: .live())) {
        self.manager = manager
        oauth = OAuthClient(store: OAuthCredentialStores.standard(for: manager.paths))
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watchers = [manager.paths.claudeJSON, manager.paths.codexTOML].map { FileWatcher(url: $0, onChange: onChange) }
        // Opening the menu bar popover or focusing the window makes one of our windows key.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in onChange() }
        // Stdio servers run in their own process groups, so they outlive the app unless stopped here.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MCPChildProcesses.terminateAll()
            MainActor.assumeIsolated { self?.inspectors.values.forEach { $0.flushLog() } }
        }
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
            let loaded = Result { try manager.loadGlobal() }
            // Saving what is shown pins servers that just appeared on top, so a
            // later addition lands above them instead of being sorted among them.
            if case let .success(servers) = loaded { manager.rememberGlobalOrder(servers.map(\.name)) }
            return (loaded, manager.projects())
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
        if case .success = loaded { syncGlobalInspectors() }
        if let project = selectedProject {
            await loadEntries(for: project)
        }
        await syncProjectInspectors()
    }

    func moveGlobal(_ name: String, onto target: String) {
        let names = ServerOrder.moving(name, onto: target, in: globals.map(\.name))
        guard names != globals.map(\.name) else { return }
        let byName = Dictionary(globals.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        globals = names.compactMap { byName[$0] }
        do {
            try manager.saveGlobalOrder(names)
        } catch {
            lastError = "Couldn't save the new order: \(Self.message(error))"
        }
    }

    func moveGlobal(_ name: String, by offset: Int) {
        let names = globals.map(\.name)
        guard let index = names.firstIndex(of: name), names.indices.contains(index + offset) else { return }
        moveGlobal(name, onto: names[index + offset])
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
            syncInspectors(in: project, entries: entries)
        case let .failure(error):
            projectEntries = []
            projectError = Self.message(error)
        }
    }

    // MARK: Server pages

    func inspect(_ target: MCPServerTarget) {
        let inspector = inspector(for: target)
        if let route, !isServerRoute(route) { returnRoutes[inspector.key] = route }
        route = .server(inspector.key)
    }

    private func inspector(for target: MCPServerTarget) -> InspectorModel {
        if let existing = inspectors[target.key] {
            existing.update(target: target)
            return existing
        }
        let inspector = InspectorModel(target: target, paths: paths, oauth: oauth) { [weak self] in
            guard let self else { return await ShellEnvironment.resolve() }
            return await self.shellEnvironment()
        }
        inspectors[target.key] = inspector
        inspectorOrder.append(target.key)
        return inspector
    }

    func inspector(forKey key: String) -> InspectorModel? {
        inspectors[key]
    }

    var orderedInspectors: [InspectorModel] {
        inspectorOrder.compactMap { inspectors[$0] }
    }

    private func isServerRoute(_ route: Route) -> Bool {
        if case .server = route { return true }
        return false
    }

    private func defaultReturnRoute(_ key: String) -> Route {
        if let path = inspectors[key]?.target.projectPath { return .project(path) }
        return .globals
    }

    func backLabel(for key: String) -> String {
        switch returnRoutes[key] ?? defaultReturnRoute(key) {
        case let .project(path): return (path as NSString).lastPathComponent
        case .globals, .server, .settings: return "Global MCPs"
        }
    }

    func leaveServerPage(_ key: String) {
        route = returnRoutes[key] ?? defaultReturnRoute(key)
    }

    private func dropInspector(_ key: String) {
        guard let inspector = inspectors.removeValue(forKey: key) else { return }
        inspector.shutdown()
        inspectorOrder.removeAll { $0 == key }
        if route == .server(key) { route = returnRoutes[key] ?? defaultReturnRoute(key) }
        returnRoutes[key] = nil
    }

    private func syncGlobalInspectors() {
        let byName = Dictionary(globals.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, inspector) in inspectors {
            guard case .global = inspector.target.origin else { continue }
            if let server = byName[inspector.target.name], let target = MCPServerTarget.global(server) {
                inspector.update(target: target)
            } else {
                dropInspector(key)
            }
        }
    }

    private func syncInspectors(in project: ProjectRef, entries: [MCPEntry]) {
        let targets = Dictionary(entries.map { MCPServerTarget.project($0) }.map { ($0.key, $0) },
                                 uniquingKeysWith: { first, _ in first })
        for (key, inspector) in inspectors {
            guard case .project = inspector.target.origin, inspector.target.projectPath == project.path else { continue }
            if let target = targets[key] {
                inspector.update(target: target)
            } else {
                dropInspector(key)
            }
        }
    }

    /// Project pages are kept current even while their project is not the one on screen.
    private func syncProjectInspectors() async {
        let paths = Set(inspectors.values.compactMap { inspector -> String? in
            guard case .project = inspector.target.origin else { return nil }
            return inspector.target.projectPath
        })
        let manager = self.manager
        for path in paths where path != selectedProject?.path {
            let project = ProjectRef(path: path)
            let result = await Task.detached(priority: .utility) { Result { try manager.projectMCPs(project) } }.value
            if case let .success(entries) = result { syncInspectors(in: project, entries: entries) }
        }
    }

    // MARK: Shell environment

    /// Resolving runs the login shell and can take seconds, so it happens once and is shared.
    func shellEnvironment() async -> ShellEnvironment {
        if let shell { return shell }
        if let shellTask { return await shellTask.value }
        let task = Task.detached(priority: .userInitiated) { await ShellEnvironment.resolve() }
        shellTask = task
        isResolvingShell = true
        let value = await task.value
        if shellTask == task {
            shell = value
            shellTask = nil
            isResolvingShell = false
        }
        return value
    }

    func reloadShellEnvironment() {
        shell = nil
        shellTask = nil
        Task { _ = await shellEnvironment() }
    }

    // MARK: Writes

    /// Throws so the editor sheet can show the failure inline.
    func add(name: String, config: MCPServerConfig, to clients: Set<MCPClient>) async throws {
        let report = try await write { try $0.add(name: name, config: config, to: clients) }
        lastNotice = Self.describe(report, done: "Added \(name) to", nothing: "Nothing was added for \(name).")
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
        carryVariables(of: .project(entry), to: name)
        lastNotice = "Saved \(name) in \(abbreviate(URL(fileURLWithPath: entry.sourcePath)))."
    }

    /// Throws so the editor sheet can show the failure inline.
    func updateGlobal(_ name: String, to newName: String, config: MCPServerConfig,
                      editedFrom original: MCPServerConfig?) async throws {
        let old = globals.first { $0.name == name }.flatMap(MCPServerTarget.global)
        let report = try await write { try $0.updateGlobal(name, to: newName, config: config, editedFrom: original) }
        if let old { carryVariables(of: old, to: newName) }
        lastNotice = Self.describe(report, done: "Saved \(newName) in", nothing: "\(name) was not changed.")
    }

    /// Variables are filed under the server's key, which contains its name.
    private func carryVariables(of old: MCPServerTarget, to newName: String) {
        guard old.name != newName else { return }
        do {
            try ClientVariableStore(url: paths.clientVariablesFile).moveVariables(from: old.key, to: old.renamed(newName).key)
        } catch {
            lastError = "Renamed, but its MCP Manager variables stayed under the old name: \(Self.message(error))"
        }
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
