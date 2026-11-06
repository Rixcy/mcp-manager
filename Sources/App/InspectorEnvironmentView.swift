import SwiftUI

struct InspectorEnvironmentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                variablesPanel
                configPanel
                shellPanel
                launchPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { _ = await model.shellEnvironment() }
    }

    // MARK: Variables for this server

    private var variablesPanel: some View {
        let missing = inspector.missingVariables(shell: model.shell)
        let issues = inspector.variableIssues
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Variables for this server")
            Text("Applied only when MCP Manager connects to \(inspector.target.name). They are never written to Claude or Codex config.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedStrong)
                .fixedSize(horizontal: false, vertical: true)
            if !missing.isEmpty {
                missingWarning(missing)
            }
            KeyValueEditor(rows: $inspector.variableRows, keyLabel: "Variable name", keyPlaceholder: "API_KEY",
                           valuePlaceholder: "value", addLabel: "Add variable", issues: issues)
            if let error = inspector.variablesError {
                FieldMessage(text: error)
            }
            HStack(spacing: 8) {
                Button("Save") { inspector.saveVariables() }
                    .buttonStyle(.orc(.primary, compact: true))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!inspector.variablesDirty || !issues.isEmpty)
                    .help("Save variables (⌘S)")
                if inspector.variablesDirty {
                    Button("Revert") { inspector.revertVariables() }
                        .buttonStyle(.orc(.secondary, compact: true))
                    FieldMessage(text: inspector.isConnected ? "Unsaved changes. Saved variables apply on the next connect."
                                                             : "Unsaved changes.",
                                 tone: .gate)
                }
            }
        }
        .orcPanel(padding: 14)
    }

    private func missingWarning(_ missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Banner(title: "Missing",
                   message: "The config uses \(missing.joined(separator: ", ")), which your shell does not set. Add a value here or export it in your shell profile.",
                   tone: .yellow)
            Button(missing.count == 1 ? "Add \(missing[0])" : "Add all \(missing.count)") {
                inspector.addVariableRows(named: missing)
            }
            .buttonStyle(.orc(.secondary, compact: true))
        }
    }

    // MARK: From the config

    @ViewBuilder
    private var configPanel: some View {
        let config = inspector.target.config
        VStack(alignment: .leading, spacing: 8) {
            switch config.transport {
            case let .stdio(_, _, env):
                SectionLabel("Environment from the config")
                hiddenNames(env.keys.sorted(), empty: "The config sets no environment variables.")
            case let .http(_, headers), let .sse(_, headers):
                SectionLabel("Headers from the config")
                hiddenNames(headers.keys.sorted(), empty: "The config sets no headers.")
                if let bearer = config.bearerTokenEnvVar {
                    HStack(spacing: 6) {
                        Text("Bearer token from")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                        Text("$\(bearer)")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.heading)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("Values are hidden here. Edit them in the server's config.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedStrong)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }

    @ViewBuilder
    private func hiddenNames(_ names: [String], empty: String) -> some View {
        if names.isEmpty {
            FieldMessage(text: empty, tone: .neutral)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(name)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.heading)
                            .textSelection(.enabled)
                        Text("= ••••••")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.mutedStrong)
                            .accessibilityLabel("value hidden")
                    }
                }
            }
        }
    }

    // MARK: From your shell

    private var shellPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("From your shell")
                Spacer()
                Button(model.isResolvingShell ? "Reading…" : "Reload") { model.reloadShellEnvironment() }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .disabled(model.isResolvingShell)
                    .help("Read your login shell's environment again, for example after editing your shell profile")
            }
            if let shell = model.shell {
                Text(sourceText(shell.source))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("PATH")
                    .font(Theme.label)
                    .foregroundStyle(Theme.mutedStrong)
                CodeBlock(text: (shell.variables["PATH"] ?? "(not set)").split(separator: ":").joined(separator: "\n"),
                          copyLabel: nil)
            } else {
                FieldMessage(text: "Reading your login shell's environment…", tone: .neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }

    private func sourceText(_ source: ShellEnvironment.Source) -> String {
        switch source {
        case let .loginShell(shell):
            return "Read from your login shell, \(shell). Servers start with these variables, as they would in a terminal."
        case let .fallback(reason):
            return "Couldn't read your login shell (\(reason)). Using MCP Manager's own environment plus common tool folders."
        }
    }

    // MARK: Resolved launch

    private var launchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(inspector.isRemote ? "Resolved URL" : "Resolved command line")
            if let shell = model.shell {
                switch inspector.previewLaunch(shell: shell) {
                case let .ready(display):
                    CodeBlock(text: display)
                case let .blocked(error):
                    Banner(title: error.title, message: error.message, tone: .yellow)
                }
            } else {
                FieldMessage(text: "Shown once your shell environment is read.", tone: .neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }
}
