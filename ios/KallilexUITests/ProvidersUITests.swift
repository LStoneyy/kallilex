import XCTest

/// Smoke tests for the Providers tab (ios-06 spec, "XCUITest smoke tests").
final class ProvidersUITests: KallilexUITestCase {
    /// Add a custom provider: tap Add provider, select Custom, enter name,
    /// URL, model, API key, save, verify it appears in the list and that
    /// the "API key saved" row shows when reopened.
    func testAddCustomProviderWithApiKey() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()

        addCustomProvider(
            app,
            name: "Custom LAN Server",
            baseUrl: "http://192.168.1.10:11434/v1",
            model: "llama-3",
            apiKey: "test-key"
        )

        app.staticTexts["Custom LAN Server"].waitAndAssertExists("New provider should appear in the list")

        tapProviderRow(app, labelContains: "Custom LAN Server")
        app.staticTexts["provider.editor.apiKey.saved"].waitAndAssertExists("Saved API key row should show after reopening")
        app.buttons["provider.editor.cancel"].tap()
    }

    /// Test connection (stub): with `-uiTestStubProvider`, the ActionRunner
    /// uses a stub provider that always succeeds. Verify "Test connection"
    /// shows "✓ Connection successful".
    func testTestConnectionWithStubProvider() {
        let app = launchApp(extraArguments: ["-uiTestStubProvider"])
        app.tabButton("tab.providers").tap()

        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists().tap()

        app.textFields["provider.editor.name"].waitAndAssertExists().clearAndTypeText("Stub Provider")
        app.textFields["provider.editor.baseUrl"].tap()
        app.textFields["provider.editor.baseUrl"].typeText("https://api.example.com/v1")
        app.textFields["provider.editor.model"].tap()
        app.textFields["provider.editor.model"].typeText("gpt-4-turbo")

        app.buttons["provider.editor.testConnection"].tap()

        let result = app.staticTexts["provider.editor.testConnection.result"]
        result.waitAndAssertExists(timeout: 10, "Test connection result should appear")
        XCTAssertEqual(result.label, "✓ Connection successful")
    }

    /// Add two providers, set the second as active, relaunch, verify the
    /// checkmark moved to the second provider.
    func testSetProviderActivePersists() {
        let app = launchApp()
        app.tabButton("tab.providers").tap()

        addCustomProvider(app, name: "Provider A", baseUrl: "https://a.example.com/v1", model: "model-a", apiKey: nil)
        addCustomProvider(app, name: "Provider B", baseUrl: "https://b.example.com/v1", model: "model-b", apiKey: nil)

        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Provider B")).firstMatch.waitAndAssertExists()
        tapProviderRow(app, labelContains: "Provider B")

        app.buttons["provider.editor.setActive"].waitAndAssertExists().tap()
        app.buttons["provider.editor.cancel"].tap()

        app.terminate()
        let relaunched = launchApp(resetState: false)
        relaunched.tabButton("tab.providers").tap()

        let rowBAfter = relaunched.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Provider B")).firstMatch
        rowBAfter.waitAndAssertExists()
        let activeMarkerQuery = NSPredicate(format: "identifier ENDSWITH %@", ".active")
        XCTAssertTrue(
            rowBAfter.images.matching(activeMarkerQuery).firstMatch.exists,
            "Provider B should show the active checkmark after relaunch"
        )

        let rowAAfter = relaunched.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Provider A")).firstMatch
        rowAAfter.waitAndAssertExists()
        XCTAssertFalse(
            rowAAfter.images.matching(activeMarkerQuery).firstMatch.exists,
            "Provider A should no longer show the active checkmark after relaunch"
        )
    }

    // MARK: - Helpers

    /// Taps a provider row by its (generated-id-free) label.
    ///
    /// `ProviderListView`'s row now renders its `PrivacyBadge` with
    /// `interactive: false`, so the row is a single plain `Button` with no
    /// nested tappable control — an ordinary `.tap()` reaches the row's
    /// own action.
    private func tapProviderRow(_ app: XCUIApplication, labelContains name: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        row.waitAndAssertExists()
        row.tap()
    }

    @discardableResult
    private func addCustomProvider(
        _ app: XCUIApplication,
        name: String,
        baseUrl: String,
        model: String,
        apiKey: String?
    ) -> XCUIApplication {
        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists().tap()

        let nameField = app.textFields["provider.editor.name"]
        nameField.waitAndAssertExists()
        nameField.clearAndTypeText(name)

        let urlField = app.textFields["provider.editor.baseUrl"]
        urlField.tap()
        urlField.typeText(baseUrl)

        let modelField = app.textFields["provider.editor.model"]
        modelField.tap()
        modelField.typeText(model)

        if let apiKey {
            app.buttons["provider.editor.apiKey.pasteAndSave"].tap()
            let keyField = app.secureTextFields["provider.editor.apiKey.field"]
            keyField.waitAndAssertExists()
            keyField.tap()
            keyField.typeText(apiKey)
        }

        app.buttons["provider.editor.save"].tap()
        return app
    }
}
