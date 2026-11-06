import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var matches: [ProjectRef] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : Array(model.rankedProjects(query).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            VStack(alignment: .leading, spacing: 10) {
                if StatusBanners.hasContent(model) { StatusBanners() }
                globalList
                projectSearch
            }
            .padding(12)
            Hairline()
            footer
        }
        .frame(width: 360)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 8) {
            OrcMark().frame(width: 22, height: 24)
            Text("MCP Manager")
                .font(Theme.title)
                .foregroundStyle(Theme.heading)
            Spacer()
            if model.hasLoaded, model.loadError == nil {
                Chip(text: model.globals.count == 1 ? "1 global MCP" : "\(model.globals.count) global MCPs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var globalList: some View {
        SectionLabel("Global MCPs")
        if !model.hasLoaded {
            FieldMessage(text: "Loading global MCPs…", tone: .neutral)
        } else if let error = model.loadError {
            Banner(title: "Can't read configs", message: error, tone: .red)
        } else if model.globals.isEmpty {
            FieldMessage(text: "No global MCPs yet. Add one to give Claude and Codex the same server.", tone: .neutral)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.globals.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Hairline().padding(.leading, 10) }
                        CompactServerRow(server: server) { openServer(server) }
                    }
                }
            }
            .frame(height: min(CGFloat(model.globals.count) * CompactServerRow.height, 300))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .orcPanel()
        }
    }

    @ViewBuilder
    private var projectSearch: some View {
        SectionLabel("Project MCPs")
        OrcTextField(label: "Find a project", placeholder: "Find a project, e.g. reels", text: $query)
            .onSubmit { if let first = matches.first { open(first) } }
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(matches) { project in
                    Button { open(project) } label: {
                        ProjectRow(project: project)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(HoverRowStyle())
                    .accessibilityHint("Opens this project's MCPs in the MCP Manager window")
                }
            }
            .orcPanel()
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            FieldMessage(text: "No project matches “\(query)”.", tone: .neutral)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Add MCP…") {
                model.route = .globals
                model.isAddingServer = true
                openWindow.mainWindow()
            }
            .buttonStyle(.orc(.primary, compact: true))
            Button("Open MCP Manager") { openWindow.mainWindow() }
                .buttonStyle(.orc(.secondary, compact: true))
                .keyboardShortcut(",", modifiers: .command)
                .help("Open MCP Manager (⌘,)")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.orc(.ghost, compact: true))
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit MCP Manager (⌘Q)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func openServer(_ server: GlobalServer) {
        guard let target = MCPServerTarget.global(server) else { return }
        model.inspect(target)
        openWindow.mainWindow()
    }

    private func open(_ project: ProjectRef) {
        model.open(project)
        query = ""
        openWindow.mainWindow()
    }
}

private struct CompactServerRow: View {
    /// A ScrollView in the menu bar window does not size to its content, so the list height is estimated from this.
    static let height: CGFloat = 50

    @EnvironmentObject private var model: AppModel
    let server: GlobalServer
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                            .lineLimit(1)
                        AvailabilityChips(server: server)
                    }
                    Text(server.primaryConfig?.transport.summary ?? "")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.mutedStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: Self.height)
            }
            .buttonStyle(HoverRowStyle())
            .accessibilityHint("Opens \(server.name) in the MCP Manager window")
            if case let .onlyIn(_, syncable) = availability(of: server), syncable {
                Button("Sync") { Task { await model.sync(server.name) } }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .disabled(model.isWriting)
                    .help("Copy \(server.name) into \(clientList(server.missingClients))")
                    .padding(.trailing, 10)
            }
        }
    }
}

/// Plain row button with the Orc hover tint (heading ink at 6%).
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.heading.opacity(configuration.isPressed ? 0.11 : (hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
