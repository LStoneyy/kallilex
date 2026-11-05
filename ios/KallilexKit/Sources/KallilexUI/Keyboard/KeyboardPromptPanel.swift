import SwiftUI
import KallilexKit

/// Prompt mode's non-Scratchpad content (ios-18, PLAN-keyboard.md §5): a
/// 44 pt chips row — the existing `PromptChipsBar`, replaced by
/// `StatusBanner` during a run, an error, the not-configured state, or a
/// pending consent request — and a 44 pt action row: 🌐 (only if
/// `showsGlobe`), ⌨ (`keyboard.mode.keys`), a hidden 🎤 placeholder
/// (ios-21), the active provider's `PrivacyBadge`, and a hidden Insert
/// placeholder (ios-19).
///
/// The "Custom…" chip is hidden (`onCustomTapped: nil`): a typed custom
/// instruction from the keyboard isn't in 1.0.0's scope (PLAN-keyboard.md
/// §3 "Not in 1.0.0").
public struct KeyboardPromptPanel: View {
    private let prompts: [CustomPrompt]
    private let state: EditorSession.State
    private let runningLabel: String
    private let inlineNote: String?
    private let activeProfile: ProviderProfile?
    private let showsGlobe: Bool
    private let onSelectPrompt: (CustomPrompt) -> Void
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConsentAllow: () -> Void
    private let onConsentDecline: () -> Void
    private let onGlobe: () -> Void
    private let onShowKeys: () -> Void

    public init(
        prompts: [CustomPrompt],
        state: EditorSession.State,
        runningLabel: String,
        inlineNote: String?,
        activeProfile: ProviderProfile?,
        showsGlobe: Bool,
        onSelectPrompt: @escaping (CustomPrompt) -> Void,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onConsentAllow: @escaping () -> Void,
        onConsentDecline: @escaping () -> Void,
        onGlobe: @escaping () -> Void,
        onShowKeys: @escaping () -> Void
    ) {
        self.prompts = prompts
        self.state = state
        self.runningLabel = runningLabel
        self.inlineNote = inlineNote
        self.activeProfile = activeProfile
        self.showsGlobe = showsGlobe
        self.onSelectPrompt = onSelectPrompt
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onConsentAllow = onConsentAllow
        self.onConsentDecline = onConsentDecline
        self.onGlobe = onGlobe
        self.onShowKeys = onShowKeys
    }

    public var body: some View {
        VStack(spacing: 0) {
            chipsRow.frame(height: 44)
            actionRow.frame(height: 44)
        }
    }

    @ViewBuilder
    private var chipsRow: some View {
        if case .idle = state, inlineNote == nil {
            PromptChipsBar(
                prompts: prompts,
                isRunning: false,
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
                onConsentDecline: onConsentDecline
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
                PrivacyBadge(profile: activeProfile, interactive: false)
            }

            // ios-19: Insert. Hidden placeholder, same reason as above.
            Text(String(localized: "keyboard.insert.placeholder", defaultValue: "Insert", bundle: .module))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
    }
}
