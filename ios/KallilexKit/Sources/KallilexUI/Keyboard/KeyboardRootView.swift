import SwiftUI
import KallilexKit
import KallilexKeyboardCore

/// The single SwiftUI root hosted by `KallilexKeyboardController`'s one
/// `UIHostingController` (ios-18, PLAN-keyboard.md §5/§10.4): prompt
/// mode's `KeyboardPromptPanel` plus a compact `KeyboardCompactToolbar`
/// row above it (Undo/Retry/Copy/Show original, "at the Scratchpad's
/// bottom edge" visually, since this sits directly below the UIKit
/// Scratchpad text view and above the chips), or keys mode's
/// `KeyboardKeysToolbar` — switching on `model.mode`. The UIKit key grid
/// and the Scratchpad text view themselves live outside this hosting
/// controller, laid out by the controller directly (D5: UIKit keys,
/// SwiftUI for the prompt/status parts).
public struct KeyboardRootView: View {
    private let model: KeyboardModel
    private let showsGlobe: Bool
    private let onGlobe: () -> Void
    /// Opens iOS Settings through `KallilexKeyboardController
    /// .openSystemSettings()` (ios-19 part B) — the Full Access card's
    /// Settings button.
    private let onOpenSettings: () -> Void

    /// Shows a brief, non-blocking "Fertig" overlay over the chips row
    /// right after a successful run (ios-18 bugfix item 4) — the
    /// VoiceOver announcement itself is already posted by
    /// `EditorSession.handleOutcome` (`editor.done.announcement`); this is
    /// purely a sighted-user visual cue, since the chips row no longer
    /// shows any "Done" state of its own once a result is treated like
    /// idle.
    @State private var showsDoneOverlay = false
    /// Bumped every time a new "Fertig" overlay is shown, so a stale hide
    /// `Task` from an earlier `.result` can't hide a later one's overlay —
    /// e.g. a second run completing (and re-showing the overlay) while the
    /// first run's 1.2 s timer is still pending would otherwise hide the
    /// second overlay immediately instead of after its own 1.2 s.
    @State private var doneGeneration = 0

    public init(
        model: KeyboardModel,
        showsGlobe: Bool,
        onGlobe: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.model = model
        self.showsGlobe = showsGlobe
        self.onGlobe = onGlobe
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        switch model.mode {
        case .prompts:
            promptsContent
        case .keys:
            KeyboardKeysToolbar(
                target: Binding(get: { model.target }, set: { model.target = $0 }),
                onShowPrompts: { model.mode = .prompts }
            )
        }
    }

    private var promptsContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                KeyboardCompactToolbar(
                    canUndo: model.session.canUndo,
                    canRetry: model.session.canRetry,
                    canCopy: model.session.canCopy,
                    showsShowOriginal: model.session.state == .result,
                    isShowingOriginal: model.session.showingOriginal,
                    onUndo: { model.undo() },
                    onRetry: { model.retry() },
                    onCopy: { model.copy() },
                    onToggleShowOriginal: { model.session.showingOriginal.toggle() }
                )
                .frame(height: KeyboardPromptMetrics.toolbarHeight)

                KeyboardPromptPanel(
                    prompts: model.settings?.prompts ?? [],
                    state: model.session.state,
                    runningLabel: model.session.lastLabel,
                    inlineNote: model.session.inlineNote,
                    isScratchpadEmpty: isScratchpadEmpty,
                    activeProfile: model.activeProfile,
                    showsGlobe: showsGlobe,
                    pendingTakeSelection: model.pendingTakeSelection,
                    canInsert: model.canInsert,
                    insertLabel: model.insertLabel,
                    canUndoInsert: model.canUndoInsert,
                    showsFullAccessCard: model.showsFullAccessCard,
                    onSelectPrompt: { prompt in
                        model.run(.prompt(instruction: prompt.instruction), label: prompt.label)
                    },
                    onCancel: { model.session.cancel() },
                    onRetry: { model.retry() },
                    onConsentAllow: { model.grantConsentAndRetry() },
                    onConsentDecline: { model.declineConsent() },
                    onDismissError: { model.session.cancel() },
                    onDismissNote: { model.session.inlineNote = nil },
                    onGlobe: onGlobe,
                    onShowKeys: { model.showKeys() },
                    onTakeSelection: { model.takeSelectionFromChip() },
                    onInsert: { model.insert() },
                    onUndoInsert: { model.undoInsert() },
                    onOpenSettings: onOpenSettings,
                    onDismissFullAccessCard: { model.showsFullAccessCard = false }
                )
            }

            if showsDoneOverlay {
                doneOverlay
            }
        }
        .onChange(of: model.session.state) { _, newState in
            guard newState == .result else { return }
            doneGeneration += 1
            let generation = doneGeneration
            showsDoneOverlay = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard generation == doneGeneration else { return }
                showsDoneOverlay = false
            }
        }
    }

    /// A small pill at the trailing end of the toolbar row, never intercepting
    /// touches (`allowsHitTesting(false)`) and hidden from the
    /// accessibility tree (`accessibilityHidden`) — VoiceOver already got
    /// `editor.done.announcement` from `EditorSession` itself.
    private var doneOverlay: some View {
        Text(String(localized: "editor.done", defaultValue: "Done", bundle: .module))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.green.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
            // Trailing end of the toolbar row, which the leading-aligned
            // icons leave empty, so the pill never covers a control.
            .padding(.top, 4)
            .padding(.trailing, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    private var isScratchpadEmpty: Bool {
        model.session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
