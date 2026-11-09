import Foundation
import KallilexKeyboardCore

/// Sits between `EditorSession`/`KeyboardModel` and the host app's
/// `TextDocument` (ios-19, PLAN-keyboard.md §7.2–7.3): the selection
/// snapshot the take-over rules read, Insert, and the guarded Undo Insert.
/// Written against `any TextDocument` (not `HostDocument` directly), so
/// `HostBridgeTests` can drive it with a fake. `@MainActor`, like every
/// other type touching a `TextDocument` (see that protocol's doc comment).
///
/// Holds no reference to `KeyboardModel`/`EditorSession` — it only reads
/// and writes `host`, plus the small amount of state (`inserted`,
/// `replaced`, when, and two context snapshots) the Undo guard needs. The
/// take-over *decision* (auto-take-over vs. the "Take selection" chip) is
/// `KeyboardModel`'s job, since it also has to reason about
/// `session.text`; this only supplies `takeSelection()`'s raw read.
@MainActor
public final class HostBridge {
    private let host: any TextDocument
    /// Injectable so `HostBridgeTests` can fake elapsed time for the 30 s
    /// Undo expiry without a real `Task.sleep`.
    private let clock: () -> Date

    /// `nil` until the first `refresh()` — "no selection reported", as
    /// opposed to `0` (a real, empty selection/cursor with no range).
    public private(set) var selectionLength: Int?

    /// What `insert(_:)` last inserted, and what it replaced (`nil` if
    /// there was no selection to replace). Both cleared by
    /// `invalidateUndo()`.
    private var inserted: String?
    private var replaced: String?
    private var insertedAt: Date?
    /// `host.documentContextBeforeInput`/`AfterInput`, snapshotted right
    /// after `insert(_:)` returns (i.e. already reflecting the insert
    /// itself). `textDidChange()`/`selectionDidChange()` compare the live
    /// context against these on every call: unchanged is fine (including
    /// the very first callback the system sends as a direct consequence of
    /// our own `insertText`, since the snapshot already reflects that same
    /// state); changed permanently latches `invalidated = true`, even if a
    /// later context happens to match again by coincidence (e.g. typing
    /// "foo" back in after deleting it) — a case the Undo guard's own
    /// fresh suffix check alone wouldn't catch.
    private var contextBeforeAtInsert: String?
    private var contextAfterAtInsert: String?
    private var invalidated = false

    public init(host: any TextDocument, clock: @escaping () -> Date = Date.init) {
        self.host = host
        self.clock = clock
    }

    /// Updates `selectionLength` from the host's current `selectedText`.
    /// Call on `selectionDidChange`/`textDidChange` and on
    /// `viewWillAppear`, per the spec; `KeyboardModel.refreshHostSelection
    /// ()` is the one caller in production.
    public func refresh() {
        selectionLength = host.selectedText?.count
    }

    /// Reads the host's current selection, live — not cached from the last
    /// `refresh()`. `nil`/empty exactly mirrors `host.selectedText`.
    public func takeSelection() -> String? {
        host.selectedText
    }

    /// `true` while the host currently reports a non-empty selection — what
    /// `insert(_:)` is about to replace. Always a live read, so the
    /// Insert button's label stays correct even if the selection changed
    /// after it was taken over (ios-19 spec, "edge cases").
    public var insertWillReplaceSelection: Bool {
        guard let text = host.selectedText else { return false }
        return !text.isEmpty
    }

    /// Calls `host.insertText(text)` — which replaces the host's selection
    /// if there is one — and records what was inserted/replaced plus the
    /// context right after, for `canUndoInsert`'s guard. Starts (or
    /// restarts) the 30 s Undo window and clears any previous
    /// `invalidated` latch.
    public func insert(_ text: String) {
        let selectionBeingReplaced = host.selectedText
        host.insertText(text)
        inserted = text
        replaced = (selectionBeingReplaced?.isEmpty == false) ? selectionBeingReplaced : nil
        insertedAt = clock()
        invalidated = false
        contextBeforeAtInsert = host.documentContextBeforeInput
        contextAfterAtInsert = host.documentContextAfterInput
    }

    /// The Undo guard (ios-19 spec, "Undo Insert — Allowed only while"):
    /// not invalidated by an edit/cursor-move hook, inside the 30 s window,
    /// and `documentContextBeforeInput` currently ends with the last
    /// `min(200, inserted.count)` `Character`s of `inserted`. Recomputed
    /// fresh every call (not cached), so a test (or a caller) that mutates
    /// the host directly, without going through `textDidChange()`/
    /// `selectionDidChange()`, still sees the right answer.
    public var canUndoInsert: Bool {
        guard !invalidated,
              let inserted, !inserted.isEmpty,
              let insertedAt,
              clock().timeIntervalSince(insertedAt) < 30,
              let before = host.documentContextBeforeInput
        else { return false }
        let suffixCount = min(200, inserted.count)
        return before.hasSuffix(inserted.suffix(suffixCount))
    }

    /// `inserted.count` × `deleteBackward()` (counted in `Character`s, per
    /// the ios-15 spike's "one `deleteBackward()` removes one `Character`"
    /// result for Notes/Mail/`UITextView`), then `insertText(replaced)` if
    /// `replaced` isn't `nil`. A no-op while `canUndoInsert` is `false`.
    /// Always ends by invalidating — Undo is one-shot.
    public func undoInsert() {
        guard canUndoInsert, let inserted else { return }
        for _ in 0..<inserted.count {
            host.deleteBackward()
        }
        if let replaced {
            host.insertText(replaced)
        }
        invalidateUndo()
    }

    /// Clears every Insert/Undo record and latches `invalidated` — called
    /// for any other edit or a keyboard switch (`KeyboardModel`/the
    /// controller wire this to typed edits reaching the host and to
    /// `viewWillDisappear`), and internally by `undoInsert()` itself.
    public func invalidateUndo() {
        invalidated = true
        inserted = nil
        replaced = nil
        insertedAt = nil
        contextBeforeAtInsert = nil
        contextAfterAtInsert = nil
    }

    /// Forward `UIInputViewController.textDidChange(_:)` here for the host
    /// proxy unconditionally (regardless of the current typing target) —
    /// see this type's doc comment on `contextBeforeAtInsert` for why an
    /// unchanged context is a no-op while a changed one permanently
    /// invalidates. A no-op entirely while no Insert is pending.
    public func textDidChange() {
        guard inserted != nil else { return }
        if host.documentContextBeforeInput != contextBeforeAtInsert {
            invalidated = true
        }
    }

    /// Forward `UIInputViewController.selectionDidChange(_:)` here the same
    /// way. Compares both the before- and after-cursor context, since a
    /// cursor move with no text edit can still change which text sits on
    /// either side of it even though nothing was inserted/deleted.
    public func selectionDidChange() {
        guard inserted != nil else { return }
        if host.documentContextBeforeInput != contextBeforeAtInsert
            || host.documentContextAfterInput != contextAfterAtInsert {
            invalidated = true
        }
    }
}
