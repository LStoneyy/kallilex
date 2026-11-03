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
}
