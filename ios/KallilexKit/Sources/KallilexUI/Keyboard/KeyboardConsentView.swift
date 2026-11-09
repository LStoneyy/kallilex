import SwiftUI
import KallilexKit

/// The keyboard's compact consent view (ios-19 part B, decision 7):
/// replaces `KeyboardStatusRow`'s one-line consent stand-in, rendered
/// inside prompt mode's expanded panel (`KeyboardModel.isPanelExpanded`)
/// while `session.state == .consentRequired(profile)`. Shows the profile
/// name and host, plus a keyboard-specific consent sentence — the app's
/// own `ConsentView` (unchanged) says "the text you share"; this says "the
/// text in the Scratchpad", since that's literally what's about to be
/// sent. Allow/Not now reuse the exact same `consent.allow`/`consent
/// .notNow` identifiers and callbacks the one-line stand-in used.
public struct KeyboardConsentView: View {
    private let profile: ProviderProfile
    private let onAllow: () -> Void
    private let onDecline: () -> Void

    public init(profile: ProviderProfile, onAllow: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.profile = profile
        self.onAllow = onAllow
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile.name)
                .font(.headline)
            Text(host)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(String(localized: "consent.notNow", defaultValue: "Not now", bundle: .module)) {
                    onDecline()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("consent.notNow")

                Spacer()

                Button(String(localized: "consent.allow", defaultValue: "Allow", bundle: .module)) {
                    onAllow()
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("consent.allow")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard.consentView")
    }

    private var host: String {
        consentHost(for: profile) ?? profile.name
    }

    private var bodyText: String {
        String(
            localized: "keyboard.consent.body",
            defaultValue: "The text in the Scratchpad is sent to \(host) to be processed.",
            bundle: .module
        )
    }
}

#Preview {
    KeyboardConsentView(
        profile: ProviderProfile(id: "1", name: "Cloud Server", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo"),
        onAllow: {},
        onDecline: {}
    )
    .frame(height: 200)
}
