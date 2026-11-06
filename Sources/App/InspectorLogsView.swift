import SwiftUI

struct InspectorLogsView: View {
    @ObservedObject var inspector: InspectorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filterText = ""
    @State private var kindFilter: LogFilter = .all
    @State private var follow = true
    @State private var confirmingClear = false

    private var visible: [MCPLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        return inspector.logEntries.filter { entry in
            kindFilter.includes(entry.kind)
                && (query.isEmpty || entry.summary.localizedCaseInsensitiveContains(query)
                    || entry.detail?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        let entries = visible
        VStack(spacing: 0) {
            toolbar(entries)
            Hairline()
            if let error = inspector.logError {
                Banner(title: "Error", message: error, tone: .red) { inspector.logError = nil }
                    .padding(12)
            }
            list(entries)
            Hairline()
            footer
        }
        .confirmationDialog("Clear the log for \(inspector.target.name)?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear log", role: .destructive) { inspector.clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(abbreviate(inspector.logURL)) and its older copies. It can't be undone.")
        }
    }

    private func toolbar(_ entries: [MCPLogEntry]) -> some View {
        HStack(spacing: 8) {
            OrcTextField(label: "Filter log", placeholder: "Filter", text: $filterText)
                .frame(maxWidth: 220)
            Picker("Show", selection: $kindFilter) {
                ForEach(LogFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.text)
                .help("Keep the newest entry in view")
            Spacer(minLength: 4)
            Button("Copy") { copyToPasteboard(InspectorModel.logText(entries)) }
                .buttonStyle(.orc(.secondary, compact: true))
                .disabled(entries.isEmpty)
                .help("Copy the \(entries.count) visible entries")
            IconButton(systemImage: "folder", label: "Reveal log file in Finder") {
                revealInFinder(inspector.logURL.path)
            }
            Button("Clear…") { confirmingClear = true }
                .buttonStyle(.orc(.destructive, compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func list(_ entries: [MCPLogEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        FieldMessage(text: inspector.logEntries.isEmpty
                                         ? "Nothing logged yet. Connect to see the messages MCP Manager and the server exchange."
                                         : "No entry matches this filter.",
                                     tone: .neutral)
                            .padding(16)
                    }
                    ForEach(entries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
            }
            .onChange(of: entries.last?.id) { _, last in
                guard follow, let last else { return }
                if reduceMotion {
                    proxy.scrollTo(last, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: follow) {
                if follow, let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear {
                if follow, let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(abbreviate(inspector.logURL))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.mutedStrong)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Text("\(inspector.logEntries.count) of at most \(InspectorModel.logLimit) entries shown")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedStrong)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }
}

private struct LogRow: View {
    let entry: MCPLogEntry
    @State private var expanded = false

    private var kind: (String, Tone) {
        switch entry.kind {
        case .outgoing: return ("sent", .accent)
        case .incoming: return ("received", .green)
        case .stderr: return ("stderr", .neutral)
        case .event: return ("event", .neutral)
        case .warning: return ("warning", .yellow)
        case .error: return ("error", .red)
        }
    }

    private var detailText: String? {
        guard let detail = entry.detail, !detail.isEmpty else { return nil }
        if let value = try? JSONValue.parse(detail), value.objectValue != nil || value.arrayValue != nil {
            return value.jsonString(pretty: true)
        }
        return detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if entry.detail?.isEmpty == false {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.mutedStrong)
                    .accessibilityLabel(expanded ? "Hide detail" : "Show detail")
                    .help(expanded ? "Hide detail" : "Show detail")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text(InspectorModel.logTimeFormatter.string(from: entry.time))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.mutedStrong)
                Chip(text: kind.0, tone: kind.1)
                Text(entry.summary)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.heading)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if expanded, let detailText {
                CodeBlock(text: detailText)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
