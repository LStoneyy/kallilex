import Foundation
import Testing
import KallilexKit

/// Verifies `PromptDefaults.defaults(locale:)` against
/// `contracts/default-prompts.json`, and the unsupported-locale fallback
/// to English. See `issues-ios/spec-ios-04-models-and-stores.md`,
/// decision 3.
struct PromptDefaultsTests {
    struct FixturePrompt: Decodable {
        let id: String
        let label: String
        let instruction: String
    }

    @Test func englishDefaultsMatchTheContractFixtureExactly() throws {
        let fixture = try ContractFixtures.decode("default-prompts.json", as: [FixturePrompt].self)
        let actual = PromptDefaults.defaults(locale: Locale(identifier: "en"))

        #expect(actual.count == fixture.count)
        for (prompt, expected) in zip(actual, fixture) {
            #expect(prompt.id == expected.id)
            #expect(prompt.label == expected.label)
            #expect(prompt.instruction == expected.instruction)
        }
    }

    @Test func unsupportedLocaleFallsBackToEnglishLabels() throws {
        let english = PromptDefaults.defaults(locale: Locale(identifier: "en"))
        let japanese = PromptDefaults.defaults(locale: Locale(identifier: "ja"))

        #expect(japanese.map(\.id) == english.map(\.id))
        #expect(japanese.map(\.label) == english.map(\.label))
        #expect(japanese.map(\.instruction) == english.map(\.instruction))
    }

    @Test func defaultsAreIndependentOfTheProcesssCurrentLocale() {
        // Regression guard for the `String(localized:bundle:locale:)`
        // pitfall documented on `PromptDefaults.defaults`: passing a
        // `locale` must actually select by that locale, not by whatever
        // language this test process happens to run under.
        let requestedEnglish = PromptDefaults.defaults(locale: Locale(identifier: "en"))
        #expect(requestedEnglish.first { $0.id == "builtin-rewrite" }?.label == "Rewrite")
    }
}
