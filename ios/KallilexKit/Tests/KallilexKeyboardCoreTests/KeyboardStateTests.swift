import Foundation
import Testing
import KallilexKeyboardCore

/// `KeyboardState` and `deleteRepeatEdit`. See
/// `issues-ios/spec-ios-17-keyboard-core-layouts-state-routing.md`.
struct KeyboardStateTests {
    private let noAutoCap = KeyboardContext(autocapitalization: .none)
    private let shiftKey = Key(kind: .shift)
    private let spaceKey = Key(kind: .space)
    private let deleteKey = Key(kind: .delete)
    private func letterKey(_ letter: String) -> Key { Key(kind: .character(letter)) }
    private func charKey(_ char: String) -> Key { Key(kind: .character(char)) }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // ---- shift ----------------------------------------------------------

    @Test func shiftOnceClearsAfterALetter() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        #expect(state.shift == .once)

        let edits = state.press(letterKey("a"), context: noAutoCap, now: t0)
        #expect(edits == [.insert("A")])
        #expect(state.shift == .off)
    }

    @Test func doubleTapWithin0point3SecondsLocksShift() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        #expect(state.shift == .once)

        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.2))
        #expect(state.shift == .locked)
    }

    @Test func slowSecondTapDoesNotLock() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.4))
        #expect(state.shift != .locked)
    }

    @Test func tapWhileLockedTurnsShiftOff() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        #expect(state.shift == .locked)

        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.2))
        #expect(state.shift == .off)
    }

    @Test func lockedShiftCapitalizesEveryLetterWithoutClearing() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        #expect(state.shift == .locked)

        let first = state.press(letterKey("a"), context: noAutoCap, now: t0)
        #expect(first == [.insert("A")])
        #expect(state.shift == .locked)
        let second = state.press(letterKey("b"), context: noAutoCap, now: t0)
        #expect(second == [.insert("B")])
        #expect(state.shift == .locked)
    }

    // ---- auto-capitalization ---------------------------------------------

    @Test func noneNeverAutoCapitalizes() {
        var state = KeyboardState()
        state.contextDidChange(KeyboardContext(autocapitalization: .none, textBeforeCursor: ""))
        #expect(state.shift == .off)
        state.contextDidChange(KeyboardContext(autocapitalization: .none, textBeforeCursor: ". "))
        #expect(state.shift == .off)
    }

    @Test func allCharactersAlwaysAutoCapitalizes() {
        var state = KeyboardState()
        state.contextDidChange(KeyboardContext(autocapitalization: .allCharacters, textBeforeCursor: "whatever"))
        #expect(state.shift == .once)
    }

    @Test func wordsAutoCapitalizesAtStartAndAfterASpace() {
        var state = KeyboardState()
        state.contextDidChange(KeyboardContext(autocapitalization: .words, textBeforeCursor: ""))
        #expect(state.shift == .once)

        state.shift = .off
        state.contextDidChange(KeyboardContext(autocapitalization: .words, textBeforeCursor: "hello "))
        #expect(state.shift == .once)

        state.shift = .off
        state.contextDidChange(KeyboardContext(autocapitalization: .words, textBeforeCursor: "hello"))
        #expect(state.shift == .off)
    }

    @Test(
        "sentences auto-capitalizes at the start and after '. ', '! ', '? '",
        arguments: ["", ". ", "! ", "? "]
    )
    func sentencesAutoCapitalizesAtStartAndAfterSentenceEndings(suffix: String) {
        var state = KeyboardState()
        let text = suffix.isEmpty ? "" : "Hello\(suffix)"
        state.contextDidChange(KeyboardContext(autocapitalization: .sentences, textBeforeCursor: text))
        #expect(state.shift == .once)
    }

    @Test func sentencesDoesNotAutoCapitalizeAfterAPlainSpace() {
        var state = KeyboardState()
        state.contextDidChange(KeyboardContext(autocapitalization: .sentences, textBeforeCursor: "hello "))
        #expect(state.shift == .off)
    }

    @Test func userOverrideWinsForExactlyTheNextContextChange() {
        var state = KeyboardState()
        let sentenceStart = KeyboardContext(autocapitalization: .sentences, textBeforeCursor: "")

        state.contextDidChange(sentenceStart)
        #expect(state.shift == .once)

        _ = state.press(shiftKey, context: sentenceStart, now: t0)
        #expect(state.shift == .off)

        // The override wins for this next context change…
        state.contextDidChange(sentenceStart)
        #expect(state.shift == .off)

        // …but not the one after that.
        state.contextDidChange(sentenceStart)
        #expect(state.shift == .once)
    }

    // ---- double space -----------------------------------------------------

    @Test func doubleSpaceAfterALetterBecomesAPeriod() {
        var state = KeyboardState()
        _ = state.press(letterKey("a"), context: noAutoCap, now: t0)
        let first = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        #expect(first == [.insert(" ")])

        let second = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.3))
        #expect(second == [.deleteBackward, .insert(". ")])
        #expect(state.shift == .once)
    }

    @Test func doubleSpaceAfterADigitBecomesAPeriod() {
        var state = KeyboardState()
        _ = state.press(charKey("1"), context: noAutoCap, now: t0)
        _ = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        let second = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.2))
        #expect(second == [.deleteBackward, .insert(". ")])
    }

    @Test func doubleSpaceDoesNotFireAfterASpace() {
        var state = KeyboardState()
        _ = state.press(spaceKey, context: noAutoCap, now: t0)
        let second = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        #expect(second == [.insert(" ")])
    }

    @Test func doubleSpaceDoesNotFireAtTheStart() {
        var state = KeyboardState()
        let edits = state.press(spaceKey, context: noAutoCap, now: t0)
        #expect(edits == [.insert(" ")])
    }

    @Test func doubleSpaceDoesNotFireAfter0point5Seconds() {
        var state = KeyboardState()
        _ = state.press(letterKey("a"), context: noAutoCap, now: t0)
        _ = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        let second = state.press(spaceKey, context: noAutoCap, now: t0.addingTimeInterval(0.7))
        #expect(second == [.insert(" ")])
    }

    // ---- layer switching ---------------------------------------------------

    @Test func layerSwitchKeysChangeTheLayer() {
        var state = KeyboardState()
        #expect(state.layer == .letters)

        _ = state.press(Key(kind: .layerSwitch(.numbers)), context: noAutoCap, now: t0)
        #expect(state.layer == .numbers)

        _ = state.press(Key(kind: .layerSwitch(.symbols)), context: noAutoCap, now: t0)
        #expect(state.layer == .symbols)

        _ = state.press(Key(kind: .layerSwitch(.letters)), context: noAutoCap, now: t0)
        #expect(state.layer == .letters)
    }

    @Test func numbersLayerReturnsToLettersAfterASpace() {
        var state = KeyboardState(layer: .numbers)
        _ = state.press(spaceKey, context: noAutoCap, now: t0)
        #expect(state.layer == .letters)
    }

    @Test func numbersLayerReturnsToLettersAfterAnApostrophe() {
        var state = KeyboardState(layer: .numbers)
        _ = state.press(charKey("'"), context: noAutoCap, now: t0)
        #expect(state.layer == .letters)
    }

    @Test func numbersLayerDoesNotReturnToLettersAfterADigit() {
        var state = KeyboardState(layer: .numbers)
        _ = state.press(charKey("1"), context: noAutoCap, now: t0)
        #expect(state.layer == .numbers)
    }

    // ---- long-press select --------------------------------------------------

    @Test func longPressSelectRespectsOnceShiftAndClearsIt() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        #expect(state.shift == .once)

        let edits = state.longPressSelect("ä", context: noAutoCap)
        #expect(edits == [.insert("Ä")])
        #expect(state.shift == .off)
    }

    @Test func longPressSelectRespectsLockedShiftWithoutClearingIt() {
        var state = KeyboardState()
        _ = state.press(shiftKey, context: noAutoCap, now: t0)
        _ = state.press(shiftKey, context: noAutoCap, now: t0.addingTimeInterval(0.1))
        #expect(state.shift == .locked)

        let edits = state.longPressSelect("ü", context: noAutoCap)
        #expect(edits == [.insert("Ü")])
        #expect(state.shift == .locked)
    }

    @Test func longPressSelectLowerCaseWhenShiftIsOff() {
        var state = KeyboardState()
        let edits = state.longPressSelect("ß", context: noAutoCap)
        #expect(edits == [.insert("ß")])
    }

    // ---- delete repeat ------------------------------------------------------

    @Test func deleteRepeatIsNilBefore0point5Seconds() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.4) == nil)
    }

    @Test func deleteRepeatFiresDeleteBackwardAt0point6Seconds() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.4) == nil)
        #expect(state.deleteRepeatEdit(heldFor: 0.6) == .deleteBackward)
    }

    @Test func deleteRepeatFiresDeleteWordBackwardAt2point1Seconds() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.4) == nil)
        #expect(state.deleteRepeatEdit(heldFor: 0.6) == .deleteBackward)
        #expect(state.deleteRepeatEdit(heldFor: 2.1) == .deleteWordBackward)
    }

    @Test func deleteRepeatDoesNotRefireWithinTheSameStep() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.55) == .deleteBackward)
        #expect(state.deleteRepeatEdit(heldFor: 0.58) == nil)
        #expect(state.deleteRepeatEdit(heldFor: 0.62) == .deleteBackward)
    }

    @Test func deleteKeyPressResetsTheRepeatCounters() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.6) == .deleteBackward)

        _ = state.press(deleteKey, context: noAutoCap, now: t0)
        // A fresh hold starting again from 0.6 s fires again, because the
        // press reset the step counters.
        #expect(state.deleteRepeatEdit(heldFor: 0.6) == .deleteBackward)
    }

    @Test func symbolsLayerDoesNotReturnToLettersAfterASpace() {
        var state = KeyboardState(layer: .symbols)
        _ = state.press(spaceKey, context: noAutoCap, now: t0)
        #expect(state.layer == .symbols)
    }

    @Test func symbolsLayerDoesNotReturnToLettersAfterAnApostrophe() {
        var state = KeyboardState(layer: .symbols)
        _ = state.press(charKey("'"), context: noAutoCap, now: t0)
        #expect(state.layer == .symbols)
    }

    @Test func deleteRepeatSkippingSeveralStepsFiresOnlyOnce() {
        var state = KeyboardState()
        #expect(state.deleteRepeatEdit(heldFor: 0.4) == nil)
        #expect(state.deleteRepeatEdit(heldFor: 1.0) == .deleteBackward)
        #expect(state.deleteRepeatEdit(heldFor: 1.0) == nil)
        #expect(state.deleteRepeatEdit(heldFor: 2.9) == .deleteWordBackward)
        #expect(state.deleteRepeatEdit(heldFor: 2.9) == nil)
    }

    @Test func nilContextCountsAsStartOfDocumentForSentences() {
        var state = KeyboardState()
        state.contextDidChange(KeyboardContext(autocapitalization: .sentences, textBeforeCursor: nil))
        #expect(state.shift == .once)
    }
}
