import SwiftUI
import KallilexKit
import KallilexUI

/// The Settings tab (ios-06): auto-run/auto-copy toggles, AI consents,
/// onboarding reset, the share-sheet guide, and About.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var consentPendingRevoke: AIConsent?
    @State private var showShareSheetGuide = false

    private static let dateStyle: Date.FormatStyle = .init(date: .abbreviated, time: .omitted)

    var body: some View {
        @Bindable var appEnv = appEnv
        Form {
            Section {
                Toggle(
                    String(localized: "settings.autoRun", defaultValue: "Run the first prompt automatically"),
                    isOn: Binding(
                        get: { appEnv.settings.autoRunFirstPrompt },
                        set: { newValue in appEnv.updateSettings { $0.autoRunFirstPrompt = newValue } }
                    )
                )
                .accessibilityIdentifier("settings.autoRun")

                Toggle(
                    String(localized: "settings.autoCopy", defaultValue: "Copy and close automatically"),
                    isOn: Binding(
                        get: { appEnv.settings.autoCopyResult },
                        set: { newValue in appEnv.updateSettings { $0.autoCopyResult = newValue } }
                    )
                )
                .accessibilityIdentifier("settings.autoCopy")
            } footer: {
                // Explicit `.primary`, not the Form section footer's own
                // default secondary/footnote dimming: at footnote size,
                // `.secondary` on this background falls short of WCAG AA
                // (caught by `AccessibilityUITests.testSettingsAudit`).
                Text(String(localized: "settings.auto.footer", defaultValue: "In the share sheet only."))
                    .foregroundStyle(.primary)
            }

            Section(String(localized: "settings.consents.heading", defaultValue: "AI data sharing")) {
                if appEnv.settings.consents.isEmpty {
                    // `.primary`, not `.secondary` (ios-11, "Contrast and
                    // color"): caught by `AccessibilityUITests
                    // .testSettingsAudit` on a fresh install, where this is
                    // the only row in the section.
                    Text(String(localized: "settings.consents.empty", defaultValue: "No active consents."))
                        .foregroundStyle(.primary)
                } else {
                    ForEach(appEnv.settings.consents) { consent in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profileName(for: consent.profileID))
                                .font(.body.weight(.semibold))
                            Text(consent.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(consent.grantedAt, format: Self.dateStyle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                consentPendingRevoke = consent
                            } label: {
                                Label(
                                    String(localized: "settings.consents.revoke.confirm.button", defaultValue: "Revoke"),
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
            }

            Section {
                Button(String(localized: "settings.showOnboarding", defaultValue: "Show setup again")) {
                    appEnv.updateSettings { $0.onboardingCompleted = false }
                }
                .accessibilityIdentifier("settings.showOnboarding")
            }

            Section {
                Button {
                    showShareSheetGuide = true
                } label: {
                    Text(String(
                        localized: "settings.shareSheetGuide.button",
                        defaultValue: "How to add Kallilex to your share sheet"
                    ))
                }
                .accessibilityIdentifier("settings.shareSheetGuide")
            }

            Section(String(localized: "settings.about.heading", defaultValue: "About")) {
                Text(versionString)
                    .accessibilityIdentifier("settings.about.version")

                Link(
                    String(localized: "settings.about.website", defaultValue: "Website"),
                    destination: URL(string: "https://kallilex.webcommits.info/")!
                )
                Link(
                    String(localized: "settings.about.privacyPolicy", defaultValue: "Privacy Policy"),
                    destination: URL(string: "https://kallilex.webcommits.info/datenschutz.html")!
                )
                Link(
                    String(localized: "settings.about.sourceCode", defaultValue: "Source Code"),
                    destination: URL(string: "https://github.com/LStoneyy/kallilex")!
                )
                NavigationLink(String(localized: "settings.about.licenses", defaultValue: "Licenses")) {
                    LicensesView()
                }
                .accessibilityIdentifier("settings.about.licenses")
            }
        }
        .navigationTitle(String(localized: "tab.settings", defaultValue: "Settings"))
        .sheet(isPresented: $showShareSheetGuide) {
            NavigationStack {
                KallilexUI.ShareSheetGuideView()
                    .navigationTitle(String(
                        localized: "settings.shareSheetGuide.title",
                        defaultValue: "Add Kallilex to your share sheet"
                    ))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "action.close", defaultValue: "Close")) {
                                showShareSheetGuide = false
                            }
                            .accessibilityIdentifier("settings.shareSheetGuide.close")
                        }
                    }
            }
        }
        .alert(
            consentPendingRevoke.map {
                String(localized: "settings.consents.revoke.confirm.title", defaultValue: "Revoke consent for \($0.host)?")
            } ?? "",
            isPresented: Binding(
                get: { consentPendingRevoke != nil },
                set: { isPresented in if !isPresented { consentPendingRevoke = nil } }
            )
        ) {
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "settings.consents.revoke.confirm.button", defaultValue: "Revoke"), role: .destructive) {
                if let consent = consentPendingRevoke {
                    appEnv.perform { try $0.revokeConsent(profileID: consent.profileID, host: consent.host) }
                }
            }
        }
    }

    private func profileName(for profileID: String) -> String {
        appEnv.settings.profiles.first { $0.id == profileID }?.name
            ?? String(localized: "settings.consents.deletedProvider", defaultValue: "Deleted provider")
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return String(
            localized: "settings.about.version",
            defaultValue: "Version \(version) (build \(build))"
        )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
