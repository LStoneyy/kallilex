import Testing
@testable import KallilexKeyboardCore

/// A minimal `TextDocument` fake: `.text` is the whole document, and the
/// cursor is always treated as sitting at its end (so
/// `documentContextBeforeInput` is simply `.text`), which is all
/// `EditRouter` needs.
private final class FakeTextDocument: TextDocument {
    var text: String

    init(text: String = "") {
        self.text = text
    }

    var selectedText: String? { nil }
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }

    func insertText(_ text: String) {
        self.text += text
    }

    func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()
    }
}

/// `EditRouter`. See
/// `issues-ios/spec-ios-17-keyboard-core-layouts-state-routing.md`.
@MainActor
struct EditRouterTests {
    // ---- routing ------------------------------------------------------

    @Test func editsGoToTheActiveDocument() {
        let scratchpad = FakeTextDocument()
        let host = FakeTextDocument()
        let router = EditRouter(scratchpad: scratchpad, host: host)

        router.apply([.insert("hi")])

        #expect(scratchpad.text == "hi")
        #expect(host.text == "")
    }

    @Test func switchingTargetRoutesSubsequentEditsToTheOtherDocument() {
        let scratchpad = FakeTextDocument()
        let host = FakeTextDocument()
        let router = EditRouter(scratchpad: scratchpad, host: host)

        router.apply([.insert("scratch")])
        router.target = .host
        router.apply([.insert("host-text")])

        #expect(scratchpad.text == "scratch")
        #expect(host.text == "host-text")
        #expect(router.activeDocument === host)
    }

    @Test func deleteBackwardAppliesToTheActiveDocument() {
        let scratchpad = FakeTextDocument(text: "hello")
        let host = FakeTextDocument(text: "world")
        let router = EditRouter(scratchpad: scratchpad, host: host)
        router.target = .host

        router.apply([.deleteBackward])

        #expect(host.text == "worl")
        #expect(scratchpad.text == "hello")
    }

    // ---- word deletion: counting Characters, including emoji / ZWJ / combining marks ----

    @Test func wordBackwardDeletesJustThePrecedingWordWhenNoTrailingWhitespace() {
        #expect(EditRouter.wordBackwardDeleteCount(before: "hello world") == 5)
    }

    @Test func wordBackwardAlsoEatsTrailingWhitespace() {
        #expect(EditRouter.wordBackwardDeleteCount(before: "hello world ") == 6)
    }

    @Test func wordBackwardOnASingleWordDeletesAllOfIt() {
        #expect(EditRouter.wordBackwardDeleteCount(before: "hello") == 5)
    }

    @Test func wordBackwardOnEmptyTextDeletesNothing() {
        #expect(EditRouter.wordBackwardDeleteCount(before: "") == 0)
    }

    @Test func wordBackwardCountsAZwjEmojiSequenceAsOneCharacter() {
        // "👨‍👩‍👧‍👦" (family: man, woman, girl, boy) is four scalars joined by
        // ZWJ, but one extended grapheme cluster / Character.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1)
        #expect(EditRouter.wordBackwardDeleteCount(before: "hi \(family)") == 1)
    }

    @Test func wordBackwardCountsABaseLetterPlusCombiningAccentAsOneCharacter() {
        // "e" + U+0301 (combining acute accent) is "é" as two scalars, one Character.
        let combining = "e\u{301}"
        #expect(combining.count == 1)
        #expect(EditRouter.wordBackwardDeleteCount(before: "caf\(combining)") == 4)
    }

    @Test func applyingDeleteWordBackwardIssuesOneDeleteBackwardPerCharacter() {
        let family = "👨‍👩‍👧‍👦"
        let scratchpad = FakeTextDocument(text: "hi \(family)")
        let host = FakeTextDocument()
        let router = EditRouter(scratchpad: scratchpad, host: host)

        router.apply([.deleteWordBackward])

        // Only the one-Character emoji is removed; "hi " (including its
        // trailing space) stays, since that space precedes the word rather
        // than trailing the cursor.
        #expect(scratchpad.text == "hi ")
    }

    @Test func applyingDeleteWordBackwardOnCombiningAccentsRemovesExactlyTheWord() {
        let combining = "e\u{301}"
        let scratchpad = FakeTextDocument(text: "hello caf\(combining)")
        let host = FakeTextDocument()
        let router = EditRouter(scratchpad: scratchpad, host: host)

        router.apply([.deleteWordBackward])

        #expect(scratchpad.text == "hello ")
    }

    @Test func wordBackwardDeletesTheNewlineThenTheWordBeforeIt() {
        #expect(EditRouter.wordBackwardDeleteCount(before: "hello\n") == 6)
    }
}
