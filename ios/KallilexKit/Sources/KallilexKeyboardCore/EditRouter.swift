/// Applies abstract `Edit`s from `KeyboardState` to whichever
/// `TextDocument` is currently selected (`target`): the Scratchpad, or the
/// host app via the extension's `textDocumentProxy`.
///
/// Deliberately not `Sendable`: it holds and mutates two reference-typed
/// `TextDocument`s and is meant to be owned and driven entirely by the
/// keyboard extension's UI code on the main thread, the way a
/// `UIViewController` is. It's marked `@MainActor` (rather than left a
/// plain non-isolated class) so Swift 6's strict concurrency checking has a
/// concrete isolation domain to check callers against, instead of silently
/// treating every member as freely callable from anywhere.
@MainActor
public final class EditRouter {
    public var target: TypingTargetKind

    private let scratchpadDocument: any TextDocument
    private let hostDocument: any TextDocument

    public init(scratchpad: any TextDocument, host: any TextDocument, target: TypingTargetKind = .scratchpad) {
        self.scratchpadDocument = scratchpad
        self.hostDocument = host
        self.target = target
    }

    public var activeDocument: any TextDocument {
        switch target {
        case .scratchpad: return scratchpadDocument
        case .host: return hostDocument
        }
    }

    public func apply(_ edits: [Edit]) {
        let document = activeDocument
        for edit in edits {
            switch edit {
            case .insert(let text):
                document.insertText(text)
            case .deleteBackward:
                document.deleteBackward()
            case .deleteWordBackward:
                deleteWordBackward(on: document)
            }
        }
    }

    /// Resolves `.deleteWordBackward` against the active document's
    /// `documentContextBeforeInput`: counts `Character`s back from the
    /// cursor through any trailing whitespace, then through the previous
    /// word, and issues that many `deleteBackward()` calls — one per
    /// `Character`, so multi-scalar grapheme clusters (emoji, ZWJ
    /// sequences, a base letter plus a combining accent) each cost exactly
    /// one call. That matches how `UITextDocumentProxy.deleteBackward()`
    /// deletes one extended grapheme cluster per call in Notes, Mail and a
    /// plain `UITextView` (confirmed by the ios-15 spike); web views are
    /// covered by ios-19's compatibility matrix — if any app class miscounts
    /// there, that's the place to special-case or disable word-delete.
    private func deleteWordBackward(on document: any TextDocument) {
        guard let before = document.documentContextBeforeInput else { return }
        let count = Self.wordBackwardDeleteCount(before: before)
        for _ in 0..<count {
            document.deleteBackward()
        }
    }

    /// Counts the `Character`s `.deleteWordBackward` should remove from the
    /// end of `before`: any whitespace run immediately before the cursor,
    /// then the word (non-whitespace run) immediately before that. Stops at
    /// the boundary before that word — it does not also eat whitespace that
    /// precedes the word, matching common "delete previous word" behavior
    /// (e.g. "hello world " → "hello ").
    ///
    /// `nonisolated` because it's a pure function of its argument with no
    /// actor-isolated state, so tests can call it directly.
    nonisolated static func wordBackwardDeleteCount(before: String) -> Int {
        let characters = Array(before)
        var index = characters.count
        var count = 0
        while index > 0, characters[index - 1].isWhitespace {
            index -= 1
            count += 1
        }
        while index > 0, !characters[index - 1].isWhitespace {
            index -= 1
            count += 1
        }
        return count
    }
}
