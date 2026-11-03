import XCTest

/// Smoke test for the one-time corruption recovery alert (ios-06 spec,
/// "XCUITest smoke tests").
final class CorruptionUITests: KallilexUITestCase {
    /// Write an invalid `settings.json` before launch, launch the app,
    /// verify the alert appears, and verify it doesn't show again on the
    /// next launch.
    func testCorruptionAlertShowsOnceThenNotAgain() {
        let app = launchApp(extraArguments: ["-uiTestCorruptSettings"])

        let alert = app.alerts.firstMatch
        alert.waitAndAssertExists(timeout: 5, "Corruption alert should appear on first launch")
        alert.buttons["OK"].tap()

        app.terminate()
        let relaunched = launchApp(resetState: false)
        relaunched.tabButton("tab.scratchpad").waitAndAssertExists()
        XCTAssertFalse(relaunched.alerts.firstMatch.exists, "Corruption alert should not reappear on the next launch")
    }
}
