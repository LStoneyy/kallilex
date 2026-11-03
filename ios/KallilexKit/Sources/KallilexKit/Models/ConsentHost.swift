import Foundation

/// The canonical host used for every consent-host computation: in
/// `SettingsService.saveProfile`'s host-change consent invalidation (this
/// spec), in `ActionRunner` (ios-05), and in `EditorSession` (ios-08).
/// Returns `nil` when `profile.baseUrl` doesn't parse into a URL with a
/// host at all — callers should treat that as "no consent host", the same
/// way the desktop's `classify_privacy` treats an unparseable base URL.
public func consentHost(for profile: ProviderProfile) -> String? {
    guard let url = URL(string: profile.baseUrl),
          let host = url.host(percentEncoded: false) else {
        return nil
    }
    let lower = host.lowercased()
    return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
}
