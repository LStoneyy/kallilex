import Foundation
import SwiftUI
import KallilexKit
import KallilexKeyboardCore

/// A `TextDocument` whose entire contents can be replaced wholesale, not
/// just edited one `Edit` at a time. Only the Scratchpad document needs
/// this: it's how `KeyboardModel` pushes a run result or an Undo into the
/// real `ScratchpadTextView` (ios-18's "Scratchpad text view (UIKit)" —
/// "a result or Undo from the session sets the text view's text and moves
/// the caret to the end"), mirrored onto whichever concrete document
/// backs the keyboard's own text view in production, or a fake in tests.
/// Kept out of `KallilexKeyboardCore.TextDocument` itself: that
/// protocol's other conformer, the host app via `textDocumentProxy`, has
/// no such operation (there is no "replace the whole document" on
/// `UITextDocumentProxy`). `@MainActor`, like `TextDocument` itself.
@MainActor
public protocol ReplaceableTextDocument: TextDocument {
    /// Replaces the entire document with `text` and moves the caret to
    /// the end.
    func setText(_ text: String)
}

/// Which mode the keyboard is showing (PLAN-keyboard.md §5): the large
/// Scratchpad with the prompt chips and the action row, or the compact
/// Scratchpad with the typing target switch and the keys.
public enum KeyboardUIMode: Equatable, Sendable {
    case prompts
    case keys
}

/// Process-wide keyboard state (ios-18's "Session and lifecycle"): the
/// mode, the typing target, the loaded settings snapshot, the (unchanged)
/// `EditorSession`, and the pure `KeyboardState` typing state machine —
/// everything a `KallilexKeyboardController` needs to survive being
/// deallocated and recreated on every appearance (ios-15 spike, unknown
/// 10). Held by `KeyboardModelStore.shared`, never by the controller
/// itself, and never persisted to disk.
///
/// Deliberately doesn't change `EditorSession`: `run`/`retry`/`undo`/
/// `grantConsentAndRetry` here call straight through to the session
/// unchanged, then push the resulting `session.text` into
/// `scratchpadDocument` via `ReplaceableTextDocument.setText(_:)`. That
/// sync step is the thing `KeyboardModelTests` exercises with a fake
/// document instead of a real text view.
@Observable @MainActor
public final class KeyboardModel {
    public var mode: KeyboardUIMode = .prompts
    public var settings: AppSettings?
    public var keyboardState: KeyboardState

    public let session: EditorSession
    public let editRouter: EditRouter
    public let scratchpadDocument: any ReplaceableTextDocument
    public let hostDocument: any TextDocument

    /// Supplies the `KeyboardContext` for whichever document `target`
    /// currently selects — set by the controller to the same builder
    /// `currentKeyboardContext()` uses. `target`'s setter calls this
    /// (when set) immediately after switching and feeds the result
    /// through `contextDidChange`, so auto-capitalization (shift) is
    /// correct for the newly active document right away rather than only
    /// after its next keystroke/selection change.
    public var activeContextProvider: (() -> KeyboardContext)?

    /// Forwards to `editRouter.target`: the single source of truth for
    /// which document typed edits currently go to.
    /// Stored in the plain (non-observable) `EditRouter`, so the getter and
    /// setter register the access/mutation with Observation by hand —
    /// otherwise SwiftUI (`KeyboardTargetSwitch`) never sees the change.
    public var target: TypingTargetKind {
        get {
            access(keyPath: \.target)
            return editRouter.target
        }
        set {
            guard newValue != editRouter.target else { return }
            withMutation(keyPath: \.target) {
                editRouter.target = newValue
            }
            if let activeContextProvider {
                contextDidChange(activeContextProvider())
            }
        }
    }

    public init(
        session: EditorSession,
        scratchpadDocument: any ReplaceableTextDocument,
        hostDocument: any TextDocument,
        keyboardState: KeyboardState = KeyboardState()
    ) {
        self.session = session
        self.scratchpadDocument = scratchpadDocument
        self.hostDocument = hostDocument
        self.keyboardState = keyboardState
        self.editRouter = EditRouter(scratchpad: scratchpadDocument, host: hostDocument)
    }

    /// `KeyboardLayoutID.resolve`'d from the loaded `settings` (or the
    /// device language, absent any) — ios-18 spec item 8. Re-evaluated on
    /// every access rather than cached, since `settings` can change after
    /// a fresh `viewWillAppear` load.
    public var keyboardLayoutID: KeyboardLayoutID {
        KeyboardLayoutID.resolve(stored: settings?.keyboardLayout, preferredLanguages: Locale.preferredLanguages)
    }

    // MARK: - Typing (KallilexKeyboardCore, ios-17)

    /// A regular key press: delegates to `keyboardState`, then applies the
    /// resulting edits to whichever document `target` currently selects.
    @discardableResult
    public func press(_ key: Key, context: KeyboardContext, now: Date = Date()) -> [Edit] {
        let edits = keyboardState.press(key, context: context, now: now)
        editRouter.apply(edits)
        return edits
    }

    /// A long-press popup selection (an alternate character, e.g. "ä" from
    /// holding "a").
    @discardableResult
    public func longPressSelect(_ alternate: String, context: KeyboardContext) -> [Edit] {
        let edits = keyboardState.longPressSelect(alternate, context: context)
        editRouter.apply(edits)
        return edits
    }

    /// Call whenever the surrounding document context changes (a tap
    /// moving the cursor, a target switch, the Scratchpad's own edits) so
    /// auto-capitalization stays correct.
    public func contextDidChange(_ context: KeyboardContext) {
        keyboardState.contextDidChange(context)
    }

    /// Call on every delete-repeat timer tick while the delete key is
    /// held; see `KeyboardState.deleteRepeatEdit(heldFor:)` for the tick
    /// contract (ticks ~0.05 s apart, cumulative duration since press).
    public func deleteRepeatTick(heldFor: TimeInterval) {
        guard let edit = keyboardState.deleteRepeatEdit(heldFor: heldFor) else { return }
        editRouter.apply([edit])
    }

    /// Call when the delete key is released, so the next hold starts
    /// counting from zero.
    public func resetDeleteRepeat() {
        keyboardState.resetDeleteRepeat()
    }

    // MARK: - Prompts (wraps `EditorSession`, unchanged)

    /// Runs `action`, then — once it completes — pushes the (possibly
    /// updated) `session.text` into `scratchpadDocument`. A no-op write if
    /// the run didn't change `text` (e.g. `.notConfigured`, `.cancelled`).
    @discardableResult
    public func run(_ action: Action, label: String) -> Task<Void, Never> {
        syncScratchpadAfter(session.run(action, label: label))
    }

    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard let task = session.retry() else { return nil }
        return syncScratchpadAfter(task)
    }

    @discardableResult
    public func grantConsentAndRetry() -> Task<Void, Never>? {
        guard let task = session.grantConsentAndRetry() else { return nil }
        return syncScratchpadAfter(task)
    }

    public func declineConsent() {
        session.declineConsent()
    }

    /// Reverts to the pre-run text (`EditorSession.undo()`) and pushes it
    /// into `scratchpadDocument` immediately — `undo()` is synchronous, so
    /// this doesn't need the `run`/`retry` task-awaiting dance above.
    public func undo() {
        session.undo()
        scratchpadDocument.setText(session.text)
    }

    /// Called from `KallilexKeyboardController.viewWillDisappear`: cancels
    /// an in-flight run without touching anything else. The controller
    /// itself is about to be deallocated (ios-15 spike, unknown 10), but
    /// this model survives — so a cancelled run's outcome, if any arrives
    /// late, is simply discarded by `EditorSession.cancel()`'s own token
    /// invalidation.
    public func cancelForDisappear() {
        session.cancel()
    }

    /// Awaits `task`, then writes `session.text` into `scratchpadDocument`
    /// — the one place a run's result (or a no-op outcome) reaches the
    /// real Scratchpad document. Returns a new `Task` wrapping both steps,
    /// so callers (production and tests alike) can await the sync too.
    @discardableResult
    private func syncScratchpadAfter(_ task: Task<Void, Never>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.scratchpadDocument.setText(self.session.text)
        }
    }
}
