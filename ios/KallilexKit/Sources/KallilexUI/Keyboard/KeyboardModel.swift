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

    /// Whether the keyboard currently has Full Access (ios-19 part B) —
    /// kept in sync with `KallilexKeyboardController.effectiveHasFullAccess`
    /// by every controller, on both `viewDidLoad` and `viewWillAppear` (a
    /// controller is deallocated and recreated on every appearance, but
    /// this model — and therefore this property — survives). Defaults to
    /// `true` so a model built before any controller has had a chance to
    /// set it (there is none in production) never shows the Full Access
    /// card spuriously.
    ///
    /// `KeyboardPasteboard`/`DynamicAccessSettingsStore`'s own
    /// `hasFullAccess` closures (built once, in `makeSession()`) read this
    /// property through `KeyboardModelStore.shared.model` rather than
    /// capturing whichever controller happened to build them — the latent
    /// bug this property's introduction fixes (see
    /// `KallilexKeyboardController.makeSession()`'s doc comment).
    public var hasFullAccess = true

    /// `true` while the Full Access card (ios-19 part B) should replace the
    /// chips/consent content in prompt mode's expanded panel — see
    /// `isPanelExpanded`. Set by `run(_:label:)`'s pre-check and by
    /// `applyFullAccessFallbackIfNeeded()`'s post-run fallback; cleared by
    /// `KeyboardFullAccessCard`'s dismiss button, by `showKeys()`, by
    /// `KallilexKeyboardController.viewWillDisappear`, and by a run
    /// actually starting.
    public var showsFullAccessCard = false

    /// `true` once the "This app doesn't share selected text…" hint
    /// (`maybeShowSelectionSharingHint()`) has been shown during the
    /// current keyboard appearance — reset by
    /// `resetSelectionSharingHintForAppearance()`, called from
    /// `viewWillAppear` before the first `refreshHostSelection()`.
    private var hasShownSelectionSharingHint = false

    public let session: EditorSession
    public let editRouter: EditRouter
    public let scratchpadDocument: any ReplaceableTextDocument
    public let hostDocument: any TextDocument
    /// The selection take-over / Insert / Undo Insert bridge (ios-19,
    /// PLAN-keyboard.md §7.2–7.3), wrapping the same `hostDocument`. Not
    /// `public`: every observable effect it has on the UI goes through
    /// `insertWillReplaceSelection`/`canUndoInsert` below, kept in sync by
    /// `syncHostState()` — an outside caller reading `hostBridge` directly
    /// would see live, non-`@Observable` state that SwiftUI can silently
    /// miss (see this type's "Host bridge" section).
    let hostBridge: HostBridge

    /// The last selection this model took over automatically (or via the
    /// "Take selection" chip) — the take-over rule's "still holds the last
    /// taken-over selection unchanged" check (ios-19 spec).
    private var lastTakenOverSelection: String?
    /// Non-`nil` while the "Take selection" chip should be shown: a
    /// non-empty host selection arrived that doesn't match the auto-take-
    /// over conditions. Cleared once used, or once the host selection
    /// disappears.
    public private(set) var pendingTakeSelection: String?

    /// `hostBridge.insertWillReplaceSelection`/`canUndoInsert`, mirrored
    /// into stored (and therefore `@Observable`-tracked) properties by
    /// `syncHostState()` — see that method's doc comment for why reading
    /// the bridge's own computed properties directly from a SwiftUI body
    /// isn't safe.
    public private(set) var insertWillReplaceSelection = false
    public private(set) var canUndoInsert = false

    private var undoInsertExpiryTask: Task<Void, Never>?

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

    /// `now` is forwarded to `HostBridge`'s own injectable clock (its
    /// 30 s Undo Insert expiry) — `Date.init` in production;
    /// `KeyboardModelTests` injects a fake to test that expiry without a
    /// real wait.
    public init(
        session: EditorSession,
        scratchpadDocument: any ReplaceableTextDocument,
        hostDocument: any TextDocument,
        keyboardState: KeyboardState = KeyboardState(),
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.scratchpadDocument = scratchpadDocument
        self.hostDocument = hostDocument
        self.keyboardState = keyboardState
        self.editRouter = EditRouter(scratchpad: scratchpadDocument, host: hostDocument)
        self.hostBridge = HostBridge(host: hostDocument, clock: now)
    }

    /// `KeyboardLayoutID.resolve`'d from the loaded `settings` (or the
    /// device language, absent any) — ios-18 spec item 8. Re-evaluated on
    /// every access rather than cached, since `settings` can change after
    /// a fresh `viewWillAppear` load.
    public var keyboardLayoutID: KeyboardLayoutID {
        KeyboardLayoutID.resolve(stored: settings?.keyboardLayout, preferredLanguages: Locale.preferredLanguages)
    }

    /// The active, enabled profile in `settings`, mirroring
    /// `ActionRunner`'s own private `activeProfile(in:)` (duplicated
    /// rather than shared, same reasoning as `isScratchpadEmpty`): `nil`
    /// with no `settings` loaded, no `activeProfileID`, or no matching
    /// enabled profile.
    public var activeProfile: ProviderProfile? {
        guard let settings, let activeID = settings.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == activeID && $0.enabled }
    }

    /// `true` in prompt mode while either the Full Access card
    /// (`showsFullAccessCard`) or a pending consent request
    /// (`session.state == .consentRequired`) should take over the panel's
    /// full height (ios-19 part B, "Expanded panel") — neither fits the
    /// fixed 44 pt chips row. Derives only from observable stored state
    /// (`mode`, `showsFullAccessCard`, `session.state`), so `@Observable`
    /// tracks it correctly for `KallilexKeyboardController`'s
    /// `trackPanelExpansion()`.
    public var isPanelExpanded: Bool {
        guard mode == .prompts else { return false }
        if showsFullAccessCard { return true }
        if case .consentRequired = session.state { return true }
        return false
    }

    // MARK: - Typing (KallilexKeyboardCore, ios-17)

    /// A regular key press: delegates to `keyboardState`, then applies the
    /// resulting edits to whichever document `target` currently selects.
    @discardableResult
    public func press(_ key: Key, context: KeyboardContext, now: Date = Date()) -> [Edit] {
        let edits = keyboardState.press(key, context: context, now: now)
        applyTyping(edits)
        return edits
    }

    /// A long-press popup selection (an alternate character, e.g. "ä" from
    /// holding "a").
    @discardableResult
    public func longPressSelect(_ alternate: String, context: KeyboardContext) -> [Edit] {
        let edits = keyboardState.longPressSelect(alternate, context: context)
        applyTyping(edits)
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
        applyTyping([edit])
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
    ///
    /// Pre-check (ios-19 part B, "Pre-check before a run"): without Full
    /// Access, a network profile (anything but `.appleOnDevice`) has no
    /// way to reach its provider at all — rather than let the run fail
    /// with a confusing network/auth error, this shows the Full Access
    /// card immediately and never starts the run. An on-device profile, or
    /// no active profile at all (the `.notConfigured` row already explains
    /// that case), run normally.
    @discardableResult
    public func run(_ action: Action, label: String) -> Task<Void, Never> {
        guard !needsFullAccessCardBeforeRunning else {
            showsFullAccessCard = true
            return Task {}
        }
        showsFullAccessCard = false
        return syncScratchpadAfter(session.run(action, label: label))
    }

    /// Same Full Access pre-check as `run(_:label:)`: the compact toolbar's
    /// Retry stays tappable while the card is up (`session.canRetry` is
    /// true again after the fallback's `cancel()`), so without this a
    /// retry would bypass the card and, on success, leave it covering the
    /// result.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard !needsFullAccessCardBeforeRunning else {
            showsFullAccessCard = true
            return nil
        }
        guard let task = session.retry() else { return nil }
        showsFullAccessCard = false
        return syncScratchpadAfter(task)
    }

    @discardableResult
    public func grantConsentAndRetry() -> Task<Void, Never>? {
        guard !needsFullAccessCardBeforeRunning else {
            showsFullAccessCard = true
            return nil
        }
        guard let task = session.grantConsentAndRetry() else { return nil }
        showsFullAccessCard = false
        return syncScratchpadAfter(task)
    }

    public func declineConsent() {
        session.declineConsent()
    }

    /// Switches to keys mode and clears the Full Access card (ios-19 part
    /// B, "the flag is also cleared when … the mode switches to keys") —
    /// the action row's ⌨ button calls this instead of setting `mode`
    /// directly.
    public func showKeys() {
        mode = .keys
        showsFullAccessCard = false
    }

    /// Copies `session.text` to the pasteboard with Full Access; without
    /// it, `KeyboardPasteboard.setString` would already silently no-op, so
    /// this instead leaves an explanatory `inlineNote` (ios-19 part B,
    /// "Copy without Full Access") rather than copying nothing and saying
    /// nothing.
    public func copy() {
        guard hasFullAccess else {
            session.inlineNote = String(
                localized: "keyboard.copy.needsFullAccess",
                defaultValue: "Copy needs Full Access.",
                bundle: .module
            )
            return
        }
        session.copy()
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

    // MARK: - Host bridge: take selection, Insert, Undo Insert (ios-19)

    /// `true` while the Scratchpad is empty or whitespace-only — mirrors
    /// `KeyboardPromptPanel`'s own check (kept duplicated rather than
    /// shared, since that view takes it as a plain `Bool` parameter); used
    /// here for `canInsert`.
    public var isScratchpadEmpty: Bool {
        session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Insert is disabled while the Scratchpad is empty or a run is in
    /// flight (ios-19 spec).
    public var canInsert: Bool {
        !isScratchpadEmpty && !session.isRunning
    }

    /// "Replace selection" while the host still reports a selection,
    /// otherwise "Insert" — derived from the stored, `syncHostState()`-kept
    /// `insertWillReplaceSelection`, not a live `hostBridge` read: a plain
    /// computed property reading straight through to `hostBridge`'s own
    /// (non-`@Observable`) computed properties would only be re-evaluated
    /// by SwiftUI when some *other*, actually-tracked property also
    /// changes in the same render — on a real device, the host selection
    /// can appear/disappear (or the Undo guard's `invalidated` latch can
    /// flip) with no such coincidental change alongside it, leaving the
    /// label/button stale.
    public var insertLabel: String {
        insertWillReplaceSelection
            ? String(localized: "keyboard.insert.replace", defaultValue: "Replace selection", bundle: .module)
            : String(localized: "keyboard.insert", defaultValue: "Insert", bundle: .module)
    }

    /// Inserts `session.text` into the host (replacing its selection if
    /// there is one), regardless of the current typing target (ios-19
    /// spec, "Typing target App"), arms the 30 s Undo Insert expiry, and
    /// syncs `canUndoInsert`/`insertWillReplaceSelection`.
    public func insert() {
        hostBridge.insert(session.text)
        scheduleUndoInsertExpiry()
        syncHostState()
        // VoiceOver has no other cue that the tap landed — the Scratchpad
        // itself doesn't change, and the button's own label just flips to
        // "Inserted · Undo" in place (ios-23 spec, "Prompt mode").
        session.feedback.announce(String(
            localized: "keyboard.insert.announcement",
            defaultValue: "Inserted",
            bundle: .module
        ))
    }

    /// Undoes the last Insert, if `canUndoInsert` allows it.
    public func undoInsert() {
        hostBridge.undoInsert()
        undoInsertExpiryTask?.cancel()
        syncHostState()
    }

    /// Called from `KallilexKeyboardController.viewWillDisappear`
    /// alongside `cancelForDisappear()`: invalidates any pending Undo
    /// Insert (the ios-19 spec's "keyboard switch → `invalidateUndo()`" —
    /// the keyboard is about to disappear, possibly to a different
    /// keyboard, and nothing about the host can be trusted on return).
    public func invalidateHostUndoOnDisappear() {
        hostBridge.invalidateUndo()
        undoInsertExpiryTask?.cancel()
        syncHostState()
    }

    /// Called from `KallilexKeyboardController.textDidChange(_:)`,
    /// unconditionally (regardless of the current typing target): forwards
    /// to `HostBridge.textDidChange()`, then syncs the observable state —
    /// the step that actually makes a just-latched `invalidated` (e.g.
    /// typing on our own keys into the host) hide "Inserted · Undo".
    public func hostTextDidChange() {
        hostBridge.textDidChange()
        syncHostState()
    }

    /// Called from `KallilexKeyboardController.selectionDidChange(_:)`,
    /// same reasoning as `hostTextDidChange()`: forwards to
    /// `HostBridge.selectionDidChange()`, runs the take-over refresh
    /// (`refreshHostSelection()`, which itself ends by syncing), so a
    /// cursor move both invalidates a pending Undo Insert and re-evaluates
    /// the take-over rules in one call.
    public func hostSelectionDidChange() {
        hostBridge.selectionDidChange()
        refreshHostSelection()
    }

    private func scheduleUndoInsertExpiry() {
        undoInsertExpiryTask?.cancel()
        undoInsertExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.syncHostState()
        }
    }

    /// The take-over rules (ios-19 spec, `KeyboardModel`, "on
    /// `viewWillAppear` and on `selectionDidChange`"): refreshes
    /// `hostBridge`'s cached selection length, then — unless a run is in
    /// flight — either takes a non-empty host selection over automatically
    /// (Scratchpad empty, or still holding the last taken-over selection
    /// unchanged) or offers it via `pendingTakeSelection` (the "Take
    /// selection" chip). An empty/`nil` host selection clears the chip,
    /// matching "it disappears … when the selection goes away". Always
    /// ends by syncing the observable host state (`insertWillReplaceSelection`
    /// changes with the selection too).
    public func refreshHostSelection() {
        hostBridge.refresh()
        defer { syncHostState() }
        guard !session.isRunning else { return }
        guard let selection = hostBridge.takeSelection(), !selection.isEmpty else {
            pendingTakeSelection = nil
            maybeShowSelectionSharingHint()
            return
        }
        if session.text.isEmpty || session.text == lastTakenOverSelection {
            applyTakeOver(selection)
        } else {
            pendingTakeSelection = selection
        }
    }

    /// Call from `KallilexKeyboardController.viewWillAppear`, before the
    /// first `refreshHostSelection()` of the new appearance — "the hint
    /// hasn't been shown yet in this keyboard appearance" (ios-19 part B).
    public func resetSelectionSharingHintForAppearance() {
        hasShownSelectionSharingHint = false
    }

    /// The narrower heuristic ios-19 part B replaces the spec's own rule
    /// with (a real selection empties both `documentContextBeforeInput`/
    /// `AfterInput`, while a lone caret inside text leaves at least one
    /// non-empty — the spike's finding; the spec's "`selectedText` nil and
    /// the context changed" would otherwise misfire on every cursor move
    /// in apps like Notes): shown at most once per appearance, and only
    /// while there's nothing more pressing already on screen (no note, no
    /// run, prompt mode) and taking over the selection wouldn't have
    /// helped anyway (the Scratchpad is empty). Called only from
    /// `refreshHostSelection()`'s own "no/empty selection" branch, so
    /// `selectedText` is already known nil/empty here.
    private func maybeShowSelectionSharingHint() {
        // `inlineNote` is only rendered in `.idle`/`.result`; setting it
        // under an error or "not configured" row would burn the
        // once-per-appearance budget without the user ever seeing it.
        guard mode == .prompts,
              session.state == .idle || session.state == .result,
              session.inlineNote == nil,
              !hasShownSelectionSharingHint,
              isScratchpadEmpty,
              hostDocument.hasText,
              Self.isEmptyContext(hostDocument.documentContextBeforeInput),
              Self.isEmptyContext(hostDocument.documentContextAfterInput)
        else { return }
        session.inlineNote = String(
            localized: "keyboard.hint.noSelectionSharing",
            defaultValue: "This app doesn't share selected text with keyboards. Type in the Scratchpad, or use Share → Kallilex.",
            bundle: .module
        )
        hasShownSelectionSharingHint = true
    }

    private static func isEmptyContext(_ text: String?) -> Bool {
        text == nil || text!.isEmpty
    }

    /// Mirrors `hostBridge.insertWillReplaceSelection`/`canUndoInsert` into
    /// this model's own stored, `@Observable`-tracked properties. The one
    /// place that reads `hostBridge`'s live, non-`@Observable` state —
    /// every other method that can change it (`insert()`, `undoInsert()`,
    /// `invalidateHostUndoOnDisappear()`, `refreshHostSelection()`, and the
    /// 30 s expiry `Task` in `scheduleUndoInsertExpiry()`) calls this
    /// afterward, so SwiftUI always has an actually-tracked property to
    /// re-render from.
    /// Applies typed edits to the current target. Typing into the host is
    /// "an edit from us" (spec ios-19): it ends Undo Insert right away,
    /// without waiting for the system to report the change back.
    private func applyTyping(_ edits: [Edit]) {
        editRouter.apply(edits)
        guard !edits.isEmpty, target == .host else { return }
        hostBridge.invalidateUndo()
        undoInsertExpiryTask?.cancel()
        syncHostState()
    }

    private func syncHostState() {
        insertWillReplaceSelection = hostBridge.insertWillReplaceSelection
        canUndoInsert = hostBridge.canUndoInsert
    }

    /// The "Take selection" chip's tap target: takes over whatever
    /// selection `refreshHostSelection()` last offered.
    public func takeSelectionFromChip() {
        guard let pendingTakeSelection else { return }
        applyTakeOver(pendingTakeSelection)
    }

    /// Replaces `session.text` with `text` directly — the same way typing
    /// into the Scratchpad does — and pushes it into the real text view.
    /// Deliberately doesn't touch `EditorSession`'s run state: taking over
    /// a selection while a result is shown (`state == .result`) therefore
    /// leaves `canUndo` exactly as it already behaves for any edit after a
    /// result (`text != lastInput`), so `EditorSession`'s own Undo brings
    /// the pre-take-over text back (ios-19 spec) with no extra bookkeeping.
    private func applyTakeOver(_ text: String) {
        session.text = text
        lastTakenOverSelection = text
        pendingTakeSelection = nil
        scratchpadDocument.setText(text)
    }

    /// Awaits `task`, then writes `session.text` into `scratchpadDocument`
    /// — the one place a run's result (or a no-op outcome) reaches the
    /// real Scratchpad document. Also applies the Full Access post-run
    /// fallback (`applyFullAccessFallbackIfNeeded()`) before that write,
    /// so a fallback's `session.cancel()` (which leaves `text` untouched)
    /// is reflected in the Scratchpad the same way a real result would be.
    /// Returns a new `Task` wrapping both steps, so callers (production
    /// and tests alike) can await the sync too.
    @discardableResult
    private func syncScratchpadAfter(_ task: Task<Void, Never>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.applyFullAccessFallbackIfNeeded()
            self.scratchpadDocument.setText(self.session.text)
        }
    }

    /// `true` while a prompt chip tap should show the Full Access card
    /// instead of starting a run (ios-19 part B, "Pre-check before a
    /// run"): no Full Access, an active profile exists, and that profile
    /// needs the network (every `ProviderKind` but `.appleOnDevice`).
    private var needsFullAccessCardBeforeRunning: Bool {
        guard !hasFullAccess, let activeProfile else { return false }
        return activeProfile.kind != .appleOnDevice
    }

    /// The post-run fallback (ios-19 part B, "Post-run fallback"): without
    /// Full Access, the keyboard has no network at all
    /// (`.unreachable`/`.localNetworkDenied`) and a missing Keychain key
    /// surfaces as an HTTP 401/403 — none of those are the real
    /// network/auth errors they look like, so this shows the Full Access
    /// card instead and returns the session to `.idle` via `cancel()`
    /// (which leaves `text` untouched) rather than leaving a confusing
    /// error on screen.
    private func applyFullAccessFallbackIfNeeded() {
        guard !hasFullAccess,
              case .failed(let error) = session.state,
              Self.isFullAccessFallbackError(error)
        else { return }
        showsFullAccessCard = true
        session.cancel()
    }

    private static func isFullAccessFallbackError(_ error: ProviderError) -> Bool {
        switch error {
        case .http(let status, _):
            return status == 401 || status == 403
        case .unreachable, .localNetworkDenied:
            return true
        default:
            return false
        }
    }
}
