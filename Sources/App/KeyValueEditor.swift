import SwiftUI

struct KeyValueRow: Identifiable, Equatable {
    var id = UUID()
    var key: String
    var value: String

    var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
    /// A row the user added and left empty; ignored when saving.
    var isBlank: Bool { trimmedKey.isEmpty && value.isEmpty }

    static func isEnvName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    static func rows(_ pairs: [String: String]) -> [KeyValueRow] {
        pairs.keys.sorted().map { KeyValueRow(key: $0, value: pairs[$0]!) }
    }

    static func pairs(_ rows: [KeyValueRow]) -> [String: String] {
        var pairs: [String: String] = [:]
        for row in rows where !row.isBlank { pairs[row.trimmedKey] = row.value }
        return pairs
    }

    /// Row id to the message shown under it: empty or invalid names and duplicates.
    static func issues(_ rows: [KeyValueRow], keyCheck: ((String) -> Bool)?, invalidMessage: String) -> [UUID: String] {
        var issues: [UUID: String] = [:]
        var seen = Set<String>()
        for row in rows where !row.isBlank {
            let key = row.trimmedKey
            if key.isEmpty {
                issues[row.id] = "Enter a name."
            } else if keyCheck?(key) == false {
                issues[row.id] = "“\(key)”: \(invalidMessage)"
            } else if !seen.insert(key.lowercased()).inserted {
                issues[row.id] = "“\(key)” is listed more than once."
            }
        }
        return issues
    }
}

/// Name/value rows with an add button. Values are hidden until the row's eye
/// button shows them, because these are usually tokens.
struct KeyValueEditor: View {
    @Binding var rows: [KeyValueRow]
    var keyLabel = "Name"
    var keyPlaceholder = "NAME"
    var valuePlaceholder = "value"
    var addLabel = "Add variable"
    var issues: [UUID: String] = [:]

    @State private var revealed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    rowView($row)
                    if let issue = issues[row.id] {
                        FieldMessage(text: issue)
                    }
                }
            }
            Button {
                rows.append(KeyValueRow(key: "", value: ""))
            } label: {
                Label(addLabel, systemImage: "plus")
            }
            .buttonStyle(.orc(.secondary, compact: true))
        }
    }

    private func rowView(_ row: Binding<KeyValueRow>) -> some View {
        let id = row.wrappedValue.id
        let name = row.wrappedValue.trimmedKey.isEmpty ? "new row" : row.wrappedValue.trimmedKey
        let shown = revealed.contains(id)
        return HStack(spacing: 6) {
            OrcTextField(label: keyLabel, placeholder: keyPlaceholder, text: row.key, mono: true,
                         invalid: issues[id] != nil)
                .frame(maxWidth: 200)
            SecretField(label: "Value for \(name)", placeholder: valuePlaceholder, text: row.value, revealed: shown)
            IconButton(systemImage: shown ? "eye.slash" : "eye", label: shown ? "Hide value for \(name)" : "Show value for \(name)") {
                if shown { revealed.remove(id) } else { revealed.insert(id) }
            }
            IconButton(systemImage: "minus.circle", label: "Remove \(name)") {
                rows.removeAll { $0.id == id }
                revealed.remove(id)
            }
        }
    }
}

/// A text field that masks its value until `revealed`.
struct SecretField: View {
    let label: String
    var placeholder = ""
    @Binding var text: String
    var revealed: Bool

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if revealed {
                TextField(label, text: $text, prompt: Text(placeholder).foregroundColor(Theme.muted))
            } else {
                SecureField(label, text: $text, prompt: Text(placeholder).foregroundColor(Theme.muted))
            }
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(Theme.mono())
        .foregroundStyle(Theme.heading)
        .focused($focused)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.bg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelRadius)
                .strokeBorder(focused ? Theme.green : Theme.border, lineWidth: 1)
        )
    }
}
