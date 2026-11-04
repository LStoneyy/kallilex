import SwiftUI
import KallilexKit
import KallilexUI

/// The first-run onboarding flow (ios-07, PLAN.md §4.1), presented by
/// `RootTabView` as a `fullScreenCover` while `!appEnv.settings
/// .onboardingCompleted`, and re-entered from Settings → "Show setup
/// again". Owns an `OnboardingFlow` (`KallilexKit`, UI-free) in `@State` and
/// renders whichever step it currently points at.
///
/// The provider-editing step (`.providerDetails`) reuses `ProviderEditor`
/// (ios-06's Providers tab form) completely unmodified, presented as a
/// `.sheet` attached to this view's own stable `NavigationStack` — not
/// nested inside the `switch` below — so dismissing it (Cancel or Save)
/// never races against this view swapping out the step underneath it.
///
/// Dismissal happens only by `appEnv.settings.onboardingCompleted` becoming
/// `true` (via `finish()`, called from "Set up later" on any step, or
/// "Start using Kallilex" on `.done`) — `RootTabView`'s cover binding reacts
/// to that and removes this view; there is no separate "close" affordance
/// here.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var flow = OnboardingFlow.initial()
    @State private var draft: ProviderDraft?
    @State private var showProviderEditor = false
    @State private var providerDetailsSaved = false
    @State private var savedProfile: ProviderProfile?
    /// Starts out as if the device were ineligible, so the on-device preset
    /// never flashes into view before `.task` below resolves the real
    /// availability (ios-10) — same reasoning as
    /// `ProviderPresetPickerView`.
    @State private var onDeviceAvailability: OnDeviceAvailability = .deviceNotEligible

    var body: some View {
        NavigationStack {
            Group {
                switch flow.currentStep {
                case .welcome:
                    OnboardingWelcomeStepView(
                        onContinue: { flow.advance() },
                        onSetUpLater: finish
                    )
                case .chooseProvider:
                    OnboardingChooseProviderStepView(
                        currentProviderName: currentProviderName,
                        presets: offeredProviderPresets(
                            existingProfiles: appEnv.settings.profiles,
                            onDeviceAvailability: onDeviceAvailability
                        ),
                        onKeepCurrent: { flow.keepCurrentProvider() },
                        onSelect: selectPreset,
                        onSetUpLater: finish
                    )
                case .providerDetails:
                    // The real content is the `.sheet` below; this is just
                    // what's visible behind it while it's up.
                    Color.clear
                case .testConnection:
                    if let savedProfile {
                        OnboardingTestConnectionStepView(
                            profile: savedProfile,
                            onContinue: { flow.advance() },
                            onSetUpLater: finish
                        )
                    }
                case .consent(let host):
                    if let savedProfile {
                        KallilexUI.ConsentView(
                            profileName: savedProfile.name,
                            host: host,
                            onAllow: { grantConsentAndAdvance(profile: savedProfile, host: host) },
                            onNotNow: { flow.advance() }
                        )
                    }
                case .shareSheetGuide:
                    OnboardingShareSheetGuideStepView(
                        onContinue: { flow.advance() },
                        onSetUpLater: finish
                    )
                case .done:
                    OnboardingDoneStepView(onStart: finish)
                }
            }
        }
        .sheet(isPresented: $showProviderEditor, onDismiss: handleProviderEditorDismiss) {
            if let draft {
                ProviderEditor(draft: draft, onSave: handleProviderSave)
            }
        }
        .task {
            onDeviceAvailability = await appEnv.onDeviceModel.availability
        }
    }

    /// `nil` when there's no existing provider at all — `chooseProvider`
    /// then hides "Keep my current provider" entirely, since there's
    /// nothing to keep. Otherwise the active profile's name, or (no active
    /// profile set) the first one's — mirrors `ActionRunner`'s own
    /// "active, falling back to none" lookup closely enough for display
    /// purposes.
    private var currentProviderName: String? {
        let profiles = appEnv.settings.profiles
        guard !profiles.isEmpty else { return nil }
        let active = profiles.first { $0.id == appEnv.settings.activeProfileID }
        return (active ?? profiles.first)?.name
    }

    // MARK: - Step transitions

    private func selectPreset(_ preset: ProviderPreset) {
        draft = ProviderDraft(preset: preset)
        providerDetailsSaved = false
        flow.advance() // -> .providerDetails
        showProviderEditor = true
    }

    /// `ProviderEditor`'s own Save button already calls `onSave` then
    /// `dismiss()`; this is that `onSave`. `saveProfile` returns the saved
    /// profile with its resolved id (generated here for a brand-new preset
    /// draft), so there's no need to diff the profile list to find it.
    private func handleProviderSave(_ profile: ProviderProfile, _ apiKey: String?) {
        do {
            let saved = try appEnv.service.saveProfile(profile, apiKey: apiKey)
            try appEnv.service.setActiveProfile(id: saved.id)
            appEnv.reload()
            providerDetailsSaved = true
            savedProfile = saved
            flow.applyConsentRequirement(consentRequirement(for: saved, consents: appEnv.settings.consents))
            flow.advance() // -> .testConnection
        } catch {
            appEnv.lastError = error.localizedDescription
        }
    }

    /// Fires for both Cancel and Save (SwiftUI's `.sheet(onDismiss:)` can't
    /// tell them apart); `providerDetailsSaved` (set only by
    /// `handleProviderSave`) disambiguates. Cancelling goes back to
    /// `.chooseProvider` rather than exiting onboarding outright, so the
    /// user can pick a different preset.
    private func handleProviderEditorDismiss() {
        guard !providerDetailsSaved else { return }
        flow.returnToChooseProvider()
    }

    private func grantConsentAndAdvance(profile: ProviderProfile, host: String) {
        appEnv.perform { try $0.grantConsent(profileID: profile.id, host: host) }
        flow.advance()
    }

    /// "Set up later" (any step) and "Start using Kallilex" (`.done`) both
    /// land here: whatever was already saved stays, `onboardingCompleted`
    /// flips to `true`, and `RootTabView`'s cover binding dismisses this
    /// view in response.
    private func finish() {
        appEnv.updateSettings { $0.onboardingCompleted = true }
    }
}

// MARK: - Welcome

private struct OnboardingWelcomeStepView: View {
    let onContinue: () -> Void
    let onSetUpLater: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text(String(localized: "onboarding.welcome.title", defaultValue: "Welcome to Kallilex"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                // Requests its own ideal height instead of accepting
                // whatever an ancestor offers (ios-11, "Dynamic Type"):
                // caught as "Text clipped" by `AccessibilityUITests
                // .testOnboardingWelcomeStepAudit`.
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.welcome.title")

            VStack(alignment: .leading, spacing: 20) {
                illustrationRow(
                    symbol: "text.quote",
                    text: String(localized: "onboarding.welcome.step1", defaultValue: "Select text in any app.")
                )
                illustrationRow(
                    symbol: "square.and.arrow.up",
                    text: String(localized: "onboarding.welcome.step2", defaultValue: "Tap Share.")
                )
                illustrationRow(
                    symbol: "sparkles",
                    text: String(localized: "onboarding.welcome.step3", defaultValue: "Tap Kallilex.")
                )
            }

            // `.primary`, not `.secondary` (ios-11, "Contrast and color"):
            // at `.subheadline` size, `.secondary` on this background falls
            // short of WCAG AA (caught by
            // `AccessibilityUITests.testOnboardingWelcomeStepAudit`).
            Text(String(localized: "onboarding.welcome.subtitle", defaultValue: "Use AI to rewrite text right in any app."))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.welcome.subtitle")

            Spacer()

            OnboardingActionButtons(
                continueTitle: String(localized: "onboarding.continue", defaultValue: "Continue"),
                onContinue: onContinue,
                onSetUpLater: onSetUpLater,
                continueIdentifier: "onboarding.welcome.continue",
                setUpLaterIdentifier: "onboarding.welcome.setUpLater"
            )
        }
        .padding()
    }

    private func illustrationRow(symbol: String, text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            Text(text)
        }
    }
}

// MARK: - Choose provider

private struct OnboardingChooseProviderStepView: View {
    /// `nil` when there's no provider configured yet — hides "Keep my
    /// current provider" entirely (re-running onboarding has nothing to
    /// keep; a brand-new install has nothing to duplicate either way, but
    /// there's nothing to show here regardless).
    let currentProviderName: String?
    /// Already filtered by `offeredProviderPresets` (ios-10) — this view
    /// has no opinion of its own on which presets to show.
    let presets: [ProviderPreset]
    let onKeepCurrent: () -> Void
    let onSelect: (ProviderPreset) -> Void
    let onSetUpLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let currentProviderName {
                    Button {
                        onKeepCurrent()
                    } label: {
                        Text(String(
                            localized: "onboarding.provider.keepCurrent",
                            defaultValue: "Keep my current provider (\(currentProviderName))"
                        ))
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("onboarding.provider.keepCurrent")
                }

                ForEach(presets, id: \.id) { preset in
                    Button {
                        onSelect(preset)
                    } label: {
                        Text(preset.label)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("onboarding.provider.preset.\(preset.id)")
                }
            }

            Button(String(localized: "onboarding.setUpLater", defaultValue: "Set up later")) {
                onSetUpLater()
            }
            .padding()
            .accessibilityIdentifier("onboarding.provider.setUpLater")
        }
        .navigationTitle(String(localized: "onboarding.provider.title", defaultValue: "Choose a provider"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Test connection

private struct OnboardingTestConnectionStepView: View {
    @Environment(AppEnvironment.self) private var appEnv

    let profile: ProviderProfile
    let onContinue: () -> Void
    let onSetUpLater: () -> Void

    private enum TestState: Equatable {
        case running
        case success
        case failure(String)
    }

    @State private var state: TestState = .running
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(String(localized: "onboarding.testConnection.title", defaultValue: "Testing your connection"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.testConnection.title")

            switch state {
            case .running:
                ProgressView()
                    .accessibilityIdentifier("onboarding.testConnection.progress")
            case .success:
                Text(String(localized: "onboarding.testConnection.success", defaultValue: "✓ Connection successful"))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("onboarding.testConnection.result")
            case .failure(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.testConnection.result")
            }

            if privacyClass(for: profile) == .lan {
                Text(ProviderDraftWarning.localNetworkHint.errorDescription ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.testConnection.localNetworkHint")
            }

            Spacer()

            // "Continue always enabled, even if test failed" — the test
            // result here is informational, same as ios-06's Providers tab.
            OnboardingActionButtons(
                continueTitle: String(localized: "onboarding.continue", defaultValue: "Continue"),
                onContinue: onContinue,
                onSetUpLater: onSetUpLater,
                continueIdentifier: "onboarding.testConnection.continue",
                setUpLaterIdentifier: "onboarding.testConnection.setUpLater"
            )
        }
        .padding()
        .onAppear(perform: runTest)
        .onDisappear { task?.cancel() }
    }

    private func runTest() {
        let apiKey: String? = profile.hasApiKey ? (try? appEnv.secretStore.get(profileID: profile.id)) : nil
        task = Task {
            let result = await appEnv.actionRunner.testConnection(profile: profile, apiKey: apiKey)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                state = .success
            case .failure(let error):
                state = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Share sheet guide

private struct OnboardingShareSheetGuideStepView: View {
    let onContinue: () -> Void
    let onSetUpLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            KallilexUI.ShareSheetGuideView()
            OnboardingActionButtons(
                continueTitle: String(localized: "onboarding.continue", defaultValue: "Continue"),
                onContinue: onContinue,
                onSetUpLater: onSetUpLater,
                continueIdentifier: "onboarding.shareSheetGuide.continue",
                setUpLaterIdentifier: "onboarding.shareSheetGuide.setUpLater"
            )
            .padding()
        }
        .navigationTitle(String(
            localized: "settings.shareSheetGuide.title",
            defaultValue: "Add Kallilex to your share sheet"
        ))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Done

private struct OnboardingDoneStepView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(String(localized: "onboarding.done.title", defaultValue: "You're all set!"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.done.title")

            Text(String(
                localized: "onboarding.done.subtitle",
                defaultValue: "Kallilex is ready to help. Return to any app, select text, tap Share, and choose Kallilex."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("onboarding.done.subtitle")

            Spacer()

            Button(String(localized: "onboarding.done.start", defaultValue: "Start using Kallilex")) {
                onStart()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding.done.start")
        }
        .padding()
    }
}

// MARK: - Shared Continue / Set up later footer

private struct OnboardingActionButtons: View {
    let continueTitle: String
    let onContinue: () -> Void
    let onSetUpLater: () -> Void
    let continueIdentifier: String
    let setUpLaterIdentifier: String

    var body: some View {
        VStack(spacing: 12) {
            Button(continueTitle, action: onContinue)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(continueIdentifier)

            Button(String(localized: "onboarding.setUpLater", defaultValue: "Set up later"), action: onSetUpLater)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(setUpLaterIdentifier)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppEnvironment(
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore(),
            actionRunner: ActionRunner(settings: InMemorySettingsStore(), secrets: InMemorySecretStore()),
            settings: .seeded()
        ))
}
