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
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()

        let scratchpad = app.textViews["keyboard.scratchpad"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", beforeRun.uppercased()),
            object: scratchpad
        )
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, "Expected the stub provider's uppercased result")

        app.buttons["editor.undo"].waitAndAssertExists().tap()
        XCTAssertEqual(scratchpad.value as? String, beforeRun, "Undo should restore the pre-run text")
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
        try app.performAccessibilityAudit(for: auditTypes)
    }

    func testPromptsModeAudit() throws {
        let app = launchKeyboardHarness()
        app.textViews["keyboard.scratchpad"].waitAndAssertExists()
        try app.performAccessibilityAudit(for: auditTypes)
    }
}
