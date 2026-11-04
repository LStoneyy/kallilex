import Testing
import KallilexKit

/// Tests for `ShareFlow`. See
/// `issues-ios/spec-ios-09-share-extension.md`.
@MainActor
struct ShareFlowTests {
    private func settings(
        autoRunFirstPrompt: Bool = false,
        autoCopyResult: Bool = false,
        prompts: [CustomPrompt] = [CustomPrompt(id: "p1", label: "Fix grammar", instruction: "Fix grammar.")]
    ) -> AppSettings {
        AppSettings(
            prompts: prompts,
            autoRunFirstPrompt: autoRunFirstPrompt,
            autoCopyResult: autoCopyResult
        )
    }

    // ---- contentState -----------------------------------------------

    @Test func contentStateIsLoadingInputWhileTextIsStillUnknown() {
        let flow = ShareFlow()
        #expect(flow.contentState(text: nil, settingsLoadFailed: false) == .loadingInput)
    }

    @Test func contentStateIsEmptyInputForEmptyExtractedText() {
        let flow = ShareFlow()
        #expect(flow.contentState(text: "", settingsLoadFailed: false) == .emptyInput)
    }

    @Test func contentStateIsEditorForNonEmptyExtractedText() {
        let flow = ShareFlow()
        #expect(flow.contentState(text: "Hello", settingsLoadFailed: false) == .editor)
    }

    @Test func contentStateIsSettingsErrorWhenSettingsFailedToLoadRegardlessOfText() {
        let flow = ShareFlow()
        #expect(flow.contentState(text: "Hello", settingsLoadFailed: true) == .settingsError)
        #expect(flow.contentState(text: nil, settingsLoadFailed: true) == .settingsError)
        #expect(flow.contentState(text: "", settingsLoadFailed: true) == .settingsError)
    }

    // ---- shouldAutoRunFirstPrompt -------------------------------------

    @Test func autoRunFiresWhenEnabledWithTextAndPrompts() {
        let flow = ShareFlow()
        let settings = settings(autoRunFirstPrompt: true)
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Hello") == true)
    }

    @Test func autoRunDoesNotFireWhenDisabled() {
        let flow = ShareFlow()
        let settings = settings(autoRunFirstPrompt: false)
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Hello") == false)
    }

    @Test func autoRunDoesNotFireForEmptyText() {
        let flow = ShareFlow()
        let settings = settings(autoRunFirstPrompt: true)
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "") == false)
    }

    @Test func autoRunDoesNotFireWithoutAnySavedPrompts() {
        let flow = ShareFlow()
        let settings = settings(autoRunFirstPrompt: true, prompts: [])
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Hello") == false)
    }

    @Test func autoRunOnlyFiresOncePerLaunch() {
        let flow = ShareFlow()
        let settings = settings(autoRunFirstPrompt: true)
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Hello") == true)
        flow.consumeAutoRun()
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Hello") == false)
        // A later, different text (e.g. the user edited it) still never
        // auto-runs again this launch.
        #expect(flow.shouldAutoRunFirstPrompt(settings: settings, text: "Something else") == false)
    }

    @Test func hasAutoRunReflectsConsumeAutoRun() {
        let flow = ShareFlow()
        #expect(flow.hasAutoRun == false)
        flow.consumeAutoRun()
        #expect(flow.hasAutoRun == true)
    }

    // ---- shouldAutoCopyResult -----------------------------------------

    @Test func autoCopyResultMirrorsTheSetting() {
        let flow = ShareFlow()
        #expect(flow.shouldAutoCopyResult(settings: settings(autoCopyResult: true)) == true)
        #expect(flow.shouldAutoCopyResult(settings: settings(autoCopyResult: false)) == false)
    }
}
