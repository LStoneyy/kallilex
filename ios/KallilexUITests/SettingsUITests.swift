import XCTest

/// Smoke tests for the Settings tab (ios-06 spec, "XCUITest smoke tests").
final class SettingsUITests: KallilexUITestCase {
    /// Toggle both auto-run and auto-copy on, verify they persist across an
    /// app restart.
    func testAutoRunAutoCopyTogglesPersist() {
        let app = launchApp()
        app.tabButton("tab.settings").tap()

        let autoRun = app.switches["settings.autoRun"]
        let autoCopy = app.switches["settings.autoCopy"]
        autoRun.waitAndAssertExists()
        autoCopy.waitAndAssertExists()

        if (autoRun.value as? String) != "1" {
            autoRun.tapSwitch()
        }
        if (autoCopy.value as? String) != "1" {
            autoCopy.tapSwitch()
        }
        XCTAssertEqual(autoRun.value as? String, "1")
        XCTAssertEqual(autoCopy.value as? String, "1")

        app.terminate()
        let relaunched = launchApp(resetState: false)
        relaunched.tabButton("tab.settings").tap()

        let autoRunAfter = relaunched.switches["settings.autoRun"]
        let autoCopyAfter = relaunched.switches["settings.autoCopy"]
        autoRunAfter.waitAndAssertExists()
        autoCopyAfter.waitAndAssertExists()
        XCTAssertEqual(autoRunAfter.value as? String, "1", "autoRun should still be on after relaunch")
        XCTAssertEqual(autoCopyAfter.value as? String, "1", "autoCopy should still be on after relaunch")
    }

    // MARK: - Keyboard section (ios-22)

    /// Settings → Keyboard → "How to add the keyboard" pushes/presents
    /// `KeyboardGuideView`, identified by its root `keyboard.guide`.
    func testKeyboardGuideOpensFromSettings() {
        let app = launchApp()
        app.tabButton("tab.settings").tap()

        app.buttons["settings.keyboard.guide"].waitAndAssertExists().tap()
        app.scrollViews["keyboard.guide"].waitAndAssertExists("The keyboard guide should open from Settings")
    }

    /// Choosing QWERTY in the layout picker survives a relaunch
    /// (`resetState: false`) — `AppSettings.keyboardLayout` round-trips
    /// through the same `SettingsStore` every other setting does.
    func testKeyboardLayoutPickerPersistsAcrossRelaunch() {
        let app = launchApp()
        app.tabButton("tab.settings").tap()

        let picker = app.buttons["settings.keyboard.layout"]
        picker.waitAndAssertExists().tap()
        app.buttons["QWERTY (English)"].waitAndAssertExists().tap()
        XCTAssertTrue(picker.label.contains("QWERTY (English)"), "The picker should show the newly selected layout")

        app.terminate()
        let relaunched = launchApp(resetState: false)
        relaunched.tabButton("tab.settings").tap()

        let pickerAfter = relaunched.buttons["settings.keyboard.layout"]
        pickerAfter.waitAndAssertExists()
        XCTAssertTrue(
            pickerAfter.label.contains("QWERTY (English)"),
            "The picker should still show QWERTY after relaunch, got \"\(pickerAfter.label)\""
        )
    }
}
