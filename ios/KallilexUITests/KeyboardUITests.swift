import XCTest

/// XCUITests for the keyboard UI (ios-18 spec part B, "UI tests").
///
/// There is no way to drive a real custom keyboard extension from XCUITest,
/// so every test here launches the app with `-uiTestKeyboardHarness`
/// (DEBUG-only, `KeyboardHarnessView`), which hosts the exact same
/// `KallilexKeyboardController` the real `KeyboardExtension` does, embedded
/// directly in the app's own view hierarchy (see that file's doc comment
/// for why this isn't done through `UIResponder.inputViewController`) —
/// mirroring `ShareExtensionUITests`' harness pattern for the Share
/// Extension.
final class KeyboardUITests: KallilexUITestCase {
    // MARK: - Helpers

    /// Launches the keyboard harness and waits for its hosted text view
    /// (`harness.hostText`) to appear, which also means the keyboard itself
    /// has become first responder and is on screen.
    @discardableResult
    private func launchKeyboardHarness(resetState: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        let app = launchApp(resetState: resetState, extraArguments: ["-uiTestKeyboardHarness"] + extraArguments)
        app.textViews["harness.hostText"].waitAndAssertExists(timeout: 10)
        return app
    }

    /// `KeyGridView`'s keys are plain `UIAccessibilityElement`s with the
    /// `.keyboardKey` trait, which XCUITest can surface either as
    /// `XCUIElementType.key` or (depending on the OS/simulator) `.button` —
    /// this checks both, mirroring `UITestCase.swift`'s `anyElement(
    /// identifier:)` for SwiftUI controls whose underlying element type
    /// isn't part of the public API either.
    private func keyboardKey(_ name: String, on app: XCUIApplication) -> XCUIElement {
        let identifier = "keyboard.key.\(name)"
        let candidates = [app.keys[identifier], app.buttons[identifier], app.otherElements[identifier]]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            return candidate
        }
        return candidates[0]
    }

    /// Switches from prompt mode (the harness's initial mode) to keys mode,
    /// then taps the Scratchpad to focus it — the same tap a real user
    /// would use to place the cursor (ios-18 spec, user story 3).
    private func enterKeysModeAndFocusScratchpad(_ app: XCUIApplication) {
        app.buttons["keyboard.mode.keys"].waitAndAssertExists().tap()
        app.textViews["keyboard.scratchpad"].waitAndAssertExists().tap()
    }

    private func typeLetters(_ letters: String, on app: XCUIApplication) {
        for letter in letters {
            keyboardKey(letter.lowercased(), on: app).waitAndAssertExists().tap()
        }
    }

    // MARK: - Typing to the Scratchpad

    func testTypingInKeysModeWithScratchpadTargetGoesToScratchpadNotHost() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()

        typeLetters("Hallo", on: app)

        let scratchpadValue = app.textViews["keyboard.scratchpad"].value as? String ?? ""
        XCTAssertTrue(
            scratchpadValue.lowercased().contains("hallo"),
            "Expected the Scratchpad to contain \"Hallo\" (auto-cap or shift), got \"\(scratchpadValue)\""
        )

        let hostValue = app.textViews["harness.hostText"].value as? String ?? ""
        XCTAssertFalse(
            hostValue.lowercased().contains("hallo"),
            "The host text view shouldn't have received any typed letters while the target is Scratchpad"
        )
    }

    // MARK: - Typing to the app

    func testTypingWithAppTargetGoesToHostText() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.app"].waitAndAssertExists().tap()

        // The switch itself must show the new target, not just route to it.
        let appSelected = NSPredicate(format: "isSelected == true")
        expectation(for: appSelected, evaluatedWith: app.buttons["keyboard.target.app"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["keyboard.target.scratchpad"].isSelected)

        typeLetters("hallo", on: app)

        let hostValue = app.textViews["harness.hostText"].value as? String ?? ""
        XCTAssertTrue(
            hostValue.lowercased().contains("hallo"),
            "Expected the host text view to contain the typed letters, got \"\(hostValue)\""
        )

        let scratchpadValue = app.textViews["keyboard.scratchpad"].value as? String ?? ""
        XCTAssertFalse(
            scratchpadValue.lowercased().contains("hallo"),
            "The Scratchpad shouldn't have received any typed letters while the target is App"
        )
    }

    // MARK: - Shift once and auto-capitalization in the Scratchpad

    func testAutoCapitalizationAndShiftOnceInTheScratchpad() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)

        // `KeyboardModel.target`'s setter only re-evaluates
        // auto-capitalization (`contextDidChange`) on an actual value
        // change, not merely tapping the already-selected segment — the
        // Scratchpad is the default target, so switching away and back
        // once is what deterministically re-evaluates it for the (still
        // empty) Scratchpad before the very first keystroke.
        app.buttons["keyboard.target.app"].waitAndAssertExists().tap()
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()

        // Sentence start, empty Scratchpad: "a" auto-capitalizes to "A".
        keyboardKey("a", on: app).waitAndAssertExists().tap()
        XCTAssertEqual(app.textViews["keyboard.scratchpad"].value as? String, "A")

        // ". " then "b": a new sentence starts, so "b" auto-capitalizes too.
        keyboardKey(".", on: app).waitAndAssertExists().tap()
        keyboardKey("space", on: app).waitAndAssertExists().tap()
        keyboardKey("b", on: app).waitAndAssertExists().tap()
        XCTAssertEqual(app.textViews["keyboard.scratchpad"].value as? String, "A. B")

        // A single shift tap capitalizes exactly the next letter, then
        // reverts: "c" (shifted) then "d" (not shifted).
        keyboardKey("shift", on: app).waitAndAssertExists().tap()
        keyboardKey("c", on: app).waitAndAssertExists().tap()
        keyboardKey("d", on: app).waitAndAssertExists().tap()
        XCTAssertEqual(app.textViews["keyboard.scratchpad"].value as? String, "A. BCd")
    }

    // MARK: - Layer switching

    /// 123 redraws the grid as the numbers pad (its digit keys exist and
    /// type digits), and ABC brings the letters back.
    func testNumbersKeySwitchesTheGridAndLettersKeySwitchesBack() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()

        keyboardKey("numbers", on: app).waitAndAssertExists().tap()
        keyboardKey("1", on: app).waitAndAssertExists().tap()
        keyboardKey("2", on: app).waitAndAssertExists().tap()

        keyboardKey("letters", on: app).waitAndAssertExists().tap()
        keyboardKey("a", on: app).waitAndAssertExists().tap()

        let value = app.textViews["keyboard.scratchpad"].value as? String ?? ""
        XCTAssertEqual(value.lowercased(), "12a")
    }

    // MARK: - Scratchpad visibility

    func testScratchpadIsVisibleAndHittable() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()

        typeLetters("hi", on: app)

        let scratchpad = app.textViews["keyboard.scratchpad"]
        XCTAssertTrue(scratchpad.exists)
        XCTAssertTrue(scratchpad.isHittable)
        XCTAssertEqual((scratchpad.value as? String)?.lowercased(), "hi")
    }

    // MARK: - Prompt run

    func testPromptRunShowsStubResultAndUndoRestoresIt() {
        // A run needs a configured, active provider (mirrors
        // `ShareExtensionUITests`): add one through the app's own
        // Providers tab first, then relaunch into the harness without
        // resetting that state.
        let setup = launchApp()
        setup.tabButton("tab.providers").tap()
        setup.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
        setup.terminate()

        let app = launchKeyboardHarness(resetState: false, extraArguments: ["-uiTestStubProvider"])
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()

        typeLetters("hello", on: app)
        let beforeRun = app.textViews["keyboard.scratchpad"].value as? String ?? ""

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "keyboard-prompt-idle")
        app.buttons["editor.chip.builtin-rewrite"].tap()

        let scratchpad = app.textViews["keyboard.scratchpad"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", beforeRun.uppercased()),
            object: scratchpad
        )
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, "Expected the stub provider's uppercased result")
        attachScreenshot(app.screenshot(), name: "keyboard-prompt-after-run")

        app.buttons["editor.undo"].waitAndAssertExists().tap()
        XCTAssertEqual(scratchpad.value as? String, beforeRun, "Undo should restore the pre-run text")
    }

    /// ios-18 bugfix: the hosting view used to be 32 pt too short for its
    /// own SwiftUI content (toolbar + chips + action row), so everything
    /// below the toolbar overflowed and wasn't hit-testable at all.
    func testPromptModeControlsAreHittable() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()
        typeLetters("hello", on: app)
        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()

        let identifiers = [
            "editor.chip.builtin-rewrite",
            "editor.chip.builtin-shorten",
            "editor.chip.builtin-improve-clarity",
            "keyboard.mode.keys",
            "editor.undo",
        ]
        for identifier in identifiers {
            let element = app.buttons[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) did not appear")
            XCTAssertTrue(element.isHittable, "\(identifier) should be hittable in prompt mode")
        }
    }

    /// ios-18 bugfix: a prompt can't usefully run against no text.
    func testEmptyScratchpadDisablesChips() {
        let app = launchKeyboardHarness()
        let chip = app.buttons["editor.chip.builtin-rewrite"]
        chip.waitAndAssertExists()
        XCTAssertFalse(chip.isEnabled, "Expected the rewrite chip to be disabled while the Scratchpad is empty")
    }

    /// ios-18 bugfix: a successful run used to replace the chips row with a
    /// permanent "Fertig" `StatusBanner`, with no way back to run another
    /// prompt. Runs two different chips back to back and checks the chips
    /// come back hittable after each.
    func testChipsComeBackAfterARunAndASecondRunAlsoWorks() {
        let setup = launchApp()
        setup.tabButton("tab.providers").tap()
        setup.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
        setup.terminate()

        let app = launchKeyboardHarness(resetState: false, extraArguments: ["-uiTestStubProvider"])
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()
        typeLetters("hello", on: app)
        let beforeFirstRun = app.textViews["keyboard.scratchpad"].value as? String ?? ""

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        let scratchpad = app.textViews["keyboard.scratchpad"]
        let afterFirstRun = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", beforeFirstRun.uppercased()),
            object: scratchpad
        )
        XCTAssertEqual(XCTWaiter().wait(for: [afterFirstRun], timeout: 10), .completed)

        let rewriteChip = app.buttons["editor.chip.builtin-rewrite"]
        XCTAssertTrue(rewriteChip.waitForExistence(timeout: 5))
        XCTAssertTrue(rewriteChip.isHittable, "The chips should come back after a successful run")

        // Append more text (in keys mode) so the second run's input really
        // differs from the first result, then run a second, different chip.
        app.buttons["keyboard.mode.keys"].waitAndAssertExists().tap()
        app.textViews["keyboard.scratchpad"].waitAndAssertExists().tap()
        typeLetters("world", on: app)
        let beforeSecondRun = scratchpad.value as? String ?? ""

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        let shortenChip = app.buttons["editor.chip.builtin-shorten"]
        XCTAssertTrue(shortenChip.waitForExistence(timeout: 5))
        XCTAssertTrue(shortenChip.isHittable)
        shortenChip.tap()

        let afterSecondRun = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", beforeSecondRun.uppercased()),
            object: scratchpad
        )
        XCTAssertEqual(XCTWaiter().wait(for: [afterSecondRun], timeout: 10), .completed, "Expected the second run's uppercased result")
        XCTAssertNotEqual(scratchpad.value as? String, beforeFirstRun.uppercased(), "The Scratchpad should have changed again")
    }

    // MARK: - Compact status row (KeyboardStatusRow)

    /// ios-18 bugfix: `StatusBanner`'s `.failed` card is 100+ pt tall and
    /// overflowed the fixed 44 pt chips row; `KeyboardStatusRow` replaces
    /// it with a one-line row whose Retry/dismiss buttons stay hittable,
    /// and dismissing returns to the chips without retrying.
    func testFailedStateShowsRetryAndDismissThenDismissBringsBackChips() {
        let setup = launchApp()
        setup.tabButton("tab.providers").tap()
        setup.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
        setup.terminate()

        let app = launchKeyboardHarness(resetState: false, extraArguments: ["-uiTestStubProviderFails"])
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()
        typeLetters("hello", on: app)

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        let retry = app.buttons["keyboard.status.retry"]
        let dismiss = app.buttons["keyboard.status.dismiss"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "keyboard.status.retry did not appear")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "keyboard.status.dismiss did not appear")
        XCTAssertTrue(retry.isHittable, "keyboard.status.retry should be hittable")
        XCTAssertTrue(dismiss.isHittable, "keyboard.status.dismiss should be hittable")

        dismiss.tap()

        let rewriteChip = app.buttons["editor.chip.builtin-rewrite"]
        XCTAssertTrue(rewriteChip.waitForExistence(timeout: 5), "Dismiss should bring the chips back")
        XCTAssertTrue(rewriteChip.isHittable, "The chips should be hittable again after dismissing the error")
    }

    /// ios-18 bugfix: the not-configured state used to show `StatusBanner`
    /// 's full card (overflowing the row); `KeyboardStatusRow` shows the
    /// text only — there's nowhere for the keyboard to navigate to — and
    /// the action row below stays hittable.
    func testNotConfiguredShowsTextAndActionRowStaysHittable() {
        let app = launchKeyboardHarness()
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()
        typeLetters("hello", on: app)

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        app.staticTexts["Set up a provider in the Kallilex app."].waitAndAssertExists(timeout: 10)

        let keysButton = app.buttons["keyboard.mode.keys"]
        XCTAssertTrue(keysButton.waitForExistence(timeout: 5))
        XCTAssertTrue(keysButton.isHittable, "keyboard.mode.keys should stay hittable while the not-configured row is shown")
    }

    /// Consent inline (ios-19 replaces this with a proper compact consent
    /// view; this only checks the one-line stand-in's buttons work): a
    /// cloud custom provider without consent shows Allow/Not now inline,
    /// both hittable, mirroring `ShareExtensionUITests
    /// .testConsentInlineThenAllowRunsThePrompt`'s provider setup.
    func testConsentInlineAllowAndNotNowAreHittable() {
        let setup = launchApp()
        setup.tabButton("tab.providers").tap()
        setup.addCustomProvider(name: "Cloud Server", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo")
        setup.terminate()

        let app = launchKeyboardHarness(resetState: false, extraArguments: ["-uiTestStubProvider"])
        enterKeysModeAndFocusScratchpad(app)
        app.buttons["keyboard.target.scratchpad"].waitAndAssertExists().tap()
        typeLetters("hello", on: app)

        app.buttons["keyboard.mode.prompts"].waitAndAssertExists().tap()
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        let allow = app.buttons["consent.allow"]
        let notNow = app.buttons["consent.notNow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "consent.allow did not appear")
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "consent.notNow did not appear")
        XCTAssertTrue(allow.isHittable, "consent.allow should be hittable")
        XCTAssertTrue(notNow.isHittable, "consent.notNow should be hittable")
    }

    // MARK: - Host bridge: take selection, Insert, Undo Insert (ios-19)

    /// User story 1 (ios-19 spec): a selection in the host (seeded via
    /// `-uiTestHostText`/`-uiTestHostSelectionRange`, since XCUITest can't
    /// reliably drive a press-and-hold selection gesture in this harness —
    /// see `KeyboardHarnessView`) lands in the Scratchpad automatically on
    /// `viewWillAppear`, the Scratchpad being empty.
    func testSelectingAWordInTheHostTakesItOverToTheScratchpadAutomatically() {
        let app = launchKeyboardHarness(extraArguments: [
            "-uiTestHostText", "Hello world today",
            "-uiTestHostSelectionRange", "6,5",
        ])

        let scratchpad = app.textViews["keyboard.scratchpad"]
        scratchpad.waitAndAssertExists()
        XCTAssertEqual(scratchpad.value as? String, "world")
    }

    /// User stories 3/5: Insert's label says "Replace selection" while the
    /// host still reports the taken-over selection; tapping it replaces
    /// that selection in the host with the stub-uppercased result; Undo
    /// Insert restores the original word.
    func testReplaceSelectionInsertsTheStubResultAndUndoRestoresTheWord() {
        let setup = launchApp()
        setup.tabButton("tab.providers").tap()
        setup.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
        setup.terminate()

        let app = launchKeyboardHarness(resetState: false, extraArguments: [
            "-uiTestStubProvider",
            "-uiTestHostText", "Hello world today",
            "-uiTestHostSelectionRange", "6,5",
        ])

        let scratchpad = app.textViews["keyboard.scratchpad"]
        XCTAssertEqual(scratchpad.value as? String, "world")

        let insertButton = app.buttons["keyboard.insert"]
        insertButton.waitAndAssertExists()
        XCTAssertEqual(insertButton.label, "Replace selection")

        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        let afterRun = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "WORLD"),
            object: scratchpad
        )
        XCTAssertEqual(XCTWaiter().wait(for: [afterRun], timeout: 10), .completed, "Expected the stub provider's uppercased result")

        app.buttons["keyboard.insert"].waitAndAssertExists().tap()

        let hostText = app.textViews["harness.hostText"]
        XCTAssertEqual(hostText.value as? String, "Hello WORLD today", "Insert should replace the selected word in the host")

        app.buttons["keyboard.undoInsert"].waitAndAssertExists().tap()
        XCTAssertEqual(hostText.value as? String, "Hello world today", "Undo Insert should restore the original word")
    }

    // MARK: - Accessibility audit

    /// Same audit types and known-issue filtering as `AccessibilityUITests`.
    private let auditTypes: XCUIAccessibilityAuditType = [
        .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
    ]

    func testKeysModeAudit() throws {
        let app = launchKeyboardHarness()
        app.buttons["keyboard.mode.keys"].waitAndAssertExists().tap()
        app.textViews["keyboard.scratchpad"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "keyboard-keys-mode")
        try app.performAccessibilityAudit(for: auditTypes)
    }

    func testPromptsModeAudit() throws {
        let app = launchKeyboardHarness()
        app.textViews["keyboard.scratchpad"].waitAndAssertExists()
        try app.performAccessibilityAudit(for: auditTypes)
    }
}
