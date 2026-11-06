import AppKit
import SwiftUI

struct Chip: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(tone.textColor)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(tone.fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(tone.stroke, lineWidth: 1))
            .fixedSize()
    }
}

/// Which clients carry a global server, named in text.
struct ClientChips: View {
    let server: GlobalServer

    var body: some View {
        HStack(spacing: 4) {
            ForEach(server.clients) { client in
                Chip(text: client.displayName)
            }
            switch availability(of: server) {
            case .both:
                EmptyView()
            case let .onlyIn(client, syncable):
                Chip(text: syncable ? "\(client.displayName) only" : "\(client.displayName) only · no SSE in Codex",
                     tone: syncable ? .gate : .neutral)
            }
            if server.codex?.enabled == false {
                Chip(text: "Disabled in Codex", tone: .yellow)
            }
        }
    }
}

enum Availability {
    case both
    /// `syncable` is false when the missing client cannot represent the transport.
    case onlyIn(MCPClient, syncable: Bool)
}

func availability(of server: GlobalServer) -> Availability {
    guard let present = server.clients.first, server.clients.count == 1 else { return .both }
    if present == .claude, case .sse = server.claude?.transport {
        return .onlyIn(.claude, syncable: false)
    }
    return .onlyIn(present, syncable: true)
}

struct OrcButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }

    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        OrcButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

extension ButtonStyle where Self == OrcButtonStyle {
    static func orc(_ kind: OrcButtonStyle.Kind = .secondary, compact: Bool = false) -> OrcButtonStyle {
        OrcButtonStyle(kind: kind, compact: compact)
    }
}

private struct OrcButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: OrcButtonStyle.Kind
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 6 : (compact ? 10 : 14))
            .padding(.vertical, compact ? 3 : 6)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovering = $0 }
    }

    private var active: Bool { hovering && isEnabled }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.bg
        case .secondary: return active ? Theme.accent : Theme.text
        case .ghost: return active ? Theme.accent : Theme.mutedStrong
        case .destructive: return Theme.redText
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return Theme.accent
        case .secondary: return Theme.panel
        case .ghost: return active ? Theme.accentSoft : .clear
        case .destructive: return active ? Theme.red.opacity(Theme.tintFill) : Theme.panel
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return active ? Theme.accent : Theme.border
        case .ghost: return .clear
        case .destructive: return active ? Theme.red.opacity(Theme.tintBorder) : Theme.border
        }
    }
}

/// Icon-only button: always labelled for VoiceOver and given a tooltip.
struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.orc(.ghost, compact: true))
        .accessibilityLabel(label)
        .help(label)
    }
}

struct OrcTextField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var mono = false
    var invalid = false
    /// Grows up to eight lines as the text wraps or gains line breaks.
    var multiline = false

    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(placeholder).foregroundColor(Theme.muted),
                  axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 8 : 1)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono() : Theme.body)
            .foregroundStyle(Theme.heading)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.bg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.panelRadius)
                    .strokeBorder(invalid ? Theme.red : (focused ? Theme.green : Theme.border), lineWidth: 1)
            )
    }
}

struct OrcTextEditor: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var invalid = false

    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono())
            .foregroundStyle(Theme.heading)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .accessibilityLabel(label)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 58, maxHeight: 96)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.mono())
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.bg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.panelRadius)
                    .strokeBorder(invalid ? Theme.red : (focused ? Theme.green : Theme.border), lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(0.4)
            .foregroundStyle(Theme.mutedStrong)
            .accessibilityAddTraits(.isHeader)
    }
}

struct FieldMessage: View {
    let text: String
    var tone: Tone = .red

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tone == .neutral ? Theme.mutedStrong : tone.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Tinted, bordered message strip. The leading word names the state.
struct Banner: View {
    let title: String
    let message: String
    let tone: Tone
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.textColor)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                IconButton(systemImage: "xmark", label: "Dismiss \(title.lowercased()) message", action: onDismiss)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(tone.hue.opacity(Theme.tintFill)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(tone.hue.opacity(Theme.tintBorder), lineWidth: 1))
    }
}

/// The model's latest action outcome: an error or a notice, both dismissible.
struct StatusBanners: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            if let error = model.lastError {
                Banner(title: "Error", message: error, tone: .red) { model.lastError = nil }
            }
            if let notice = model.lastNotice {
                Banner(title: "Done", message: notice, tone: .green) { model.lastNotice = nil }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.lastError)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.lastNotice)
    }

    static func hasContent(_ model: AppModel) -> Bool {
        model.lastError != nil || model.lastNotice != nil
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}

extension View {
    func orcPanel(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

func revealInFinder(_ path: String) {
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
    }
}

func abbreviate(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

/// "Claude", "Claude and Codex": stable order, text for notices and dialogs.
func clientList(_ clients: some Collection<MCPClient>) -> String {
    let names = MCPClient.allCases.filter(clients.contains).map(\.displayName)
    switch names.count {
    case 0: return "no client"
    case 1: return names[0]
    default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

struct CodeBlock: View {
    let text: String
    var copyLabel: String? = "Copy"

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.heading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .padding(.trailing, copyLabel == nil ? 0 : 64)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.code))
            .overlay(alignment: .topTrailing) {
                if let copyLabel {
                    CopyButton(text: text, label: copyLabel).padding(4)
                }
            }
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"

    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : label) {
            copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .buttonStyle(.orc(.secondary, compact: true))
        .help("Copy to the clipboard")
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct InspectorStatusChip: View {
    @ObservedObject var inspector: InspectorModel

    var body: some View {
        Chip(text: inspector.statusText, tone: inspector.statusTone)
            .accessibilityLabel("Connection: \(inspector.statusText)")
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.title)
                .foregroundStyle(Theme.heading)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.orc(.primary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orcPanel(padding: 16)
    }
}
