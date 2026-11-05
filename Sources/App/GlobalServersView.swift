import SwiftUI
import UniformTypeIdentifiers

struct GlobalServersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: GlobalServer?
    @State private var removing: GlobalServer?
    @State private var dragging: String?

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
                Text(model.globals.count > 1 ? "Every Claude and Codex session can use these. Drag to reorder." : "Every Claude and Codex session can use these.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
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
            EmptyStateView(title: "No global MCPs yet",
                           message: "Anything you add here goes into Claude and Codex at the same time.",
                           actionTitle: "Add MCP", action: { model.isAddingServer = true })
        } else {
            ServerList(items: model.globals) { server in
                GlobalServerRow(server: server, onEdit: { editing = server }, onRemove: { removing = server })
                    .opacity(dragging == server.name ? 0.4 : 1)
                    .onDrag {
                        dragging = server.name
                        return NSItemProvider(object: server.name as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(target: server.name, dragging: $dragging, model: model))
            }
            // A drop between rows or on the list's edge still ends the drag and keeps the new order.
            .onDrop(of: [.text], delegate: ReorderDropDelegate(target: nil, dragging: $dragging, model: model))
            filesNote
        }
    }

    private var filesNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Saved to \(abbreviate(model.paths.claudeJSON)) and \(abbreviate(model.paths.codexTOML)), with a backup before every change.")
                .foregroundStyle(Theme.mutedStrong)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(model.paths.claudeJSON.path)\n\(model.paths.codexTOML.path)")
            Button("Show Backups") { revealInFinder(model.paths.backupDir.path) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
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
            (client == .claude ? model.paths.claudeJSON : model.paths.codexTOML).lastPathComponent
        }
        return "It comes out of \(files.joined(separator: " and ")). MCP Manager backs up each file first."
    }
}

private struct GlobalServerRow: View {
    @EnvironmentObject private var model: AppModel
    let server: GlobalServer
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var target: MCPServerTarget? { MCPServerTarget.global(server) }

    private var canSync: Bool {
        if case let .onlyIn(_, syncable) = availability(of: server) { return syncable }
        return false
    }

    var body: some View {
        if let config = server.primaryConfig {
            ServerListRow(name: server.name, transport: config.transport, onOpen: open) {
                AvailabilityChips(server: server)
                if let key = target?.key, let inspector = model.inspector(forKey: key) {
                    InspectorStatusChip(inspector: inspector)
                }
            } accessory: {
                if canSync {
                    Button("Sync to \(clientList(server.missingClients))") {
                        Task { await model.sync(server.name) }
                    }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .help("Copy \(server.name) into \(clientList(server.missingClients))")
                    .disabled(model.isWriting)
                }
            } menuItems: {
                Button("Edit…", action: onEdit)
                    .disabled(model.isWriting)
                Divider()
                Button("Move Up") { model.moveGlobal(server.name, by: -1) }
                    .disabled(model.globals.first?.name == server.name)
                Button("Move Down") { model.moveGlobal(server.name, by: 1) }
                    .disabled(model.globals.last?.name == server.name)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
                    .disabled(model.isWriting)
            }
        }
    }

    private func open() {
        if let target { model.inspect(target) }
    }
}

/// Moves the dragged row as it passes over others, and saves the order on drop.
private struct ReorderDropDelegate: DropDelegate {
    /// The row under the pointer; nil for the list as a whole.
    let target: String?
    @Binding var dragging: String?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, let target, dragging != target else { return }
        withAnimation(.snappy(duration: 0.2)) {
            model.moveGlobal(dragging, onto: target, save: false)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragging == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragging != nil else { return false }
        dragging = nil
        model.saveGlobalOrder()
        return true
    }
}
