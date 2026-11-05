/// An abstract text edit produced by `KeyboardState`, applied to whichever
/// `TextDocument` is currently active by an `EditRouter`.
public enum Edit: Equatable, Sendable {
    case insert(String)
    case deleteBackward
    case deleteWordBackward
}
