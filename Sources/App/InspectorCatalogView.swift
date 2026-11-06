import SwiftUI

/// List on the left, the selected item on the right; shared by Resources and Prompts.
private struct CatalogSplit<Items: View, Detail: View>: View {
    @ViewBuilder let list: Items
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) { list }
                    .padding(12)
            }
            .frame(width: 260)
            .background(Theme.panel)
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                detail
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.heading)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.mutedStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.chip : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Resources

struct InspectorResourcesView: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        if !inspector.isConnected {
            NotConnectedState(inspector: inspector, what: "resources").padding(16)
        } else if inspector.resources.isEmpty && inspector.templates.isEmpty {
            EmptyStateView(title: "No resources", message: "\(inspector.target.name) lists no resources or templates.")
                .padding(16)
        } else {
            CatalogSplit {
                if !inspector.resources.isEmpty { SectionLabel("Resources").padding(.horizontal, 8) }
                ForEach(inspector.resources) { resource in
                    CatalogRow(title: resource.title ?? resource.name, subtitle: resource.uri,
                               selected: inspector.selectedResourceURI == resource.uri) {
                        inspector.selectResource(resource.uri)
                    }
                }
                if !inspector.templates.isEmpty {
                    SectionLabel("Templates").padding(.horizontal, 8).padding(.top, 8)
                    ForEach(inspector.templates) { template in
                        CatalogRow(title: template.title ?? template.name, subtitle: template.uriTemplate,
                                   selected: inspector.selectedResourceURI == template.uriTemplate) {
                            inspector.selectResource(template.uriTemplate)
                        }
                    }
                }
            } detail: {
                resourceDetail
            }
        }
    }

    @ViewBuilder
    private var resourceDetail: some View {
        if let resource = inspector.resources.first(where: { $0.uri == inspector.selectedResourceURI }) {
            ResourceDetail(inspector: inspector, resource: resource)
        } else if let template = inspector.templates.first(where: { $0.uriTemplate == inspector.selectedResourceURI }) {
            TemplateDetail(template: template)
        } else {
            FieldMessage(text: "Pick a resource on the left.", tone: .neutral)
        }
    }
}

private struct ResourceDetail: View {
    @ObservedObject var inspector: InspectorModel
    let resource: MCPResource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(resource.title ?? resource.name)
                    .font(Theme.title)
                    .foregroundStyle(Theme.heading)
                    .textSelection(.enabled)
                Text(resource.uri)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if let mimeType = resource.mimeType { Chip(text: mimeType) }
                    if let size = resource.size { Chip(text: formatBytes(size)) }
                }
                if let description = resource.description {
                    Text(description)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(inspector.resourceRead == .loading ? "Reading…" : "Read") { inspector.readResource(resource.uri) }
                .buttonStyle(.orc(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(inspector.resourceRead == .loading)
                .help("Read this resource (⌘↩)")
            switch inspector.resourceRead {
            case .idle, .loading:
                EmptyView()
            case let .loaded(contents):
                if contents.isEmpty {
                    FieldMessage(text: "The server returned no contents.", tone: .neutral)
                }
                ForEach(Array(contents.enumerated()), id: \.offset) { _, item in
                    ResourceContentsView(contents: item)
                }
            case let .failed(error):
                ErrorCallout(error: error)
            }
        }
    }
}

private struct TemplateDetail: View {
    let template: MCPResourceTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(template.title ?? template.name)
                .font(Theme.title)
                .foregroundStyle(Theme.heading)
                .textSelection(.enabled)
            Text(template.uriTemplate)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            if let mimeType = template.mimeType { Chip(text: mimeType) }
            if let description = template.description {
                Text(description)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FieldMessage(text: "A template describes a family of resources. Fill in its placeholders to get a URI the server can read.",
                         tone: .neutral)
        }
    }
}

// MARK: Prompts

struct InspectorPromptsView: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        if !inspector.isConnected {
            NotConnectedState(inspector: inspector, what: "prompts").padding(16)
        } else if inspector.prompts.isEmpty {
            EmptyStateView(title: "No prompts", message: "\(inspector.target.name) lists no prompts.")
                .padding(16)
        } else {
            CatalogSplit {
                ForEach(inspector.prompts) { prompt in
                    CatalogRow(title: prompt.displayTitle, subtitle: prompt.displayTitle == prompt.name ? nil : prompt.name,
                               selected: inspector.selectedPromptName == prompt.name) {
                        inspector.selectPrompt(prompt.name)
                    }
                }
            } detail: {
                if let prompt = inspector.prompts.first(where: { $0.name == inspector.selectedPromptName }) {
                    PromptDetail(inspector: inspector, prompt: prompt)
                } else {
                    FieldMessage(text: "Pick a prompt on the left.", tone: .neutral)
                }
            }
        }
    }
}

private struct PromptDetail: View {
    @ObservedObject var inspector: InspectorModel
    let prompt: MCPPrompt

    var body: some View {
        let missing = inspector.missingPromptArguments(prompt)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.displayTitle)
                    .font(Theme.title)
                    .foregroundStyle(Theme.heading)
                    .textSelection(.enabled)
                if prompt.displayTitle != prompt.name {
                    Text(prompt.name).font(Theme.mono(12)).foregroundStyle(Theme.mutedStrong).textSelection(.enabled)
                }
                if let description = prompt.description {
                    Text(description)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if prompt.arguments.isEmpty {
                FieldMessage(text: "This prompt takes no arguments.", tone: .neutral)
            }
            ForEach(prompt.arguments, id: \.name) { argument in
                argumentField(argument)
            }
            HStack(spacing: 8) {
                Button(inspector.promptResult == .loading ? "Getting…" : "Get") { inspector.getPrompt(prompt) }
                    .buttonStyle(.orc(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!missing.isEmpty || inspector.promptResult == .loading)
                    .help("Get this prompt (⌘↩)")
                if !missing.isEmpty {
                    FieldMessage(text: "Fill in \(missing.joined(separator: ", ")) first.", tone: .neutral)
                }
            }
            result
        }
    }

    private func argumentField(_ argument: MCPPromptArgument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(argument.title ?? argument.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                Text(argument.required ? "required" : "optional")
                    .font(.system(size: 11))
                    .foregroundStyle(argument.required ? Theme.gateText : Theme.mutedStrong)
            }
            OrcTextField(label: argument.title ?? argument.name, placeholder: argument.name,
                         text: Binding(get: { inspector.promptValue(prompt.name, argument.name) },
                                       set: { inspector.setPromptValue($0, prompt: prompt.name, argument: argument.name) }),
                         multiline: true)
            if let description = argument.description {
                FieldMessage(text: description, tone: .neutral)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        switch inspector.promptResult {
        case .idle, .loading:
            EmptyView()
        case let .loaded(value):
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Messages")
                if let description = value.description {
                    FieldMessage(text: description, tone: .neutral)
                }
                ForEach(Array(value.messages.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 4) {
                        Chip(text: message.role, tone: message.role == "assistant" ? .accent : .neutral)
                        ContentBlockView(content: message.content)
                    }
                }
            }
        case let .failed(error):
            ErrorCallout(error: error)
        }
    }
}
