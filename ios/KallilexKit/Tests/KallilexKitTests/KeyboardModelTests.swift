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
}
