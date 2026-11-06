import SwiftUI

struct ProjectRow: View {
    let project: ProjectRef

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.heading)
                .lineLimit(1)
            Text(project.displayPath)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedStrong)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    let project: ProjectRef

    private struct SourceGroup: Identifiable {
        let label: String
        let sourcePath: String
        var entries: [MCPEntry]
        var id: String { label + "|" + sourcePath }
    }

    private var groups: [SourceGroup] {
        var groups: [SourceGroup] = []
        for entry in model.projectEntries {
            if let index = groups.firstIndex(where: { $0.label == entry.scope.label && $0.sourcePath == entry.sourcePath }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(SourceGroup(label: entry.scope.label, sourcePath: entry.sourcePath, entries: [entry]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text(project.displayPath)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.mutedStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(project.path)
            }
            Spacer()
            Chip(text: "Read-only")
                .help("Project MCPs are listed for reference. Edit them in the project's own config files.")
            Button("Reveal in Finder") { revealInFinder(project.path) }
                .buttonStyle(.orc(.secondary, compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.projectError {
            Banner(title: "Can't read project MCPs", message: error, tone: .red)
        } else if model.isLoadingProject, model.projectEntries.isEmpty {
            FieldMessage(text: "Loading MCPs for \(project.name)…", tone: .neutral)
        } else if model.projectEntries.isEmpty {
            emptyState
        } else {
            ForEach(groups) { group in
                groupPanel(group)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No MCPs configured for \(project.name)")
                .font(Theme.title)
                .foregroundStyle(Theme.heading)
            Text("Checked these files:")
                .font(Theme.body)
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(checkedFiles, id: \.self) { file in
                    Text(file)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.code))
            Text("Global MCPs still apply here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedStrong)
        }
        .orcPanel(padding: 16)
    }

    private var checkedFiles: [String] {
        let dir = project.displayPath
        return [
            "\(abbreviate(model.paths.claudeJSON))  →  projects[\"\(dir)\"].mcpServers",
            "\(dir)/.mcp.json",
            "\(dir)/.codex/config.toml",
        ]
    }

    private func groupPanel(_ group: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                        Chip(text: group.entries.count == 1 ? "1 MCP" : "\(group.entries.count) MCPs")
                    }
                    Text((group.sourcePath as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.mutedStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                IconButton(systemImage: "folder", label: "Reveal \(group.sourcePath) in Finder") {
                    revealInFinder(group.sourcePath)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ForEach(group.entries) { entry in
                Hairline()
                ProjectEntryRow(entry: entry)
            }
        }
        .orcPanel()
    }
}

private struct ProjectEntryRow: View {
    let entry: MCPEntry

    private var detailKeys: String? {
        switch entry.config.transport {
        case let .stdio(_, _, env) where !env.isEmpty:
            return "env: " + env.keys.sorted().joined(separator: ", ")
        case let .http(_, headers) where !headers.isEmpty, let .sse(_, headers) where !headers.isEmpty:
            return "headers: " + headers.keys.sorted().joined(separator: ", ")
        default:
            return entry.config.bearerTokenEnvVar.map { "bearer token: $\($0)" }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                    .textSelection(.enabled)
                Chip(text: entry.client.displayName)
                Chip(text: entry.config.transport.kindLabel)
                if !entry.config.enabled {
                    Chip(text: "Disabled", tone: .yellow)
                }
            }
            Text(entry.config.transport.summary)
                .font(Theme.mono())
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(entry.config.transport.summary)
            if let detailKeys {
                Text(detailKeys)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.mutedStrong)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
