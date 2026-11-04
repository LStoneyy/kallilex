import XCTest

/// XCUITests for the Share Extension's UI (ios-09 spec part B, "Extension
/// integration tests").
///
/// There is no way to drive a real Share Extension from XCUITest, so every
/// test here launches the app with `-uiTestShareHarness` (DEBUG-only,
/// `ShareHarnessView`), which hosts the exact same `ShareHost`/
/// `ShareHostView` the real `ShareViewController` does. Provider/settings
/// setup happens through the real app UI first — `addCustomProvider`
/// (`UITestCase.swift`) and the Settings tab's toggles — then `app
/// .terminate()` and a `resetState: false` relaunch into the harness picks
/// that state back up, mirroring `PromptsUITests.testReorderPromptsPersists`.
final class ShareExtensionUITests: KallilexUITestCase {
    /// Not configured: with no provider at all, running shows the
    /// not-configured card with the extension's own (button-less) copy —
    /// there's nowhere for the Share Extension to navigate to.
    func testNotConfiguredShowsCardWithNoOpenProvidersButton() {
        let app = launchApp(extraArguments: ["-uiTestShareHarness", "-uiTestShareText", "hello"])

        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        app.staticTexts["Open the Kallilex app to set up a provider."].waitAndAssertExists()
        XCTAssertFalse(
            app.buttons["editor.notConfigured.openProviders"].exists,
            "The Share Extension can't navigate anywhere, so this button must not appear"
        )
    }

    /// Empty input: launching the harness with no `-uiTestShareText` shows
    /// the empty-input card.
    ///
    /// `share.emptyInput`'s `.accessibilityElement(children: .combine)`
    /// card doesn't reliably surface as any one of `anyElement`'s
    /// `.buttons`/`.cells`/`.otherElements` candidates, so this matches by
    /// identifier across every element type instead (mirrors
    /// `ScratchpadUITests.waitForDoneStatus`).
    func testEmptyInputShowsTheEmptyInputCard() {
        let app = launchApp(extraArguments: ["-uiTestShareHarness"])

        let emptyInputCard = app.descendants(matching: .any).matching(identifier: "share.emptyInput").firstMatch
        emptyInputCard.waitAndAssertExists(timeout: 10)
    }

    /// Consent inline: a cloud custom provider without consent shows the
    /// consent card inline; tapping Allow runs the prompt and shows the
    /// result, plus the paste hint shown only in the extension's editor.
    func testConsentInlineThenAllowRunsThePrompt() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.addCustomProvider(name: "Cloud Server", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo")

        app.terminate()
        let harness = launchApp(
            resetState: false,
            extraArguments: ["-uiTestShareHarness", "-uiTestStubProvider", "-uiTestShareText", "hello"]
        )

        harness.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        harness.staticTexts["consent.title"].waitAndAssertExists()
        harness.buttons["consent.allow"].tap()

        let editor = harness.textViews["editor.textEditor"]
        editor.waitAndAssertExists(timeout: 10)
        XCTAssertEqual(editor.value as? String, "HELLO")
        XCTAssertTrue(harness.staticTexts["share.pasteHint"].exists, "share.pasteHint should appear once a result is shown")
    }

    /// Auto-run: with "run first prompt automatically" on and a provider
    /// that needs no consent (LAN), the first prompt runs on its own —
    /// without tapping anything — once the harness launches with text.
    func testAutoRunRunsTheFirstPromptWithoutTapping() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")

        enableSetting(app, identifier: "settings.autoRun")

        app.terminate()
        let harness = launchApp(
            resetState: false,
            extraArguments: ["-uiTestShareHarness", "-uiTestStubProvider", "-uiTestShareText", "hello"]
        )

        let editor = harness.textViews["editor.textEditor"]
        editor.waitAndAssertExists(timeout: 10)
        XCTAssertEqual(editor.value as? String, "HELLO", "Auto-run should have produced the uppercased result without any tap")
    }

    /// Auto-copy and close: with both auto-run and auto-copy on, the
    /// result is produced, copied, and the sheet closes on its own —
    /// `shareHarness.outcome` ends up "completed" without any tap.
    func testAutoCopyClosesTheSheetAutomatically() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")

        enableSetting(app, identifier: "settings.autoRun")
        enableSetting(app, identifier: "settings.autoCopy")

        app.terminate()
        let harness = launchApp(
            resetState: false,
            extraArguments: [
                "-uiTestShareHarness", "-uiTestStubProvider", "-uiTestLongCopiedConfirmation", "-uiTestShareText", "hello",
            ]
        )

        let outcome = harness.staticTexts["shareHarness.outcome"]
        outcome.waitAndAssertExists(
            timeout: 15,
            "Auto-copy should have closed the harness (shareHarness.outcome) without any tap"
        )
        XCTAssertEqual(outcome.label, "completed")

        // Skipped: reading `UIPasteboard.general` from the test process
        // itself (as opposed to the app under test writing to it) fails in
        // this Simulator/CI configuration with `PBErrorDomain Code=13
        // "Operation not authorized."` — the same category of Simulator
        // pasteboard unreliability `ScratchpadUITests` already documents
        // for `PasteButton`'s in-app paste gesture, just on the write/read
        // side instead. The "completed" outcome above is still a faithful
        // proxy for auto-copy having run, since `copyAndClose()` always
        // calls `session.copy()` before `onFinish()`.
    }

    /// Manual Copy & Close: with auto-run off, tapping a chip then "Copy &
    /// Close" also ends up "completed".
    func testManualCopyAndCloseEndsCompleted() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")

        app.terminate()
        let harness = launchApp(
            resetState: false,
            extraArguments: [
                "-uiTestShareHarness", "-uiTestStubProvider", "-uiTestLongCopiedConfirmation", "-uiTestShareText", "hello",
            ]
        )

        harness.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()
        let editor = harness.textViews["editor.textEditor"]
        editor.waitAndAssertExists(timeout: 10)
        XCTAssertEqual(editor.value as? String, "HELLO")

        harness.buttons["share.copyAndClose"].waitAndAssertExists().tap()

        let outcome = harness.staticTexts["shareHarness.outcome"]
        outcome.waitAndAssertExists(timeout: 10)
        XCTAssertEqual(outcome.label, "completed")
    }

    /// Close: tapping the close button ends "cancelled".
    func testCloseEndsCancelled() {
        let app = launchApp(extraArguments: ["-uiTestShareHarness", "-uiTestShareText", "hello"])

        app.buttons["share.close"].waitAndAssertExists().tap()

        let outcome = app.staticTexts["shareHarness.outcome"]
        outcome.waitAndAssertExists()
        XCTAssertEqual(outcome.label, "cancelled")
    }

    // MARK: - Helpers

    /// Turns a Settings toggle on (a no-op if it's already on) through the
    /// Settings tab, mirroring `SettingsUITests.testAutoRunAutoCopyTogglesPersist`.
    private func enableSetting(_ app: XCUIApplication, identifier: String) {
        app.tabButton("tab.settings").tap()
        let toggle = app.switches[identifier]
        toggle.waitAndAssertExists()
        if (toggle.value as? String) != "1" {
            toggle.tapSwitch()
        }
        XCTAssertEqual(toggle.value as? String, "1")
    }
}
