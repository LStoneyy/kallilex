/// Pure key-press/commit bookkeeping for `KeyGridView`, decoupled from
/// UIKit so it's directly unit-testable. Tracks one press per touch
/// (keyed by a caller-supplied `Hashable` touch identity — `KeyGridView`
/// uses `ObjectIdentifier(touch)`), which is what lets two simultaneous
/// touches type correctly: a second touch beginning while an earlier
/// character press is still down commits that earlier press immediately
/// (rollover typing), rather than losing it or double-committing once
/// both eventually lift.
///
/// This only decides *what* to commit and *when* — never *how*:
/// `KeyGridView` turns each `Commit` into an actual
/// `KeyboardModel.press`/`longPressSelect` call, using the `Key` data it
/// already has at `keyIndex`. Nothing here calls `KeyboardState`/
/// `EditRouter` or inserts/deletes anything — a character key's default
/// output is typed exactly once, at its commit, never speculatively on
/// touch-down and never undone with a `deleteBackward` — so shift/caps-
/// lock/double-space state, and the host app's own undo stack, only ever
/// see the edits the user actually ends up producing.
public struct KeyPressTracker<TouchID: Hashable> {
    /// A decided commit: the key index to apply, and — if an alternates
    /// popup was showing and the user slid onto one — which alternate to
    /// use instead of that key's own default output.
    public struct Commit: Equatable {
        public let keyIndex: Int
        public let alternateIndex: Int?

        public init(keyIndex: Int, alternateIndex: Int? = nil) {
            self.keyIndex = keyIndex
            self.alternateIndex = alternateIndex
        }
    }

    /// How a key kind resolves at the end of its press.
    public enum PressKind: Equatable, Sendable {
        /// Character keys: commit on lift, to whichever key is currently
        /// under the finger (it may have moved — see `moveTouch`), or to
        /// the selected alternate if the popup was showing. Eligible for
        /// rollover: a new touch's `beginTouch` commits an in-progress
        /// `.character` press immediately — whether the new touch is
        /// itself `.character` or `.immediate` (see `.immediate` below).
        case character
        /// Shift, globe, the layer-switch keys: commit on lift, but only
        /// if the finger is still over the original key at that point
        /// (see `updateDeferredPresence`) — sliding off and lifting
        /// elsewhere cancels. Never retargeted, never rolled over.
        case deferred
        /// Delete, space, return: already committed by the caller on
        /// touch-down. Tracked only so `endTouch`/`cancelAll` have
        /// something to clean up; always resolves to no further commit.
        /// Also rollover-eligible as the *new* touch (but never as the
        /// in-progress one being rolled over, which must be `.character`)
        /// — matches the system keyboard, where hitting space/delete/
        /// return while a letter is still down commits that letter first.
        case immediate
    }

    private struct Press {
        let kind: PressKind
        var currentKeyIndex: Int
        /// `.deferred` only: whether the touch is currently over the key
        /// it started on.
        var isOverOriginalKey = true
        var hasAlternates = false
        var selectedAlternateIndex: Int?
    }

    private var presses: [TouchID: Press] = [:]

    public init() {}

    /// Call on touch-down. Returns the commit for *another* touch's
    /// still-in-progress `.character` press, if any (rollover: triggered
    /// by a new `.character` or `.immediate` touch, never by `.deferred`)
    /// — the caller applies that commit, then this touch's own press
    /// begins tracking from `keyIndex`. Equivalent to `takeRolloverCommit()`
    /// (only for rollover-eligible kinds) followed by `registerTouch` —
    /// kept as a convenience for callers that don't need to act on the
    /// rollover commit (e.g. rebuild something) before registering the
    /// new touch; `KeyGridView` calls the two separately instead, since a
    /// rollover commit can itself change the layout the new touch's
    /// `keyIndex` needs to be resolved against.
    @discardableResult
    public mutating func beginTouch(_ id: TouchID, at keyIndex: Int, kind: PressKind) -> Commit? {
        let rollover = (kind == .character || kind == .immediate) ? takeRolloverCommit() : nil
        registerTouch(id, at: keyIndex, kind: kind)
        return rollover
    }

    /// Commits (and stops tracking) an in-progress `.character` press, if
    /// any, without starting to track any new touch — the
    /// rollover half of `beginTouch`, split out so a caller can apply the
    /// commit (which may itself change state the new touch's `keyIndex`
    /// needs to be resolved against) before calling `registerTouch`.
    /// Normally at most one `.character` press is in progress when a new
    /// touch lands (two-finger typing); if there were ever more than one,
    /// which one is committed is unspecified (dictionary order).
    @discardableResult
    public mutating func takeRolloverCommit() -> Commit? {
        guard let id = presses.first(where: { $0.value.kind == .character })?.key else { return nil }
        return endTouch(id, cancelled: false)
    }

    /// Starts tracking a new touch at `keyIndex`, with no rollover check
    /// of its own — the non-rollover half of `beginTouch`. Also used
    /// outside of touch-down, to re-register a touch that survived a
    /// mid-press grid rebuild (`KeyGridView`'s layer-switch remap) at its
    /// new key index.
    public mutating func registerTouch(_ id: TouchID, at keyIndex: Int, kind: PressKind) {
        presses[id] = Press(kind: kind, currentKeyIndex: keyIndex)
    }

    /// Call on touch-move for a `.character` press: moves it to
    /// `keyIndex`. A no-op (returns `false`) for any other kind, once an
    /// alternates popup is showing for this touch, for an untracked
    /// touch, or if the key didn't actually change.
    @discardableResult
    public mutating func moveTouch(_ id: TouchID, to keyIndex: Int) -> Bool {
        guard var press = presses[id], press.kind == .character, !press.hasAlternates,
              press.currentKeyIndex != keyIndex else { return false }
        press.currentKeyIndex = keyIndex
        presses[id] = press
        return true
    }

    /// Call on touch-move for a `.deferred` press, with whether the
    /// touch is currently over its original key.
    public mutating func updateDeferredPresence(_ id: TouchID, isOverOriginalKey: Bool) {
        guard var press = presses[id], press.kind == .deferred else { return }
        press.isOverOriginalKey = isOverOriginalKey
        presses[id] = press
    }

    /// Call once a long-press fires for `id`'s current key: marks it as
    /// showing alternates, so further `moveTouch` calls are ignored (the
    /// caller routes further moves to `selectAlternate` instead).
    public mutating func showAlternates(for id: TouchID) {
        guard var press = presses[id], press.kind == .character else { return }
        press.hasAlternates = true
        press.selectedAlternateIndex = nil
        presses[id] = press
    }

    public mutating func selectAlternate(_ id: TouchID, index: Int?) {
        guard var press = presses[id], press.hasAlternates else { return }
        press.selectedAlternateIndex = index
        presses[id] = press
    }

    public func currentKeyIndex(for id: TouchID) -> Int? { presses[id]?.currentKeyIndex }
    public func isShowingAlternates(for id: TouchID) -> Bool { presses[id]?.hasAlternates ?? false }

    /// Every key index currently tracked by an active touch —
    /// `KeyGridView` diffs this against its previous call to update key
    /// highlighting, instead of keeping its own per-touch bookkeeping.
    public var activeKeyIndices: Set<Int> { Set(presses.values.map(\.currentKeyIndex)) }

    /// Call on touch-up: returns the commit for `id`'s press (if any),
    /// and stops tracking it. `nil` for a cancelled lift, an untracked
    /// touch, an `.immediate` press (already committed on touch-down), or
    /// a `.deferred` press lifted off its original key.
    @discardableResult
    public mutating func endTouch(_ id: TouchID, cancelled: Bool) -> Commit? {
        guard let press = presses.removeValue(forKey: id) else { return nil }
        guard !cancelled else { return nil }
        switch press.kind {
        case .character:
            return Commit(keyIndex: press.currentKeyIndex, alternateIndex: press.selectedAlternateIndex)
        case .deferred:
            return press.isOverOriginalKey ? Commit(keyIndex: press.currentKeyIndex) : nil
        case .immediate:
            return nil
        }
    }

    /// Stops tracking every touch without producing any commits — the
    /// keyboard is disappearing, or every in-progress press must
    /// otherwise be abandoned.
    public mutating func cancelAll() {
        presses.removeAll()
    }
}
