import SwiftUI
import KallilexKit

/// Prompt mode's non-Scratchpad content (ios-18, PLAN-keyboard.md §5): a
/// 44 pt chips row — the existing `PromptChipsBar`, replaced by
/// `StatusBanner` only while a run is in flight, for a pending consent
/// request, or for an error — and a 44 pt action row: 🌐 (only if
/// `showsGlobe`), ⌨ (`keyboard.mode.keys`), a hidden 🎤 placeholder
/// (ios-21), the active provider's `KeyboardCompactPrivacyBadge`, and a
/// hidden Insert placeholder (ios-19).
///
/// A successful run (`.result`) is treated like `.idle` for this row: the
/// chips come back immediately rather than getting stuck behind a
/// permanent "Fertig" banner with no way back (ios-18 bugfix). The
/// not-configured state still shows `StatusBanner`'s own card, since there
/// is nothing the chips could usefully run against.
///
/// The "Custom…" chip is hidden (`onCustomTapped: nil`): a typed custom
/// instruction from the keyboard isn't in 1.0.0's scope (PLAN-keyboard.md
/// §3 "Not in 1.0.0").
public struct KeyboardPromptPanel: View {
    private let prompts: [CustomPrompt]
    private let state: EditorSession.State
    private let runningLabel: String
    private let inlineNote: String?
    /// `true` while the Scratchpad is empty or whitespace-only — disables
    /// every chip (ios-18 bugfix: a prompt can't usefully run against no
    /// text). Mirrors `EditorSession.canCopy`'s own "nothing to act on"
    /// check, trimmed so whitespace-only text counts as empty too.
    private let isScratchpadEmpty: Bool
    private let activeProfile: ProviderProfile?
    private let showsGlobe: Bool
    private let onSelectPrompt: (CustomPrompt) -> Void
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConsentAllow: () -> Void
    private let onConsentDecline: () -> Void
    private let onDismissError: () -> Void
    private let onGlobe: () -> Void
    private let onShowKeys: () -> Void

    public init(
        prompts: [CustomPrompt],
        state: EditorSession.State,
        runningLabel: String,
        inlineNote: String?,
        isScratchpadEmpty: Bool,
        activeProfile: ProviderProfile?,
        showsGlobe: Bool,
        onSelectPrompt: @escaping (CustomPrompt) -> Void,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onConsentAllow: @escaping () -> Void,
        onConsentDecline: @escaping () -> Void,
        onDismissError: @escaping () -> Void,
        onGlobe: @escaping () -> Void,
        onShowKeys: @escaping () -> Void
    ) {
        self.prompts = prompts
        self.state = state
        self.runningLabel = runningLabel
        self.inlineNote = inlineNote
        self.isScratchpadEmpty = isScratchpadEmpty
        self.activeProfile = activeProfile
        self.showsGlobe = showsGlobe
        self.onSelectPrompt = onSelectPrompt
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onConsentAllow = onConsentAllow
        self.onConsentDecline = onConsentDecline
        self.onDismissError = onDismissError
        self.onGlobe = onGlobe
        self.onShowKeys = onShowKeys
    }

    public var body: some View {
        VStack(spacing: 0) {
            chipsRow.frame(height: KeyboardPromptMetrics.chipsHeight)
            actionRow.frame(height: KeyboardPromptMetrics.actionHeight)
        }
    }

    /// `.idle`/`.result` (with no `inlineNote`) show the chips;
    /// `.running`/`.failed`/`.consentRequired`/`.notConfigured` (or an
    /// idle state with a note, e.g. right after declining consent) show
    /// `StatusBanner` instead.
    @ViewBuilder
    private var chipsRow: some View {
        if (state == .idle || state == .result), inlineNote == nil {
            PromptChipsBar(
                prompts: prompts,
                isRunning: isScratchpadEmpty,
                onSelectPrompt: onSelectPrompt,
                onCustomTapped: nil
            )
        } else {
            StatusBanner(
                state: state,
                runningLabel: runningLabel,
                inlineNote: inlineNote,
                onCancel: onCancel,
                onRetry: onRetry,
                onConsentAllow: onConsentAllow,
                onConsentDecline: onConsentDecline,
                onDismissError: onDismissError
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            if showsGlobe {
                Button(action: onGlobe) {
                    Text("🌐").font(.title2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(String(
                    localized: "keyboard.key.globe",
                    defaultValue: "next keyboard",
                    bundle: .module
                ))
                .accessibilityIdentifier("keyboard.key.globe")
            }

            Button(action: onShowKeys) {
                Text("⌨").font(.title2)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(String(localized: "keyboard.showKeys", defaultValue: "Show keys", bundle: .module))
            .accessibilityIdentifier("keyboard.mode.keys")

            // ios-21: dictation. Hidden placeholder so the row's layout
            // doesn't shift once it's added.
            Text("🎤").font(.title2).opacity(0).accessibilityHidden(true)

            Spacer()

            if let activeProfile {
                KeyboardCompactPrivacyBadge(profile: activeProfile)
            }

            // ios-19: Insert. Hidden placeholder, same reason as above.
            Text(String(localized: "keyboard.insert.placeholder", defaultValue: "Insert", bundle: .module))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
    }
}
