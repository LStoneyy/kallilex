import Foundation
import Testing
import KallilexKit
import KallilexUI
import KallilexKeyboardCore

/// A minimal `ReplaceableTextDocument` fake, mirroring
/// `KallilexKeyboardCoreTests`' `FakeTextDocument` (the cursor is always
/// treated as sitting at the end, so `documentContextBeforeInput` is
/// simply `.text`) plus `setText(_:)` for `KeyboardModel`'s
/// run-result/Undo sync.
@MainActor
private final class FakeKeyboardDocument: ReplaceableTextDocument {
    var text: String = ""

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

    func setText(_ text: String) {
        self.text = text
    }
}

/// A `TextDocument` fake standing in for the host app, with a settable
/// `selectedText` for the take-over/Insert tests below. Like
/// `FakeKeyboardDocument`, the cursor is treated as sitting at the end of
/// `text`: `insertText` replaces `selectedText` if it names a substring of
/// `text` (and clears it, as a real selection collapses after an insert),
/// else appends; `deleteBackward` removes the last `Character`. Good
/// enough for these tests' word-at-the-end scenarios — the full Undo-guard
/// matrix (cursor moves, 30 s expiry, non-trailing selections, …) is
/// `HostBridgeTests`' job against its own, selection-range-aware fake.
@MainActor
private final class FakeSelectableHostDocument: TextDocument {
    var text: String
    var selectedText: String?

    init(text: String = "") {
        self.text = text
    }

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }

    func insertText(_ newText: String) {
        if let selectedText, !selectedText.isEmpty, let range = text.range(of: selectedText) {
            text.replaceSubrange(range, with: newText)
        } else {
            text += newText
        }
        selectedText = nil
    }

    func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()
    }
}

/// A mutable injected clock, forwarded to `KeyboardModel.init(now:)` →
/// `HostBridge`'s own clock — lets the Undo Insert 30 s expiry tests below
/// advance time without a real wait.
@MainActor
private final class MutableClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// Tests for `KeyboardModel` (ios-18). Uses the same
/// `FakeActionRunning`/`FakePasteboard`/`FakeConsentGranting`/
/// `FakeEditorFeedback` fakes as `EditorSessionTests`, plus
/// `FakeKeyboardDocument` above for the Scratchpad/host documents.
@MainActor
struct KeyboardModelTests {
    private func makeSession(runner: any ActionRunning = FakeActionRunning()) -> EditorSession {
        EditorSession(
            actionRunner: runner,
            pasteboard: FakePasteboard(),
            consentGranting: FakeConsentGranting(),
            feedback: FakeEditorFeedback()
        )
    }

    // ---- mode switching --------------------------------------------------

    @Test func modeSwitchingKeepsTheSessionText() {
        let model = KeyboardModel(
            session: makeSession(),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: FakeKeyboardDocument()
        )
        model.session.text = "hello"

        model.mode = .keys
        #expect(model.session.text == "hello")

        model.mode = .prompts
        #expect(model.session.text == "hello")
    }

    // ---- target switching -------------------------------------------------

    @Test func targetSwitchingRoutesEditsToTheRightDocument() {
        let scratchpad = FakeKeyboardDocument()
        let host = FakeKeyboardDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: scratchpad, hostDocument: host)

        model.press(Key(kind: .character("a")), context: KeyboardContext(autocapitalization: .none))
        #expect(scratchpad.text == "a")
        #expect(host.text == "")

        model.target = .host
        model.press(Key(kind: .character("b")), context: KeyboardContext(autocapitalization: .none))
        #expect(host.text == "b")
        #expect(scratchpad.text == "a")
    }

    @Test func targetSwitchReEvaluatesAutoCapitalizationImmediately() {
        let host = FakeKeyboardDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.keyboardState.shift = .off
        // The newly active document (the host) reports `.words`, with
        // nothing before the cursor — `shouldAutoCapitalize` fires for
        // that combination, same as the start of a sentence.
        model.activeContextProvider = {
            KeyboardContext(autocapitalization: .words, textBeforeCursor: host.documentContextBeforeInput)
        }

        model.target = .host

        #expect(model.keyboardState.shift == .once)
    }

    // ---- a run result updates the Scratchpad document ---------------------

    @Test func aRunResultUpdatesTheTextAndTheScratchpadDocument() async {
        let runner = FakeActionRunning()
        let scratchpad = FakeKeyboardDocument()
        let model = KeyboardModel(
            session: makeSession(runner: runner),
            scratchpadDocument: scratchpad,
            hostDocument: FakeKeyboardDocument()
        )
        model.session.text = "hello"

        let task = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")
        await runner.resolveOldest(with: .ok("HELLO"))
        await task.value

        #expect(model.session.text == "HELLO")
        #expect(scratchpad.text == "HELLO")
    }

    @Test func undoRevertsTheTextAndTheScratchpadDocument() async {
        let runner = FakeActionRunning()
        let scratchpad = FakeKeyboardDocument()
        let model = KeyboardModel(
            session: makeSession(runner: runner),
            scratchpadDocument: scratchpad,
            hostDocument: FakeKeyboardDocument()
        )
        model.session.text = "hello"

        let task = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")
        await runner.resolveOldest(with: .ok("HELLO"))
        await task.value
        #expect(scratchpad.text == "HELLO")

        model.undo()

        #expect(model.session.text == "hello")
        #expect(scratchpad.text == "hello")
    }

    // ---- cancelForDisappear -------------------------------------------------

    @Test func cancelForDisappearCancelsARun() async {
        let runner = FakeActionRunning()
        let model = KeyboardModel(
            session: makeSession(runner: runner),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: FakeKeyboardDocument()
        )
        model.session.text = "hello"

        _ = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")
        #expect(model.session.isRunning)

        model.cancelForDisappear()

        #expect(!model.session.isRunning)
    }

    // ---- take-over rules (ios-19) -----------------------------------------

    @Test func aNonEmptySelectionIsTakenOverAutomaticallyWhenTheScratchpadIsEmpty() {
        let host = FakeSelectableHostDocument()
        let scratchpad = FakeKeyboardDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: scratchpad, hostDocument: host)
        host.selectedText = "hello"

        model.refreshHostSelection()

        #expect(model.session.text == "hello")
        #expect(scratchpad.text == "hello")
        #expect(model.pendingTakeSelection == nil)
    }

    @Test func aNewSelectionReplacesTheScratchpadWhileItStillHoldsTheLastTakenOverSelectionUnchanged() {
        let host = FakeSelectableHostDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        host.selectedText = "hello"
        model.refreshHostSelection()
        #expect(model.session.text == "hello")

        // The Scratchpad still holds exactly that selection, untouched —
        // a new one arrives and should replace it automatically too.
        host.selectedText = "world"
        model.refreshHostSelection()

        #expect(model.session.text == "world")
        #expect(model.pendingTakeSelection == nil)
    }

    @Test func aNewSelectionOffersTheChipWhenTheScratchpadHasBeenEditedSince() {
        let host = FakeSelectableHostDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "my own draft"
        host.selectedText = "hello"

        model.refreshHostSelection()

        #expect(model.session.text == "my own draft", "The chip offers the selection; it doesn't apply it")
        #expect(model.pendingTakeSelection == "hello")
    }

    @Test func tappingTheChipAppliesThePendingSelection() {
        let host = FakeSelectableHostDocument()
        let scratchpad = FakeKeyboardDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: scratchpad, hostDocument: host)
        model.session.text = "my own draft"
        host.selectedText = "hello"
        model.refreshHostSelection()
        #expect(model.pendingTakeSelection == "hello")

        model.takeSelectionFromChip()

        #expect(model.session.text == "hello")
        #expect(scratchpad.text == "hello")
        #expect(model.pendingTakeSelection == nil)
    }

    @Test func theChipDisappearsWhenTheSelectionGoesAway() {
        let host = FakeSelectableHostDocument()
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "my own draft"
        host.selectedText = "hello"
        model.refreshHostSelection()
        #expect(model.pendingTakeSelection == "hello")

        host.selectedText = nil
        model.refreshHostSelection()

        #expect(model.pendingTakeSelection == nil)
    }

    @Test func noTakeOverHappensWhileARunIsInFlight() async {
        let runner = FakeActionRunning()
        let host = FakeSelectableHostDocument()
        let model = KeyboardModel(session: makeSession(runner: runner), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "hello"
        let task = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")
        host.selectedText = "world"

        model.refreshHostSelection()
        #expect(model.session.text == "hello", "A run in flight must not be clobbered by a take-over")
        #expect(model.pendingTakeSelection == nil)

        await runner.resolveOldest(with: .ok("HELLO"))
        await task.value
    }

    @Test func takingOverASelectionWhileAResultIsShownLetsEditorUndoRestoreThePriorText() async {
        let runner = FakeActionRunning()
        let host = FakeSelectableHostDocument()
        let scratchpad = FakeKeyboardDocument()
        let model = KeyboardModel(session: makeSession(runner: runner), scratchpadDocument: scratchpad, hostDocument: host)
        model.session.text = "hello"
        let task = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")
        await runner.resolveOldest(with: .ok("HELLO"))
        await task.value
        #expect(model.session.state == .result)

        host.selectedText = "take me"
        model.refreshHostSelection()
        #expect(model.pendingTakeSelection == "take me", "The result in the Scratchpad isn't empty/unchanged, so it's offered, not applied")

        model.takeSelectionFromChip()
        #expect(model.session.text == "take me")
        #expect(scratchpad.text == "take me")
        #expect(model.session.canUndo, "EditorSession's own Undo must still work after a take-over replaces the text")

        model.undo()

        #expect(model.session.text == "hello", "Undo brings back the pre-run text, exactly as it would for any edit after a result")
    }

    // ---- Insert / Undo Insert (ios-19) -------------------------------------

    @Test func canInsertIsFalseWhileTheScratchpadIsEmptyOrWhitespaceOnly() {
        let model = KeyboardModel(
            session: makeSession(),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: FakeSelectableHostDocument()
        )
        #expect(!model.canInsert)

        model.session.text = "   \n  "
        #expect(!model.canInsert)

        model.session.text = "hi"
        #expect(model.canInsert)
    }

    @Test func canInsertIsFalseWhileARunIsInFlight() {
        let runner = FakeActionRunning()
        let model = KeyboardModel(
            session: makeSession(runner: runner),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: FakeSelectableHostDocument()
        )
        model.session.text = "hi"

        _ = model.run(.prompt(instruction: "Fix grammar."), label: "Fix grammar")

        #expect(!model.canInsert)
    }

    /// `insertLabel` only reflects `insertWillReplaceSelection` once that's
    /// synced — `hostSelectionDidChangeSyncsInsertWillReplaceSelectionAndTheInsertLabel`
    /// below covers the sync path; this just checks the default (no sync
    /// yet) state.
    @Test func insertLabelDefaultsToInsertBeforeAnySync() {
        let model = KeyboardModel(
            session: makeSession(),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: FakeSelectableHostDocument()
        )

        #expect(model.insertLabel == "Insert")
    }

    @Test func insertWritesTheScratchpadTextIntoTheHostAndEnablesUndoInsert() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"

        model.insert()

        #expect(host.text == "hello WORLD")
        #expect(model.canUndoInsert)
    }

    @Test func undoInsertRevertsTheHostTextAndDisablesItself() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"
        model.insert()

        model.undoInsert()

        #expect(host.text == "hello world")
        #expect(!model.canUndoInsert)
    }

    @Test func invalidateHostUndoOnDisappearDisablesUndoInsert() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"
        model.insert()
        #expect(model.canUndoInsert)

        model.invalidateHostUndoOnDisappear()

        #expect(!model.canUndoInsert)
    }

    /// Review fix: `canUndoInsert`/`insertWillReplaceSelection` must be
    /// stored, `@Observable`-tracked properties kept in sync by
    /// `hostTextDidChange()`/`hostSelectionDidChange()` — not plain
    /// computed properties reading straight through to `HostBridge`'s own
    /// live state, which SwiftUI can fail to re-render for (no other
    /// tracked property changes alongside them).
    @Test func hostTextDidChangeSyncsCanUndoInsertAfterAStrayEditToTheHost() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"
        model.insert()
        #expect(model.canUndoInsert)

        // Typing on our own keys with the target set to the host (or any
        // other edit reaching it) changes the host's text directly —
        // the controller always forwards this to `hostTextDidChange()`,
        // regardless of the current typing target.
        host.insertText("!")
        model.hostTextDidChange()

        #expect(!model.canUndoInsert)
    }

    @Test func typingOnOurKeysIntoTheHostEndsUndoInsertImmediately() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"
        model.insert()
        #expect(model.canUndoInsert)

        model.target = .host
        model.press(Key(kind: .character("x")), context: KeyboardContext(autocapitalization: .none))

        #expect(!model.canUndoInsert)
    }

    @Test func typingIntoTheScratchpadKeepsUndoInsert() {
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "WORLD"
        model.insert()

        model.target = .scratchpad
        model.press(Key(kind: .character("x")), context: KeyboardContext(autocapitalization: .none))

        #expect(model.canUndoInsert)
    }

    @Test func hostSelectionDidChangeSyncsInsertWillReplaceSelectionAndTheInsertLabel() {
        let host = FakeSelectableHostDocument(text: "hello world")
        let model = KeyboardModel(session: makeSession(), scratchpadDocument: FakeKeyboardDocument(), hostDocument: host)
        model.session.text = "my own draft"
        #expect(!model.insertWillReplaceSelection)
        #expect(model.insertLabel == "Insert")

        host.selectedText = "world"
        model.hostSelectionDidChange()

        #expect(model.insertWillReplaceSelection)
        #expect(model.insertLabel == "Replace selection")

        host.selectedText = nil
        model.hostSelectionDidChange()

        #expect(!model.insertWillReplaceSelection)
        #expect(model.insertLabel == "Insert")
    }

    @Test func undoInsertBecomesUnavailableOnceTheClockPassesThirtySecondsAndStateIsResynced() {
        let clock = MutableClock()
        let host = FakeSelectableHostDocument(text: "hello world")
        host.selectedText = "world"
        let model = KeyboardModel(
            session: makeSession(),
            scratchpadDocument: FakeKeyboardDocument(),
            hostDocument: host,
            now: { clock.now }
        )
        model.session.text = "WORLD"
        model.insert()
        #expect(model.canUndoInsert)

        clock.now.addTimeInterval(30)
        // In production, the real 30 s `Task` armed by `insert()` is what
        // calls back into the model to resync at this point
        // (`scheduleUndoInsertExpiry()`); here, any call that ends in
        // `syncHostState()` re-evaluates `canUndoInsert` against the
        // now-expired window the same way.
        model.refreshHostSelection()

        #expect(!model.canUndoInsert)
    }
}
