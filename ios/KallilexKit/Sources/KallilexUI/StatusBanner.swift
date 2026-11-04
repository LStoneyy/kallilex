import SwiftUI
import KallilexKit

/// Renders `EditorSession.state` (ios-08): the running spinner + Cancel,
/// the result's brief "Done", a failure with its message and Retry, the
/// not-configured card, and the consent card (`ConsentView`). Takes a
/// `(EditorSession.State, String?)` pair plus plain closures rather than the
/// session itself, so it previews/tests independently of `EditorSession`.
///
/// `onOpenProviders` is `nil` in the Share Extension, which has no
/// navigation to the container app's Providers tab — in that case the
/// not-configured card shows title/message only, no action button.
public struct StatusBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: EditorSession.State
    /// The running prompt's label (or the localized "Custom instruction") —
    /// `EditorSession.lastLabel` at the call site. Only read while
    /// `state` is `.running`.
    private let runningLabel: String
    private let inlineNote: String?
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConsentAllow: () -> Void
    private let onConsentDecline: () -> Void
    private let onOpenProviders: (() -> Void)?

    public init(
        state: EditorSession.State,
        runningLabel: String,
        inlineNote: String?,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onConsentAllow: @escaping () -> Void,
        onConsentDecline: @escaping () -> Void,
        onOpenProviders: (() -> Void)? = nil
    ) {
        self.state = state
        self.runningLabel = runningLabel
        self.inlineNote = inlineNote
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onConsentAllow = onConsentAllow
        self.onConsentDecline = onConsentDecline
        self.onOpenProviders = onOpenProviders
    }

    public var body: some View {
        content
            .transition(reduceMotion ? .identity : .opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            if let inlineNote {
                Text(inlineNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("editor.inlineNote")
            }

        case .running:
            HStack(spacing: 12) {
                ProgressView()
                Text(runningText)
                    .accessibilityLabel(runningText)
                Spacer()
                Button(String(localized: "editor.cancel", defaultValue: "Cancel", bundle: .module)) {
                    onCancel()
                }
                .accessibilityIdentifier("editor.statusBanner.cancel")
            }
            .padding()
            .background(Color(.secondarySystemBackground))

        case .result:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "editor.done", defaultValue: "Done", bundle: .module))
            }
            .accessibilityElement(children: .combine)
            .padding()
            .background(Color(.secondarySystemBackground))

        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error.localizedDescription)
                }
                Button(String(localized: "editor.retry", defaultValue: "Retry", bundle: .module)) {
                    onRetry()
                }
                .accessibilityIdentifier("editor.statusBanner.retry")
            }
            .padding()
            .background(Color(.secondarySystemBackground))

        case .notConfigured:
            VStack(alignment: .leading, spacing: 12) {
                Text(String(
                    localized: "editor.notConfigured.title",
                    defaultValue: "No provider configured",
                    bundle: .module
                ))
                .font(.headline)
                Text(notConfiguredMessage)
                    .foregroundStyle(.secondary)
                if let onOpenProviders {
                    Button(String(
                        localized: "editor.notConfigured.action",
                        defaultValue: "Open Providers",
                        bundle: .module
                    )) {
                        onOpenProviders()
                    }
                    .accessibilityIdentifier("editor.notConfigured.openProviders")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))

        case .consentRequired(let profile):
            ConsentView(
                profileName: profile.name,
                host: consentHost(for: profile) ?? "",
                onAllow: { onConsentAllow() },
                onNotNow: onConsentDecline
            )
        }
    }

    private var runningText: String {
        String(
            localized: "editor.running",
            defaultValue: "Rewriting with \(runningLabel)…",
            bundle: .module
        )
    }

    /// The `.notConfigured` body text. When `onOpenProviders` is `nil` —
    /// the Share Extension, which has no Providers tab to navigate to —
    /// this points the user at the container app instead of the button
    /// that isn't shown.
    private var notConfiguredMessage: String {
        if onOpenProviders != nil {
            return String(
                localized: "editor.notConfigured.message",
                defaultValue: "Set up an AI provider in Kallilex to run prompts.",
                bundle: .module
            )
        }
        return String(
            localized: "extension.notConfigured.message",
            defaultValue: "Open the Kallilex app to set up a provider.",
            bundle: .module
        )
    }
}

#Preview {
    StatusBanner(
        state: .running(.prompt(instruction: "Fix grammar and spelling.")),
        runningLabel: "Fix grammar",
        inlineNote: nil,
        onCancel: {},
        onRetry: {},
        onConsentAllow: {},
        onConsentDecline: {}
    )
}
