import XCTest

/// A German-language smoke pass (ios-11 spec, "German UI smoke test"):
/// launches with `-AppleLanguages (de) -AppleLocale de_DE` via
/// `launchApp(language: .german)` and checks that German actually shows up
/// in a few stable, representative places — the tab labels, the
/// Scratchpad's seeded default prompt chips, and the provider-add sheet —
/// without trying to assert every string in the catalogs (that's
/// `StringCatalogTests`' job).
final class GermanLocalizationUITests: KallilexUITestCase {
    /// Every tab's label is German, and each main tab gets a screenshot.
    /// Identifiers (`tab.scratchpad`, etc.) stay the same across
    /// languages; only the tab bar's own displayed label changes, so this
    /// looks the button up by its German text directly, mirroring
    /// `tabButton(_:)`'s English-label lookup for the other tests.
    func testTabLabelsAreGermanWithScreenshots() {
        let app = launchApp(language: .german)

        let scratchpadTab = app.tabBars.buttons["Notizblock"]
        scratchpadTab.waitAndAssertExists("Expected the Scratchpad tab to be labeled \"Notizblock\" in German")
        scratchpadTab.tap()
        attachScreenshot(app.screenshot(), name: "de-01-scratchpad")

        let promptsTab = app.tabBars.buttons["Prompts"]
        promptsTab.waitAndAssertExists("Expected the Prompts tab to stay \"Prompts\" in German (glossary: prompt stays \"Prompt\")")
        promptsTab.tap()
        attachScreenshot(app.screenshot(), name: "de-02-prompts")

        let providersTab = app.tabBars.buttons["Anbieter"]
        providersTab.waitAndAssertExists("Expected the Providers tab to be labeled \"Anbieter\" in German")
        providersTab.tap()
        attachScreenshot(app.screenshot(), name: "de-03-providers")

        let settingsTab = app.tabBars.buttons["Einstellungen"]
        settingsTab.waitAndAssertExists("Expected the Settings tab to be labeled \"Einstellungen\" in German")
        settingsTab.tap()
        attachScreenshot(app.screenshot(), name: "de-04-settings")
    }

    /// A fresh install seeds the three default prompts with their German
    /// labels (`PromptDefaults.defaults(locale:)`, resolved from the
    /// process's own `-AppleLocale` at seeding time) — the Scratchpad's
    /// chips show "Umschreiben", not "Rewrite". The chip's accessibility
    /// identifier (`editor.chip.builtin-rewrite`) is stable across
    /// languages; only its displayed label changes.
    func testScratchpadDefaultPromptChipsAreGermanAfterReset() {
        let app = launchApp(language: .german)

        app.tabBars.buttons["Notizblock"].waitAndAssertExists().tap()

        let rewriteChip = app.buttons["editor.chip.builtin-rewrite"]
        rewriteChip.waitAndAssertExists()
        XCTAssertEqual(rewriteChip.label, "Umschreiben")

        let shortenChip = app.buttons["editor.chip.builtin-shorten"]
        shortenChip.waitAndAssertExists()
        XCTAssertEqual(shortenChip.label, "Kürzen")
    }

    /// The provider-add sheet (title, Cancel button, and the "Custom"
    /// preset row) shows German.
    func testProviderAddSheetShowsGerman() {
        let app = launchApp(language: .german)

        app.tabBars.buttons["Anbieter"].waitAndAssertExists().tap()
        app.buttons["provider.add"].waitAndAssertExists().tap()

        app.navigationBars["Anbieter hinzufügen"].waitAndAssertExists(
            "Expected the provider-add sheet's title to be \"Anbieter hinzufügen\" in German"
        )

        let customPreset = app.buttons["provider.preset.custom"]
        customPreset.waitAndAssertExists()
        XCTAssertEqual(customPreset.label, "Benutzerdefiniert")

        app.navigationBars.buttons["Abbrechen"].waitAndAssertExists(
            "Expected the Cancel button to read \"Abbrechen\" in German"
        )
        attachScreenshot(app.screenshot(), name: "de-05-provider-add")
    }
}
