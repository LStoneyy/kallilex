import Foundation
import Testing
import Synchronization
import KallilexKit
import KallilexUI

/// An `ActionRunning` fake for `EditorSessionTests`: every call suspends on
/// a `CheckedContinuation` until a test explicitly resolves it (FIFO, via
/// `resolveOldest`), so every scenario — including "two runs in flight,
/// resolve the first one late" — is deterministic without any sleeps.
final class FakeActionRunning: ActionRunning, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let text: String
        let action: Action
    }

    private let calls = Mutex<[Call]>([])
    private let pending = Mutex<[CheckedContinuation<RunOutcome, Never>]>([])

    func recordedCalls() -> [Call] {
        calls.withLock { $0 }
    }

    var pendingCount: Int {
        pending.withLock { $0.count }
    }

    func run(text: String, action: Action) async -> RunOutcome {
        calls.withLock { $0.append(Call(text: text, action: action)) }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0.append(continuation) }
        }
    }

    /// Resolves the oldest still-pending call with `outcome`. `EditorSession
    /// .run` starts its runner call from inside a detached `Task`, so the
    /// call this is meant to resolve may not have reached `run(text:
    /// action:)` yet by the time this is invoked right after; this yields
    /// cooperatively (never a timed sleep) until it has, rather than
    /// requiring every test to synchronize on that itself.
    func resolveOldest(with outcome: RunOutcome) async {
        while pending.withLock({ $0.isEmpty }) {
            await Task.yield()
        }
        let continuation = pending.withLock { $0.removeFirst() }
        continuation.resume(returning: outcome)
    }
}

/// A `ConsentGranting` fake: records every call, and either succeeds or
/// throws `Failure.boom` depending on `behavior`.
final class FakeConsentGranting: ConsentGranting, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let profileID: String
        let host: String
    }

    enum Behavior {
        case succeeding
        case throwing
    }

    enum Failure: Error {
        case boom
    }

    private let behavior: Behavior
    private let calls = Mutex<[Call]>([])

    init(_ behavior: Behavior = .succeeding) {
        self.behavior = behavior
    }

    func recordedCalls() -> [Call] {
        calls.withLock { $0 }
    }

    func grantConsent(profileID: String, host: String) throws {
        calls.withLock { $0.append(Call(profileID: profileID, host: host)) }
        if case .throwing = behavior {
            throw Failure.boom
        }
    }
}

/// A `Pasteboard` fake: records every `setString` call.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let strings = Mutex<[String]>([])

    func setString(_ string: String) {
        strings.withLock { $0.append(string) }
    }

    func recordedStrings() -> [String] {
        strings.withLock { $0 }
    }
}

/// An `EditorFeedback` fake: records every announcement and haptic call.
final class FakeEditorFeedback: EditorFeedback, @unchecked Sendable {
    private let announcements = Mutex<[String]>([])
    private let successCount = Mutex<Int>(0)
    private let errorCount = Mutex<Int>(0)

    func recordedAnnouncements() -> [String] {
        announcements.withLock { $0 }
    }

    func recordedSuccessCount() -> Int {
        successCount.withLock { $0 }
    }

    func recordedErrorCount() -> Int {
        errorCount.withLock { $0 }
    }

    func announce(_ message: String) {
        announcements.withLock { $0.append(message) }
    }

    func success() {
        successCount.withLock { $0 += 1 }
    }

    func error() {
        errorCount.withLock { $0 += 1 }
    }
}

/// Tests for `EditorSession`. See
/// `issues-ios/spec-ios-08-shared-editor-and-scratchpad.md`.
@MainActor
struct EditorSessionTests {
    func sampleProfile(
        id: String = "p1",
        baseUrl: String = "https://api.openai.com/v1"
    ) -> ProviderProfile {
        ProviderProfile(id: id, name: "OpenAI", baseUrl: baseUrl, model: "gpt-4")
    }

    func makeSession(
        actionRunner: FakeActionRunning = FakeActionRunning(),
        pasteboard: FakePasteboard = FakePasteboard(),
        consentGranting: FakeConsentGranting = FakeConsentGranting(),
        feedback: FakeEditorFeedback = FakeEditorFeedback()
    ) -> EditorSession {
        EditorSession(
            actionRunner: actionRunner,
            pasteboard: pasteboard,
            consentGranting: consentGranting,
            feedback: feedback
        )
    }

    // ---- idle ----------------------------------------------------------

    @Test func startsIdleAndEmpty() {
        let session = makeSession()
        #expect(session.text == "")
        #expect(session.state == .idle)
        #expect(session.isEditable)
        #expect(!session.isRunning)
    }

    // ---- run: success / failure ----------------------------------------

    @Test func runAPromptReplacesTextOnSuccess() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix grammar"), label: "Fix grammar")
        #expect(session.isRunning)
        #expect(session.state == .running(.prompt(instruction: "Fix grammar")))

        await fake.resolveOldest(with: .ok("HELLO"))
        await task.value

        #expect(session.state == .result)
        #expect(session.text == "HELLO")
        #expect(session.lastInput == "hello")
        #expect(fake.recordedCalls() == [FakeActionRunning.Call(text: "hello", action: .prompt(instruction: "Fix grammar"))])
    }

    @Test func runFailureSetsFailedState() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .failed(.missingModel))
        await task.value

        #expect(session.state == .failed(.missingModel))
        // The original text is left alone on failure.
        #expect(session.text == "hello")
    }

    @Test func notConfiguredSetsNotConfiguredState() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .notConfigured)
        await task.value

        #expect(session.state == .notConfigured)
    }

    // ---- cancellation ----------------------------------------------------

    @Test func cancelWhileRunningReturnsToIdle() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        #expect(session.isRunning)

        session.cancel()
        #expect(session.state == .idle)
        #expect(session.isEditable)

        // The cancelled run's outcome, even if it resolves afterward, must
        // never change state.
        await fake.resolveOldest(with: .ok("too late"))
        await task.value
        #expect(session.state == .idle)
        #expect(session.text == "hello")
    }

    @Test func runWhileRunningCancelsThePreviousRunAndStartsANewOne() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "first"

        let taskA = session.run(.prompt(instruction: "A"), label: "A")
        session.text = "second"
        let taskB = session.run(.prompt(instruction: "B"), label: "B")

        // `state`/`lastInput` are updated synchronously inside `run`, so
        // these hold regardless of whether the detached tasks have reached
        // `actionRunner.run` yet.
        #expect(session.state == .running(.prompt(instruction: "B")))
        #expect(session.lastInput == "second")

        await fake.resolveOldest(with: .ok("A result"))
        await taskA.value
        await fake.resolveOldest(with: .ok("B result"))
        await taskB.value

        #expect(session.state == .result)
        #expect(session.text == "B result")
        // Both runs reached the action runner — the first wasn't just
        // dropped, it was actually cancelled/superseded.
        #expect(fake.recordedCalls().count == 2)
    }

    @Test func supersededRunOutcomeIsIgnoredEvenWhenItResolvesLast() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "first"

        let taskA = session.run(.prompt(instruction: "A"), label: "A")
        session.text = "second"
        let taskB = session.run(.prompt(instruction: "B"), label: "B")

        // Resolve B (the current run) first, then A (the superseded run)
        // late — A's outcome must never overwrite B's.
        await fake.resolveOldest(with: .ok("A result"))
        await taskA.value
        await fake.resolveOldest(with: .ok("B result"))
        await taskB.value

        #expect(session.state == .result)
        #expect(session.text == "B result")

        // Re-run from the result so we can show A resolving "late" (after
        // B already completed) still changes nothing.
        #expect(session.lastAction == .prompt(instruction: "B"))
    }

    @Test func textIsNotEditableWhileRunning() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        #expect(!session.isEditable)

        await fake.resolveOldest(with: .ok("HELLO"))
        await task.value
        #expect(session.isEditable)
    }

    // ---- retry -------------------------------------------------------------

    @Test func retryResetsTextAndRerunsLastAction() async throws {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task1 = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .ok("HELLO"))
        await task1.value
        #expect(session.text == "HELLO")

        let task2 = try #require(session.retry())
        #expect(session.text == "hello")
        #expect(session.state == .running(.prompt(instruction: "Fix")))

        await fake.resolveOldest(with: .ok("HELLO AGAIN"))
        await task2.value

        #expect(session.text == "HELLO AGAIN")
        #expect(fake.recordedCalls().map(\.text) == ["hello", "hello"])
    }

    // ---- undo --------------------------------------------------------------

    @Test func undoResetsTextToLastInputAfterAResult() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .ok("HELLO"))
        await task.value

        #expect(session.canUndo)
        session.undo()

        #expect(session.text == "hello")
        #expect(session.state == .idle)
    }

    @Test func undoIsANoOpOutsideResultState() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        session.cancel()
        await fake.resolveOldest(with: .ok("ignored"))
        await task.value

        session.text = "edited by hand"
        #expect(!session.canUndo)
        session.undo()

        #expect(session.text == "edited by hand")
        #expect(session.state == .idle)
    }

    // ---- edit after result --------------------------------------------------

    @Test func editingAfterAResultThenRunningUsesTheEditedText() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task1 = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .ok("HELLO"))
        await task1.value

        session.text = "HELLO, EDITED"
        let task2 = session.run(.prompt(instruction: "Shorten"), label: "Shorten")
        #expect(session.lastInput == "HELLO, EDITED")

        await fake.resolveOldest(with: .ok("SHORT"))
        await task2.value

        #expect(fake.recordedCalls().last?.text == "HELLO, EDITED")
        #expect(session.text == "SHORT")
    }

    // ---- show original -------------------------------------------------------

    @Test func showingOriginalDisplaysLastInputReadOnly() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .ok("HELLO"))
        await task.value

        session.showingOriginal = true
        #expect(session.displayedText == "hello")
        #expect(!session.isEditable)

        session.showingOriginal = false
        #expect(session.displayedText == "HELLO")
        #expect(session.isEditable)
    }

    // ---- consent -------------------------------------------------------------

    @Test func consentRequiredThenAllowGrantsConsentAndRetriesTheAction() async throws {
        let fake = FakeActionRunning()
        let consentGranting = FakeConsentGranting()
        let session = makeSession(actionRunner: fake, consentGranting: consentGranting)
        let profile = sampleProfile()
        session.text = "hello"

        let task1 = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .consentRequired(profile))
        await task1.value
        #expect(session.state == .consentRequired(profile))

        let task2 = try #require(session.grantConsentAndRetry())
        #expect(consentGranting.recordedCalls() == [FakeConsentGranting.Call(profileID: "p1", host: "api.openai.com")])

        await fake.resolveOldest(with: .ok("FIXED"))
        await task2.value

        #expect(session.state == .result)
        #expect(session.text == "FIXED")
    }

    @Test func consentRequiredThenDeclineGoesIdleWithANote() async {
        let fake = FakeActionRunning()
        let session = makeSession(actionRunner: fake)
        let profile = sampleProfile()
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .consentRequired(profile))
        await task.value

        session.declineConsent()

        #expect(session.state == .idle)
        #expect(session.inlineNote == "Nothing was sent.")
    }

    @Test func consentGrantFailureKeepsConsentRequiredAndDoesNotRetry() async {
        let fake = FakeActionRunning()
        let consentGranting = FakeConsentGranting(.throwing)
        let session = makeSession(actionRunner: fake, consentGranting: consentGranting)
        let profile = sampleProfile()
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix")
        await fake.resolveOldest(with: .consentRequired(profile))
        await task.value

        let retryTask = session.grantConsentAndRetry()

        #expect(retryTask == nil)
        #expect(session.state == .consentRequired(profile))
        #expect(session.inlineNote == "Couldn't save your choice. Try again.")
        // No second call was ever made to the action runner.
        #expect(fake.recordedCalls().count == 1)
    }

    // ---- copy ----------------------------------------------------------------

    @Test func copyWritesCurrentTextToThePasteboard() {
        let pasteboard = FakePasteboard()
        let session = makeSession(pasteboard: pasteboard)
        session.text = "hello"

        session.copy()

        #expect(pasteboard.recordedStrings() == ["hello"])
    }

    // ---- announcements and haptics --------------------------------------------

    @Test func announcesRunningThenDoneAndPlaysSuccessHaptic() async {
        let fake = FakeActionRunning()
        let feedback = FakeEditorFeedback()
        let session = makeSession(actionRunner: fake, feedback: feedback)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix grammar")
        #expect(feedback.recordedAnnouncements() == ["Rewriting with Fix grammar…"])

        await fake.resolveOldest(with: .ok("HELLO"))
        await task.value

        #expect(feedback.recordedAnnouncements() == ["Rewriting with Fix grammar…", "Done. The result is ready."])
        #expect(feedback.recordedSuccessCount() == 1)
        #expect(feedback.recordedErrorCount() == 0)
    }

    @Test func copyAnnouncesCopied() {
        let feedback = FakeEditorFeedback()
        let session = makeSession(feedback: feedback)
        session.text = "hello"

        session.copy()

        #expect(feedback.recordedAnnouncements() == ["Copied"])
    }

    @Test func announcesTheErrorDescriptionAndPlaysErrorHaptic() async {
        let fake = FakeActionRunning()
        let feedback = FakeEditorFeedback()
        let session = makeSession(actionRunner: fake, feedback: feedback)
        session.text = "hello"

        let task = session.run(.prompt(instruction: "Fix"), label: "Fix grammar")
        await fake.resolveOldest(with: .failed(.missingModel))
        await task.value

        #expect(feedback.recordedAnnouncements().last == ProviderError.missingModel.localizedDescription)
        #expect(feedback.recordedErrorCount() == 1)
        #expect(feedback.recordedSuccessCount() == 0)
    }

    // ---- long text -------------------------------------------------------------

    @Test func isTextLongReflectsTheTwentyThousandCharacterThreshold() {
        let session = makeSession()
        session.text = String(repeating: "a", count: 20_000)
        #expect(!session.isTextLong)

        session.text = String(repeating: "a", count: 20_001)
        #expect(session.isTextLong)
    }
}

/// An `ActionRunning` that hangs until its task is cancelled and reports
/// the cancellation through `cancelled`.
final class HangingActionRunning: ActionRunning {
    let cancelled: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (cancelled, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func run(text: String, action: Action) async -> RunOutcome {
        let continuation = continuation
        await withTaskCancellationHandler {
            // Suspends until cancelled; nothing else resumes it.
            let (stream, _) = AsyncStream.makeStream(of: Void.self)
            for await _ in stream {}
        } onCancel: {
            continuation.yield()
        }
        return .cancelled
    }
}

@MainActor
struct EditorSessionLifetimeTests {
    /// Releasing the session mid-run (e.g. the share sheet is dismissed)
    /// cancels the in-flight request instead of letting it run on.
    @Test func releasingTheSessionCancelsTheRun() async {
        let runner = HangingActionRunning()
        var session: EditorSession? = EditorSession(
            actionRunner: runner,
            pasteboard: FakePasteboard(),
            consentGranting: FakeConsentGranting(),
            feedback: FakeEditorFeedback()
        )
        session?.text = "hello"
        session?.run(.prompt(instruction: "x"), label: "X")
        // Let the run reach the runner before dropping the session.
        await Task.yield()
        session = nil

        var iterator = runner.cancelled.makeAsyncIterator()
        let wasCancelled: Void? = await iterator.next()
        #expect(wasCancelled != nil)
    }
}
