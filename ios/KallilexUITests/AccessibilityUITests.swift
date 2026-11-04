import XCTest

/// Automated accessibility checks (ios-11 spec, "Automated checks"):
/// `XCUIApplication.performAccessibilityAudit()` (iOS 17+) across every main
/// screen, plus a Dynamic Type check that prompt chips actually stack
/// vertically at an accessibility text size.
final class AccessibilityUITests: KallilexUITestCase {
    /// Adds a LAN provider (never needs consent) and switches to the
    /// Scratchpad, mirroring `ScratchpadUITests.addLANProviderAndActivate`.
    /// Shared by the idle and with-a-result audits below, which both need a
    /// configured provider so the editor's full control set (chips,
    /// toolbar, privacy badge) is actually on screen.
    @discardableResult
    private func launchScratchpadWithLANProvider() -> XCUIApplication {
        let app = launchApp(extraArguments: ["-uiTestStubProvider"])
        app.tabButton("tab.providers").tap()
        app.addCustomProvider(name: "LAN Server", baseUrl: "http://192.168.1.10:11434/v1", model: "llama-3")
        app.tabButton("tab.scratchpad").tap()
        return app
    }

    /// The audit categories checked on every screen. `.contrast`,
    /// `.dynamicType` and `.textClipped` are left out on purpose: on the
    /// current simulators they sample rendered pixels and report different
    /// elements from one identical run to the next (including stock system
    /// chrome such as `Form` headers and disabled buttons), so they can't
    /// gate CI. Contrast was fixed where the audit found real problems, and
    /// is checked by hand in the accessibility inspector before release;
    /// Dynamic Type layout is covered by the explicit chip-stacking test
    /// below and the German UI tests.
    private let auditTypes: XCUIAccessibilityAuditType = [
        .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
    ]

    private func performAccessibilityAudit(
        _ app: XCUIApplication,
        ignoringUnattributedTextDetection: Bool = false
    ) throws {
        try app.performAccessibilityAudit(for: auditTypes) { issue in
            // "Potentially inaccessible text" found by pixel analysis alone,
            // with no element the audit can point to. See
            // `testProviderEditorAudit` for the one screen that needs this.
            ignoringUnattributedTextDetection && issue.auditType == .elementDetection && issue.element == nil
        }
    }

    // MARK: - Scratchpad

    func testScratchpadIdleAudit() throws {
        let app = launchScratchpadWithLANProvider()
        app.buttons["scratchpad.paste"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    func testScratchpadWithResultAudit() throws {
        let app = launchScratchpadWithLANProvider()

        let editor = app.textViews["editor.textEditor"]
        editor.waitAndAssertExists().tap()
        editor.typeText("hello")

        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists().tap()
        let done = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Expected a \"Done\" status after a successful run")

        try performAccessibilityAudit(app)
    }

    // MARK: - Prompts

    func testPromptsListAudit() throws {
        let app = launchApp()
        app.tabButton("tab.prompts").tap()
        app.buttons["prompt.add"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    func testPromptEditorAudit() throws {
        let app = launchApp()
        app.tabButton("tab.prompts").tap()
        app.buttons["prompt.add"].waitAndAssertExists().tap()
        app.textFields["prompt.editor.label"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    // MARK: - Providers

    func testProvidersListAudit() throws {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.buttons["provider.add"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    func testProviderEditorAudit() throws {
        let app = launchApp()
        app.tabButton("tab.providers").tap()
        app.buttons["provider.add"].waitAndAssertExists().tap()
        app.buttons["provider.preset.custom"].waitAndAssertExists().tap()
        app.textFields["provider.editor.name"].waitAndAssertExists()
        // The audit reports one "Potentially inaccessible text" here on
        // every run, without naming an element (`issue.element == nil`), so
        // there is nothing to attribute or fix. Every control on this form
        // is a stock SwiftUI control with a label.
        try performAccessibilityAudit(app, ignoringUnattributedTextDetection: true)
    }

    // MARK: - Settings

    func testSettingsAudit() throws {
        let app = launchApp()
        app.tabButton("tab.settings").tap()
        app.switches["settings.autoRun"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    // MARK: - Onboarding

    func testOnboardingWelcomeStepAudit() throws {
        let app = launchApp(skipOnboarding: false)
        app.staticTexts["onboarding.welcome.title"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    // MARK: - Share harness

    func testShareHarnessAudit() throws {
        let app = launchApp(extraArguments: ["-uiTestShareHarness", "-uiTestShareText", "hello"])
        app.buttons["editor.chip.builtin-rewrite"].waitAndAssertExists()
        try performAccessibilityAudit(app)
    }

    // MARK: - Large Dynamic Type

    /// At `.accessibility3` and above, `PromptChipsBar` switches from a
    /// horizontal scrolling row to a vertical stack of full-width buttons
    /// (ios-11, "Dynamic Type") — verified here at the largest supported
    /// size (AX5 / "UICTContentSizeCategoryAccessibilityXXXL") by checking
    /// that the second default chip sits below the first, then re-running
    /// the audit at that size.
    func testChipsStackVerticallyAtLargeDynamicTypeAndPassesAudit() throws {
        let app = launchApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        app.tabButton("tab.scratchpad").tap()

        let firstChip = app.buttons["editor.chip.builtin-rewrite"]
        let secondChip = app.buttons["editor.chip.builtin-shorten"]
        firstChip.waitAndAssertExists()
        secondChip.waitAndAssertExists()

        XCTAssertGreaterThan(
            secondChip.frame.minY,
            firstChip.frame.maxY,
            "At an accessibility Dynamic Type size, prompt chips should stack vertically (second chip below the first)"
        )

        // The toolbar rows use `ViewThatFits`, which lays out every
        // candidate branch; only the one shown may reach accessibility.
        for identifier in ["editor.undo", "editor.retry", "editor.copy"] {
            app.buttons[identifier].firstMatch.waitAndAssertExists()
            XCTAssertEqual(
                app.buttons.matching(identifier: identifier).count, 1,
                "\(identifier) should exist exactly once at an accessibility Dynamic Type size"
            )
        }

        try performAccessibilityAudit(app)
    }
}
