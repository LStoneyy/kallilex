import XCTest
import UIKit

/// XCUITests for the Scratchpad tab (ios-08 spec, "XCUITest" section).
///
/// `PasteButton`'s `onPaste` callback is a well-known no-op in the iOS
/// Simulator (it fires normally on a real device) — confirmed empirically
/// here: tapping it after `UIPasteboard.general.string = "hello"` from the
/// test process never updated the editor, even after a 5s poll, with no
/// system alert in the way. So these tests put text into the editor by
/// typing directly (still exercising the real editor/run/consent/status
/// flow end to end), while still asserting `scratchpad.paste` exists and
/// is tappable, so a real regression there (e.g. a missing identifier)
/// still fails the build.
final class ScratchpadUITests: KallilexUITestCase {
    /// Paste and run: the Paste button is present and tappable; typing
    /// "hello" into the editor and tapping a prompt chip shows the stub
    /// provider's uppercased result and a "Done" status.
    func testPasteAndRunShowsTheUppercasedResult() {
        let app = launchApp(extraArguments: ["-uiTestStubProvider"])
        addLANProviderAndActivate(app)
        app.tabButton("tab.scratchpad").tap()

        app.buttons["scratchpad.paste"].waitAndAssertExists()
        typeIntoEditor(app, text: "hello")

        attachScreenshot(app.screenshot(), name: "scratchpad-idle-with-chips")

        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        waitForDoneStatus(app)
        attachScreenshot(app.screenshot(), name: "scratchpad-result")

        let editor = app.textViews["editor.textEditor"]
        editor.waitAndAssertExists()
        XCTAssertEqual(editor.value as? String, "HELLO")
    }

    /// Copy: with text in the editor, tap Copy, "Copied" appears and then
    /// disappears on its own (no fixed sleep — `waitForNonExistence`).
    func testCopyShowsThenHidesTheCopiedConfirmation() {
        // A longer confirmation: XCUITest waits for the app to go idle
        // after the tap, which can outlast the default 0.8 s.
        let app = launchApp(extraArguments: ["-uiTestStubProvider", "-uiTestLongCopiedConfirmation"])
        addLANProviderAndActivate(app)
        app.tabButton("tab.scratchpad").tap()

        typeIntoEditor(app, text: "hello")

        app.buttons["editor.copy"].waitAndAssertExists().tap()

        let copied = app.staticTexts["editor.copied"]
        copied.waitAndAssertExists(timeout: 5, "\"Copied\" should appear after tapping Copy")
        XCTAssertTrue(copied.waitForNonExistence(timeout: 5), "\"Copied\" should disappear on its own")
    }

    /// Undo and "Show original" after a result: toggling "Show original"
    /// displays the pre-run text read-only, and Undo reverts to it and
    /// returns to idle.
    func testShowOriginalAndUndoAfterAResult() {
        let app = launchApp(extraArguments: ["-uiTestStubProvider"])
        addLANProviderAndActivate(app)
        app.tabButton("tab.scratchpad").tap()

        typeIntoEditor(app, text: "hello")
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()
        waitForDoneStatus(app)

        let editor = app.textViews["editor.textEditor"]
        editor.waitAndAssertExists()
        XCTAssertEqual(editor.value as? String, "HELLO")

        app.switches["editor.showOriginal"].waitAndAssertExists().tap()
        XCTAssertEqual(editor.value as? String, "hello", "Toggling \"Show original\" on should display the pre-run text")

        app.switches["editor.showOriginal"].tap()
        XCTAssertEqual(editor.value as? String, "HELLO", "Toggling \"Show original\" off should display the result again")

        app.buttons["editor.undo"].waitAndAssertExists().tap()
        XCTAssertEqual(editor.value as? String, "hello", "Undo should revert to the pre-run text")
        XCTAssertFalse(app.switches["editor.showOriginal"].exists, "\"Show original\" should disappear once back at idle")
    }

    /// Not configured: with no provider at all, running shows the
    /// not-configured card, and "Open Providers" switches to the Providers
    /// tab.
    func testNotConfiguredShowsCardAndOpensProvidersTab() {
        let app = launchApp()
        app.tabButton("tab.scratchpad").tap()

        typeIntoEditor(app, text: "hello")
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        app.staticTexts["No provider configured"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "scratchpad-not-configured")

        app.buttons["editor.notConfigured.openProviders"].waitAndAssertExists().tap()
        app.staticTexts["provider.emptyState"].waitAndAssertExists("Tapping \"Open Providers\" should switch to the (empty) Providers tab")
    }

    /// Cloud consent in the editor: running against a cloud custom
    /// provider shows the consent card; "Not now" leaves "Nothing was
    /// sent."; running again and Allow runs the action and shows the
    /// result.
    func testCloudProviderShowsConsentCardThenRunsAfterAllow() {
        let app = launchApp(extraArguments: ["-uiTestStubProvider"])
        addCloudProviderAndActivate(app)
        app.tabButton("tab.scratchpad").tap()

        typeIntoEditor(app, text: "hello")
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        app.staticTexts["consent.title"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "scratchpad-consent")
        app.buttons["consent.notNow"].tap()

        app.staticTexts["editor.inlineNote"].waitAndAssertExists()
        XCTAssertEqual(app.staticTexts["editor.inlineNote"].label, "Nothing was sent.")

        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()
        app.staticTexts["consent.title"].waitAndAssertExists()
        app.buttons["consent.allow"].tap()

        waitForDoneStatus(app)
        let editor = app.textViews["editor.textEditor"]
        XCTAssertEqual(editor.value as? String, "HELLO")
    }

    /// Reorder prompts then see the new chip order in the Scratchpad: add
    /// two prompts, drag the first below the second, and verify the
    /// Scratchpad's chips swap order too.
    func testReorderingPromptsChangesTheScratchpadChipOrder() {
        let app = launchApp()
        app.tabButton("tab.prompts").tap()

        addPrompt(app, label: "Zebra Prompt", instruction: "Do the zebra thing.")
        addPrompt(app, label: "Yak Prompt", instruction: "Do the yak thing.")

        let zebraRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Zebra Prompt")).firstMatch
        let yakRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Yak Prompt")).firstMatch
        zebraRow.waitAndAssertExists()
        yakRow.waitAndAssertExists()

        app.navigationBars.buttons["Edit"].waitAndAssertExists().tap()

        // Drag "Zebra Prompt" (currently above "Yak Prompt") down past it,
        // by its trailing reorder handle — the same downward drag
        // `PromptsUITests.testReorderPromptsPersists` uses. Dropping onto
        // the top edge of the row above proved unreliable on slow CI
        // runners (the drop landed just below it, leaving the order
        // unchanged), so this drags well into the lower part of the target
        // row and holds there briefly before releasing.
        let from = zebraRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let to = yakRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9))
        from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)

        app.navigationBars.buttons["Done"].waitAndAssertExists().tap()

        app.tabButton("tab.scratchpad").tap()

        let zebraChip = app.buttons.matching(NSPredicate(format: "label == %@", "Zebra Prompt")).firstMatch
        let yakChip = app.buttons.matching(NSPredicate(format: "label == %@", "Yak Prompt")).firstMatch
        zebraChip.waitAndAssertExists()
        yakChip.waitAndAssertExists()

        XCTAssertLessThan(
            yakChip.frame.minX,
            zebraChip.frame.minX,
            "After dragging \"Zebra Prompt\" below \"Yak Prompt\" in the Prompts tab, the \"Yak Prompt\" chip should now come first in the Scratchpad"
        )
    }

    // MARK: - Helpers

    /// Taps the editor and types `text` into it — see the type-level doc
    /// comment for why these tests don't rely on actually tapping
    /// `scratchpad.paste` to get text in.
    private func typeIntoEditor(_ app: XCUIApplication, text: String) {
        let editor = app.textViews["editor.textEditor"]
        editor.waitAndAssertExists().tap()
        editor.typeText(text)
    }

    /// Waits for the status banner's "Done" confirmation to appear, after a
    /// successful run.
    private func waitForDoneStatus(_ app: XCUIApplication) {
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Expected a \"Done\" status after a successful run")
    }

    /// Adds a LAN provider (`http://192.168.1.10:11434/v1`, never needs
    /// consent) through the Providers tab and returns to it afterward. It
    /// becomes the active provider automatically, since it's the first one
    /// added.
    private func addLANProviderAndActivate(_ app: XCUIApplication) {
        app.tabButton("tab.providers").tap()
        addCustomProvider(app, name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
    }

    /// Adds a cloud custom provider (`https://api.example.com/v1`, needs
    /// consent) through the Providers tab. It becomes the active provider
    /// automatically, since it's the first one added.
    private func addCloudProviderAndActivate(_ app: XCUIApplication) {
        app.tabButton("tab.providers").tap()
        addCustomProvider(app, name: "Cloud Server", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo")
    }

    /// Adds a custom provider through the Providers tab (mirrors
    /// `ProvidersUITests.addCustomProvider`).
    private func addCustomProvider(_ app: XCUIApplication, name: String, baseUrl: String, model: String) {
        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists().tap()

        app.textFields["provider.editor.name"].waitAndAssertExists().clearAndTypeText(name)
        let urlField = app.textFields["provider.editor.baseUrl"]
        urlField.tap()
        urlField.typeText(baseUrl)
        let modelField = app.textFields["provider.editor.model"]
        modelField.tap()
        modelField.typeText(model)

        app.buttons["provider.editor.save"].tap()
    }

    /// Adds a prompt through the Prompts tab (mirrors
    /// `PromptsUITests.testAddPrompt`).
    private func addPrompt(_ app: XCUIApplication, label: String, instruction: String) {
        app.buttons["prompt.add"].waitAndAssertExists().tap()

        let labelField = app.textFields["prompt.editor.label"]
        labelField.waitAndAssertExists()
        labelField.clearAndTypeText(label)

        let instructionEditor = app.textViews["prompt.editor.instruction"]
        instructionEditor.tap()
        instructionEditor.typeText(instruction)

        app.buttons["prompt.editor.save"].tap()
        app.staticTexts[label].waitAndAssertExists()
    }
}
