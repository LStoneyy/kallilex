import SwiftUI
import KallilexKit

/// Prompt mode's non-Scratchpad content (ios-18/ios-19, PLAN-keyboard.md
/// §5/§7): a 44 pt chips row — the "Take selection" chip (ios-19, when
/// `pendingTakeSelection` is non-`nil`) followed by the existing
/// `PromptChipsBar`, replaced by `KeyboardStatusRow` only while a run is in
/// flight, for a pending consent request, or for an error — and a 44 pt
/// action row: 🌐 (only if `showsGlobe`), ⌨ (`keyboard.mode.keys`), a
/// hidden 🎤 placeholder (ios-21), the active provider's
/// `KeyboardCompactPrivacyBadge`, and Insert/"Inserted · Undo" (ios-19,
/// `keyboard.insert`/`keyboard.undoInsert`), whichever currently applies.
///
/// `KeyboardStatusRow`, not `StatusBanner` itself, renders every non-chips
/// state: `StatusBanner`'s `.failed`/`.notConfigured` cards are 100+ pt
/// tall — built for the app's full `EditorScreen` — and would overflow
/// this 44 pt row into the action row below (ios-18 bugfix). The app's
/// own `StatusBanner`/`EditorScreen` are unaffected.
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
    /// Non-`nil` while the "Take selection" chip (ios-19) should be shown —
    /// see `KeyboardModel.pendingTakeSelection`. Its text itself isn't
    /// displayed; only its presence matters here.
    private let pendingTakeSelection: String?
    private let canInsert: Bool
    private let insertLabel: String
    private let canUndoInsert: Bool
    /// `true` while the Full Access card (ios-19 part B) should replace
    /// the chips/consent content — see `KeyboardModel.showsFullAccessCard`.
    private let showsFullAccessCard: Bool
    private let onSelectPrompt: (CustomPrompt) -> Void
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onConsentAllow: () -> Void
    private let onConsentDecline: () -> Void
    private let onDismissError: () -> Void
    private let onDismissNote: () -> Void
    private let onGlobe: () -> Void
    private let onShowKeys: () -> Void
    private let onTakeSelection: () -> Void
    private let onInsert: () -> Void
    private let onUndoInsert: () -> Void
    private let onOpenSettings: () -> Void
    private let onDismissFullAccessCard: () -> Void

    public init(
        prompts: [CustomPrompt],
        state: EditorSession.State,
        runningLabel: String,
        inlineNote: String?,
        isScratchpadEmpty: Bool,
        activeProfile: ProviderProfile?,
        showsGlobe: Bool,
        pendingTakeSelection: String?,
        canInsert: Bool,
        insertLabel: String,
        canUndoInsert: Bool,
        showsFullAccessCard: Bool,
        onSelectPrompt: @escaping (CustomPrompt) -> Void,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onConsentAllow: @escaping () -> Void,
        onConsentDecline: @escaping () -> Void,
        onDismissError: @escaping () -> Void,
        onDismissNote: @escaping () -> Void,
        onGlobe: @escaping () -> Void,
        onShowKeys: @escaping () -> Void,
        onTakeSelection: @escaping () -> Void,
        onInsert: @escaping () -> Void,
        onUndoInsert: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDismissFullAccessCard: @escaping () -> Void
    ) {
        self.prompts = prompts
        self.state = state
        self.runningLabel = runningLabel
        self.inlineNote = inlineNote
        self.isScratchpadEmpty = isScratchpadEmpty
        self.activeProfile = activeProfile
        self.showsGlobe = showsGlobe
        self.pendingTakeSelection = pendingTakeSelection
        self.canInsert = canInsert
        self.insertLabel = insertLabel
        self.canUndoInsert = canUndoInsert
        self.showsFullAccessCard = showsFullAccessCard
        self.onSelectPrompt = onSelectPrompt
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onConsentAllow = onConsentAllow
        self.onConsentDecline = onConsentDecline
        self.onDismissError = onDismissError
        self.onDismissNote = onDismissNote
        self.onGlobe = onGlobe
        self.onShowKeys = onShowKeys
        self.onTakeSelection = onTakeSelection
        self.onInsert = onInsert
        self.onUndoInsert = onUndoInsert
        self.onOpenSettings = onOpenSettings
        self.onDismissFullAccessCard = onDismissFullAccessCard
    }

    /// `true` while the Full Access card or the compact consent view
    /// should take over the panel's full height instead of the fixed
    /// 44 pt chips row — mirrors `KeyboardModel.isPanelExpanded`'s own
    /// `mode == .prompts && (…)` check (this view is only ever shown in
    /// prompt mode to begin with, so only the card/consent half applies
    /// here).
    private var isExpanded: Bool {
        showsFullAccessCard || isConsentRequired
    }

    private var isConsentRequired: Bool {
        if case .consentRequired = state { return true }
        return false
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                chipsRow.frame(height: KeyboardPromptMetrics.chipsHeight)
            }
            actionRow.frame(height: KeyboardPromptMetrics.actionHeight)
        }
    }

    /// The expanded panel's content (ios-19 part B, "Expanded panel"): the
    /// Full Access card takes priority — a card shown as the post-run
    /// fallback for an error that also happens to need consent would
    /// otherwise have nowhere to resolve the consent request from (Allow
    /// would just fail again without Full Access anyway).
    @ViewBuilder
    private var expandedContent: some View {
        if showsFullAccessCard {
            KeyboardFullAccessCard(onOpenSettings: onOpenSettings, onDismiss: onDismissFullAccessCard)
        } else if case .consentRequired(let profile) = state {
            KeyboardConsentView(profile: profile, onAllow: onConsentAllow, onDecline: onConsentDecline)
        }
    }

    /// `.idle`/`.result` (with no `inlineNote`) show the chips;
    /// `.running`/`.failed`/`.notConfigured` (or an idle state with a
    /// note, e.g. right after declining consent) show `KeyboardStatusRow`
    /// instead. `.consentRequired` never reaches this view — `isExpanded`
    /// catches it first.
    @ViewBuilder
    private var chipsRow: some View {
        if (state == .idle || state == .result), inlineNote == nil {
            HStack(spacing: 8) {
                if pendingTakeSelection != nil {
                    TakeSelectionChip(onTap: onTakeSelection)
                        .padding(.leading, 12)
                }
                PromptChipsBar(
                    prompts: prompts,
                    isRunning: isScratchpadEmpty,
                    onSelectPrompt: onSelectPrompt,
                    onCustomTapped: nil
                )
            }
        } else {
            KeyboardStatusRow(
                state: state,
                runningLabel: runningLabel,
                inlineNote: inlineNote,
                onCancel: onCancel,
                onRetry: onRetry,
                onDismissError: onDismissError,
                onDismissNote: onDismissNote
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

            // ios-19: Insert / "Inserted · Undo" — whichever is current
            // replaces the other in place, so the row never grows past its
            // fixed 44 pt height.
            if canUndoInsert {
                Button(action: onUndoInsert) {
                    Text(String(localized: "keyboard.undoInsert", defaultValue: "Inserted · Undo", bundle: .module))
                        .lineLimit(1)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("keyboard.undoInsert")
            } else {
                Button(action: onInsert) {
                    Text(insertLabel)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInsert)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("keyboard.insert")
            }
        }
        .padding(.horizontal, 12)
    }
}

/// The "Take selection" chip (ios-19 spec): the first item of the chips
/// row, before the prompt chips, shown while a non-empty host selection
/// doesn't qualify for the automatic take-over (`KeyboardModel
/// .pendingTakeSelection`). `.borderedProminent` plus an icon, rather than
/// `PromptChip`'s plain `.bordered` capsule, so it reads as visually
/// distinct from the prompt chips it sits next to, per the spec.
private struct TakeSelectionChip: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label(
                String(localized: "keyboard.takeSelection", defaultValue: "Take selection", bundle: .module),
                systemImage: "text.cursor"
            )
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("keyboard.takeSelection")
        .accessibilityHint(String(
            localized: "keyboard.takeSelection.hint",
            defaultValue: "Replaces the Scratchpad with the app's current selection.",
            bundle: .module
        ))
    }
}
