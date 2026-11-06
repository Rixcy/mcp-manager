import SwiftUI

struct GlobalServersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renaming: GlobalServer?
    @State private var editing: GlobalServer?
    @State private var removing: GlobalServer?

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
        .sheet(item: $renaming) { server in
            RenameSheet(server: server)
                .environmentObject(model)
        }
        .sheet(item: $editing) { server in
            ServerEditorSheet(editingGlobal: server)
                .environmentObject(model)
        }
        .confirmationDialog(
            removing.map { "Remove “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { server in
            removeButtons(for: server)
        } message: { server in
            Text(removeMessage(for: server))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Global MCPs")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text("Shared by Claude and Codex")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
                Text("\(abbreviate(model.paths.claudeJSON))  ·  \(abbreviate(model.paths.codexTOML))")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.mutedStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Add MCP") { model.isAddingServer = true }
                .buttonStyle(.orc(.primary))
                .keyboardShortcut("n", modifiers: .command)
                .help("Add an MCP to Claude and Codex (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            FieldMessage(text: "Loading global MCPs…", tone: .neutral)
        } else if let error = model.loadError {
            Banner(title: "Can't read configs", message: error, tone: .red)
        } else if model.globals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No global MCPs yet")
                    .font(Theme.title)
                    .foregroundStyle(Theme.heading)
                Text("Anything you add here goes into Claude and Codex at the same time.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                Button("Add MCP") { model.isAddingServer = true }
                    .buttonStyle(.orc(.primary))
            }
            .orcPanel(padding: 16)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.globals.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Hairline() }
                    GlobalServerRow(server: server, onEdit: { editing = server }, onRename: { renaming = server },
                                    onRemove: { removing = server })
                }
            }
            .orcPanel()
            Text("A timestamped backup of each config is kept in \(abbreviate(model.paths.backupDir)) before every change.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedStrong)
        }
    }

    @ViewBuilder
    private func removeButtons(for server: GlobalServer) -> some View {
        if server.clients.count > 1 {
            Button("Remove from \(clientList(server.clients))", role: .destructive) {
                Task { await model.remove(server.name, from: Set(server.clients)) }
            }
            ForEach(server.clients) { client in
                Button("Remove from \(client.displayName) only") {
                    Task { await model.remove(server.name, from: [client]) }
                }
            }
        } else {
            Button("Remove from \(clientList(server.clients))", role: .destructive) {
                Task { await model.remove(server.name, from: Set(server.clients)) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func removeMessage(for server: GlobalServer) -> String {
        let files = server.clients.map { client in
            "\(client.displayName) (\(abbreviate(client == .claude ? model.paths.claudeJSON : model.paths.codexTOML)))"
        }
        return "This removes “\(server.name)” from \(files.joined(separator: " and ")). "
            + "A backup of each file is kept in \(abbreviate(model.paths.backupDir))."
    }
}

private struct GlobalServerRow: View {
    @EnvironmentObject private var model: AppModel
    let server: GlobalServer
    let onEdit: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    private var target: MCPServerTarget? { MCPServerTarget.global(server) }

    private func open() {
        if let target { model.inspect(target) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.heading)
                        .textSelection(.enabled)
                    if let kind = server.primaryConfig?.transport.kindLabel {
                        Chip(text: kind)
                    }
                    if let key = target?.key, let inspector = model.inspector(forKey: key) {
                        InspectorStatusChip(inspector: inspector)
                    }
                }
                if let config = server.primaryConfig {
                    Text(config.transport.summary)
                        .font(Theme.mono())
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(config.transport.summary)
                }
                ClientChips(server: server)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if case let .onlyIn(_, syncable) = availability(of: server), syncable {
                    Button("Sync to \(clientList(server.missingClients))") {
                        Task { await model.sync(server.name) }
                    }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .help("Copy \(server.name) into \(clientList(server.missingClients))")
                    .disabled(model.isWriting)
                }
                Button("Open", action: open)
                    .buttonStyle(.orc(.secondary, compact: true))
                    .disabled(target == nil)
                    .help("Open \(server.name) to connect, run its tools and read its logs")
                Button("Edit…", action: onEdit)
                    .buttonStyle(.orc(.secondary, compact: true))
                    .disabled(model.isWriting)
                Button("Remove…", action: onRemove)
                    .buttonStyle(.orc(.destructive, compact: true))
                    .disabled(model.isWriting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Open", action: open)
            Button("Edit…", action: onEdit)
            Button("Rename…", action: onRename)
            if case let .onlyIn(_, syncable) = availability(of: server), syncable {
                Button("Sync to \(clientList(server.missingClients))") { Task { await model.sync(server.name) } }
            }
            Divider()
            Button("Remove…", role: .destructive, action: onRemove)
        }
    }
}
