import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(inspector: inspector)
            Hairline()
            VStack(alignment: .leading, spacing: 10) {
                if StatusBanners.hasContent(model) { StatusBanners() }
                notices
                InspectorTabBar(inspector: inspector)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Hairline()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Without a floor, SwiftUI measures the wrapped error and empty-state text at a
        // near-zero width when sizing the window, and the page asks to be thousands of points tall.
        .frame(minWidth: 480)
    }

    @ViewBuilder
    private var notices: some View {
        if let error = inspector.failure {
            ErrorCallout(error: error,
                         onSignIn: inspector.canSignIn ? { inspector.signIn() } : nil,
                         onOpenEnvironment: { inspector.tab = .environment },
                         onShowLogs: inspector.tab == .logs ? nil : { inspector.tab = .logs },
                         onRetry: { inspector.connect() })
        }
        if inspector.configChanged {
            HStack(spacing: 8) {
                Banner(title: "Config changed", message: "Reconnect to apply.", tone: .yellow)
                Button("Reconnect") { inspector.reconnect() }
                    .buttonStyle(.orc(.secondary, compact: true))
            }
        }
        if let error = inspector.catalogError {
            ErrorCallout(error: error, onDismiss: { inspector.dismissCatalogError() })
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch inspector.tab {
        case .tools: InspectorToolsView(inspector: inspector)
        case .resources: InspectorResourcesView(inspector: inspector)
        case .prompts: InspectorPromptsView(inspector: inspector)
        case .logs: InspectorLogsView(inspector: inspector)
        case .environment: InspectorEnvironmentView(inspector: inspector)
        case .info: InspectorInfoView(inspector: inspector)
        }
    }
}

private struct InspectorHeader: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inspector: InspectorModel
    @State private var confirmingSignOut = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The back button drops its text before the title block has to truncate in narrow windows.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    backButton(iconOnly: false)
                    titleBlock.fixedSize()
                }
                HStack(alignment: .center, spacing: 8) {
                    backButton(iconOnly: true)
                    titleBlock
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .confirmationDialog("Sign out of \(inspector.target.name)?", isPresented: $confirmingSignOut,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { inspector.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MCP Manager forgets its sign-in for this server. Claude and Codex keep their own. You can sign in again at any time.")
        }
    }

    private func backButton(iconOnly: Bool) -> some View {
        Button {
            model.leaveServerPage(inspector.key)
        } label: {
            if iconOnly {
                Label(model.backLabel(for: inspector.key), systemImage: "chevron.left").labelStyle(.iconOnly)
            } else {
                Label(model.backLabel(for: inspector.key), systemImage: "chevron.left")
            }
        }
        .buttonStyle(.orc(.ghost, compact: true))
        .keyboardShortcut("[", modifiers: .command)
        .help("\(model.backLabel(for: inspector.key)) (⌘[)")
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            TransportIcon(transport: inspector.target.config.transport, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    title
                    InspectorStatusChip(inspector: inspector)
                }
                HStack(spacing: 6) {
                    Text("\(inspector.target.config.transport.kindLabel) · \(inspector.target.locationLabel)")
                    if case let .connecting(step) = inspector.state {
                        Text("· \(step.label)")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedStrong)
                .lineLimit(1)
            }
        }
    }

    private var title: some View {
        Text(inspector.target.name)
            .font(Theme.headline)
            .foregroundStyle(Theme.heading)
            .lineLimit(1)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if inspector.isRemote, inspector.hasOAuthCredential, !inspector.isBusy {
                Button("Sign out…") { confirmingSignOut = true }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .help("Forget the stored sign-in for this server")
            }
            if inspector.canSignIn {
                Button("Sign in") { inspector.signIn() }
                    .buttonStyle(.orc(.secondary, compact: true))
            }
            switch inspector.state {
            case .notConnected, .failed:
                Button("Connect") { inspector.connect() }
                    .buttonStyle(.orc(.primary, compact: true))
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Connect (⌘K)")
            case .connecting:
                Button("Cancel") { inspector.disconnect() }
                    .buttonStyle(.orc(.secondary, compact: true))
            case .signingIn:
                Button("Cancel sign-in") { inspector.cancelSignIn() }
                    .buttonStyle(.orc(.secondary, compact: true))
            case .connected:
                Button("Reconnect") { inspector.reconnect() }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Reconnect (⌘R)")
                Button("Disconnect") { inspector.disconnect() }
                    .buttonStyle(.orc(.secondary, compact: true))
            }
        }
    }
}

private struct InspectorTabBar: View {
    @ObservedObject var inspector: InspectorModel

    private var tabs: [InspectorTab] {
        InspectorTab.allCases.filter { tab in
            switch tab {
            case .resources: return inspector.capabilities?.resources == true
            case .prompts: return inspector.capabilities?.prompts == true
            default: return true
            }
        }
    }

    private func count(_ tab: InspectorTab) -> Int? {
        switch tab {
        case .tools: return inspector.isConnected ? inspector.tools.count : nil
        case .resources: return inspector.resources.count + inspector.templates.count
        case .prompts: return inspector.prompts.count
        case .logs: return inspector.logEntries.isEmpty ? nil : inspector.logEntries.count
        case .environment, .info: return nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                TabButton(title: tab.title, count: count(tab), selected: inspector.tab == tab) {
                    inspector.tab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server sections")
        .onChange(of: tabs) {
            if !tabs.contains(inspector.tab) { inspector.tab = .tools }
        }
    }
}

private struct TabButton: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(Theme.label)
                        .foregroundStyle(Theme.mutedStrong)
                }
            }
            .foregroundStyle(selected ? Theme.heading : Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.chip : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A tab body that scrolls instead of growing the window when the window is short.
struct InspectorPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

struct NotConnectedState: View {
    @ObservedObject var inspector: InspectorModel
    let what: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch inspector.state {
            case let .connecting(step):
                EmptyStateView(title: "Connecting to \(inspector.target.name)", message: step.label)
            case .signingIn:
                EmptyStateView(title: "Signing in", message: "Finish signing in in your browser. MCP Manager connects as soon as you're done.")
            default:
                EmptyStateView(title: "Not connected",
                               message: "Connect to \(inspector.target.name) to see its \(what).",
                               actionTitle: "Connect", action: { inspector.connect() })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
