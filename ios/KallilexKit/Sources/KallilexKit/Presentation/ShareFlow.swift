import Foundation

/// What the Share Extension's root view should render (ios-09, PLAN.md
/// §8.3), decided from input extraction and settings loading alone, before
/// `EditorSession.State` ever enters the picture. `.editor` covers every
/// other `EditorSession.State` (`.ready`, `.running`, `.result`, `.failed`,
/// `.notConfigured`, `.consentRequired`): those are rendered by the shared
/// `EditorScreen`/`StatusBanner`, not chosen here.
public enum ShareContentState: Equatable, Sendable {
    case loadingInput
    case emptyInput
    case settingsError
    case editor
}

/// UI-free decisions the Share Extension makes from its loaded settings and
/// extracted input (ios-09, PLAN.md §4.2/§4.3/§8.3): which content state to
/// show, whether to auto-run the first saved prompt once the sheet opens,
/// and whether a freshly produced result should auto-copy and close.
///
/// A `final class`, not a value type like `OnboardingFlow`: auto-run must
/// fire **at most once per launch**, even though `shouldAutoRunFirstPrompt`
/// may be asked many times as SwiftUI re-renders the root view while
/// extraction/settings loading is still in flight. That "has this already
/// happened" latch needs to survive across those re-evaluations without the
/// caller re-threading a value type by hand, so it lives behind `consumeAutoRun()`.
@MainActor
public final class ShareFlow {
    public private(set) var hasAutoRun = false

    public init() {}

    /// What the root view should render, given the text extraction has
    /// produced so far (`nil` while still extracting) and whether loading
    /// `AppSettings` failed. A settings failure always wins over an empty
    /// or still-loading `text`: the user can't fix what `InputExtractor`
    /// found, but can open the app to fix a broken settings file.
    public func contentState(text: String?, settingsLoadFailed: Bool) -> ShareContentState {
        if settingsLoadFailed {
            return .settingsError
        }
        guard let text else {
            return .loadingInput
        }
        return text.isEmpty ? .emptyInput : .editor
    }

    /// Whether to run `settings.prompts.first` right after input is
    /// extracted (PLAN.md §4.2's "Run the first prompt automatically"
    /// speed-up): `settings.autoRunFirstPrompt` is on, `text` is non-empty,
    /// there is at least one saved prompt, and this hasn't already
    /// happened this launch. The caller must call `consumeAutoRun()` once
    /// it actually starts that run, so a later state change (e.g. the user
    /// retries, producing a second result) never auto-runs again.
    public func shouldAutoRunFirstPrompt(settings: AppSettings, text: String) -> Bool {
        guard !hasAutoRun,
              settings.autoRunFirstPrompt,
              !text.isEmpty,
              !settings.prompts.isEmpty else {
            return false
        }
        return true
    }

    /// Marks the one-time auto-run as having happened, so
    /// `shouldAutoRunFirstPrompt` never returns `true` again this launch.
    public func consumeAutoRun() {
        hasAutoRun = true
    }

    /// Whether a freshly produced result should auto-copy and close the
    /// sheet (PLAN.md §4.2's "Copy and close automatically" speed-up). The
    /// caller is responsible for only asking this while `EditorSession
    /// .state` is actually `.result`.
    public func shouldAutoCopyResult(settings: AppSettings) -> Bool {
        settings.autoCopyResult
    }
}
