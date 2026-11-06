import SwiftUI

struct ServerEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case stdio, http, sse
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stdio: return "stdio"
            case .http: return "HTTP"
            case .sse: return "SSE"
            }
        }
    }

    @State private var name = ""
    @State private var kind: Kind = .stdio
    @State private var command = ""
    @State private var argsText = ""
    @State private var envRows: [KeyValueRow] = []
    @State private var url = ""
    @State private var headerRows: [KeyValueRow] = []
    @State private var bearerEnvVar = ""
    @State private var toClaude = true
    @State private var toCodex = true

    @State private var nameTouched = false
    @State private var submitError: String?
    @State private var submitting = false

    /// A project MCP being edited in its own file.
    let editing: MCPEntry?
    /// A global MCP being edited in every client that has it.
    let editingGlobal: GlobalServer?

    /// With neither `editing` nor `editingGlobal`, the sheet adds a global MCP.
    init(editing: MCPEntry? = nil, editingGlobal: GlobalServer? = nil) {
        self.editing = editing
        self.editingGlobal = editingGlobal
        if let entry = editing {
            prefill(name: entry.name, config: entry.config)
        } else if let server = editingGlobal, let config = server.primaryConfig {
            prefill(name: server.name, config: config)
        }
    }

    private mutating func prefill(name: String, config: MCPServerConfig) {
        _name = State(initialValue: name)
        _bearerEnvVar = State(initialValue: config.bearerTokenEnvVar ?? "")
        switch config.transport {
        case let .stdio(command, args, env):
            _kind = State(initialValue: .stdio)
            _command = State(initialValue: command)
            _argsText = State(initialValue: args.joined(separator: "\n"))
            _envRows = State(initialValue: KeyValueRow.rows(env))
        case let .http(url, headers), let .sse(url, headers):
            if case .sse = config.transport { _kind = State(initialValue: .sse) } else { _kind = State(initialValue: .http) }
            _url = State(initialValue: url)
            _headerRows = State(initialValue: KeyValueRow.rows(headers))
        }
    }

    private var isEditing: Bool { editing != nil || editingGlobal != nil }

    /// Codex has no SSE transport, so a server Codex holds can't switch to it.
    private var kinds: [Kind] {
        editing?.client == .codex || editingGlobal?.codex != nil ? [.stdio, .http] : Kind.allCases
    }

    private var targets: Set<MCPClient> {
        var set: Set<MCPClient> = []
        if toClaude { set.insert(.claude) }
        if toCodex, kind != .sse { set.insert(.codex) }
        return set
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
            }
            .padding(16)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    transportPicker
                    if kind == .stdio { stdioFields } else { remoteFields }
                    if !isEditing { targetToggles }
                    if let submitError {
                        Banner(title: isEditing ? "Couldn't save" : "Couldn't add", message: submitError, tone: .red)
                    }
                }
                .padding(16)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.orc(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? (isEditing ? "Saving…" : "Adding…") : primaryLabel) { submit() }
                    .buttonStyle(.orc(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(16)
            .background(Theme.panel)
        }
        .frame(width: 540)
        .frame(minHeight: 620)
        .background(Theme.bg)
    }

    // MARK: Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Name")
            OrcTextField(label: "Name", placeholder: "linear", text: $name, mono: true,
                         invalid: nameTouched && nameIssue != nil)
                .onChange(of: name) { nameTouched = true }
            if nameTouched, let nameIssue {
                FieldMessage(text: nameIssue)
            } else {
                FieldMessage(text: editing == nil ? "Letters, digits, - or _. Used as the key in both configs."
                                                  : "Letters, digits, - or _. Used as the key in this file.", tone: .neutral)
            }
        }
    }

    private var transportPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Transport")
            Picker("Transport", selection: $kind) {
                ForEach(kinds) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Command")
                OrcTextField(label: "Command", placeholder: "npx", text: $command, mono: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Arguments")
                OrcTextEditor(label: "Arguments, one per line", placeholder: "-y\n@acme/mcp-server", text: $argsText)
                FieldMessage(text: "One argument per line.", tone: .neutral)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Environment")
                KeyValueEditor(rows: $envRows, keyLabel: "Variable name", keyPlaceholder: "API_KEY",
                               valuePlaceholder: "value", addLabel: "Add variable", issues: envIssues)
            }
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("URL")
                OrcTextField(label: "URL", placeholder: "https://mcp.example.com/mcp", text: $url, mono: true,
                             invalid: urlIssue != nil && !url.isEmpty)
                if let urlIssue, !url.isEmpty { FieldMessage(text: urlIssue) }
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Headers")
                KeyValueEditor(rows: $headerRows, keyLabel: "Header name", keyPlaceholder: "X-Team",
                               valuePlaceholder: "value", addLabel: "Add header", issues: headerIssues)
            }
            if kind == .http {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Bearer token env var (optional)")
                    OrcTextField(label: "Bearer token environment variable", placeholder: "LINEAR_API_KEY",
                                 text: $bearerEnvVar, mono: true, invalid: bearerIssue != nil)
                    FieldMessage(
                        text: bearerIssue ?? "Codex reads the token from this variable; Claude gets an Authorization: Bearer header.",
                        tone: bearerIssue == nil ? .neutral : .red
                    )
                }
            }
        }
    }

    private var targetToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Add to")
            HStack(spacing: 16) {
                Toggle("Claude", isOn: $toClaude)
                Toggle("Codex", isOn: Binding(get: { toCodex && kind != .sse }, set: { toCodex = $0 }))
                    .disabled(kind == .sse)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.text)
            if kind == .sse {
                FieldMessage(text: "Codex has no SSE transport, so this MCP is added to Claude only.", tone: .gate)
            } else if targets.count == 1 {
                FieldMessage(text: "Only \(clientList(targets)) gets this MCP. It will show as “\(clientList(targets)) only”.", tone: .gate)
            } else if targets.isEmpty {
                FieldMessage(text: "Pick at least one client.")
            }
        }
    }

    // MARK: Validation

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameIssue: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        if let message = MCPManager.validateName(trimmedName) { return message }
        if let entry = editing {
            let taken = model.projectEntries.contains {
                $0.name == trimmedName && $0.name != entry.name && $0.sourcePath == entry.sourcePath && $0.scope == entry.scope
            }
            return taken ? "This file already has an MCP called “\(trimmedName)”." : nil
        }
        if let existing = model.globals.first(where: { $0.name == trimmedName }), existing.name != editingGlobal?.name {
            return "\(clientList(existing.clients)) already \(existing.clients.count > 1 ? "have" : "has") an MCP called “\(trimmedName)”."
        }
        return nil
    }

    private var envIssues: [UUID: String] {
        KeyValueRow.issues(envRows, keyCheck: KeyValueRow.isEnvName,
                           invalidMessage: "use letters, digits and _, not starting with a digit.")
    }

    private var headerIssues: [UUID: String] {
        KeyValueRow.issues(headerRows, keyCheck: nil, invalidMessage: "")
    }

    private var envIssue: String? { envIssues.isEmpty ? nil : "Fix the environment variables above." }
    private var headersIssue: String? { headerIssues.isEmpty ? nil : "Fix the headers above." }

    private var urlIssue: String? {
        let value = url.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "Enter a URL." }
        guard let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parsed.host != nil
        else { return "Use a full http:// or https:// URL." }
        return nil
    }

    private var bearerIssue: String? {
        let value = bearerEnvVar.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || isEnvName(value) { return nil }
        return "Use an environment variable name like LINEAR_API_KEY."
    }

    private var transportIssue: String? {
        switch kind {
        case .stdio:
            if command.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a command." }
            return envIssue
        case .http:
            return urlIssue ?? headersIssue ?? bearerIssue
        case .sse:
            return urlIssue ?? headersIssue
        }
    }

    private var canSubmit: Bool {
        !submitting && nameIssue == nil && transportIssue == nil && (isEditing || !targets.isEmpty)
    }

    private var title: String {
        if let name = editing?.name ?? editingGlobal?.name { return "Edit \(name)" }
        return "Add MCP"
    }

    private var subtitle: String {
        if let entry = editing {
            return "Saved to \(abbreviate(URL(fileURLWithPath: entry.sourcePath))) · \(entry.scope.label)"
        }
        if let server = editingGlobal {
            let files = server.clients.map { abbreviate($0 == .claude ? model.paths.claudeJSON : model.paths.codexTOML) }
            return "Saved to \(files.joined(separator: " and ")). Settings MCP Manager doesn't show are kept."
        }
        return "Written to Claude and Codex together, so both CLIs see the same server."
    }

    private var primaryLabel: String {
        if isEditing { return "Save" }
        switch (targets.contains(.claude), targets.contains(.codex)) {
        case (true, true): return "Add to Claude & Codex"
        case (true, false): return "Add to Claude"
        case (false, true): return "Add to Codex"
        case (false, false): return "Add"
        }
    }

    private func isEnvName(_ value: String) -> Bool {
        KeyValueRow.isEnvName(value)
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func buildConfig() -> MCPServerConfig {
        let headers = KeyValueRow.pairs(headerRows)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .stdio:
            let env = KeyValueRow.pairs(envRows)
            return MCPServerConfig(transport: .stdio(command: command.trimmingCharacters(in: .whitespaces),
                                                     args: lines(argsText), env: env))
        case .http:
            let bearer = bearerEnvVar.trimmingCharacters(in: .whitespaces)
            return MCPServerConfig(transport: .http(url: trimmedURL, headers: headers),
                                   bearerTokenEnvVar: bearer.isEmpty ? nil : bearer)
        case .sse:
            return MCPServerConfig(transport: .sse(url: trimmedURL, headers: headers))
        }
    }

    private func submit() {
        nameTouched = true
        guard canSubmit else { return }
        submitting = true
        submitError = nil
        let name = trimmedName
        var config = buildConfig()
        let targets = self.targets
        let editing = self.editing
        let editingGlobal = self.editingGlobal
        Task {
            do {
                if let server = editingGlobal {
                    try await model.updateGlobal(server.name, to: name, config: config)
                } else if let entry = editing {
                    // The sheet has no enabled toggle; keep whatever the file had.
                    config.enabled = entry.config.enabled
                    try await model.updateProjectEntry(entry, name: name, config: config)
                } else {
                    try await model.add(name: name, config: config, to: targets)
                }
                dismiss()
            } catch {
                submitError = AppModel.message(error)
            }
            submitting = false
        }
    }
}
