import Testing
import KallilexKeyboardCore
@testable import KallilexUI

/// Tests for `KeyGridView.characterAccessibilityLabel(base:shift:)` (ios-23
/// spec, "Accessibility": "the shifted state … in the label when shift is
/// on") — the pure piece of `accessibilityLabel(for:)`'s character-key
/// case, factored out so it's testable without a real `KeyGridView`/
/// `KeyboardModel`.
@MainActor
struct KeyGridViewAccessibilityTests {
    @Test func shiftOffKeepsTheBareLetter() {
        #expect(KeyGridView.characterAccessibilityLabel(base: "a", shift: .off) == "a")
    }

    @Test func shiftOnceSpeaksTheCapitalForm() {
        #expect(KeyGridView.characterAccessibilityLabel(base: "a", shift: .once) == "Capital A")
    }

    @Test func shiftLockedAlsoSpeaksTheCapitalForm() {
        #expect(KeyGridView.characterAccessibilityLabel(base: "a", shift: .locked) == "Capital A")
    }

    @Test func digitsAndSymbolsKeepTheirBareGlyphWhileShiftIsOn() {
        for glyph in ["1", ",", ".", "€"] {
            #expect(KeyGridView.characterAccessibilityLabel(base: glyph, shift: .once) == glyph)
            #expect(KeyGridView.characterAccessibilityLabel(base: glyph, shift: .locked) == glyph)
        }
    }

    @Test func umlautsAreLettersToo() {
        #expect(KeyGridView.characterAccessibilityLabel(base: "ä", shift: .once) == "Capital Ä")
    }

    @Test func everyLetterUppercasesInTheCapitalForm() {
        #expect(KeyGridView.characterAccessibilityLabel(base: "z", shift: .locked) == "Capital Z")
    }
}
