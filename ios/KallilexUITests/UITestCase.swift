import XCTest

/// Shared launch helper for every Kallilex UI test (ios-06 part 2).
///
/// Every test launches with `-uiTestResetState` by default, so each test
/// starts from a fresh install: no `settings.json`, no
/// `settings.corrupt-*.json` backup, and no stored API keys (see
/// `AppEnvironment.applyUITestLaunchArguments()`, DEBUG-only). Persistence
/// tests pass `resetState: false` on the relaunch that checks a value
/// survived, so the reset doesn't wipe out what the first launch wrote.
@MainActor
class KallilexUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches a fresh `XCUIApplication`, with `-uiTestResetState` unless
    /// `resetState` is `false`, plus any `extraArguments` (e.g.
    /// `-uiTestStubProvider`, `-uiTestCorruptSettings`).
    ///
    /// Always forces English (`-AppleLanguages (en) -AppleLocale en_US`),
    /// regardless of the simulator's own language setting. `tabButton(_:)`
    /// below matches tab bar buttons by their (untranslated) English label
    /// — forcing the process language here keeps that match stable once
    /// ios-11 adds German, rather than depending on whatever language the
    /// CI runner's simulator happens to default to.
    @discardableResult
    func launchApp(resetState: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if resetState {
            arguments.append("-uiTestResetState")
        }
        arguments.append(contentsOf: extraArguments)
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Attaches `screenshot` to the test run with `lifetime = .keepAlways`,
    /// so it survives in the result bundle even when the test passes.
    func attachScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
extension XCUIElement {
    /// Waits up to `timeout` for the element to exist, failing the test
    /// immediately (via `continueAfterFailure = false`) with a clear
    /// message if it never appears, instead of letting a later, unrelated
    /// interaction fail with a confusing error.
    @discardableResult
    func waitAndAssertExists(timeout: TimeInterval = 5, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssert(waitForExistence(timeout: timeout), message.isEmpty ? "\(self) did not appear" : message, file: file, line: line)
        return self
    }

    /// Replaces whatever text is already in a text field (e.g. a preset's
    /// pre-filled name) with `text`, by backspacing its current value
    /// before typing — `XCUIElement` has no direct "clear" API.
    ///
    /// Always backspaces a generous fixed count (rather than exactly
    /// `value`'s length): reading `.value` right after `.tap()` can return
    /// a stale/short snapshot before the field's layout has settled,
    /// under-deleting and leaving a residue that `typeText` then inserts
    /// in front of or behind (cursor-position-dependent) — backspacing an
    /// already-empty field is a harmless no-op, so over-deleting is safe.
    func clearAndTypeText(_ text: String) {
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        typeText(text)
    }

    /// Taps a `Toggle`'s actual switch control, near the row's trailing
    /// edge, instead of `.tap()`'s default point at the center of the row.
    ///
    /// Verified empirically (`DebugUITests`, removed after use): a Form
    /// row's `Toggle` exposes two nested `Switch` accessibility elements —
    /// an outer one spanning the whole row (the one our own
    /// `.accessibilityIdentifier` names) and the real native control
    /// against the trailing edge. `.tap()`'s default point, the row's
    /// center, does not reliably flip the switch; tapping near the
    /// trailing edge, where the real control sits, does.
    func tapSwitch() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
}

@MainActor
extension XCUIApplication {
    /// Finds `identifier` across the element types SwiftUI commonly
    /// surfaces an identified control as (`.buttons`, `.cells`,
    /// `.otherElements`) — the exact `XCUIElement` type backing a given
    /// SwiftUI control (e.g. a `NavigationLink` row in a `Form`) isn't part
    /// of its public API and can vary.
    func anyElement(identifier: String, timeout: TimeInterval = 2) -> XCUIElement {
        let candidates = [buttons[identifier], cells[identifier], otherElements[identifier]]
        for candidate in candidates where candidate.waitForExistence(timeout: timeout) {
            return candidate
        }
        return candidates[0]
    }

    /// The tab bar button for one of `RootTabView`'s four tabs, found by
    /// its label rather than by its `tab.*` accessibility identifier.
    ///
    /// Verified empirically (`DebugUITests`, removed after use): SwiftUI's
    /// `.tabItem { ... }.accessibilityIdentifier("tab.scratchpad")` pattern
    /// sets that identifier on the tab's *content* view, not on the
    /// underlying `UITabBarItem` button — the button itself carries no
    /// identifier at all, only its localized title. Matching by label is
    /// the pragmatic workaround; it stays stable once German is added
    /// (ios-11) because `launchApp(_:extraArguments:)` always forces the
    /// process language to English, independently of the simulator's own
    /// language setting.
    func tabButton(_ identifier: String) -> XCUIElement {
        let label: String
        switch identifier {
        case "tab.scratchpad": label = "Scratchpad"
        case "tab.prompts": label = "Prompts"
        case "tab.providers": label = "Providers"
        case "tab.settings": label = "Settings"
        default: label = identifier
        }
        return tabBars.buttons[label]
    }
}
