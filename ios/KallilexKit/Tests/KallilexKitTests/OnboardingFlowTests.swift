import Testing
import KallilexKit

/// Tests for `OnboardingFlow`. See
/// `issues-ios/spec-ios-07-consent-and-onboarding.md`.
struct OnboardingFlowTests {
    private func isConsentStep(_ step: OnboardingFlow.Step) -> Bool {
        if case .consent = step { return true }
        return false
    }

    // ---- initial sequencing --------------------------------------------

    @Test func initialStartsAtWelcomeWithTheFixedSkeletonAndNoConsent() {
        let flow = OnboardingFlow.initial()
        #expect(flow.currentStep == .welcome)
        #expect(flow.steps == [
            .welcome, .chooseProvider, .providerDetails, .testConnection,
            .shareSheetGuide, .keyboardGuide, .done,
        ])
    }

    // ---- ios-22: keyboardGuide step --------------------------------------

    @Test func keyboardGuideComesRightAfterShareSheetGuideAndRightBeforeDone() {
        let flow = OnboardingFlow.initial()
        let shareSheetIndex = flow.steps.firstIndex(of: .shareSheetGuide)
        let keyboardGuideIndex = flow.steps.firstIndex(of: .keyboardGuide)
        let doneIndex = flow.steps.firstIndex(of: .done)
        #expect(keyboardGuideIndex == shareSheetIndex.map { $0 + 1 })
        #expect(doneIndex == keyboardGuideIndex.map { $0 + 1 })
    }

    /// "Later" on the keyboard guide step advances to `.done` (mirrors
    /// `OnboardingView`'s `onLater: { flow.advance() }`) — the same target
    /// `skipToEnd()` would land on, since `.done` is already the next step.
    @Test func advancingPastKeyboardGuideLandsOnDone() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.keepCurrentProvider() // -> shareSheetGuide
        flow.advance() // -> keyboardGuide
        #expect(flow.currentStep == .keyboardGuide)
        flow.advance() // "Later" -> done
        #expect(flow.currentStep == .done)
    }

    /// "Set up later" from the keyboard guide step (same affordance every
    /// other step offers) also reaches `.done`, via `skipToEnd()`.
    @Test func skipToEndFromKeyboardGuideLandsOnDone() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.keepCurrentProvider() // -> shareSheetGuide
        flow.advance() // -> keyboardGuide
        flow.skipToEnd()
        #expect(flow.currentStep == .done)
    }

    /// Back navigation (`returnToChooseProvider`) from a step after
    /// `keyboardGuide` is unaffected by the new step's position — mirrors
    /// `returnToChooseProviderGoesBackFromLaterSteps` below, one step
    /// further along.
    @Test func returnToChooseProviderStillWorksWithKeyboardGuideInTheStepList() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.keepCurrentProvider() // -> shareSheetGuide
        flow.advance() // -> keyboardGuide
        flow.returnToChooseProvider()
        #expect(flow.currentStep == .chooseProvider)
    }

    @Test func advanceMovesForwardAndStopsAtDone() {
        var flow = OnboardingFlow.initial()
        for _ in flow.steps.indices {
            flow.advance()
        }
        #expect(flow.currentStep == .done)
        flow.advance() // no-op past the end
        #expect(flow.currentStep == .done)
    }

    @Test func skipToEndLandsOnDone() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.skipToEnd()
        #expect(flow.currentStep == .done)
    }

    @Test func keepCurrentProviderJumpsStraightToShareSheetGuide() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.keepCurrentProvider()
        #expect(flow.currentStep == .shareSheetGuide)
    }

    @Test func returnToChooseProviderGoesBackFromLaterSteps() {
        var flow = OnboardingFlow.initial()
        flow.advance() // chooseProvider
        flow.advance() // providerDetails
        flow.advance() // testConnection
        flow.returnToChooseProvider()
        #expect(flow.currentStep == .chooseProvider)
    }

    // ---- step sequencing per configured profile -------------------------
    // Mirrors `ConsentRequirementTests`: sequencing is decided from the
    // saved profile, not the preset, via `applyConsentRequirement`.

    @Test func openAIPresetCloudProfileAddsConsentStep() {
        var flow = OnboardingFlow.initial()
        let preset = providerPresets().first { $0.id == "openai" }!
        let profile = ProviderProfile(id: "p1", name: preset.label, baseUrl: preset.baseUrl, model: "gpt-4-turbo", hasApiKey: true)

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        #expect(flow.steps.contains { isConsentStep($0) })
    }

    @Test func ollamaPresetLANProfileDoesNotAddConsentStep() {
        var flow = OnboardingFlow.initial()
        let preset = providerPresets().first { $0.id == "ollama" }!
        let profile = ProviderProfile(id: "p1", name: preset.label, baseUrl: preset.baseUrl, model: "llama3")

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        #expect(!flow.steps.contains { isConsentStep($0) })
    }

    @Test func customPresetEditedToACloudHostAddsConsentStepNamingTheHost() {
        var flow = OnboardingFlow.initial()
        let profile = ProviderProfile(id: "p1", name: "Custom", baseUrl: "https://api.example.com/v1", model: "gpt-4")

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        #expect(flow.steps.contains(.consent(host: "api.example.com")))
    }

    @Test func customPresetWithLocalhostDoesNotAddConsentStep() {
        var flow = OnboardingFlow.initial()
        let profile = ProviderProfile(id: "p1", name: "Custom", baseUrl: "http://localhost:11434/v1", model: "llama3")

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        #expect(!flow.steps.contains { isConsentStep($0) })
    }

    @Test func consentStepIsInsertedRightAfterTestConnection() {
        var flow = OnboardingFlow.initial()
        let profile = ProviderProfile(id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4")

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        let testConnectionIndex = flow.steps.firstIndex(of: .testConnection)
        let consentIndex = flow.steps.firstIndex(of: .consent(host: "api.openai.com"))
        #expect(testConnectionIndex != nil)
        #expect(consentIndex == (testConnectionIndex.map { $0 + 1 }))
    }

    @Test func applyConsentRequirementIsIdempotentAndNeverDuplicates() {
        var flow = OnboardingFlow.initial()
        let profile = ProviderProfile(id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4")

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))
        flow.applyConsentRequirement(consentRequirement(for: profile, consents: []))

        #expect(flow.steps.filter { isConsentStep($0) }.count == 1)
    }

    @Test func applyConsentRequirementRemovesAStaleConsentStepWhenNoLongerNeeded() {
        var flow = OnboardingFlow.initial()
        let cloudProfile = ProviderProfile(id: "p1", name: "Custom", baseUrl: "https://api.example.com/v1", model: "m")
        flow.applyConsentRequirement(consentRequirement(for: cloudProfile, consents: []))
        #expect(flow.steps.contains { isConsentStep($0) })

        // The user edits the same profile again to a local host.
        let localProfile = ProviderProfile(id: "p1", name: "Custom", baseUrl: "http://localhost:11434/v1", model: "m")
        flow.applyConsentRequirement(consentRequirement(for: localProfile, consents: []))

        #expect(!flow.steps.contains { isConsentStep($0) })
    }

    @Test func aProfileAlreadyGrantedConsentDoesNotAddTheStepAgain() {
        var flow = OnboardingFlow.initial()
        let profile = ProviderProfile(id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4")
        let consent = AIConsent(profileID: "p1", host: "api.openai.com", grantedAt: .now)

        flow.applyConsentRequirement(consentRequirement(for: profile, consents: [consent]))

        #expect(!flow.steps.contains { isConsentStep($0) })
    }
}
