import UIKit
import KallilexKit

/// The keyboard's `Pasteboard` (ios-18, PLAN-keyboard.md §7.1 and §10.3):
/// writes `UIPasteboard.general` only when `hasFullAccess` returns `true`
/// — Copy without Full Access is a no-op (PLAN-keyboard.md §2.1: "General
/// pasteboard: No" without Full Access; ios-19 adds the explanatory Full
/// Access hint for Copy). `hasFullAccess` is a closure, read fresh on
/// every call, rather than a stored `Bool`, since it can change while the
/// keyboard is open (the user granting Full Access in Settings).
/// `@unchecked Sendable`: `Pasteboard` requires `Sendable`, but
/// `hasFullAccess` is a plain `() -> Bool` — in production a `@Sendable`
/// closure reading the lock-protected, process-wide
/// `KallilexKeyboardController.sharedHasFullAccess` rather than whichever
/// controller happened to build it (`makeSession()` runs once per
/// process; ios-19 part B, latent-bug fix). `setString` itself is only
/// called from the main actor via `EditorSession.copy()`.
public struct KeyboardPasteboard: Pasteboard, @unchecked Sendable {
    private let hasFullAccess: () -> Bool

    public init(hasFullAccess: @escaping () -> Bool) {
        self.hasFullAccess = hasFullAccess
    }

    public func setString(_ string: String) {
        guard hasFullAccess() else { return }
        UIPasteboard.general.string = string
    }
}
