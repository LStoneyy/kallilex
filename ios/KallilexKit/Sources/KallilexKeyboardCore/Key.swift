/// Which of the three layers a key belongs to, and which a `layerSwitch`
/// key switches to.
public enum KeyboardLayer: Sendable, Equatable, CaseIterable {
    case letters
    case numbers
    case symbols
}

/// A single key on a `KeyboardLayout` row.
public struct Key: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A lower-case base output, e.g. `"q"`, `"'"`, `"€"`. `KeyboardState`
        /// upper-cases it when shift is `.once`/`.locked`.
        case character(String)
        case shift
        case delete
        case space
        case returnKey
        /// Switches `KeyboardState.layer` to the associated layer.
        case layerSwitch(KeyboardLayer)
        /// Triggers the system input-mode switcher; present only when
        /// `showsGlobe` is true. Carries no edit of its own.
        case globe
    }

    public var kind: Kind
    /// Long-press alternates, lower-case, each exactly one `Character`.
    public var alternates: [String]
    /// Relative width; `1.0` is one letter key's width.
    public var widthUnits: Double

    public init(kind: Kind, alternates: [String] = [], widthUnits: Double = 1.0) {
        self.kind = kind
        self.alternates = alternates
        self.widthUnits = widthUnits
    }
}
