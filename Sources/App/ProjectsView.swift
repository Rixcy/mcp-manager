import SwiftUI

struct ProjectRow: View {
    let project: ProjectRef
    /// The parent folder tells apart projects with the same name; elsewhere it repeats.
    var showsFolder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.heading)
                .lineLimit(1)
            if showsFolder {
                Text((project.displayPath as NSString).deletingLastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(project.displayPath)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    let project: ProjectRef
    @State private var editing: MCPEntry?
    @State private var removing: MCPEntry?

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
                    if StatusBanners.hasContent(model) { StatusBanners() }
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editing) { entry in
            ServerEditorSheet(editing: entry)
                .environmentObject(model)
        }
        .confirmationDialog(
            removing.map { "Remove “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { entry in
            Button("Remove from \(fileName(entry))", role: .destructive) {
                Task { await model.removeProjectEntry(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(removeMessage(for: entry))
        }
    }

    private func fileName(_ entry: MCPEntry) -> String {
        (entry.sourcePath as NSString).lastPathComponent
    }

    private func removeMessage(for entry: MCPEntry) -> String {
        var message = "It comes out of \(fileName(entry))"
        if case .claudeLocal = entry.scope { message += " for \(project.name) only" }
        message += ". MCP Manager backs up the file first."
        if case .claudeProject = entry.scope {
            message += " .mcp.json is often committed to the repo, so teammates may see this change."
        }
        return message
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
            Text("MCP Manager looked in:")
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
        ["\(abbreviate(model.paths.claudeJSON)) (this project's entry)", ".mcp.json", ".codex/config.toml"]
    }

    private func groupPanel(_ group: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.heading)
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
            .padding(.vertical, 8)
            .background(Theme.heading.opacity(0.03))
            Hairline()
            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Hairline().padding(.leading, 54) }
                ProjectEntryRow(entry: entry, onEdit: { editing = entry }, onRemove: { removing = entry })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .orcPanel()
    }
}

private struct ProjectEntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: MCPEntry
    let onEdit: () -> Void
    let onRemove: () -> Void

    private func open() {
        model.inspect(.project(entry))
    }

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
        ServerListRow(name: entry.name, transport: entry.config.transport, detail: detailKeys, onOpen: open) {
            if !entry.config.enabled {
                Chip(text: "Disabled", tone: .yellow)
            }
            if let inspector = model.inspector(forKey: MCPServerTarget.project(entry).key) {
                InspectorStatusChip(inspector: inspector)
            }
        } accessory: {
            EmptyView()
        } menuItems: {
            Button("Edit…", action: onEdit)
                .disabled(model.isWriting)
            Divider()
            Button("Remove…", role: .destructive, action: onRemove)
                .disabled(model.isWriting)
        }
    }
}
