import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case tools, resources, prompts, logs, environment, info
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .resources: return "Resources"
        case .prompts: return "Prompts"
        case .logs: return "Logs"
        case .environment: return "Environment"
        case .info: return "Info"
        }
    }
}

enum ConnectStep: Equatable {
    case readingShell, starting, loading

    var label: String {
        switch self {
        case .readingShell: return "Reading shell environment…"
        case .starting: return "Starting and handshaking…"
        case .loading: return "Loading tools…"
        }
    }
}

enum ConnectionState: Equatable {
    case notConnected
    case connecting(ConnectStep)
    case connected(MCPInitializeResult)
    /// `challenge` is set when signing in is the fix.
    case failed(HelpfulError, challenge: AuthChallenge?)
    case signingIn
}

struct AuthChallenge: Equatable {
    var url: URL
    var header: String?
}

enum ArgumentMode: String, CaseIterable, Identifiable {
    case form, json
    var id: String { rawValue }
    var label: String { self == .form ? "Form" : "JSON" }
}

struct ToolDraft: Equatable {
    var values: [String: String]
    var json: String
    var mode: ArgumentMode = .form
    /// Field name to message; "" holds a message about the whole JSON text.
    var errors: [String: String] = [:]
    /// Arguments the schema does not describe, kept only in JSON mode.
    var extraNames: [String] = []
}

struct ActiveCall: Identifiable {
    let id: UUID
    let toolName: String
    let started: Date
    var progress: MCPProgress?
    let task: Task<Void, Never>
}

struct CallRecord: Identifiable, Equatable {
    enum Outcome: Equatable {
        case result(MCPToolResult)
        case failure(HelpfulError)
    }

    let id: UUID
    let toolName: String
    let arguments: [String: JSONValue]
    let started: Date
    let duration: Duration
    let outcome: Outcome

    var argumentsJSON: String { JSONValue.object(arguments).jsonString(pretty: true) }
}

enum LoadState<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(HelpfulError)
}

enum LaunchPreview {
    case ready(String)
    case blocked(HelpfulError)
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all, messages, serverOutput, eventsAndErrors
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .messages: return "Messages"
        case .serverOutput: return "Server output"
        case .eventsAndErrors: return "Events and errors"
        }
    }

    func includes(_ kind: MCPLogEntry.Kind) -> Bool {
        switch self {
        case .all: return true
        case .messages: return kind == .incoming || kind == .outgoing
        case .serverOutput: return kind == .stderr
        case .eventsAndErrors: return kind == .event || kind == .warning || kind == .error
        }
    }
}

/// Entries arrive on whatever thread the transport records on. They wait here
/// and reach SwiftUI in batches, so a server flooding stderr cannot stall the UI.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MCPLogEntry] = []
    private var scheduled = false

    /// True when the caller should schedule a drain.
    func append(_ entry: MCPLogEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(entry)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> [MCPLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let batch = pending
        pending = []
        scheduled = false
        return batch
    }
}

/// Lives in `AppModel` by target key so a session survives page changes.
@MainActor
final class InspectorModel: ObservableObject, Identifiable {
    static let logLimit = 2_000
    static let historyLimit = 50

    @Published private(set) var target: MCPServerTarget
    @Published private(set) var state: ConnectionState = .notConnected
    /// The config changed on disk while connected; the live session still uses the old one.
    @Published private(set) var configChanged = false
    @Published var tab: InspectorTab = .tools
    @Published private(set) var transportInfo: MCPTransportInfo?
    @Published private(set) var resolvedLaunch: ResolvedLaunch?
    @Published private(set) var hasOAuthCredential = false
    @Published private(set) var pingResult: LoadState<Duration> = .idle

    @Published private(set) var tools: [MCPTool] = []
    @Published var toolSearch = ""
    @Published var selectedToolName: String?
    @Published private(set) var drafts: [String: ToolDraft] = [:]
    @Published private(set) var activeCall: ActiveCall?
    @Published private(set) var history: [CallRecord] = []
    @Published private(set) var shownCallID: UUID?

    @Published private(set) var resources: [MCPResource] = []
    @Published private(set) var templates: [MCPResourceTemplate] = []
    @Published var selectedResourceURI: String?
    @Published private(set) var resourceRead: LoadState<[MCPResourceContents]> = .idle
    @Published private(set) var prompts: [MCPPrompt] = []
    @Published var selectedPromptName: String?
    @Published private(set) var promptArguments: [String: [String: String]] = [:]
    @Published private(set) var promptResult: LoadState<MCPPromptResult> = .idle
    @Published private(set) var catalogError: HelpfulError?

    @Published private(set) var logEntries: [MCPLogEntry] = []
    @Published var logError: String?

    @Published var variableRows: [KeyValueRow] = []
    @Published private(set) var savedVariableRows: [KeyValueRow] = []
    @Published private(set) var variablesError: String?

    nonisolated var id: String { key }
    nonisolated let key: String

    let paths: ConfigPaths
    private let oauth: OAuthClient
    private let shellProvider: @MainActor () async -> ShellEnvironment
    private let variableStore: ClientVariableStore
    private let logBuffer = LogBuffer()
    private var log: MCPLogFile?
    private var session: MCPClientSession?
    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?

    init(target: MCPServerTarget, paths: ConfigPaths, oauth: OAuthClient,
         shell: @escaping @MainActor () async -> ShellEnvironment) {
        self.target = target
        key = target.key
        self.paths = paths
        self.oauth = oauth
        shellProvider = shell
        variableStore = ClientVariableStore(url: paths.clientVariablesFile)
        loadVariables()
        loadLogTail()
        refreshCredential()
    }

    // MARK: Derived

    var logURL: URL { paths.logsDir.appendingPathComponent(target.logFileName) }

    var isRemote: Bool {
        if case .stdio = target.config.transport { return false }
        return true
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .connecting, .signingIn: return true
        default: return false
        }
    }

    var initializeResult: MCPInitializeResult? {
        if case let .connected(result) = state { return result }
        return nil
    }

    var capabilities: MCPServerCapabilities? { initializeResult?.capabilities }

    var failure: HelpfulError? {
        if case let .failed(error, _) = state { return error }
        return nil
    }

    /// The server URL credentials are filed under: the resolved one once known.
    var remoteURL: URL? {
        switch resolvedLaunch?.target {
        case let .streamableHTTP(url, _)?, let .sse(url, _)?: return url
        default: break
        }
        switch target.config.transport {
        case let .http(url, _), let .sse(url, _): return URL(string: url)
        case .stdio: return nil
        }
    }

    var statusText: String {
        switch state {
        case .notConnected: return "Not connected"
        case let .connecting(step): return step == .loading ? "Loading…" : "Connecting…"
        case let .connected(result):
            guard result.capabilities.tools else { return "Connected" }
            return "Connected · \(tools.count == 1 ? "1 tool" : "\(tools.count) tools")"
        case .failed: return "Failed"
        case .signingIn: return "Signing in…"
        }
    }

    var statusTone: Tone {
        switch state {
        case .notConnected: return .neutral
        case .connecting, .signingIn: return .accent
        case .connected: return configChanged ? .yellow : .green
        case .failed: return .red
        }
    }

    // MARK: Config

    func update(target newTarget: MCPServerTarget) {
        guard newTarget != target else { return }
        if newTarget.config != target.config {
            if isConnected || isBusy {
                configChanged = true
            } else {
                resolvedLaunch = nil
            }
        }
        target = newTarget
    }

    // MARK: Connection

    func connect() {
        guard !isBusy else { return }
        // The Missing warning and the resolved command line already count unsaved rows.
        if variablesDirty, variableIssues.isEmpty { saveVariables() }
        generation += 1
        let current = generation
        connectTask = Task { await runConnect(generation: current) }
    }

    func reconnect() {
        disconnect()
        connect()
    }

    func disconnect() {
        generation += 1
        connectTask?.cancel()
        signInTask?.cancel()
        activeCall?.task.cancel()
        activeCall = nil
        catalogError = nil
        stopSession()
        state = .notConnected
        configChanged = false
    }

    /// Writes buffered log lines now; the app is quitting.
    func flushLog() {
        log?.flush()
    }

    /// Ends the session and closes the log; the model is about to be dropped.
    func shutdown() {
        disconnect()
        log?.close()
        log = nil
    }

    private func runConnect(generation current: Int) async {
        stopSession()
        configChanged = false
        let launchTarget = target
        catalogError = nil
        pingResult = .idle
        state = .connecting(.readingShell)
        let shell = await shellProvider()
        guard current == generation else { return }

        let launch: ResolvedLaunch
        do {
            let variables = try variableStore.variables(for: key)
            launch = try LaunchResolver.resolve(launchTarget, shell: shell, variables: variables, homeDirectory: paths.home.path)
        } catch {
            fail(error)
            return
        }
        resolvedLaunch = launch
        let auth: MCPAuthProvider? = isRemote ? OAuthAuthProvider(client: oauth) : nil
        let session = MCPClientSession(launch: launch, log: logFile(), auth: auth)
        self.session = session
        state = .connecting(.starting)
        do {
            let result = try await session.connect()
            guard current == generation else {
                await session.close()
                return
            }
            transportInfo = await session.transportInfo
            observe(session, generation: current)
            state = .connecting(.loading)
            await loadCatalog(result.capabilities, session: session, generation: current)
            guard current == generation else { return }
            state = .connected(result)
            configChanged = target.config != launchTarget.config
            refreshCredential()
        } catch {
            guard current == generation else { return }
            stopSession()
            fail(error)
        }
    }

    private func observe(_ session: MCPClientSession, generation current: Int) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard let self, current == self.generation else { return }
                await self.handle(event, session: session, generation: current)
            }
        }
    }

    private func handle(_ event: MCPSessionEvent, session: MCPClientSession, generation current: Int) async {
        switch event {
        case .toolsChanged:
            await refreshTools(session, generation: current)
        case .resourcesChanged:
            await refreshResources(session, generation: current)
        case .promptsChanged:
            await refreshPrompts(session, generation: current)
        case let .closed(error):
            guard current == generation else { return }
            generation += 1
            activeCall?.task.cancel()
            activeCall = nil
            self.session = nil
            transportInfo = nil
            configChanged = false
            if let error {
                fail(error)
            } else {
                state = .notConnected
            }
        }
    }

    private func stopSession() {
        eventsTask?.cancel()
        eventsTask = nil
        transportInfo = nil
        if let session {
            self.session = nil
            Task { await session.close() }
        }
    }

    private func fail(_ error: Error) {
        var challenge: AuthChallenge?
        if case let .authorizationRequired(url, header)? = error as? MCPClientError {
            challenge = AuthChallenge(url: URL(string: url) ?? remoteURL ?? URL(fileURLWithPath: "/"), header: header)
        }
        let helpful = HelpfulError(error)
        if challenge == nil, helpful.offersSignIn, let url = remoteURL {
            challenge = AuthChallenge(url: url, header: nil)
        }
        state = .failed(helpful, challenge: challenge)
    }

    // MARK: Sign-in

    var canSignIn: Bool {
        guard isRemote, !isBusy else { return false }
        if case let .failed(error, challenge) = state { return challenge != nil || error.offersSignIn }
        return false
    }

    func signIn() {
        guard isRemote else { return }
        let challenge: AuthChallenge?
        if case let .failed(_, found) = state { challenge = found } else { challenge = nil }
        guard let serverURL = remoteURL ?? challenge?.url else { return }
        generation += 1
        stopSession()
        state = .signingIn
        let current = generation
        let oauth = self.oauth
        let hints = target.config.oauth
        let log = logFile()
        signInTask = Task {
            do {
                _ = try await oauth.signIn(serverURL: serverURL, challenge: challenge?.header, hints: hints, log: log,
                                           openBrowser: { url in
                                               let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                                               if !opened {
                                                   throw MCPClientError.oauth(.callbackServerFailed("macOS could not open the sign-in page in your default browser"))
                                               }
                                           })
                guard current == generation else { return }
                refreshCredential()
                state = .notConnected
                connect()
            } catch {
                guard current == generation else { return }
                fail(error)
            }
        }
    }

    func cancelSignIn() {
        generation += 1
        signInTask?.cancel()
        state = .notConnected
    }

    func signOut() {
        guard let url = remoteURL else { return }
        do {
            try oauth.signOut(serverURL: url)
            hasOAuthCredential = false
            if isConnected { reconnect() }
        } catch {
            fail(error)
        }
    }

    func refreshCredential() {
        guard isRemote, let url = remoteURL else {
            hasOAuthCredential = false
            return
        }
        let oauth = self.oauth
        Task {
            let found = await Task.detached { oauth.credential(for: url) != nil }.value
            hasOAuthCredential = found
        }
    }

    // MARK: Catalog

    private func loadCatalog(_ capabilities: MCPServerCapabilities, session: MCPClientSession, generation current: Int) async {
        tools = []
        resources = []
        templates = []
        prompts = []
        if capabilities.tools { await refreshTools(session, generation: current) }
        guard current == generation else { return }
        if capabilities.resources { await refreshResources(session, generation: current) }
        guard current == generation else { return }
        if capabilities.prompts { await refreshPrompts(session, generation: current) }
        if !capabilities.tools, tab == .tools {
            tab = capabilities.resources ? .resources : (capabilities.prompts ? .prompts : .info)
        }
    }

    private func refreshTools(_ session: MCPClientSession, generation current: Int) async {
        do {
            let listed = try await session.listTools()
            guard current == generation else { return }
            tools = listed
            if let selected = selectedToolName, !tools.contains(where: { $0.name == selected }) { selectedToolName = nil }
            if selectedToolName == nil { selectedToolName = tools.first?.name }
        } catch {
            reportCatalogError(error, generation: current)
        }
    }

    private func refreshResources(_ session: MCPClientSession, generation current: Int) async {
        do {
            let listed = try await session.listResources()
            let listedTemplates = (try? await session.listResourceTemplates()) ?? []
            guard current == generation else { return }
            resources = listed
            templates = listedTemplates
        } catch {
            reportCatalogError(error, generation: current)
        }
    }

    private func refreshPrompts(_ session: MCPClientSession, generation current: Int) async {
        do {
            let listed = try await session.listPrompts()
            guard current == generation else { return }
            prompts = listed
        } catch {
            reportCatalogError(error, generation: current)
        }
    }

    /// A load that the user cancelled, or that belongs to an older connection, is not an error to show.
    private func reportCatalogError(_ error: Error, generation current: Int) {
        guard current == generation, (error as? MCPClientError) != .cancelled, !(error is CancellationError) else { return }
        catalogError = HelpfulError(error)
    }

    func dismissCatalogError() {
        catalogError = nil
    }

    // MARK: Tools

    var selectedTool: MCPTool? {
        tools.first { $0.name == selectedToolName }
    }

    var filteredTools: [MCPTool] {
        let query = toolSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tools }
        return tools.filter { tool in
            [tool.name, tool.displayTitle, tool.description ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func draft(for tool: MCPTool) -> ToolDraft {
        if let draft = drafts[tool.name] { return draft }
        let schema = ToolSchema(inputSchema: tool.inputSchema)
        let values = schema.initialValues
        let json: String
        if case let .success(arguments) = schema.arguments(from: values) {
            json = JSONValue.object(arguments).jsonString(pretty: true)
        } else {
            json = "{}"
        }
        return ToolDraft(values: values, json: json)
    }

    func setValue(_ value: String, field: String, tool: MCPTool) {
        var draft = draft(for: tool)
        draft.values[field] = value
        draft.errors[field] = nil
        drafts[tool.name] = draft
    }

    func setJSON(_ text: String, tool: MCPTool) {
        var draft = draft(for: tool)
        draft.json = text
        draft.errors[""] = nil
        drafts[tool.name] = draft
    }

    /// Switching keeps what was typed: the form becomes JSON, and JSON fills the form.
    func setMode(_ mode: ArgumentMode, tool: MCPTool) {
        var draft = draft(for: tool)
        guard draft.mode != mode else { return }
        let schema = ToolSchema(inputSchema: tool.inputSchema)
        switch mode {
        case .json:
            switch schema.arguments(from: draft.values) {
            case let .success(arguments):
                var merged = arguments
                if case let .success(previous) = ToolSchema.arguments(fromJSON: draft.json) {
                    for name in schema.unknownNames(in: previous) { merged[name] = previous[name] }
                }
                draft.json = JSONValue.object(merged).jsonString(pretty: true)
                draft.errors = [:]
            case let .failure(errors):
                draft.errors = errors.messages
                drafts[tool.name] = draft
                return
            }
        case .form:
            switch ToolSchema.arguments(fromJSON: draft.json) {
            case let .success(arguments):
                draft.values = schema.values(from: arguments)
                draft.extraNames = schema.unknownNames(in: arguments)
                draft.errors = [:]
            case let .failure(errors):
                draft.errors = errors.messages
                drafts[tool.name] = draft
                return
            }
        }
        draft.mode = mode
        drafts[tool.name] = draft
    }

    func runSelectedTool() {
        guard let tool = selectedTool, activeCall == nil, let session, isConnected else { return }
        var draft = draft(for: tool)
        let schema = ToolSchema(inputSchema: tool.inputSchema)
        let parsed = draft.mode == .form ? schema.arguments(from: draft.values) : ToolSchema.arguments(fromJSON: draft.json)
        let arguments: [String: JSONValue]
        switch parsed {
        case let .success(value):
            arguments = value
            draft.errors = [:]
            drafts[tool.name] = draft
        case let .failure(errors):
            draft.errors = errors.messages
            drafts[tool.name] = draft
            return
        }

        let callID = UUID()
        let started = Date()
        let clock = ContinuousClock()
        let start = clock.now
        let name = tool.name
        let task = Task { [weak self] in
            let outcome: CallRecord.Outcome
            do {
                let result = try await session.callTool(name: name, arguments: arguments) { progress in
                    Task { @MainActor in self?.updateProgress(progress, call: callID) }
                }
                outcome = .result(result)
            } catch {
                outcome = .failure(HelpfulError(error))
            }
            self?.finishCall(CallRecord(id: callID, toolName: name, arguments: arguments, started: started,
                                        duration: clock.now - start, outcome: outcome))
        }
        activeCall = ActiveCall(id: callID, toolName: name, started: started, progress: nil, task: task)
    }

    func cancelCall() {
        activeCall?.task.cancel()
    }

    private func updateProgress(_ progress: MCPProgress, call: UUID) {
        guard activeCall?.id == call else { return }
        activeCall?.progress = progress
    }

    private func finishCall(_ record: CallRecord) {
        if activeCall?.id == record.id { activeCall = nil }
        history.insert(record, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        shownCallID = record.id
    }

    var shownCall: CallRecord? {
        guard let shownCallID else { return nil }
        return history.first { $0.id == shownCallID && $0.toolName == selectedToolName }
    }

    func history(for toolName: String) -> [CallRecord] {
        history.filter { $0.toolName == toolName }
    }

    /// Shows the call's result and puts its arguments back in the editor.
    func restore(_ record: CallRecord) {
        selectedToolName = record.toolName
        shownCallID = record.id
        guard let tool = tools.first(where: { $0.name == record.toolName }) else { return }
        let schema = ToolSchema(inputSchema: tool.inputSchema)
        var draft = draft(for: tool)
        draft.values = schema.values(from: record.arguments)
        draft.json = record.argumentsJSON
        draft.extraNames = schema.unknownNames(in: record.arguments)
        draft.errors = [:]
        if !draft.extraNames.isEmpty { draft.mode = .json }
        drafts[tool.name] = draft
    }

    // MARK: Resources and prompts

    func readResource(_ uri: String) {
        guard let session else { return }
        selectedResourceURI = uri
        resourceRead = .loading
        Task {
            do {
                let contents = try await session.readResource(uri: uri)
                guard selectedResourceURI == uri else { return }
                resourceRead = .loaded(contents)
            } catch {
                guard selectedResourceURI == uri else { return }
                resourceRead = .failed(HelpfulError(error))
            }
        }
    }

    func selectResource(_ uri: String) {
        guard selectedResourceURI != uri else { return }
        selectedResourceURI = uri
        resourceRead = .idle
    }

    func selectPrompt(_ name: String) {
        guard selectedPromptName != name else { return }
        selectedPromptName = name
        promptResult = .idle
    }

    func promptValue(_ prompt: String, _ argument: String) -> String {
        promptArguments[prompt]?[argument] ?? ""
    }

    func setPromptValue(_ value: String, prompt: String, argument: String) {
        promptArguments[prompt, default: [:]][argument] = value
    }

    func missingPromptArguments(_ prompt: MCPPrompt) -> [String] {
        prompt.arguments.filter { $0.required && promptValue(prompt.name, $0.name).isEmpty }.map(\.name)
    }

    func getPrompt(_ prompt: MCPPrompt) {
        guard let session, missingPromptArguments(prompt).isEmpty else { return }
        let arguments = (promptArguments[prompt.name] ?? [:]).filter { !$0.value.isEmpty }
        promptResult = .loading
        Task {
            do {
                let result = try await session.getPrompt(name: prompt.name, arguments: arguments)
                guard selectedPromptName == prompt.name else { return }
                promptResult = .loaded(result)
            } catch {
                guard selectedPromptName == prompt.name else { return }
                promptResult = .failed(HelpfulError(error))
            }
        }
    }

    // MARK: Ping

    func ping() {
        guard let session else { return }
        pingResult = .loading
        Task {
            do {
                pingResult = .loaded(try await session.ping())
            } catch {
                pingResult = .failed(HelpfulError(error))
            }
        }
    }

    // MARK: Logs

    private func logFile() -> MCPLogFile {
        if let log { return log }
        let buffer = logBuffer
        let file = MCPLogFile(url: logURL) { [weak self] entry in
            guard buffer.append(entry) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self?.drainLogs() }
            }
        }
        log = file
        return file
    }

    private func drainLogs() {
        let batch = logBuffer.take()
        guard !batch.isEmpty else { return }
        logEntries.append(contentsOf: batch)
        if logEntries.count > Self.logLimit { logEntries.removeFirst(logEntries.count - Self.logLimit) }
    }

    private func loadLogTail() {
        let url = logURL
        Task {
            let tail = await Task.detached(priority: .utility) { MCPLogFile.readTail(url: url, limit: 500) }.value
            guard !tail.isEmpty else { return }
            logEntries.insert(contentsOf: tail, at: 0)
            if logEntries.count > Self.logLimit { logEntries.removeFirst(logEntries.count - Self.logLimit) }
        }
    }

    func clearLogs() {
        log?.flush()
        do {
            try MCPLogFile.clear(url: logURL)
            _ = logBuffer.take()
            logEntries = []
            logError = nil
        } catch {
            logError = "Couldn't clear the log: \(AppModel.message(error))"
        }
    }

    static func logText(_ entries: [MCPLogEntry]) -> String {
        entries.map { entry in
            var line = "\(logTimeFormatter.string(from: entry.time)) [\(entry.kind.rawValue)] \(entry.summary)"
            if let detail = entry.detail, !detail.isEmpty { line += "\n    " + detail }
            return line
        }.joined(separator: "\n")
    }

    static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: Variables

    var variablesDirty: Bool {
        meaningful(variableRows) != meaningful(savedVariableRows)
    }

    private func meaningful(_ rows: [KeyValueRow]) -> [KeyValueRow] {
        rows.filter { !$0.isBlank }
    }

    var variableIssues: [UUID: String] {
        KeyValueRow.issues(variableRows, keyCheck: KeyValueRow.isEnvName,
                           invalidMessage: "Use letters, digits and _, not starting with a digit.")
    }

    private func loadVariables() {
        do {
            let stored = try variableStore.variables(for: key)
            savedVariableRows = stored.map { KeyValueRow(id: $0.id, key: $0.name, value: $0.value) }
            variableRows = savedVariableRows
            variablesError = nil
        } catch {
            variablesError = "Couldn't read saved variables: \(AppModel.message(error))"
        }
    }

    func saveVariables() {
        guard variableIssues.isEmpty else { return }
        let rows = meaningful(variableRows)
        let variables = rows.map { ClientVariable(id: $0.id, name: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value) }
        do {
            try variableStore.setVariables(variables, for: key)
            savedVariableRows = rows
            variableRows = rows
            variablesError = nil
        } catch {
            variablesError = "Couldn't save variables: \(AppModel.message(error))"
        }
    }

    func revertVariables() {
        variableRows = savedVariableRows
    }

    func addVariableRows(named names: [String]) {
        for name in names where !variableRows.contains(where: { $0.key == name }) {
            variableRows.append(KeyValueRow(key: name, value: ""))
        }
    }

    /// Names the config needs that neither the shell nor this server's variables provide. The
    /// config's own env doesn't count: `${VAR}` expands from the shell, as in Claude Code, so
    /// `"GITHUB_TOKEN": "${GITHUB_TOKEN}"` still needs GITHUB_TOKEN from somewhere else.
    func missingVariables(shell: ShellEnvironment?) -> [String] {
        var provided = Set(variableRows.map { $0.key.trimmingCharacters(in: .whitespaces) })
        if let shell { provided.formUnion(shell.variables.keys) }
        var seen = Set<String>()
        return VariableExpansion.requiredNames(in: target.config).filter { !provided.contains($0) && seen.insert($0).inserted }
    }

    /// What connecting would launch or call right now, or why it can't.
    func previewLaunch(shell: ShellEnvironment) -> LaunchPreview {
        let variables = meaningful(variableRows).map { ClientVariable(id: $0.id, name: $0.trimmedKey, value: $0.value) }
        do {
            return .ready(try LaunchResolver.resolve(target, shell: shell, variables: variables,
                                                     homeDirectory: paths.home.path).displayName)
        } catch {
            return .blocked(HelpfulError(error))
        }
    }
}

func formatDuration(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1e15
    if milliseconds < 1 { return "under 1 ms" }
    if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
    return String(format: "%.2f s", milliseconds / 1000)
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}
