import SwiftUI
import KallilexKit
import KallilexKeyboardCore

/// The single SwiftUI root hosted by `KallilexKeyboardController`'s one
/// `UIHostingController` (ios-18, PLAN-keyboard.md §5/§10.4): prompt
/// mode's `KeyboardPromptPanel` plus a compact `EditorToolbar` row above
/// it (Undo/Retry/Copy, "at the Scratchpad's bottom edge" visually, since
/// this sits directly below the UIKit Scratchpad text view and above the
/// chips), or keys mode's `KeyboardKeysToolbar` — switching on
/// `model.mode`. The UIKit key grid and the Scratchpad text view
/// themselves live outside this hosting controller, laid out by the
/// controller directly (D5: UIKit keys, SwiftUI for the prompt/status
/// parts).
public struct KeyboardRootView: View {
    private let model: KeyboardModel
    private let showsGlobe: Bool
    private let onGlobe: () -> Void

    public init(model: KeyboardModel, showsGlobe: Bool, onGlobe: @escaping () -> Void) {
        self.model = model
        self.showsGlobe = showsGlobe
        self.onGlobe = onGlobe
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
        VStack(spacing: 0) {
            EditorToolbar(
                canUndo: model.session.canUndo,
                canRetry: model.session.canRetry,
                canCopy: model.session.canCopy,
                onUndo: { model.undo() },
                onRetry: { model.retry() },
                onCopy: { model.session.copy() }
            )
            .frame(height: 32)
            .padding(.horizontal, 12)

            KeyboardPromptPanel(
                prompts: model.settings?.prompts ?? [],
                state: model.session.state,
                runningLabel: model.session.lastLabel,
                inlineNote: model.session.inlineNote,
                activeProfile: activeProfile,
                showsGlobe: showsGlobe,
                onSelectPrompt: { prompt in
                    model.run(.prompt(instruction: prompt.instruction), label: prompt.label)
                },
                onCancel: { model.session.cancel() },
                onRetry: { model.retry() },
                onConsentAllow: { model.grantConsentAndRetry() },
                onConsentDecline: { model.declineConsent() },
                onGlobe: onGlobe,
                onShowKeys: { model.mode = .keys }
            )
        }
    }

    private var activeProfile: ProviderProfile? {
        guard let settings = model.settings, let activeID = settings.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == activeID && $0.enabled }
    }
}
