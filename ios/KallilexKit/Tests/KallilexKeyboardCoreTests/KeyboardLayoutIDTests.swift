import Testing
import KallilexKeyboardCore

/// `KeyboardLayoutID.resolve`. See
/// `issues-ios/spec-ios-17-keyboard-core-layouts-state-routing.md`.
struct KeyboardLayoutIDTests {
    @Test func nilStoredFallsBackToGermanDeviceLanguage() {
        let resolved = KeyboardLayoutID.resolve(stored: nil, preferredLanguages: ["de-DE", "en-US"])
        #expect(resolved == .qwertz)
    }

    @Test func nilStoredFallsBackToNonGermanDeviceLanguage() {
        let resolved = KeyboardLayoutID.resolve(stored: nil, preferredLanguages: ["en-US", "de-DE"])
        #expect(resolved == .qwerty)
    }

    @Test func unknownStoredValueFallsBackTheSameWayAsNil() {
        let resolved = KeyboardLayoutID.resolve(stored: "dvorak", preferredLanguages: ["de-CH"])
        #expect(resolved == .qwertz)
    }

    @Test func knownStoredValueWinsRegardlessOfLanguage() {
        let resolved = KeyboardLayoutID.resolve(stored: "qwerty", preferredLanguages: ["de-DE"])
        #expect(resolved == .qwerty)
    }

    @Test func emptyPreferredLanguagesDefaultsToQwerty() {
        let resolved = KeyboardLayoutID.resolve(stored: nil, preferredLanguages: [])
        #expect(resolved == .qwerty)
    }

    @Test func germanPrefixMatchIsCaseInsensitiveAndAllowsRegionVariants() {
        #expect(KeyboardLayoutID.resolve(stored: nil, preferredLanguages: ["DE-de"]) == .qwertz)
        #expect(KeyboardLayoutID.resolve(stored: nil, preferredLanguages: ["de_CH"]) == .qwertz)
    }
}
