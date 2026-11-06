import SwiftUI

/// A `HelpfulError` in full: what went wrong, what to try, the technical
/// details on request, and buttons for the fixes the error points at.
struct ErrorCallout: View {
    let error: HelpfulError
    /// Shown whenever given; the caller knows whether sign-in applies.
    var onSignIn: (() -> Void)?
    var onOpenEnvironment: (() -> Void)?
    var onShowLogs: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Error")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tone.red.textColor)
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let onDismiss {
                    IconButton(systemImage: "xmark", label: "Dismiss error", action: onDismiss)
                }
            }
            Text(error.message)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !error.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(error.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Theme.mutedStrong).accessibilityHidden(true)
                            Text(suggestion)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let details = error.details, !details.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    CodeBlock(text: details, copyLabel: "Copy details")
                        .padding(.top, 4)
                } label: {
                    Text("Technical details")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.mutedStrong)
                }
            }
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Tone.red.hue.opacity(Theme.tintFill)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Tone.red.hue.opacity(Theme.tintBorder), lineWidth: 1))
    }

    @ViewBuilder
    private var actions: some View {
        let signIn = onSignIn
        let environment = error.offersEnvironment ? onOpenEnvironment : nil
        if signIn != nil || environment != nil || onShowLogs != nil || onRetry != nil {
            HStack(spacing: 6) {
                if let signIn {
                    Button("Sign in", action: signIn).buttonStyle(.orc(.primary, compact: true))
                }
                if let environment {
                    Button("Open Environment", action: environment).buttonStyle(.orc(.secondary, compact: true))
                }
                if let onRetry {
                    Button("Try again", action: onRetry).buttonStyle(.orc(.secondary, compact: true))
                }
                if let onShowLogs {
                    Button("Show Logs", action: onShowLogs).buttonStyle(.orc(.secondary, compact: true))
                }
            }
        }
    }
}
