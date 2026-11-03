import XCTest

/// XCUITests for the first-run onboarding flow (ios-07, PLAN.md §4.1).
/// Every test here opts out of `launchApp`'s default `-uiTestSkipOnboarding`
/// (`skipOnboarding: false`), so the cover actually appears.
final class OnboardingUITests: KallilexUITestCase {
    /// On a genuinely fresh install, the onboarding cover appears instead
    /// of the tab UI.
    func testFirstLaunchShowsOnboarding() {
        let app = launchApp(skipOnboarding: false)

        let title = app.staticTexts["onboarding.welcome.title"]
        title.waitAndAssertExists("Onboarding welcome screen should appear on first launch")
        attachScreenshot(app.screenshot(), name: "onboarding-welcome")
    }

    /// A LAN (Ollama-style) provider never needs consent: welcome → choose
    /// Ollama → provider details → test connection (stub) → share sheet
    /// guide → done, landing on the tab UI with the provider saved and
    /// active.
    func testCompleteOnboardingWithLANProviderSkipsConsent() {
        let app = launchApp(skipOnboarding: false, extraArguments: ["-uiTestStubProvider"])

        app.staticTexts["onboarding.welcome.title"].waitAndAssertExists()
        app.buttons["onboarding.welcome.continue"].tap()

        app.buttons["onboarding.provider.preset.ollama"].waitAndAssertExists().tap()
        fillProviderEditor(app, baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3", apiKey: nil)

        app.staticTexts["onboarding.testConnection.title"].waitAndAssertExists()
        let result = app.staticTexts["onboarding.testConnection.result"]
        result.waitAndAssertExists(timeout: 10, "Test connection result should appear")
        app.buttons["onboarding.testConnection.continue"].tap()

        // LAN providers skip consent entirely — the next step is the guide.
        XCTAssertFalse(app.staticTexts["consent.title"].exists, "LAN provider should never show the consent step")
        app.staticTexts["shareSheetGuide.step1"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "onboarding-shareSheetGuide")
        app.buttons["onboarding.shareSheetGuide.continue"].tap()

        app.staticTexts["onboarding.done.title"].waitAndAssertExists()
        app.buttons["onboarding.done.start"].tap()

        app.tabButton("tab.scratchpad").waitAndAssertExists("Onboarding should land on the tab UI")

        app.tabButton("tab.providers").tap()
        app.staticTexts["Ollama on your Mac"].waitAndAssertExists("The provider saved during onboarding should appear in the list")
        let activeMarkerQuery = NSPredicate(format: "identifier ENDSWITH %@", ".active")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Ollama"))
            .firstMatch.images.matching(activeMarkerQuery).firstMatch
            .waitAndAssertExists("The onboarding provider should be active")
    }

    /// A cloud custom provider requires consent: the consent step appears
    /// after testing the connection, and allowing it lists the consent in
    /// Settings afterward.
    func testCompleteOnboardingWithCloudProviderShowsConsent() {
        let app = launchApp(skipOnboarding: false, extraArguments: ["-uiTestStubProvider"])

        app.staticTexts["onboarding.welcome.title"].waitAndAssertExists()
        app.buttons["onboarding.welcome.continue"].tap()

        app.buttons["onboarding.provider.preset.custom"].waitAndAssertExists().tap()
        fillProviderEditor(app, baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo", apiKey: "test-key")

        app.staticTexts["onboarding.testConnection.title"].waitAndAssertExists()
        app.staticTexts["onboarding.testConnection.result"].waitAndAssertExists(timeout: 10)
        app.buttons["onboarding.testConnection.continue"].tap()

        app.staticTexts["consent.title"].waitAndAssertExists("Cloud provider should show the consent step")
        attachScreenshot(app.screenshot(), name: "onboarding-consent")
        app.buttons["consent.allow"].tap()

        app.staticTexts["shareSheetGuide.step1"].waitAndAssertExists()
        app.buttons["onboarding.shareSheetGuide.continue"].tap()
        app.staticTexts["onboarding.done.title"].waitAndAssertExists()
        app.buttons["onboarding.done.start"].tap()

        app.tabButton("tab.scratchpad").waitAndAssertExists()

        app.tabButton("tab.settings").tap()
        app.staticTexts["api.example.com"].waitAndAssertExists("The granted consent should be listed in Settings")
    }

    /// "Set up later" on the Welcome step dismisses onboarding without a
    /// profile, and a later relaunch (without resetting state) never shows
    /// it again.
    func testSkipOnWelcomeDismissesOnboardingPermanently() {
        let app = launchApp(skipOnboarding: false)

        app.staticTexts["onboarding.welcome.title"].waitAndAssertExists()
        app.buttons["onboarding.welcome.setUpLater"].tap()

        app.tabButton("tab.scratchpad").waitAndAssertExists("Set up later should dismiss onboarding straight to the tab UI")

        app.terminate()
        let relaunched = launchApp(resetState: false, skipOnboarding: false)
        relaunched.tabButton("tab.scratchpad").waitAndAssertExists("Onboarding should not reappear on a later launch")
        XCTAssertFalse(relaunched.staticTexts["onboarding.welcome.title"].exists)
    }

    /// Re-running onboarding ("Show setup again") with a provider already
    /// configured must not silently create a duplicate: picking "Keep my
    /// current provider" on the Choose Provider step skips straight to the
    /// share sheet guide, and the Providers tab still shows exactly the one
    /// pre-existing (and still active) provider afterward.
    func testShowSetupAgainKeepingCurrentProviderDoesNotDuplicateIt() {
        let app = launchApp()
        addCustomProvider(app, name: "Existing Provider", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo")

        app.tabButton("tab.settings").tap()
        app.buttons["settings.showOnboarding"].waitAndAssertExists().tap()

        app.staticTexts["onboarding.welcome.title"].waitAndAssertExists()
        app.buttons["onboarding.welcome.continue"].tap()

        app.buttons["onboarding.provider.keepCurrent"].waitAndAssertExists().tap()

        app.staticTexts["shareSheetGuide.step1"].waitAndAssertExists("Keeping the current provider should skip straight to the share sheet guide")
        app.buttons["onboarding.shareSheetGuide.continue"].tap()
        app.staticTexts["onboarding.done.title"].waitAndAssertExists()
        app.buttons["onboarding.done.start"].tap()

        app.tabButton("tab.providers").tap()
        app.staticTexts["Existing Provider"].waitAndAssertExists()
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Existing Provider")).count,
            1,
            "Keeping the current provider should not create a duplicate"
        )
        let activeMarkerQuery = NSPredicate(format: "identifier ENDSWITH %@", ".active")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Existing Provider"))
            .firstMatch.images.matching(activeMarkerQuery).firstMatch
            .waitAndAssertExists("The pre-existing provider should still be active")
    }

    // MARK: - Helpers

    /// Adds a custom provider through the Providers tab (ios-06's own
    /// flow), for tests that need a pre-existing provider before onboarding
    /// is re-entered. Mirrors `ProvidersUITests.addCustomProvider`.
    private func addCustomProvider(_ app: XCUIApplication, name: String, baseUrl: String, model: String) {
        app.tabButton("tab.providers").tap()
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

    /// Fills in the provider editor sheet (reused, unmodified, from the
    /// Providers tab) that onboarding presents for its `.providerDetails`
    /// step, and saves it.
    private func fillProviderEditor(_ app: XCUIApplication, baseUrl: String, model: String, apiKey: String?) {
        let urlField = app.textFields["provider.editor.baseUrl"]
        urlField.waitAndAssertExists()
        urlField.clearAndTypeText(baseUrl)

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
    }
}
