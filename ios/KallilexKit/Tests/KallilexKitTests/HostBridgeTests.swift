import Foundation
import Testing
import KallilexKeyboardCore
import KallilexUI

/// A `TextDocument` fake that models an actual document buffer with a
/// selection/cursor (as a `Character`-index half-open range), so
/// `insertText`/`deleteBackward` behave like a real host: `insertText`
/// replaces the current selection (or inserts at the cursor), and
/// `deleteBackward` deletes the selection if there is one, else the
/// preceding `Character` — exactly the ios-15 spike's "one
/// `deleteBackward()` removes one `Character`" result for Notes/Mail/
/// `UITextView`. `selectionRange == nil` is "no selection reported"; an
/// empty (collapsed) range is a plain cursor, which — like the real
/// `HostDocument`/`ScratchpadDocument` — reports `selectedText == nil`
/// too (not `""`).
@MainActor
private final class FakeHostDocument: TextDocument {
    private(set) var characters: [Character]
    var selectionRange: Range<Int>?

    init(text: String = "", cursorAtEnd: Bool = true) {
        characters = Array(text)
        selectionRange = cursorAtEnd ? characters.count..<characters.count : nil
    }

    var text: String { String(characters) }

    var selectedText: String? {
        guard let selectionRange, !selectionRange.isEmpty else { return nil }
        return String(characters[selectionRange])
    }

    var documentContextBeforeInput: String? {
        guard let selectionRange else { return nil }
        return String(characters[0..<selectionRange.lowerBound])
    }

    var documentContextAfterInput: String? {
        guard let selectionRange else { return nil }
        return String(characters[selectionRange.upperBound...])
    }

    func insertText(_ text: String) {
        let range = selectionRange ?? (characters.count..<characters.count)
        characters.replaceSubrange(range, with: Array(text))
        let newCursor = range.lowerBound + text.count
        selectionRange = newCursor..<newCursor
    }

    func deleteBackward() {
        if let selectionRange, !selectionRange.isEmpty {
            characters.removeSubrange(selectionRange)
            self.selectionRange = selectionRange.lowerBound..<selectionRange.lowerBound
            return
        }
        let cursor = selectionRange?.lowerBound ?? characters.count
        guard cursor > 0 else { return }
        characters.remove(at: cursor - 1)
        selectionRange = (cursor - 1)..<(cursor - 1)
    }

    /// Test helper: selects `range` (highlights text, as the user would).
    func select(_ range: Range<Int>) {
        selectionRange = range
    }

    /// Test helper: moves the cursor (an empty "selection") to `index`,
    /// with no text change — a tap elsewhere in the document.
    func moveCursor(to index: Int) {
        selectionRange = index..<index
    }
}

/// A mutable injected clock for the 30 s Undo Insert expiry.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// `HostBridge` (ios-19 spec, "HostBridge" / "Testing Decisions"). Take-over
/// rules are `KeyboardModel`'s own (see `KeyboardModelTests`), since they
/// also need `session.text`; this covers Insert and the guarded Undo
/// Insert against a fake `TextDocument`.
@MainActor
struct HostBridgeTests {
    private func makeBridge(host: FakeHostDocument, clock: TestClock) -> HostBridge {
        HostBridge(host: host, clock: { clock.now })
    }

    // ---- selection snapshot -------------------------------------------

    @Test func refreshUpdatesSelectionLengthFromTheLiveSelection() {
        let host = FakeHostDocument(text: "hello world")
        let bridge = makeBridge(host: host, clock: TestClock())
        host.select(0..<5)

        bridge.refresh()

        #expect(bridge.selectionLength == 5)
    }

    @Test func takeSelectionReadsTheLiveSelectionEachTime() {
        let host = FakeHostDocument(text: "hello world")
        let bridge = makeBridge(host: host, clock: TestClock())

        #expect(bridge.takeSelection() == nil)

        host.select(0..<5)
        #expect(bridge.takeSelection() == "hello")
    }

    // ---- Insert ----------------------------------------------------------

    @Test func insertWithASelectionRecordsWhatWasReplaced() {
        let host = FakeHostDocument(text: "hello world")
        let bridge = makeBridge(host: host, clock: TestClock())
        host.select(6..<11)

        bridge.insert("WORLD")

        #expect(host.text == "hello WORLD")
        #expect(bridge.canUndoInsert)
    }

    @Test func insertWithoutASelectionRecordsNilReplaced() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert("world")

        #expect(host.text == "hello world")
        // No `replaced` text means Undo only deletes, never reinserts —
        // exercised below (`undoWithNoReplacedTextOnlyDeletes`).
    }

    @Test func insertWillReplaceSelectionTracksTheLiveSelection() {
        let host = FakeHostDocument(text: "hello world")
        let bridge = makeBridge(host: host, clock: TestClock())

        #expect(!bridge.insertWillReplaceSelection)

        host.select(6..<11)
        #expect(bridge.insertWillReplaceSelection)

        host.moveCursor(to: 11)
        #expect(!bridge.insertWillReplaceSelection)
    }

    // ---- Undo guard --------------------------------------------------------

    @Test func undoIsAllowedRightAfterInsert() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert("world")

        #expect(bridge.canUndoInsert)
    }

    @Test func undoIsNotAllowedBeforeAnyInsert() {
        let host = FakeHostDocument(text: "hello")
        let bridge = makeBridge(host: host, clock: TestClock())

        #expect(!bridge.canUndoInsert)
    }

    @Test func textDidChangeWithAnUnchangedContextDoesNotInvalidate() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")

        // A spurious notification with nothing actually having changed —
        // the spec's "textDidChange with an unchanged context is fine".
        bridge.textDidChange()
        bridge.textDidChange()

        #expect(bridge.canUndoInsert)
    }

    @Test func undoIsNotAllowedAfterAnotherEditThroughTheHost() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        // Typing on our own keys with the target set to the host counts as
        // an edit (ios-19 spec) — simulated here the same way the
        // controller would observe it: the host's text changes, then the
        // system notifies via `textDidChange`.
        host.insertText("!")
        bridge.textDidChange()

        #expect(!bridge.canUndoInsert)
    }

    @Test func undoIsNotAllowedAfterACursorMove() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        host.moveCursor(to: 0)
        bridge.selectionDidChange()

        #expect(!bridge.canUndoInsert)
    }

    @Test func undoIsNotAllowedAfter30Seconds() {
        let host = FakeHostDocument(text: "hello ")
        let clock = TestClock()
        let bridge = makeBridge(host: host, clock: clock)
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        clock.now.addTimeInterval(30)

        #expect(!bridge.canUndoInsert)
    }

    @Test func undoIsNotAllowedWhenTheContextDoesNotEndWithTheInsertedTextEvenWithoutAHookCall() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        // Move the cursor without ever calling `selectionDidChange()`: the
        // guard's own fresh suffix check (not just the hook latch) must
        // already reject this.
        host.moveCursor(to: 0)

        #expect(!bridge.canUndoInsert)
    }

    /// The hook-based latch's reason to exist: a context match recomputed
    /// fresh at Undo time can't tell "nothing happened" from "something
    /// happened and then coincidentally restored the same tail" — only the
    /// persistent `invalidated` flag, set by a hook call in between, can.
    @Test func undoStaysInvalidatedEvenIfTheContextLaterMatchesAgainByCoincidence() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        // Delete "world" back off, notifying in between (context no longer
        // ends with "world" — latches `invalidated`)...
        for _ in 0..<5 { host.deleteBackward() }
        bridge.textDidChange()
        #expect(!bridge.canUndoInsert)

        // ...then retype exactly "world", which makes the live context
        // match again — the latch must still hold.
        host.insertText("world")
        bridge.textDidChange()

        #expect(!bridge.canUndoInsert)
    }

    // ---- Undo action -------------------------------------------------------

    @Test func undoDeletesCharacterCountTimesAndReinsertsTheReplacedSelection() {
        let host = FakeHostDocument(text: "hello world")
        let bridge = makeBridge(host: host, clock: TestClock())
        host.select(6..<11)

        bridge.insert("WORLD")
        #expect(host.text == "hello WORLD")

        bridge.undoInsert()

        #expect(host.text == "hello world")
        #expect(!bridge.canUndoInsert, "Undo is one-shot")
    }

    @Test func undoWithNoReplacedTextOnlyDeletes() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert("world")
        bridge.undoInsert()

        #expect(host.text == "hello ")
    }

    @Test func undoCountsCharactersNotUnicodeScalarsForAnEmojiZwjSequence() {
        // "👨‍👩‍👧‍👦" (family: man, woman, girl, boy) is four scalars joined by
        // ZWJ, but one extended grapheme cluster / Character — the
        // ios-15 spike's emoji case.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1)
        let host = FakeHostDocument(text: "hi ")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert(family)
        #expect(host.text == "hi \(family)")

        bridge.undoInsert()

        #expect(host.text == "hi ")
    }

    @Test func undoCountsCharactersNotUnicodeScalarsForABaseLetterPlusCombiningAccent() {
        // "e" + U+0301 (combining acute accent) is "é" as two scalars, one
        // Character — the ios-15 spike's combining-accent case.
        let combining = "e\u{301}"
        #expect(combining.count == 1)
        let host = FakeHostDocument(text: "caf")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert(combining)
        #expect(host.text == "caf\(combining)")

        bridge.undoInsert()

        #expect(host.text == "caf")
    }

    @Test func undoHandlesAnInsertedNewline() {
        // The ios-15 spike's newline case: one `deleteBackward()` removes
        // the newline itself as a single `Character`.
        let host = FakeHostDocument(text: "line one")
        let bridge = makeBridge(host: host, clock: TestClock())

        bridge.insert("\nline two")
        #expect(host.text == "line one\nline two")

        bridge.undoInsert()

        #expect(host.text == "line one")
    }

    @Test func undoInsertIsANoOpWhileNotAllowed() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        host.insertText("!")
        bridge.textDidChange()
        #expect(!bridge.canUndoInsert)

        bridge.undoInsert()

        #expect(host.text == "hello world!", "A disallowed Undo must not touch the document at all")
    }

    // ---- invalidateUndo() ---------------------------------------------------

    @Test func invalidateUndoDisablesUndoWithoutTouchingTheDocument() {
        let host = FakeHostDocument(text: "hello ")
        let bridge = makeBridge(host: host, clock: TestClock())
        bridge.insert("world")
        #expect(bridge.canUndoInsert)

        bridge.invalidateUndo()

        #expect(!bridge.canUndoInsert)
        #expect(host.text == "hello world")

        bridge.undoInsert()
        #expect(host.text == "hello world", "undoInsert() after invalidateUndo() must be a no-op")
    }
}
