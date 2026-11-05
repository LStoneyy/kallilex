import UIKit
import KallilexKeyboardCore

/// Wraps the Scratchpad `UITextView` as a `TextDocument` (`EditRouter`'s
/// routing target) and a `ReplaceableTextDocument` (`KeyboardModel`'s sync
/// target). `textView` is `weak`: the view itself is recreated by every
/// new `KallilexKeyboardController` instance (ios-18 lifecycle — the
/// controller is deallocated on every disappearance), while this wrapper
/// is held by the process-wide `KeyboardModel` and survives across that.
/// `attach`/`detach` repoint it on every appearance/disappearance.
@MainActor
public final class ScratchpadDocument: ReplaceableTextDocument {
    public weak var textView: UITextView?

    public init(textView: UITextView? = nil) {
        self.textView = textView
    }

    public func attach(_ textView: UITextView) {
        self.textView = textView
    }

    public func detach() {
        textView = nil
    }

    public var selectedText: String? {
        guard let textView, let range = textView.selectedTextRange, !range.isEmpty else { return nil }
        return textView.text(in: range)
    }

    public var documentContextBeforeInput: String? {
        guard let textView, let range = textView.selectedTextRange,
              let start = textView.textRange(from: textView.beginningOfDocument, to: range.start)
        else { return nil }
        return textView.text(in: start)
    }

    public var documentContextAfterInput: String? {
        guard let textView, let range = textView.selectedTextRange,
              let end = textView.textRange(from: range.end, to: textView.endOfDocument)
        else { return nil }
        return textView.text(in: end)
    }

    public func insertText(_ text: String) {
        textView?.insertText(text)
    }

    public func deleteBackward() {
        textView?.deleteBackward()
    }

    /// Sets the whole text and moves the caret to the end — what a run
    /// result or Undo does to the real Scratchpad (ios-18 spec,
    /// "Scratchpad text view (UIKit)"). A no-op if no text view is
    /// currently attached (e.g. between controller instances).
    public func setText(_ text: String) {
        guard let textView else { return }
        textView.text = text
        let end = (text as NSString).length
        textView.selectedRange = NSRange(location: end, length: 0)
    }
}

/// Wraps the host app's `UITextDocumentProxy` as a `TextDocument`.
/// `proxy` is reattached by every new `KallilexKeyboardController` (its
/// own `textDocumentProxy` differs each time) and cleared again on
/// disappearance, so a stale proxy from a deallocated controller is never
/// written to. `weak`, as a second line of defense: a controller that
/// disappeared without `detach()` running (or running late) can't leave
/// this pointing at a deallocated proxy either way.
@MainActor
public final class HostDocument: TextDocument {
    public weak var proxy: UITextDocumentProxy?

    public init(proxy: UITextDocumentProxy? = nil) {
        self.proxy = proxy
    }

    public func attach(_ proxy: UITextDocumentProxy) {
        self.proxy = proxy
    }

    public func detach() {
        proxy = nil
    }

    public var selectedText: String? { proxy?.selectedText }
    public var documentContextBeforeInput: String? { proxy?.documentContextBeforeInput }
    public var documentContextAfterInput: String? { proxy?.documentContextAfterInput }

    public func insertText(_ text: String) {
        proxy?.insertText(text)
    }

    public func deleteBackward() {
        proxy?.deleteBackward()
    }
}
