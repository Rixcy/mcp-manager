import SwiftUI

struct RenameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let server: GlobalServer

    @State private var newName: String
    @State private var submitError: String?
    @State private var submitting = false

    init(server: GlobalServer) {
        self.server = server
        _newName = State(initialValue: server.name)
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private var issue: String? {
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed == server.name { return nil }
        if let message = MCPManager.validateName(trimmed) { return message }
        if let clash = model.globals.first(where: { $0.name == trimmed }) {
            return "\(clientList(clash.clients)) already \(clash.clients.count > 1 ? "have" : "has") an MCP called “\(trimmed)”."
        }
        return nil
    }

    private var canSubmit: Bool { !submitting && issue == nil && trimmed != server.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename “\(server.name)”")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.heading)
                Text("Renames it in \(clientList(server.clients)), keeping every other setting as it is.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedStrong)
            }
            .padding(16)
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("New name")
                OrcTextField(label: "New name", placeholder: server.name, text: $newName, mono: true,
                             invalid: issue != nil)
                    .onSubmit(submit)
                if let issue {
                    FieldMessage(text: issue)
                } else {
                    FieldMessage(text: "Letters, digits, - or _.", tone: .neutral)
                }
                if let submitError {
                    Banner(title: "Couldn't rename", message: submitError, tone: .red)
                }
            }
            .padding(16)
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.orc(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Renaming…" : "Rename") { submit() }
                    .buttonStyle(.orc(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(16)
            .background(Theme.panel)
        }
        .frame(width: 440)
        .background(Theme.bg)
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        submitError = nil
        let oldName = server.name
        let target = trimmed
        Task {
            do {
                try await model.rename(oldName, to: target)
                dismiss()
            } catch {
                submitError = AppModel.message(error)
            }
            submitting = false
        }
    }
}
