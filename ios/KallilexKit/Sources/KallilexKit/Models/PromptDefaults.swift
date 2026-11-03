import Foundation

/// The three default prompts, ported byte-for-byte from
/// `contracts/default-prompts.json`. The label is localized once, at
/// seeding time only (PLAN.md §11, Q8) — the stored label is then user
/// data, never re-translated. English values for the `prompt.default.*`
/// keys live in `Resources/Localizable.xcstrings`; German is added in
/// ios-11.
public enum PromptDefaults {
    /// Returns the three seeded prompts, with labels localized for
    /// `locale`.
    ///
    /// `String(localized:bundle:locale:)` does **not** actually select the
    /// translation by its `locale:` argument — verified empirically: it
    /// keeps resolving through the bundle's *preferred* localizations
    /// (driven by the process's own language settings), so passing a
    /// `locale` that differs from the process's current language still
    /// returns the process-language string. Instead, this resolves the
    /// `.lproj` sub-bundle for `locale`'s language directly and reads the
    /// string from that specific bundle, which is unaffected by the
    /// process's own locale. Falls back to English when `locale`'s
    /// language has no translation (e.g. before ios-11 adds German, or any
    /// other unsupported language).
    public static func defaults(locale: Locale = .current) -> [CustomPrompt] {
        [
            CustomPrompt(
                id: "builtin-rewrite",
                label: localizedLabel("prompt.default.rewrite", locale: locale),
                instruction: "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone."
            ),
            CustomPrompt(
                id: "builtin-shorten",
                label: localizedLabel("prompt.default.shorten", locale: locale),
                instruction: "Make the user's text noticeably shorter while keeping its essential meaning and tone."
            ),
            CustomPrompt(
                id: "builtin-improve-clarity",
                label: localizedLabel("prompt.default.improveClarity", locale: locale),
                instruction: "Make the user's text clearer and easier to understand without changing its meaning."
            ),
        ]
    }

    /// Resolves `key` from the `.lproj` sub-bundle matching `locale`'s
    /// language, falling back to the `en.lproj` sub-bundle (and finally to
    /// `key` itself) when no such sub-bundle exists in `Bundle.module`.
    static func localizedLabel(
        _ key: String,
        locale: Locale,
        bundle: Bundle = .module
    ) -> String {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        if let value = string(forKey: key, languageCode: languageCode, in: bundle) {
            return value
        }
        if let value = string(forKey: key, languageCode: "en", in: bundle) {
            return value
        }
        return key
    }

    private static func string(forKey key: String, languageCode: String, in bundle: Bundle) -> String? {
        guard let path = bundle.path(forResource: languageCode, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return nil
        }
        let value = languageBundle.localizedString(forKey: key, value: nil, table: "Localizable")
        // `localizedString` returns the key itself when the key truly
        // isn't present in that table — treat that as "not found" so the
        // English fallback kicks in instead of surfacing the raw key.
        return value == key ? nil : value
    }
}
