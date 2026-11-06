import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The detail toolbar holds no items, so the page header moves up
                // into its band instead of sitting below an empty strip.
                .ignoresSafeArea(.container, edges: .top)
                .background(Theme.bg.ignoresSafeArea())
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $model.isAddingServer) {
            ServerEditorSheet()
                .environmentObject(model)
        }
        .onAppear { model.scheduleRefresh(delay: .zero) }
    }

    private var sidebar: some View {
        let ranked = model.rankedProjects(query)
        let sharedNames = Dictionary(grouping: model.projects, by: \.name).filter { $0.value.count > 1 }.keys
        return List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundStyle(Theme.mutedStrong)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Global MCPs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.heading)
                    Spacer()
                    if model.hasLoaded, model.loadError == nil {
                        Text("\(model.globals.count)")
                            .font(Theme.label)
                            .monospacedDigit()
                            .foregroundStyle(Theme.mutedStrong)
                            .accessibilityLabel("\(model.globals.count) servers")
                    }
                }
                .padding(.vertical, 3)
                .sidebarRow(.globals, selection: $model.route)
            }

            if !model.inspectorOrder.isEmpty {
                Section {
                    ForEach(model.orderedInspectors) { inspector in
                        ConnectionRow(inspector: inspector)
                            .sidebarRow(.server(inspector.key), selection: $model.route)
                    }
                } header: {
                    SectionLabel("Connections")
                }
            }

            Section {
                OrcTextField(label: "Search projects", placeholder: "Search projects", text: $query)
                    .onSubmit { if let first = ranked.first { model.open(first) } }
                if model.hasLoaded, model.projects.isEmpty {
                    FieldMessage(text: "No projects found in Claude or Codex config.", tone: .neutral)
                } else if ranked.isEmpty {
                    FieldMessage(text: "No project matches “\(query)”.", tone: .neutral)
                }
                ForEach(ranked) { project in
                    ProjectRow(project: project, showsFolder: sharedNames.contains(project.name))
                        .padding(.vertical, 2)
                        .sidebarRow(.project(project.path), selection: $model.route)
                }
            } header: {
                HStack {
                    SectionLabel("Projects")
                    Spacer()
                    if model.hasLoaded {
                        Text(query.isEmpty ? "\(model.projects.count)" : "\(ranked.count) of \(model.projects.count)")
                            .font(Theme.label)
                            .foregroundStyle(Theme.mutedStrong)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                OrcMark().frame(width: 22, height: 24)
                Text("MCP Manager")
                    .font(Theme.title)
                    .foregroundStyle(Theme.heading)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.panel)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .project:
            if let project = model.selectedProject {
                ProjectDetailView(project: project)
            }
        case let .server(key):
            if let inspector = model.inspector(forKey: key) {
                InspectorView(inspector: inspector)
                    .id(key)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    EmptyStateView(title: "This server is no longer configured",
                                   message: "It was removed or renamed in its config file.",
                                   actionTitle: "Back to Global MCPs", action: { model.route = .globals })
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .globals, nil:
            GlobalServersView()
        }
    }
}

private extension View {
    /// Draws the selected row in Orc's neutral chip colour. A `List(selection:)`
    /// sidebar paints selection in the user's macOS accent colour instead.
    func sidebarRow(_ route: Route, selection: Binding<Route?>) -> some View {
        let isSelected = selection.wrappedValue == route
        return Button { selection.wrappedValue = route } label: {
            self.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.chip : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectionRow: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(inspector.target.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.heading)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Chip(text: inspector.statusText, tone: inspector.statusTone)
            }
            Text(inspector.target.locationLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedStrong)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}
