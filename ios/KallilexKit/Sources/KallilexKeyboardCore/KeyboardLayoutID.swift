/// Which physical letter layout the keyboard uses.
///
/// Persisted (as its `rawValue`) in `AppSettings.keyboardLayout`, a plain
/// `String?` on the `KallilexKit` side because that package cannot depend on
/// this one. `resolve` is the single place that turns a stored value (or its
/// absence) into a concrete layout.
public enum KeyboardLayoutID: String, Codable, Sendable, CaseIterable {
    case qwertz
    case qwerty

    /// Maps a stored settings value, plus the device's preferred languages,
    /// to a concrete layout.
    ///
    /// - `stored` decodes to a known layout: that layout, unchanged.
    /// - `stored` is `nil`, empty, or doesn't match a known raw value: falls
    ///   back to the device language. A first preferred language starting
    ///   with "de" (case-insensitively; covers "de", "de-DE", "de_CH", …)
    ///   resolves to `.qwertz`; anything else (including an empty
    ///   `preferredLanguages`) resolves to `.qwerty`.
    ///
    /// `preferredLanguages` is a parameter (rather than read from `Locale`
    /// internally) so this stays deterministic and testable; callers
    /// typically pass `Locale.preferredLanguages`.
    public static func resolve(stored: String?, preferredLanguages: [String]) -> KeyboardLayoutID {
        if let stored, let id = KeyboardLayoutID(rawValue: stored) {
            return id
        }
        if let first = preferredLanguages.first, first.lowercased().hasPrefix("de") {
            return .qwertz
        }
        return .qwerty
    }
}
