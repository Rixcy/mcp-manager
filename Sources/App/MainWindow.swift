import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    private var isSidebarCollapsed: Bool { model.sidebarVisibility == .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The detail toolbar holds no items, so the page header moves up
                // into its band instead of sitting below an empty strip. With the
                // sidebar collapsed the traffic lights and sidebar button sit in
                // that band, so the header stays below them.
                .ignoresSafeArea(.container, edges: isSidebarCollapsed ? [] : .top)
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
        let ranked = model.rankedProjects(model.projectQuery)
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
                if model.hasLoaded, model.projects.isEmpty {
                    FieldMessage(text: "No projects found in Claude or Codex config.", tone: .neutral)
                } else if ranked.isEmpty {
                    FieldMessage(text: "No project matches “\(model.projectQuery)”.", tone: .neutral)
                }
                ForEach(ranked) { project in
                    ProjectRow(project: project, showsFolder: sharedNames.contains(project.name))
                        .padding(.vertical, 2)
                        .sidebarRow(.project(project.path), selection: $model.route)
                }
            } header: {
                // Section headers run closer to the sidebar edge than rows do; this
                // lines the field and its icon up with the Global MCPs row above.
                ProjectSearchHeader { if let first = ranked.first { model.open(first) } }
                    .padding(.trailing, 8)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Hairline()
                Button { model.route = .settings } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.mutedStrong)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text("Settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.heading)
                        Spacer()
                        Text("⌘,")
                            .font(Theme.label)
                            .foregroundStyle(Theme.muted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.route == .settings ? Theme.chip : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.route == .settings ? .isSelected : [])
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
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
        case .settings:
            SettingsView()
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

/// The Projects heading, which turns into the project search field when its magnifying glass is clicked.
private struct ProjectSearchHeader: View {
    @EnvironmentObject private var model: AppModel
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if model.isSearchingProjects {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedStrong)
                    .accessibilityHidden(true)
                TextField("Search projects", text: $model.projectQuery,
                          prompt: Text("Search projects").foregroundColor(Theme.muted))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.heading)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: close)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close project search")
                .help("Close search (Esc)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.bg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.panelRadius)
                    .strokeBorder(focused ? Theme.green : Theme.border, lineWidth: 1)
            )
            .onAppear { DispatchQueue.main.async { focused = true } }
        } else {
            HStack {
                SectionLabel("Projects")
                Spacer()
                Button { model.isSearchingProjects = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.mutedStrong)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Search projects")
                .help("Search projects (⌘F)")
            }
        }
    }

    private func close() {
        model.projectQuery = ""
        model.isSearchingProjects = false
    }
}
