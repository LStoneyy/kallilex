import Foundation

/// Shift/caps-lock state.
public enum ShiftState: Sendable, Equatable, CaseIterable {
    case off
    case once
    case locked
}

/// The keyboard's pure typing state machine: which layer is showing, shift
/// state, double-space-to-period, and the layer-switch-back-to-letters
/// rule. No UIKit, no Foundation timers — `now` and `heldFor` are always
/// parameters, so none of this needs a clock to test.
public struct KeyboardState: Sendable {
    public var layer: KeyboardLayer
    public var shift: ShiftState

    /// Time of the most recent single shift tap that produced `.once`, used
    /// to detect a following double-tap within 0.3 s. `nil` once consumed
    /// by a lock, or by the window closing.
    private var lastShiftOnceTapAt: Date?

    /// Set when the user explicitly cancels shift (a tap while `.locked`,
    /// or a second, slow tap from `.once`). Consumed by the very next
    /// `contextDidChange`, which then skips auto-capitalization once —
    /// "a user's explicit shift-off wins until the next context change."
    private var userCancelledShift = false

    /// Whether the last character inserted (by `press` or
    /// `longPressSelect`) was a letter or digit. Double space only fires
    /// right after one of those.
    private var lastInsertWasLetterOrDigit = false

    /// The time of a space press that is still eligible to become the
    /// first half of a "double space → period" pair; `nil` once that
    /// 0.5 s window has closed or a non-space key intervened.
    private var pendingDoubleSpaceAt: Date?

    /// How many 0.1 s character-repeat steps have been emitted since the
    /// delete key last went down (see `deleteRepeatEdit`).
    private var deleteRepeatStep = 0
    /// How many 0.25 s word-repeat steps have been emitted since the
    /// delete key last went down.
    private var deleteWordRepeatStep = 0

    public init(layer: KeyboardLayer = .letters, shift: ShiftState = .off) {
        self.layer = layer
        self.shift = shift
    }

    private var isShiftActive: Bool { shift == .once || shift == .locked }

    // MARK: - Key presses

    public mutating func press(_ key: Key, context: KeyboardContext, now: Date) -> [Edit] {
        switch key.kind {
        case .character(let base):
            return pressCharacter(base)
        case .shift:
            pressShift(now: now)
            return []
        case .delete:
            resetDeleteRepeat()
            pendingDoubleSpaceAt = nil
            lastInsertWasLetterOrDigit = false
            return [.deleteBackward]
        case .space:
            return pressSpace(now: now)
        case .returnKey:
            pendingDoubleSpaceAt = nil
            lastInsertWasLetterOrDigit = false
            return [.insert("\n")]
        case .layerSwitch(let target):
            layer = target
            pendingDoubleSpaceAt = nil
            return []
        case .globe:
            // No edit of its own; the view asks the OS to switch input modes.
            return []
        }
    }

    /// A long-press popup selection (an alternate character). Respects
    /// shift the same way a regular letter key press does.
    public mutating func longPressSelect(_ alternate: String, context: KeyboardContext) -> [Edit] {
        let isLetter = alternate.first?.isLetter ?? false
        let output = isShiftActive ? alternate.uppercased() : alternate
        if shift == .once, isLetter {
            shift = .off
        }
        pendingDoubleSpaceAt = nil
        lastInsertWasLetterOrDigit = isLetter || (alternate.first?.isNumber ?? false)
        return [.insert(output)]
    }

    /// Auto-capitalization: called whenever the surrounding document
    /// context changes. Sets shift to `.once` when `context.autocapitalization`
    /// asks for it; never downgrades an existing `.locked`. A user's
    /// explicit shift-off (see `userCancelledShift`) wins over exactly the
    /// next call.
    public mutating func contextDidChange(_ context: KeyboardContext) {
        if userCancelledShift {
            userCancelledShift = false
            return
        }
        guard shift != .locked else { return }
        if shouldAutoCapitalize(context) {
            shift = .once
        }
    }

    // MARK: - Delete repeat

    /// Call on every timer tick while the delete key is held, passing the
    /// cumulative duration since the key went down (press-to-now, not
    /// tick-to-tick). The expected tick contract: the view ticks on a fixed
    /// short interval — 0.05 s is the one this is tuned for — and calls
    /// this on every tick. Internally this tracks which repeat step was
    /// last emitted (separately for the character and word phases), so it
    /// returns a non-`nil` `Edit` only the first tick that crosses a new
    /// step boundary, not on every tick:
    ///
    /// - `nil` while `heldFor < 0.5` — the first delete already happened on
    ///   the initial `press(_:context:now:)`, not here;
    /// - `.deleteBackward` the first time `heldFor` reaches each 0.1 s mark
    ///   at/after 0.5 s (0.5, 0.6, 0.7, …);
    /// - `.deleteWordBackward` the first time `heldFor` reaches each 0.25 s
    ///   mark at/after 2.0 s (2.0, 2.25, 2.5, …), tracked independently of
    ///   the character-repeat steps above (so crossing into word-repeat
    ///   doesn't skip or double-fire a step).
    ///
    /// Call `resetDeleteRepeat()` when the key is released so the next hold
    /// starts counting from zero; `press(_:context:now:)` already does this
    /// automatically for a `.delete` key's initial press.
    public mutating func deleteRepeatEdit(heldFor: TimeInterval) -> Edit? {
        if heldFor >= 2.0 {
            let step = Int((heldFor - 2.0) / 0.25) + 1
            guard step > deleteWordRepeatStep else { return nil }
            deleteWordRepeatStep = step
            return .deleteWordBackward
        }
        if heldFor >= 0.5 {
            let step = Int((heldFor - 0.5) / 0.1) + 1
            guard step > deleteRepeatStep else { return nil }
            deleteRepeatStep = step
            return .deleteBackward
        }
        return nil
    }

    /// Resets the repeat-step counters `deleteRepeatEdit` tracks. Call this
    /// when the delete key is released.
    public mutating func resetDeleteRepeat() {
        deleteRepeatStep = 0
        deleteWordRepeatStep = 0
    }

    // MARK: - Private helpers

    private mutating func pressCharacter(_ base: String) -> [Edit] {
        let isLetter = base.first?.isLetter ?? false
        let isDigit = base.first?.isNumber ?? false
        let output = isShiftActive ? base.uppercased() : base
        if shift == .once, isLetter {
            shift = .off
        }
        pendingDoubleSpaceAt = nil
        lastInsertWasLetterOrDigit = isLetter || isDigit
        if base == "'" {
            returnToLettersIfNeeded()
        }
        return [.insert(output)]
    }

    private mutating func pressShift(now: Date) {
        switch shift {
        case .off:
            shift = .once
            lastShiftOnceTapAt = now
            userCancelledShift = false
        case .once:
            if let last = lastShiftOnceTapAt, now.timeIntervalSince(last) <= 0.3 {
                shift = .locked
                userCancelledShift = false
            } else {
                shift = .off
                userCancelledShift = true
            }
            lastShiftOnceTapAt = nil
        case .locked:
            shift = .off
            lastShiftOnceTapAt = nil
            userCancelledShift = true
        }
        pendingDoubleSpaceAt = nil
    }

    private mutating func pressSpace(now: Date) -> [Edit] {
        defer { returnToLettersIfNeeded() }
        if let pending = pendingDoubleSpaceAt, now.timeIntervalSince(pending) <= 0.5 {
            pendingDoubleSpaceAt = nil
            lastInsertWasLetterOrDigit = false
            shift = .once
            return [.deleteBackward, .insert(". ")]
        }
        pendingDoubleSpaceAt = lastInsertWasLetterOrDigit ? now : nil
        lastInsertWasLetterOrDigit = false
        return [.insert(" ")]
    }

    private mutating func returnToLettersIfNeeded() {
        // Only the numbers layer returns to letters, as on the system
        // keyboard; the symbols layer stays put.
        if layer == .numbers {
            layer = .letters
        }
    }

    private func shouldAutoCapitalize(_ context: KeyboardContext) -> Bool {
        switch context.autocapitalization {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            let text = context.textBeforeCursor ?? ""
            return text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n")
        case .sentences:
            let text = context.textBeforeCursor ?? ""
            if text.isEmpty { return true }
            return text.hasSuffix(". ") || text.hasSuffix("! ") || text.hasSuffix("? ")
        }
    }
}
