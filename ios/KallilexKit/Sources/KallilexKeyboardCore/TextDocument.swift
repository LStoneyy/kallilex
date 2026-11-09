/// A text input target the keyboard can type into. Mirrors the slice of
/// `UITextDocumentProxy` the keyboard needs, as a protocol, so
/// `KallilexKeyboardCore` has no UIKit dependency. The extension supplies
/// two concrete conformances: `HostDocument` around `textDocumentProxy`,
/// and `ScratchpadDocument` around the Scratchpad's own text view (ios-18).
///
/// `@MainActor` (added for ios-18): both real conformers wrap UIKit types
/// (`UITextDocumentProxy`, `UITextView`) that are themselves main-actor-
/// isolated under Swift 6's UIKit overlay, so a nonisolated protocol
/// requirement couldn't be witnessed by either without a `nonisolated`
/// escape hatch that would itself be unsound (synchronously touching
/// main-actor-isolated UIKit state from a nonisolated context). `EditRouter`
/// (ios-17) is already `@MainActor`, and `EditRouterTests`' plain
/// (non-isolated) `FakeTextDocument` still satisfies this fine — a
/// nonisolated implementation always satisfies an isolated requirement.
@MainActor
public protocol TextDocument: AnyObject {
    var selectedText: String? { get }
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    /// Whether the document currently has any text at all (ios-19 part B,
    /// the "hosts that don't share the selection" hint). `UITextDocumentProxy`
    /// already has this via `UIKeyInput`; `ScratchpadDocument` derives it
    /// from its own text view.
    var hasText: Bool { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// Which `TextDocument` an `EditRouter` currently sends edits to.
///
/// `Equatable` (added for ios-18): `KeyboardModel`/`KeyboardTargetSwitch`
/// compare the current target against a tapped segment and against
/// `.host` to decide whether to rebuild the host's `KeyboardContext` —
/// `EditRouter`'s own ios-17 tests never needed this, only assignment and
/// identity checks on the routed-to document.
public enum TypingTargetKind: Sendable, Equatable {
    case scratchpad
    case host
}
