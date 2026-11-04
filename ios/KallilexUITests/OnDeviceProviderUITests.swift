import XCTest

/// XCUITests for the Apple on-device provider (ios-10 spec). Every test
/// launches with `-uiTestOnDeviceAvailability <value>`, which substitutes a
/// fake `OnDeviceModel` reporting that availability — see
/// `AppEnvironment.makeOnDeviceModel()` — so these run deterministically
/// without a real eligible device or Apple Intelligence.
final class OnDeviceProviderUITests: KallilexUITestCase {
    /// `available`: the on-device preset can be added through the
    /// Providers tab, and its editor shows "Ready".
    func testOnDeviceAvailableShowsReadyInTheEditor() {
        let app = launchApp(extraArguments: ["-uiTestOnDeviceAvailability", "available"])
        app.tabButton("tab.providers").tap()

        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.appleOnDevice"].waitAndAssertExists(timeout: 10).tap()

        let availability = app.staticTexts["provider.editor.availability"]
        availability.waitAndAssertExists(timeout: 10, "Availability row should appear")
        XCTAssertEqual(availability.label, "Ready")
    }

    /// `notEnabled`: the editor shows the "Turn on Apple Intelligence…"
    /// hint instead of "Ready".
    func testOnDeviceNotEnabledShowsTheEnableHintInTheEditor() {
        let app = launchApp(extraArguments: ["-uiTestOnDeviceAvailability", "notEnabled"])
        app.tabButton("tab.providers").tap()

        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.appleOnDevice"].waitAndAssertExists(timeout: 10).tap()

        let availability = app.staticTexts["provider.editor.availability"]
        availability.waitAndAssertExists(timeout: 10, "Availability row should appear")
        XCTAssertEqual(availability.label, "Turn on Apple Intelligence in Settings.")
    }

    /// `notEligible`: the preset is never offered in the "Add provider"
    /// picker.
    func testOnDeviceNotEligibleHidesThePresetInThePicker() {
        let app = launchApp(extraArguments: ["-uiTestOnDeviceAvailability", "notEligible"])
        app.tabButton("tab.providers").tap()

        app.buttons["provider.add"].waitAndAssertExists().tap()
        // Confirm the picker itself loaded (and had time to resolve its own
        // availability check) before asserting the on-device preset's
        // absence — otherwise this would pass trivially before the sheet
        // even appeared.
        app.buttons["provider.preset.custom"].waitAndAssertExists(timeout: 10)
        XCTAssertFalse(app.buttons["provider.preset.appleOnDevice"].exists, "An ineligible device should never offer the on-device preset")
    }

    /// Once one on-device profile exists, the preset disappears from the
    /// picker (at most one on-device profile at a time).
    func testOnDevicePresetDisappearsOnceAProfileExists() {
        let app = launchApp(extraArguments: ["-uiTestOnDeviceAvailability", "available"])
        app.tabButton("tab.providers").tap()

        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.appleOnDevice"].waitAndAssertExists(timeout: 10).tap()
        app.staticTexts["provider.editor.availability"].waitAndAssertExists(timeout: 10)
        app.buttons["provider.editor.save"].tap()

        app.staticTexts["Apple Intelligence (on device)"].waitAndAssertExists(
            "The on-device provider should appear in the list"
        )

        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists(timeout: 10)
        XCTAssertFalse(
            app.buttons["provider.preset.appleOnDevice"].exists,
            "The preset should no longer be offered once a profile already exists"
        )
    }
}
