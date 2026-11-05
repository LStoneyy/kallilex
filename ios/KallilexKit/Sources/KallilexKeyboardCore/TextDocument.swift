/// A text input target the keyboard can type into. Mirrors the slice of
/// `UITextDocumentProxy` the keyboard needs, as a protocol, so
/// `KallilexKeyboardCore` has no UIKit dependency. The extension supplies
/// two concrete conformances: `HostDocument` around `textDocumentProxy`,
/// and `ScratchpadDocument` around the Scratchpad's own text view (ios-18).
public protocol TextDocument: AnyObject {
    var selectedText: String? { get }
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// Which `TextDocument` an `EditRouter` currently sends edits to.
public enum TypingTargetKind: Sendable {
    case scratchpad
    case host
}
