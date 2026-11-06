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
    @State private var envText = ""
    @State private var url = ""
    @State private var headersText = ""
    @State private var bearerEnvVar = ""
    @State private var toClaude = true
    @State private var toCodex = true

    @State private var nameTouched = false
    @State private var submitError: String?
    @State private var submitting = false

    private var targets: Set<MCPClient> {
        var set: Set<MCPClient> = []
        if toClaude { set.insert(.claude) }
        if toCodex, kind != .sse { set.insert(.codex) }
        return set
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add MCP")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text("Written to Claude and Codex together, so both CLIs see the same server.")
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
                    targetToggles
                    if let submitError {
                        Banner(title: "Couldn't add", message: submitError, tone: .red)
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
                Button(submitting ? "Adding…" : primaryLabel) { submit() }
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
                FieldMessage(text: "Letters, digits, - or _. Used as the key in both configs.", tone: .neutral)
            }
        }
    }

    private var transportPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Transport")
            Picker("Transport", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
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
                OrcTextEditor(label: "Environment variables, KEY=value per line", placeholder: "API_KEY=…",
                              text: $envText, invalid: envIssue != nil)
                FieldMessage(text: envIssue ?? "KEY=value, one per line.", tone: envIssue == nil ? .neutral : .red)
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
                OrcTextEditor(label: "Headers, Name: value per line", placeholder: "X-Team: platform",
                              text: $headersText, invalid: headersIssue != nil)
                FieldMessage(text: headersIssue ?? "Name: value, one per line.", tone: headersIssue == nil ? .neutral : .red)
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
        if let existing = model.globals.first(where: { $0.name == trimmedName }) {
            return "\(clientList(existing.clients)) already \(existing.clients.count > 1 ? "have" : "has") an MCP called “\(trimmedName)”."
        }
        return nil
    }

    private var envIssue: String? { parsePairs(envText, separator: "=", what: "KEY=value", keyCheck: isEnvName).issue }
    private var headersIssue: String? { parsePairs(headersText, separator: ":", what: "Name: value", keyCheck: nil).issue }

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
        !submitting && nameIssue == nil && transportIssue == nil && !targets.isEmpty
    }

    private var primaryLabel: String {
        switch (targets.contains(.claude), targets.contains(.codex)) {
        case (true, true): return "Add to Claude & Codex"
        case (true, false): return "Add to Claude"
        case (false, true): return "Add to Codex"
        case (false, false): return "Add"
        }
    }

    private func isEnvName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func parsePairs(_ text: String, separator: Character, what: String,
                            keyCheck: ((String) -> Bool)?) -> (pairs: [String: String], issue: String?) {
        var pairs: [String: String] = [:]
        for (index, line) in lines(text).enumerated() {
            guard let split = line.firstIndex(of: separator) else {
                return ([:], "Line \(index + 1) needs \(what).")
            }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || keyCheck?(key) == false {
                return ([:], "Line \(index + 1): “\(key)” is not a valid name.")
            }
            pairs[key] = value
        }
        return (pairs, nil)
    }

    private func buildConfig() -> MCPServerConfig {
        let headers = parsePairs(headersText, separator: ":", what: "", keyCheck: nil).pairs
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .stdio:
            let env = parsePairs(envText, separator: "=", what: "", keyCheck: isEnvName).pairs
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
        let config = buildConfig()
        let targets = self.targets
        Task {
            do {
                try await model.add(name: name, config: config, to: targets)
                dismiss()
            } catch {
                submitError = AppModel.message(error)
            }
            submitting = false
        }
    }
}
