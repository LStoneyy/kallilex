import XCTest

/// A single smoke test that visits all four tabs plus the provider editor
/// and the Licenses view, attaching a screenshot of each (ios-06 spec,
/// "XCUITest smoke tests").
final class NavigationSmokeUITests: KallilexUITestCase {
    func testNavigateAllTabsAndAttachScreenshots() {
        let app = launchApp()

        app.tabButton("tab.scratchpad").waitAndAssertExists().tap()
        attachScreenshot(app.screenshot(), name: "01-scratchpad")

        app.tabButton("tab.prompts").tap()
        app.buttons["prompt.add"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "02-prompts")

        app.tabButton("tab.providers").tap()
        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists().tap()

        let nameField = app.textFields["provider.editor.name"]
        nameField.waitAndAssertExists()
        nameField.clearAndTypeText("Screenshot Server")
        let urlField = app.textFields["provider.editor.baseUrl"]
        urlField.tap()
        urlField.typeText("http://192.168.1.10:11434/v1")
        let modelField = app.textFields["provider.editor.model"]
        modelField.tap()
        modelField.typeText("llama-3\n")
        attachScreenshot(app.screenshot(), name: "04-provider-editor")

        app.buttons["provider.editor.save"].tap()
        app.staticTexts["Screenshot Server"].waitAndAssertExists("New provider should appear in the list")
        attachScreenshot(app.screenshot(), name: "03-providers")

        app.tabButton("tab.settings").tap()
        let licensesLink = app.anyElement(identifier: "settings.about.licenses")
        licensesLink.waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "05-settings")

        licensesLink.tap()
        // The identifier is on the `ScrollView` wrapping the license text,
        // not on a `StaticText`.
        app.scrollViews["settings.licenses.text"].waitAndAssertExists()
        attachScreenshot(app.screenshot(), name: "06-licenses")
    }
}
