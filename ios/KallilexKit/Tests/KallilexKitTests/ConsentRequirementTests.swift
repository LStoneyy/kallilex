import Foundation
import Testing
import KallilexKit

/// Tests for `consentRequirement(for:consents:)`. See
/// `issues-ios/spec-ios-07-consent-and-onboarding.md`.
struct ConsentRequirementTests {
    func profile(kind: ProviderKind = .openAICompatible, baseUrl: String, id: String = "p1") -> ProviderProfile {
        ProviderProfile(id: id, name: "P", kind: kind, baseUrl: baseUrl, model: "m")
    }

    @Test func cloudOpenAICompatibleWithoutConsentIsRequired() {
        let p = profile(baseUrl: "https://api.openai.com/v1")
        #expect(consentRequirement(for: p, consents: []) == .required(host: "api.openai.com"))
    }

    @Test func localDoesNotNeedConsent() {
        let p = profile(baseUrl: "http://localhost:11434/v1")
        #expect(consentRequirement(for: p, consents: []) == .notNeeded)
    }

    @Test func lanDoesNotNeedConsent() {
        let p = profile(baseUrl: "http://192.168.1.10:11434/v1")
        #expect(consentRequirement(for: p, consents: []) == .notNeeded)
    }

    @Test func onDeviceDoesNotNeedConsent() {
        let p = profile(kind: .appleOnDevice, baseUrl: "")
        #expect(consentRequirement(for: p, consents: []) == .notNeeded)
    }

    @Test func unknownKindDoesNotNeedConsent() {
        let p = profile(kind: .unknown("applePrivateCloud"), baseUrl: "https://example.com/v1")
        #expect(consentRequirement(for: p, consents: []) == .notNeeded)
    }

    @Test func grantedConsentIsRecognized() {
        let p = profile(baseUrl: "https://api.openai.com/v1")
        let consent = AIConsent(profileID: p.id, host: "api.openai.com", grantedAt: Date())
        #expect(consentRequirement(for: p, consents: [consent]) == .granted)
    }

    @Test func hostChangeRequiresConsentAgain() {
        let p = profile(baseUrl: "https://api.anthropic.com/v1")
        let consent = AIConsent(profileID: p.id, host: "api.openai.com", grantedAt: Date())
        #expect(consentRequirement(for: p, consents: [consent]) == .required(host: "api.anthropic.com"))
    }

    @Test func consentForADifferentProfileIdDoesNotCount() {
        let p = profile(baseUrl: "https://api.openai.com/v1", id: "p1")
        let consent = AIConsent(profileID: "other", host: "api.openai.com", grantedAt: Date())
        #expect(consentRequirement(for: p, consents: [consent]) == .required(host: "api.openai.com"))
    }
}
