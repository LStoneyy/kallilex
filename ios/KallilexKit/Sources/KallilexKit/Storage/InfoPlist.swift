import Foundation

/// Reads the App Group id and the Keychain access group from the app's own
/// `Info.plist`, so team-specific values (set once via the
/// `KALLILEX_APP_GROUP` / `KALLILEX_KEYCHAIN_GROUP` build settings, ios-02)
/// never get hardcoded in source. Both the container app (ios-06) and the
/// Share Extension (ios-09) read these through this helper rather than
/// `Bundle.main` directly.
///
/// There is no fallback: a missing or unresolved key means a build
/// misconfiguration, and `preconditionFailure` makes that visible
/// immediately rather than silently falling back to a wrong group.
public enum InfoPlist {
    public static var kallilexAppGroup: String { value(for: "KallilexAppGroup") }
    public static var kallilexKeychainAccessGroup: String { value(for: "KallilexKeychainAccessGroup") }

    private static func value(for key: String) -> String {
        guard let resolved = resolve(Bundle.main.object(forInfoDictionaryKey: key)) else {
            preconditionFailure("Info.plist key \(key) is missing or unresolved")
        }
        return resolved
    }

    /// The pure validation behind `value(for:)`, factored out so it can be
    /// unit-tested without `Bundle.main`: `nil` when `raw` isn't a
    /// non-empty `String`, or is a build setting placeholder that never got
    /// resolved (`"$(...)"`, left over when the backing build setting is
    /// unset).
    static func resolve(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }
}
