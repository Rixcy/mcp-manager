import SwiftUI

struct InspectorToolsView: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        if !inspector.isConnected {
            InspectorPane { NotConnectedState(inspector: inspector, what: "tools") }
        } else if inspector.tools.isEmpty {
            InspectorPane {
                EmptyStateView(title: "No tools",
                               message: inspector.capabilities?.tools == true
                                   ? "\(inspector.target.name) is connected but lists no tools."
                                   : "\(inspector.target.name) does not offer tools.")
            }
        } else {
            HStack(spacing: 0) {
                ToolListColumn(inspector: inspector)
                    .frame(width: 240)
                Rectangle().fill(Theme.border).frame(width: 1)
                ScrollView {
                    if let tool = inspector.selectedTool {
                        ToolDetail(inspector: inspector, tool: tool)
                            .id(tool.name)
                            .padding(16)
                    } else {
                        FieldMessage(text: "Pick a tool on the left.", tone: .neutral)
                            .padding(16)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ToolListColumn: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        let tools = inspector.filteredTools
        VStack(alignment: .leading, spacing: 8) {
            OrcTextField(label: "Search tools", placeholder: "Search tools", text: $inspector.toolSearch)
            if tools.isEmpty {
                FieldMessage(text: "No tool matches “\(inspector.toolSearch)”.", tone: .neutral)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tools) { tool in
                        ToolListRow(tool: tool, selected: inspector.selectedToolName == tool.name) {
                            inspector.selectedToolName = tool.name
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
    }
}

private struct ToolListRow: View {
    let tool: MCPTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.heading)
                    .lineLimit(2)
                if tool.displayTitle != tool.name {
                    Text(tool.name)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.mutedStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ToolAnnotationChips(annotations: tool.annotations)
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

struct ToolAnnotationChips: View {
    let annotations: MCPToolAnnotations

    var body: some View {
        let chips = Self.chips(annotations)
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.0) { chip in
                    Chip(text: chip.0, tone: chip.1)
                }
            }
        }
    }

    static func chips(_ annotations: MCPToolAnnotations) -> [(String, Tone)] {
        var chips: [(String, Tone)] = []
        if annotations.readOnlyHint == true { chips.append(("read-only", .green)) }
        if annotations.destructiveHint == true, annotations.readOnlyHint != true { chips.append(("destructive", .red)) }
        if annotations.idempotentHint == true { chips.append(("idempotent", .neutral)) }
        if annotations.openWorldHint == true { chips.append(("open world", .neutral)) }
        return chips
    }
}

private struct ToolDetail: View {
    @ObservedObject var inspector: InspectorModel
    let tool: MCPTool

    private var schema: ToolSchema { ToolSchema(inputSchema: tool.inputSchema) }
    private var isDestructive: Bool { tool.annotations.destructiveHint == true && tool.annotations.readOnlyHint != true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            ToolArgumentsEditor(inspector: inspector, tool: tool, schema: schema)
            runRow
            if let record = inspector.shownCall {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Result")
                    CallOutcomeView(record: record)
                }
            }
            ToolHistoryList(inspector: inspector, toolName: tool.name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tool.displayTitle)
                .font(Theme.title)
                .foregroundStyle(Theme.heading)
                .textSelection(.enabled)
            if tool.displayTitle != tool.name {
                Text(tool.name)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.mutedStrong)
                    .textSelection(.enabled)
            }
            ToolAnnotationChips(annotations: tool.annotations)
            if let description = tool.description, !description.isEmpty {
                Text(description)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var runRow: some View {
        if let call = inspector.activeCall, call.toolName == tool.name {
            HStack(spacing: 10) {
                Button("Cancel") { inspector.cancelCall() }
                    .buttonStyle(.orc(.secondary))
                    .keyboardShortcut(.cancelAction)
                CallProgressLine(call: call)
            }
        } else {
            HStack(spacing: 10) {
                Button(isDestructive ? "Run destructive tool" : "Run") { inspector.runSelectedTool() }
                    .buttonStyle(.orc(isDestructive ? .destructive : .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(inspector.activeCall != nil || !inspector.isConnected)
                    .help("Run \(tool.name) (⌘↩)")
                if isDestructive {
                    FieldMessage(text: "The server marks this tool as destructive: it may change or delete data.", tone: .red)
                } else if inspector.activeCall != nil {
                    FieldMessage(text: "Another tool is running. Wait for it or cancel it first.", tone: .neutral)
                }
            }
        }
    }
}

private struct CallProgressLine: View {
    let call: ActiveCall

    var body: some View {
        TimelineView(.periodic(from: call.started, by: 0.1)) { context in
            HStack(spacing: 8) {
                if let fraction = call.progress?.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                    Text("\(Int(fraction * 100))%")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Running")
                }
                Text(call.progress?.message ?? "Running…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(String(format: "%.1f s", context.date.timeIntervalSince(call.started)))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.mutedStrong)
                    .accessibilityLabel("Elapsed")
            }
        }
    }
}

private struct ToolHistoryList: View {
    @ObservedObject var inspector: InspectorModel
    let toolName: String

    var body: some View {
        let records = inspector.history(for: toolName)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("History")
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Hairline() }
                        HistoryRow(record: record, selected: inspector.shownCallID == record.id) {
                            inspector.restore(record)
                        }
                    }
                }
                .orcPanel()
            }
        }
    }
}

private struct HistoryRow: View {
    let record: CallRecord
    let selected: Bool
    let action: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var status: (String, Tone) {
        switch record.outcome {
        case let .result(result): return result.isError ? ("Tool error", .yellow) : ("OK", .green)
        case .failure: return ("Failed", .red)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(Self.time.string(from: record.started))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                Chip(text: status.0, tone: status.1)
                Text(record.arguments.isEmpty ? "no arguments" : JSONValue.object(record.arguments).jsonString())
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.mutedStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(formatDuration(record.duration))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.mutedStrong)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Theme.chip : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this result and restore its arguments")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Arguments

private struct ToolArgumentsEditor: View {
    @ObservedObject var inspector: InspectorModel
    let tool: MCPTool
    let schema: ToolSchema

    var body: some View {
        let draft = inspector.draft(for: tool)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Arguments")
                Spacer()
                Picker("Argument editor", selection: Binding(get: { draft.mode }, set: { inspector.setMode($0, tool: tool) })) {
                    ForEach(ArgumentMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if draft.mode == .json {
                jsonEditor(draft)
            } else if schema.takesNoArguments {
                FieldMessage(text: "This tool takes no arguments.", tone: .neutral)
            } else {
                if !draft.extraNames.isEmpty {
                    FieldMessage(text: "Not in the form: \(draft.extraNames.joined(separator: ", ")). Switch to JSON to send them.",
                                 tone: .gate)
                }
                if let message = draft.errors[""] { FieldMessage(text: message) }
                ForEach(schema.fields) { field in
                    ToolFieldView(field: field, error: draft.errors[field.name], text: binding(field))
                }
            }
        }
    }

    private func binding(_ field: ToolSchema.Field) -> Binding<String> {
        Binding(get: { inspector.draft(for: tool).values[field.name] ?? "" },
                set: { inspector.setValue($0, field: field.name, tool: tool) })
    }

    @ViewBuilder
    private func jsonEditor(_ draft: ToolDraft) -> some View {
        OrcTextEditor(label: "Arguments as JSON", placeholder: "{}",
                      text: Binding(get: { inspector.draft(for: tool).json }, set: { inspector.setJSON($0, tool: tool) }),
                      invalid: draft.errors[""] != nil)
            .frame(minHeight: 120)
        if let message = draft.errors[""] {
            FieldMessage(text: message)
        } else {
            FieldMessage(text: "A JSON object, sent as the tool's arguments exactly as written.", tone: .neutral)
        }
    }
}

private struct ToolFieldView: View {
    let field: ToolSchema.Field
    let error: String?
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                if field.label != field.name {
                    Text(field.name)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.mutedStrong)
                }
                Text(field.required ? "required" : "optional")
                    .font(.system(size: 11))
                    .foregroundStyle(field.required ? Theme.gateText : Theme.mutedStrong)
                Text(kindLabel)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.mutedStrong)
            }
            input
            if let error {
                FieldMessage(text: error)
            } else if let description = field.description, !description.isEmpty {
                FieldMessage(text: description, tone: .neutral)
            }
        }
    }

    private var kindLabel: String {
        var label: String
        switch field.kind {
        case let .string(format): label = format.map { "string · \($0)" } ?? "string"
        case .choice: label = "choice"
        case .integer: label = "integer"
        case .number: label = "number"
        case .boolean: label = "boolean"
        case .stringArray: label = "list of strings"
        case let .json(expected): label = expected.map { "JSON \($0)" } ?? "JSON"
        }
        if let minimum = field.minimum { label += " ≥ \(JSONValue.double(minimum).jsonString())" }
        if let maximum = field.maximum { label += " ≤ \(JSONValue.double(maximum).jsonString())" }
        return label
    }

    @ViewBuilder
    private var input: some View {
        switch field.kind {
        case .string:
            OrcTextField(label: field.label, placeholder: field.placeholder, text: $text, invalid: error != nil, multiline: true)
        case let .choice(options):
            Picker(field.label, selection: $text) {
                if !field.required || text.isEmpty { Text("Not set").tag("") }
                ForEach(options.map(ToolSchema.Field.optionText), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .integer, .number:
            OrcTextField(label: field.label, placeholder: field.placeholder, text: $text, mono: true, invalid: error != nil)
                .frame(maxWidth: 220)
        case .boolean:
            booleanInput
        case .stringArray:
            OrcTextEditor(label: "\(field.label), one item per line", placeholder: field.placeholder, text: $text,
                          invalid: error != nil)
        case .json:
            OrcTextEditor(label: "\(field.label) as JSON", placeholder: field.placeholder, text: $text, invalid: error != nil)
        }
    }

    @ViewBuilder
    private var booleanInput: some View {
        if field.required {
            Toggle(field.label, isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false" }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(field.label)
        } else {
            Picker(field.label, selection: $text) {
                Text("Not set").tag("")
                Text("true").tag("true")
                Text("false").tag("false")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}
