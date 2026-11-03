import SwiftUI

/// The AI-data-sharing consent screen (ios-07, PLAN.md §10.1 / App Review
/// 5.1.2(i)): shown before the first prompt is ever sent to a cloud
/// `.openAICompatible` profile. Shared between the container app's
/// onboarding flow and, later, the Share Extension's inline consent prompt
/// (ios-09) — hence `profileName`/`host` as plain strings rather than a full
/// `ProviderProfile`, which the extension may not always have on hand in the
/// same shape.
///
/// Nothing is pre-selected: neither button carries `.keyboardShortcut` or
/// any other "default action" affordance, so the user must deliberately tap
/// one.
public struct ConsentView: View {
    private let profileName: String
    private let host: String
    private let onAllow: () async -> Void
    private let onNotNow: () -> Void

    public init(
        profileName: String,
        host: String,
        onAllow: @escaping () async -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.profileName = profileName
        self.host = host
        self.onAllow = onAllow
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "consent.title",
                defaultValue: "Send text to \(profileName)?",
                bundle: .module
            ))
            .font(.title2.bold())
            .accessibilityIdentifier("consent.title")

            Text(String(
                localized: "consent.body",
                defaultValue: "When you run a prompt, the text you share and the prompt's instruction are sent to \(host) (\(profileName)) to be processed. Kallilex doesn't collect or store your text itself; the provider's privacy policy applies.",
                bundle: .module
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("consent.body")

            Spacer()

            HStack(spacing: 12) {
                Button(String(localized: "consent.notNow", defaultValue: "Not now", bundle: .module)) {
                    onNotNow()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("consent.notNow")

                Spacer()

                Button(String(localized: "consent.allow", defaultValue: "Allow", bundle: .module)) {
                    Task { await onAllow() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("consent.allow")
            }
        }
        .padding()
    }
}

#Preview {
    ConsentView(
        profileName: "OpenAI",
        host: "api.openai.com",
        onAllow: {},
        onNotNow: {}
    )
}
