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
        return List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Theme.mutedStrong)
                        .accessibilityHidden(true)
                    Text("Claude & Codex")
                        .foregroundStyle(Theme.heading)
                    Spacer()
                    if model.hasLoaded, model.loadError == nil {
                        Chip(text: "\(model.globals.count)")
                            .accessibilityLabel("\(model.globals.count) global MCPs")
                    }
                }
                .sidebarRow(.globals, selection: $model.route)
            } header: {
                SectionLabel("Global MCPs")
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
                    ProjectRow(project: project)
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
