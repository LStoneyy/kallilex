import SwiftUI
import KallilexKit

/// Keyboard-only stand-in for `StatusBanner` inside `KeyboardPromptPanel`'s
/// fixed 44 pt chips row (ios-18 bugfix): `StatusBanner`'s `.failed`/
/// `.notConfigured` cases are 100+ pt card layouts built for the app's
/// full `EditorScreen`; rendered inside the keyboard's fixed 44 pt row
/// they overflowed into the action row below, with buttons that weren't
/// reliably tappable. This renders the same `EditorSession.State` cases —
/// plus the idle/result "inline note" case `StatusBanner` also handles —
/// as a single line, exactly `KeyboardPromptMetrics.chipsHeight` tall,
/// reusing `StatusBanner`'s own strings and callbacks rather than
/// introducing new behavior. `StatusBanner`/`EditorScreen` themselves are
/// untouched: the app keeps its full-size cards.
///
/// `.consentRequired` never reaches this view (ios-19 part B):
/// `KeyboardPromptPanel.isExpanded` catches it first and renders the
/// proper compact `KeyboardConsentView` instead, inside the expanded
/// panel. The `.consentRequired` case below is therefore unreachable in
/// practice — kept only so this `switch` stays exhaustive over
/// `EditorSession.State` without an `@unknown default`.
public struct KeyboardStatusRow: View {
    private let state: EditorSession.State
    private let runningLabel: String
    private let inlineNote: String?
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onDismissError: () -> Void
    /// Clears `inlineNote` (e.g. after consent was declined) so the chips
    /// row comes back without needing a new run — `StatusBanner`'s own
    /// idle/note case has no such affordance, since the app's
    /// `EditorScreen` always keeps the chips visible alongside it.
    private let onDismissNote: () -> Void

    public init(
        state: EditorSession.State,
        runningLabel: String,
        inlineNote: String?,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onDismissError: @escaping () -> Void,
        onDismissNote: @escaping () -> Void
    ) {
        self.state = state
        self.runningLabel = runningLabel
        self.inlineNote = inlineNote
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onDismissError = onDismissError
        self.onDismissNote = onDismissNote
    }

    public var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(height: KeyboardPromptMetrics.chipsHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .running:
            runningRow
        case .failed(let error):
            failedRow(error)
        case .notConfigured:
            notConfiguredRow
        case .consentRequired:
            EmptyView()
        case .idle, .result:
            if let inlineNote {
                noteRow(inlineNote)
            }
        }
    }

    private var runningRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(runningText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(runningText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "editor.cancel", defaultValue: "Cancel", bundle: .module)) {
                onCancel()
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("keyboard.status.cancel")
        }
    }

    private func failedRow(_ error: ProviderError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(error.localizedDescription)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(error.localizedDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "editor.retry", defaultValue: "Retry", bundle: .module)) {
                onRetry()
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("keyboard.status.retry")
            Button {
                onDismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(String(
                localized: "editor.statusBanner.dismiss",
                defaultValue: "Dismiss error",
                bundle: .module
            ))
            .accessibilityIdentifier("keyboard.status.dismiss")
        }
    }

    private var notConfiguredRow: some View {
        Text(String(
            localized: "keyboard.status.notConfigured",
            defaultValue: "Set up a provider in the Kallilex app.",
            bundle: .module
        ))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ note: String) -> some View {
        HStack(spacing: 8) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                // The "doesn't share the selection" hint (ios-19 part B)
                // is a full sentence, not a short word like "Copied" —
                // two lines plus a modest shrink keeps it inside this
                // fixed 44 pt row instead of truncating to nothing useful.
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("editor.inlineNote")
            Button {
                onDismissNote()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(String(
                localized: "keyboard.status.dismissNote",
                defaultValue: "Dismiss",
                bundle: .module
            ))
            .accessibilityIdentifier("keyboard.status.dismiss")
        }
    }

    private var runningText: String {
        String(
            localized: "editor.running",
            defaultValue: "Rewriting with \(runningLabel)…",
            bundle: .module
        )
    }
}

#Preview("Running") {
    KeyboardStatusRow(
        state: .running(.prompt(instruction: "Fix grammar and spelling.")),
        runningLabel: "Fix grammar",
        inlineNote: nil,
        onCancel: {},
        onRetry: {},
        onDismissError: {},
        onDismissNote: {}
    )
}

#Preview("Failed") {
    KeyboardStatusRow(
        state: .failed(.unreachable("example.com")),
        runningLabel: "",
        inlineNote: nil,
        onCancel: {},
        onRetry: {},
        onDismissError: {},
        onDismissNote: {}
    )
}

#Preview("Not configured") {
    KeyboardStatusRow(
        state: .notConfigured,
        runningLabel: "",
        inlineNote: nil,
        onCancel: {},
        onRetry: {},
        onDismissError: {},
        onDismissNote: {}
    )
}
