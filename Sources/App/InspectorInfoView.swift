import SwiftUI

struct InspectorInfoView: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = inspector.initializeResult {
                    serverPanel(result)
                    capabilitiesPanel(result.capabilities)
                    if let instructions = result.instructions, !instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Instructions")
                            Text(instructions)
                                .font(Theme.body)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .orcPanel(padding: 14)
                    }
                    connectionPanel
                } else {
                    NotConnectedState(inspector: inspector, what: "server details")
                }
                filesPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func serverPanel(_ result: MCPInitializeResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Server")
            InfoLine(label: "Name", value: result.serverInfo.name, mono: true)
            if let title = result.serverInfo.title { InfoLine(label: "Title", value: title) }
            InfoLine(label: "Version", value: result.serverInfo.version.isEmpty ? "not given" : result.serverInfo.version, mono: true)
            InfoLine(label: "Protocol", value: result.protocolVersion, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }

    private func capabilitiesPanel(_ capabilities: MCPServerCapabilities) -> some View {
        let names = capabilityNames(capabilities)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Capabilities")
            if names.isEmpty {
                FieldMessage(text: "The server declared no capabilities.", tone: .neutral)
            } else {
                HStack(spacing: 4) {
                    ForEach(names, id: \.self) { Chip(text: $0, tone: .accent) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }

    private func capabilityNames(_ capabilities: MCPServerCapabilities) -> [String] {
        var names: [String] = []
        if capabilities.tools { names.append(capabilities.toolsListChanged ? "tools · list changes" : "tools") }
        if capabilities.resources {
            var name = "resources"
            if capabilities.resourcesSubscribe { name += " · subscribe" }
            if capabilities.resourcesListChanged { name += " · list changes" }
            names.append(name)
        }
        if capabilities.prompts { names.append(capabilities.promptsListChanged ? "prompts · list changes" : "prompts") }
        if capabilities.logging { names.append("logging") }
        if capabilities.completions { names.append("completions") }
        return names
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Connection")
            if let info = inspector.transportInfo {
                if let pid = info.processID { InfoLine(label: "Process ID", value: String(pid), mono: true) }
                if let endpoint = info.endpoint { InfoLine(label: "Endpoint", value: endpoint, mono: true) }
                if let session = info.sessionID { InfoLine(label: "Session ID", value: session, mono: true) }
            }
            if let launch = inspector.resolvedLaunch {
                InfoLine(label: inspector.isRemote ? "URL" : "Command", value: launch.displayName, mono: true)
            }
            HStack(spacing: 8) {
                Button("Ping") { inspector.ping() }
                    .buttonStyle(.orc(.secondary, compact: true))
                    .disabled(inspector.pingResult == .loading)
                pingText
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }

    @ViewBuilder
    private var pingText: some View {
        switch inspector.pingResult {
        case .idle: EmptyView()
        case .loading: FieldMessage(text: "Pinging…", tone: .neutral)
        case let .loaded(duration): FieldMessage(text: "Answered in \(formatDuration(duration)).", tone: .green)
        case let .failed(error): FieldMessage(text: "\(error.title). \(error.message)")
        }
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Files")
            HStack(spacing: 6) {
                InfoLine(label: "Log", value: abbreviate(inspector.logURL), mono: true)
                IconButton(systemImage: "folder", label: "Reveal log file in Finder") {
                    revealInFinder(inspector.logURL.path)
                }
            }
            InfoLine(label: "Variables", value: abbreviate(inspector.paths.clientVariablesFile), mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 14)
    }
}

struct InfoLine: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedStrong)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(mono ? Theme.mono(12) : Theme.body)
                .foregroundStyle(Theme.heading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
