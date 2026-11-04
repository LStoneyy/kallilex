import Foundation
import SwiftUI
import KallilexKit

/// Writes text to a pasteboard. A seam over `UIPasteboard` (ios-08) so
/// `EditorSession.copy()` is testable with a fake; the production
/// implementation (`DevicePasteboard`, ios-09/the Scratchpad tab) lives
/// outside this package, next to the concrete `UIPasteboard` it wraps.
public protocol Pasteboard: Sendable {
    func setString(_ string: String)
}

/// Grants AI-data-sharing consent for a `(profileID, host)` pair. Injected
/// so `EditorSession` can grant consent without depending on a concrete
/// `SettingsStore`/`SettingsService` shape in its tests.
public protocol ConsentGranting: Sendable {
    func grantConsent(profileID: String, host: String) throws
}

/// The production `ConsentGranting`: wraps `SettingsService.grantConsent`
/// (ios-04/ios-05).
public struct SettingsServiceConsentGranter: ConsentGranting {
    private let settingsService: SettingsService

    public init(settingsService: SettingsService) {
        self.settingsService = settingsService
    }

    public func grantConsent(profileID: String, host: String) throws {
        try settingsService.grantConsent(profileID: profileID, host: host)
    }
}

/// Accessibility announcements and haptic feedback triggered by
/// `EditorSession` state transitions, injected so tests can assert on them
/// without touching real VoiceOver/UIKit APIs. `@MainActor` because the
/// production implementation drives `UINotificationFeedbackGenerator`,
/// which is itself main-actor-isolated; `EditorSession` (also `@MainActor`)
/// is the only caller.
@MainActor
public protocol EditorFeedback: Sendable {
    /// Posts a VoiceOver announcement.
    func announce(_ message: String)
    /// Plays the "success" haptic.
    func success()
    /// Plays the "error" haptic.
    func error()
}

/// The production `EditorFeedback`: VoiceOver announcements via
/// `AccessibilityNotification.Announcement`, haptics via
/// `UINotificationFeedbackGenerator` (PLAN.md §11).
public struct ProductionEditorFeedback: EditorFeedback {
    public init() {}

    public func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    public func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    public func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// State container for the shared editor (ios-08, PLAN.md §4.2/§4.3/§8.3):
/// owns the editor's text, the current/last run, and every state
/// transition (running, result, failed, not configured, consent required),
/// plus the side effects (VoiceOver announcements, haptics) those
/// transitions trigger. Shared between the Scratchpad tab and the Share
/// Extension (ios-09), both of which render it through the reusable
/// `KallilexUI` components below rather than duplicating this logic.
///
/// Depends on `any ActionRunning` (not the concrete `ActionRunner`), `any
/// Pasteboard` and `any ConsentGranting` so every state transition is
/// testable with fakes — see `EditorSessionTests`.
@Observable @MainActor
public final class EditorSession: Sendable {
    /// Soft warning threshold (PLAN.md §8.3): 20,000 characters. Not a hard
    /// limit — the on-device hard limit is ios-10.
    public static let longTextThreshold = 20_000

    public enum State: Equatable {
        case idle
        case running(Action)
        case result
        case failed(ProviderError)
        case notConfigured
        case consentRequired(ProviderProfile)
    }

    /// The editor's current content. Always the single source of truth for
    /// what's displayed and edited while `isEditable` is `true`; a result
    /// replaces it in place rather than being held separately.
    public var text: String = ""
    /// The text the most recent run used as its input — the target of
    /// `undo()`/`retry()`, and the "original" shown by `showingOriginal`.
    public private(set) var lastInput: String = ""
    public private(set) var lastAction: Action?
    /// The prompt label (or the localized "Custom instruction") the most
    /// recent run used, for the running status and VoiceOver announcement.
    public private(set) var lastLabel: String = ""
    /// Toggles the editor between the current `text` and `lastInput` while
    /// `state == .result`. Reset to `false` whenever a new run starts.
    public var showingOriginal: Bool = false
    public private(set) var state: State = .idle
    /// A short note shown below the editor outside of any other state
    /// (currently only set by `grantConsentAndRetry()`/`declineConsent()`).
    public var inlineNote: String?

    public let actionRunner: any ActionRunning
    public let pasteboard: any Pasteboard
    public let consentGranting: any ConsentGranting
    public let feedback: any EditorFeedback

    private var runTask: Task<Void, Never>?

    isolated deinit {
        runTask?.cancel()
    }
    /// Identifies the run currently allowed to mutate state. Replaced every
    /// time `run(_:label:)` or `cancel()` runs, so an outcome from a
    /// superseded or already-cancelled run can never change state — even if
    /// the underlying `Task` itself ignores cancellation (as test fakes may
    /// do on purpose).
    private var currentToken = UUID()

    public init(
        actionRunner: any ActionRunning,
        pasteboard: any Pasteboard,
        consentGranting: any ConsentGranting,
        feedback: any EditorFeedback = ProductionEditorFeedback()
    ) {
        self.actionRunner = actionRunner
        self.pasteboard = pasteboard
        self.consentGranting = consentGranting
        self.feedback = feedback
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// `false` while running or while showing the original (both display
    /// read-only content), so a result or the original is never clobbered
    /// by in-flight edits.
    public var isEditable: Bool {
        !isRunning && !showingOriginal
    }

    /// The text the editor should currently display: `lastInput` while
    /// `showingOriginal` is on, `text` otherwise.
    public var displayedText: String {
        showingOriginal ? lastInput : text
    }

    /// `true` once a result has been applied and not yet undone or edited
    /// back to `lastInput` — the only state Undo is available in.
    public var canUndo: Bool {
        guard case .result = state else { return false }
        return text != lastInput
    }

    public var canRetry: Bool {
        lastAction != nil && !isRunning
    }

    public var canCopy: Bool {
        !text.isEmpty
    }

    /// `true` when `text` exceeds `longTextThreshold` — drives the
    /// non-blocking `LongTextWarning`.
    public var isTextLong: Bool {
        text.count > Self.longTextThreshold
    }

    /// Cancels any in-flight run, records `text` as `lastInput`/`lastAction`
    /// /`lastLabel`, and starts a new run. The outcome updates `state`
    /// unless superseded by a later call to `run`/`cancel` first. Returns
    /// the underlying `Task` (`@discardableResult`) so tests can await it
    /// deterministically via `task.value` or `waitForCurrentRun()`.
    @discardableResult
    public func run(_ action: Action, label: String) -> Task<Void, Never> {
        runTask?.cancel()
        let token = UUID()
        currentToken = token

        let input = text
        lastInput = input
        lastAction = action
        lastLabel = label
        showingOriginal = false
        inlineNote = nil
        state = .running(action)

        feedback.announce(String(
            localized: "editor.running",
            defaultValue: "Rewriting with \(label)…",
            bundle: .module
        ))

        // Capture the runner, not `self`, across the await: the session can
        // then be released mid-run (e.g. the share sheet is dismissed), and
        // its deinit cancels the request.
        let runner = actionRunner
        let task = Task { @MainActor [weak self] in
            let outcome = await runner.run(text: input, action: action)
            self?.handleOutcome(outcome, token: token)
        }
        runTask = task
        return task
    }

    /// Awaits the currently in-flight run, if any. No-op (returns
    /// immediately) once `state` is no longer `.running`. Tests use this
    /// instead of sleeping to observe a run's final state deterministically.
    public func waitForCurrentRun() async {
        guard let runTask else { return }
        await runTask.value
    }

    private func handleOutcome(_ outcome: RunOutcome, token: UUID) {
        guard token == currentToken else { return }
        runTask = nil
        switch outcome {
        case .ok(let result):
            text = result
            state = .result
            feedback.announce(String(
                localized: "editor.done.announcement",
                defaultValue: "Done. The result is ready.",
                bundle: .module
            ))
            feedback.success()
        case .notConfigured:
            state = .notConfigured
        case .consentRequired(let profile):
            state = .consentRequired(profile)
        case .cancelled:
            state = .idle
        case .failed(let error):
            state = .failed(error)
            feedback.announce(error.localizedDescription)
            feedback.error()
        }
    }

    /// Cancels the in-flight run, if any, and returns to `.idle`. Any
    /// outcome the cancelled run produces afterward is ignored (see
    /// `currentToken`).
    public func cancel() {
        runTask?.cancel()
        runTask = nil
        currentToken = UUID()
        state = .idle
    }

    /// Resets `text` to `lastInput` and re-runs `lastAction` with
    /// `lastLabel` — a no-op if nothing has ever run.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard let lastAction else { return nil }
        text = lastInput
        return run(lastAction, label: lastLabel)
    }

    /// Reverts to `lastInput` and returns to `.idle`. Only meaningful (and
    /// only intended to be enabled by callers) while `canUndo` is `true`.
    public func undo() {
        guard case .result = state else { return }
        text = lastInput
        showingOriginal = false
        state = .idle
    }

    /// Writes `text` to the injected `pasteboard` and announces it to
    /// VoiceOver.
    public func copy() {
        pasteboard.setString(text)
        feedback.announce(String(localized: "editor.copied", defaultValue: "Copied", bundle: .module))
    }

    /// While `state == .consentRequired(profile)`: grants consent for
    /// `profile`'s current host and re-runs `lastAction`. If granting
    /// throws, `state` stays `.consentRequired`, `inlineNote` explains the
    /// failure, and nothing is sent. A no-op (returns `nil`) outside
    /// `.consentRequired`, or if `profile`'s `baseUrl` has no host.
    @discardableResult
    public func grantConsentAndRetry() -> Task<Void, Never>? {
        guard case .consentRequired(let profile) = state,
              let lastAction,
              let host = consentHost(for: profile) else { return nil }
        do {
            try consentGranting.grantConsent(profileID: profile.id, host: host)
        } catch {
            inlineNote = String(
                localized: "editor.consent.saveFailed",
                defaultValue: "Couldn't save your choice. Try again.",
                bundle: .module
            )
            return nil
        }
        return run(lastAction, label: lastLabel)
    }

    /// Declines the pending consent request: returns to `.idle` without
    /// sending anything, and leaves an explanatory `inlineNote`.
    public func declineConsent() {
        state = .idle
        inlineNote = String(
            localized: "editor.consent.declined",
            defaultValue: "Nothing was sent.",
            bundle: .module
        )
    }
}
