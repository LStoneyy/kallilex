/// How the active text input wants capitalization handled — mirrors
/// `UITextAutocapitalizationType` without depending on UIKit.
public enum Autocapitalization: Sendable, Equatable, CaseIterable {
    case none
    case words
    case sentences
    case allCharacters
}

/// The slice of surrounding document state `KeyboardState` needs to decide
/// shift, auto-capitalization and the numbers-layer-returns-to-letters
/// behavior. The view builds this from the active `TextDocument`; the
/// Scratchpad always supplies `.sentences`.
public struct KeyboardContext: Sendable {
    public var autocapitalization: Autocapitalization
    /// A short run of text immediately before the cursor. `nil` and `""`
    /// are both treated as "nothing before the cursor" (start of
    /// document), mirroring `UITextDocumentProxy.documentContextBeforeInput`
    /// returning `nil` at the very start of an (otherwise empty) document.
    public var textBeforeCursor: String?

    public init(autocapitalization: Autocapitalization, textBeforeCursor: String? = nil) {
        self.autocapitalization = autocapitalization
        self.textBeforeCursor = textBeforeCursor
    }
}
