import XCTest

/// Smoke tests for the Prompts tab (ios-06 spec, "XCUITest smoke tests").
final class PromptsUITests: KallilexUITestCase {
    /// Add a prompt: tap Add, enter label and instruction, save, verify it
    /// appears in the list.
    func testAddPrompt() {
        let app = launchApp()
        app.tabButton("tab.prompts").tap()

        app.buttons["prompt.add"].waitAndAssertExists().tap()

        let labelField = app.textFields["prompt.editor.label"]
        labelField.waitAndAssertExists()
        labelField.clearAndTypeText("My Test Prompt")

        let instructionEditor = app.textViews["prompt.editor.instruction"]
        instructionEditor.tap()
        instructionEditor.typeText("Do the thing, please.")

        app.buttons["prompt.editor.save"].tap()

        app.staticTexts["My Test Prompt"].waitAndAssertExists("New prompt should appear in the list")
    }

    /// Reorder prompts: drag one to a new position (using the list's edit
    /// mode reorder handle), relaunch without resetting state, and verify
    /// the new order persisted.
    func testReorderPromptsPersists() {
        let app = launchApp()
        app.tabButton("tab.prompts").tap()

        let rewriteRow = app.buttons["prompt.row.builtin-rewrite"]
        let shortenRow = app.buttons["prompt.row.builtin-shorten"]
        rewriteRow.waitAndAssertExists()
        shortenRow.waitAndAssertExists()

        app.navigationBars.buttons["Edit"].waitAndAssertExists().tap()

        // Drag from near the trailing edge of the first row (where the
        // reorder handle sits in edit mode) to just below the second row,
        // moving "Rewrite" past "Shorten". On slow CI runners a drop
        // sometimes leaves the order unchanged even when dragged slowly, so
        // check the on-screen order and try again a few times before
        // relaunching. The test is about persistence, not drag gestures.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "prompt.row."))
        for _ in 0..<3 {
            let from = rewriteRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            let to = shortenRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9))
            from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            if rows.element(boundBy: 0).identifier == "prompt.row.builtin-shorten" { break }
        }
        XCTAssertEqual(
            rows.element(boundBy: 0).identifier,
            "prompt.row.builtin-shorten",
            "The drag should have moved Shorten to the top before relaunch"
        )

        app.navigationBars.buttons["Done"].waitAndAssertExists().tap()

        app.terminate()
        let relaunched = launchApp(resetState: false)
        relaunched.tabButton("tab.prompts").tap()

        let firstRow = relaunched.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "prompt.row.")
        ).element(boundBy: 0)
        firstRow.waitAndAssertExists()
        XCTAssertEqual(
            firstRow.identifier,
            "prompt.row.builtin-shorten",
            "Expected the dragged-to-top prompt to persist as the first row after relaunch"
        )
    }
}
