import Foundation

/// UI-free presentation data for a provider's privacy badge (ios-06):
/// a localized title, an SF Symbol name, and an accessibility label, derived
/// from a `ProviderProfile` via `privacyClass(for:)`. `KallilexUI`'s
/// `PrivacyBadge` view renders this.
///
/// The field is named `classification`, not `privacyClass`, to avoid
/// colliding with the free function `privacyClass(for:)` it's computed
/// from — a stored property shadows a same-named global function for every
/// unqualified use of that identifier within this type's scope, and the
/// module can't be used to disambiguate either, since `KallilexKit` is also
/// the name of this module's own namespacing enum.
public struct PrivacyBadgeInfo: Equatable, Sendable {
    /// `nil` for a `.unknown` provider kind, which has no meaningful privacy
    /// class (mirrors `privacyClass(for:)`).
    public let classification: PrivacyClass?
    public let title: String
    public let symbolName: String
    public let accessibilityLabel: String

    public init(profile: ProviderProfile) {
        let classification = privacyClass(for: profile)
        self.classification = classification

        let title: String
        let symbolName: String
        switch classification {
        case .onDevice:
            title = String(localized: "privacy.onDevice", defaultValue: "On device", bundle: .module)
            symbolName = "cpu"
        case .local:
            title = String(localized: "privacy.local", defaultValue: "This device", bundle: .module)
            symbolName = "desktopcomputer"
        case .lan:
            title = String(localized: "privacy.lan", defaultValue: "Your network", bundle: .module)
            symbolName = "wifi"
        case .cloud:
            let host = Self.host(for: profile.baseUrl)
            title = String(
                localized: "privacy.cloud",
                defaultValue: "Cloud: \(host)",
                bundle: .module
            )
            symbolName = "cloud"
        case nil:
            title = String(localized: "privacy.unsupported", defaultValue: "Unsupported", bundle: .module)
            symbolName = "exclamationmark.triangle"
        }
        self.title = title
        self.symbolName = symbolName
        self.accessibilityLabel = title
    }

    /// Extracts `baseUrl`'s host for the "Cloud: <host>" title, falling back
    /// to the raw `baseUrl` string when it doesn't parse — this is a display
    /// label, not a security check, so it should never show nothing.
    private static func host(for baseUrl: String) -> String {
        URL(string: baseUrl)?.host(percentEncoded: false) ?? baseUrl
    }
}
