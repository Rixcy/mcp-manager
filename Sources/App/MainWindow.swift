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
                .background(Theme.bg.ignoresSafeArea())
                // The detail toolbar holds no items, so a visible background
                // draws an empty bar above the page header.
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
        return List(selection: $model.route) {
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
                .tag(Route.globals)
            } header: {
                SectionLabel("Global MCPs")
            }

            Section {
                OrcTextField(label: "Search projects", placeholder: "Search projects", text: $query)
                    .onSubmit { if let first = ranked.first { model.open(first) } }
                    .selectionDisabled()
                if model.hasLoaded, model.projects.isEmpty {
                    FieldMessage(text: "No projects found in Claude or Codex config.", tone: .neutral)
                        .selectionDisabled()
                } else if ranked.isEmpty {
                    FieldMessage(text: "No project matches “\(query)”.", tone: .neutral)
                        .selectionDisabled()
                }
                ForEach(ranked) { project in
                    ProjectRow(project: project)
                        .tag(Route.project(project.path))
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
