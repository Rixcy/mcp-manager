import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Preferences.newServerTransportKey) private var transport: ServerEditorSheet.Kind = .http

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Adding MCPs") { addingMCPs }
                    section("Files") { files }
                    section("About") { about }
                }
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text("How MCP Manager adds servers, and where it keeps its files.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .orcPanel()
        }
    }

    private var addingMCPs: some View {
        SettingRow(title: "Default transport",
                   detail: "New MCPs start on this. It follows whichever of the two you last added with.") {
            Picker("Default transport", selection: $transport) {
                ForEach([ServerEditorSheet.Kind.http, .stdio]) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var files: some View {
        fileRow("Claude config", model.paths.claudeJSON)
        Hairline().padding(.leading, 14)
        fileRow("Codex config", model.paths.codexTOML)
        Hairline().padding(.leading, 14)
        fileRow("Backups", model.paths.backupDir, detail: "A copy of each file is saved here before every change.")
        Hairline().padding(.leading, 14)
        fileRow("Logs", model.paths.logsDir, detail: "One log per server you connect to, with secrets scrubbed.")
    }

    private func fileRow(_ title: String, _ url: URL, detail: String? = nil) -> some View {
        SettingRow(title: title, detail: detail, path: abbreviate(url)) {
            Button("Show in Finder") { revealInFinder(url.path) }
                .buttonStyle(.orc(.secondary, compact: true))
                .help(url.path)
        }
    }

    private var about: some View {
        SettingRow(title: "Version", detail: "Run mcp-manager update in Terminal to get the latest.",
                   path: Self.sourceCommit ?? "Development build") {
            CopyButton(text: "mcp-manager update", label: "Copy Command")
        }
    }

    /// install.sh writes the commit it built into the bundle.
    private static let sourceCommit: String? = Bundle.main.url(forResource: "source-commit", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var path: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                if let path {
                    Text(path)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.mutedStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
