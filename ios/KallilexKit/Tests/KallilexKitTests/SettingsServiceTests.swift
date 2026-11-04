import Foundation
import Testing
import KallilexKit

/// Tests for `SettingsService`'s profile, prompt and consent operations.
/// See `issues-ios/spec-ios-04-models-and-stores.md`.
struct SettingsServiceTests {
    func makeService(initial: AppSettings = .init(prompts: [])) -> (SettingsService, InMemorySettingsStore, InMemorySecretStore) {
        let settings = InMemorySettingsStore(initial: initial)
        let secrets = InMemorySecretStore()
        return (SettingsService(settings: settings, secrets: secrets), settings, secrets)
    }

    func sampleProfile(id: String = "", baseUrl: String = "http://localhost:11434/v1") -> ProviderProfile {
        ProviderProfile(id: id, name: "Profile \(id)", baseUrl: baseUrl, model: "llama3")
    }

    // ---- saveProfile: validation --------------------------------------------

    @Test func saveProfileRejectsABlankName() {
        let (service, _, _) = makeService()
        var profile = sampleProfile(id: "a")
        profile.name = "   "
        #expect(throws: SettingsServiceError.validation(.blankProfileName)) {
            try service.saveProfile(profile, apiKey: nil)
        }
    }

    @Test func saveProfileRejectsATimeoutBelowOne() {
        let (service, _, _) = makeService()
        var profile = sampleProfile(id: "a")
        profile.timeoutSecs = 0
        #expect(throws: SettingsServiceError.validation(.invalidTimeout)) {
            try service.saveProfile(profile, apiKey: nil)
        }
    }

    @Test func saveProfileAllowsAnEmptyBaseUrlAndModel() throws {
        // Mirrors desktop's `validate_profile`: baseUrl/model aren't
        // validated at save time.
        let (service, _, _) = makeService()
        var profile = sampleProfile(id: "a")
        profile.baseUrl = ""
        profile.model = ""
        let saved = try service.saveProfile(profile, apiKey: nil)
        #expect(saved.id == "a")
    }

    @Test func saveProfileAllowsAppleOnDeviceWithEmptyBaseUrlAndModelAndNoApiKey() throws {
        // ios-10: the on-device profile has no URL, model, or key at all.
        let (service, _, _) = makeService()
        let profile = ProviderProfile(id: "a", name: "On-Device", kind: .appleOnDevice, baseUrl: "", model: "")
        let saved = try service.saveProfile(profile, apiKey: nil)
        #expect(saved.id == "a")
        #expect(saved.baseUrl.isEmpty)
        #expect(saved.model.isEmpty)
        #expect(saved.hasApiKey == false)
    }

    // ---- saveProfile: id generation and upsert ------------------------------

    @Test func saveProfileWithAnEmptyIdGeneratesOneAndReturnsIt() throws {
        let (service, settings, _) = makeService()
        let saved = try service.saveProfile(sampleProfile(id: ""), apiKey: nil)
        #expect(!saved.id.isEmpty)
        #expect(try settings.load().profiles.map(\.id) == [saved.id])
    }

    @Test func saveProfileWithAnExistingIdUpsertsInPlaceAndReturnsTheSameId() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)

        var updated = sampleProfile(id: "a")
        updated.name = "Renamed"
        let saved = try service.saveProfile(updated, apiKey: nil)

        #expect(saved.id == "a")
        #expect(saved.name == "Renamed")
        #expect(try settings.load().profiles.count == 1)
    }

    // ---- saveProfile: first-profile activation ------------------------------

    @Test func theFirstSavedProfileBecomesActive() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        #expect(try settings.load().activeProfileID == "a")
    }

    @Test func aSecondSavedProfileDoesNotChangeTheActiveProfile() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        try service.saveProfile(sampleProfile(id: "b"), apiKey: nil)
        #expect(try settings.load().activeProfileID == "a")
    }

    // ---- saveProfile: the three apiKey cases --------------------------------

    @Test func apiKeyNilPreservesTheExistingKeyAndFlag() throws {
        let (service, _, secrets) = makeService()
        let profile = sampleProfile(id: "a")
        try service.saveProfile(profile, apiKey: "sk-key")

        let saved = try service.saveProfile(profile, apiKey: nil)

        #expect(saved.hasApiKey)
        #expect(try secrets.get(profileID: "a") == "sk-key")
    }

    @Test func apiKeyBlankAfterTrimmingDeletesTheKeyAndClearsTheFlag() throws {
        let (service, _, secrets) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: "sk-key")

        let saved = try service.saveProfile(sampleProfile(id: "a"), apiKey: "   ")

        #expect(!saved.hasApiKey)
        #expect(try secrets.get(profileID: "a") == nil)
    }

    @Test func apiKeyNonBlankSetsTheKeyAndFlag() throws {
        let (service, _, secrets) = makeService()
        let saved = try service.saveProfile(sampleProfile(id: "a"), apiKey: "sk-key")

        #expect(saved.hasApiKey)
        #expect(try secrets.get(profileID: "a") == "sk-key")
    }

    @Test func apiKeyNilOnABrandNewProfileLeavesHasApiKeyFalse() throws {
        let (service, _, _) = makeService()
        let saved = try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        #expect(!saved.hasApiKey)
    }

    // ---- saveProfile: consent invalidation on host change -------------------

    @Test func savingWithAChangedHostRemovesThatProfilesConsentsForTheOldHost() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://old-host/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "old-host")

        var moved = sampleProfile(id: "a", baseUrl: "http://new-host/v1")
        moved.name = "Profile a"
        try service.saveProfile(moved, apiKey: nil)

        #expect(try settings.load().consents.isEmpty)
    }

    @Test func savingWithTheSameHostKeepsConsent() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://same-host/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "same-host")

        // Re-save with only the model changed — host untouched.
        var resaved = sampleProfile(id: "a", baseUrl: "http://same-host/v1")
        resaved.model = "different-model"
        try service.saveProfile(resaved, apiKey: nil)

        #expect(try settings.load().consents.count == 1)
    }

    @Test func savingWithOnlyAPortChangeDoesNotInvalidateConsent() throws {
        // `consentHost(for:)` ignores the port, so a port-only change
        // must never invalidate consent.
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://localhost:11434/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "localhost")

        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://localhost:11435/v1"), apiKey: nil)

        #expect(try settings.load().consents.count == 1)
    }

    @Test func savingWithOnlyAPathChangeDoesNotInvalidateConsent() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://api.example.com/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "api.example.com")

        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://api.example.com/v2/chat"), apiKey: nil)

        #expect(try settings.load().consents.count == 1)
    }

    @Test func movingToAnUnparseableBaseUrlRemovesAllOfThisProfilesConsents() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://old-host/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "old-host")

        try service.saveProfile(sampleProfile(id: "a", baseUrl: "not a url"), apiKey: nil)

        #expect(try settings.load().consents.isEmpty)
    }

    @Test func hostChangeOnOneProfileDoesNotTouchAnotherProfilesConsent() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://host-a/v1"), apiKey: nil)
        try service.saveProfile(sampleProfile(id: "b", baseUrl: "http://host-b/v1"), apiKey: nil)
        try service.grantConsent(profileID: "a", host: "host-a")
        try service.grantConsent(profileID: "b", host: "host-b")

        try service.saveProfile(sampleProfile(id: "a", baseUrl: "http://new-host-a/v1"), apiKey: nil)

        let consents = try settings.load().consents
        #expect(!consents.contains { $0.profileID == "a" })
        #expect(consents.contains { $0.profileID == "b" })
    }

    // ---- deleteProfile -------------------------------------------------

    @Test func deletingAProfileRemovesItsKeyAndClearsActiveIdAndConsents() throws {
        let (service, settings, secrets) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: "sk-key")
        try service.grantConsent(profileID: "a", host: "localhost")

        let profiles = try service.deleteProfile(id: "a")

        #expect(profiles.isEmpty)
        #expect(try secrets.get(profileID: "a") == nil)
        let loaded = try settings.load()
        #expect(loaded.activeProfileID == nil)
        #expect(loaded.consents.isEmpty)
    }

    @Test func deletingAnUnknownProfileIsANoOp() throws {
        let (service, _, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        let profiles = try service.deleteProfile(id: "missing")
        #expect(profiles.count == 1)
    }

    // ---- setActiveProfile ------------------------------------------------

    @Test func setActiveProfileRejectsAnUnknownId() throws {
        let (service, _, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        #expect(throws: SettingsServiceError.profileNotFound("missing")) {
            try service.setActiveProfile(id: "missing")
        }
    }

    @Test func setActiveProfileRoundTripsAKnownId() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)
        try service.saveProfile(sampleProfile(id: "b"), apiKey: nil)

        try service.setActiveProfile(id: "b")

        #expect(try settings.load().activeProfileID == "b")
    }

    @Test func setActiveProfileAcceptsNilToClear() throws {
        let (service, settings, _) = makeService()
        try service.saveProfile(sampleProfile(id: "a"), apiKey: nil)

        try service.setActiveProfile(id: nil)

        #expect(try settings.load().activeProfileID == nil)
    }

    // ---- savePrompt / deletePrompt -----------------------------------------

    @Test func savePromptRejectsABlankLabel() {
        let (service, _, _) = makeService()
        #expect(throws: SettingsServiceError.validation(.blankPromptLabel)) {
            try service.savePrompt(CustomPrompt(id: "a", label: "   ", instruction: "Do something."))
        }
    }

    @Test func savePromptRejectsABlankInstruction() {
        let (service, _, _) = makeService()
        #expect(throws: SettingsServiceError.validation(.blankPromptInstruction)) {
            try service.savePrompt(CustomPrompt(id: "a", label: "Label", instruction: "   "))
        }
    }

    @Test func savePromptWithAnEmptyIdGeneratesOne() throws {
        let (service, _, _) = makeService()
        let prompts = try service.savePrompt(CustomPrompt(id: "", label: "L", instruction: "I"))
        #expect(prompts.count == 1)
        #expect(!prompts[0].id.isEmpty)
    }

    @Test func savePromptWithAnExistingIdUpsertsInPlace() throws {
        let (service, _, _) = makeService()
        try service.savePrompt(CustomPrompt(id: "a", label: "L", instruction: "I"))
        let prompts = try service.savePrompt(CustomPrompt(id: "a", label: "Renamed", instruction: "I"))
        #expect(prompts.count == 1)
        #expect(prompts[0].label == "Renamed")
    }

    @Test func deletingAPromptRemovesItAndKeepsTheRest() throws {
        let (service, _, _) = makeService()
        try service.savePrompt(CustomPrompt(id: "a", label: "A", instruction: "I"))
        try service.savePrompt(CustomPrompt(id: "b", label: "B", instruction: "I"))

        let prompts = try service.deletePrompt(id: "a")

        #expect(!prompts.contains { $0.id == "a" })
        #expect(prompts.contains { $0.id == "b" })
    }

    @Test func deletingAnUnknownPromptIsANoOp() throws {
        let (service, _, _) = makeService()
        try service.savePrompt(CustomPrompt(id: "a", label: "A", instruction: "I"))
        let prompts = try service.deletePrompt(id: "missing")
        #expect(prompts.count == 1)
    }

    // ---- movePrompts -----------------------------------------------------

    @Test func movePromptsReordersTheList() throws {
        let (service, _, _) = makeService()
        try service.savePrompt(CustomPrompt(id: "a", label: "A", instruction: "I"))
        try service.savePrompt(CustomPrompt(id: "b", label: "B", instruction: "I"))
        try service.savePrompt(CustomPrompt(id: "c", label: "C", instruction: "I"))
        try service.savePrompt(CustomPrompt(id: "d", label: "D", instruction: "I"))

        let prompts = try service.movePrompts(fromOffsets: IndexSet([0]), toOffset: 2)

        #expect(prompts.map(\.id) == ["b", "a", "c", "d"])
    }

    // ---- restoreDefaultPrompts ---------------------------------------------

    @Test func restoreDefaultPromptsAddsMissingDefaultsWithoutDuplicating() throws {
        let (service, _, _) = makeService(initial: AppSettings(prompts: []))
        try service.savePrompt(CustomPrompt(id: "custom-1", label: "Custom", instruction: "I"))

        let prompts = try service.restoreDefaultPrompts(locale: Locale(identifier: "en"))

        let defaultIDs = Set(PromptDefaults.defaults(locale: Locale(identifier: "en")).map(\.id))
        #expect(defaultIDs.isSubset(of: Set(prompts.map(\.id))))
        #expect(prompts.contains { $0.id == "custom-1" })
        #expect(prompts.count == defaultIDs.count + 1)

        // Calling it again must not duplicate anything.
        let again = try service.restoreDefaultPrompts(locale: Locale(identifier: "en"))
        #expect(again.count == prompts.count)
    }

    @Test func restoreDefaultPromptsNeverRemovesAUserEditedDefault() throws {
        let (service, _, _) = makeService(initial: .seeded(locale: Locale(identifier: "en")))
        try service.savePrompt(CustomPrompt(id: "builtin-rewrite", label: "My Rewrite", instruction: "Custom instruction"))

        let prompts = try service.restoreDefaultPrompts(locale: Locale(identifier: "en"))

        let rewrite = try #require(prompts.first { $0.id == "builtin-rewrite" })
        #expect(rewrite.label == "My Rewrite")
        #expect(rewrite.instruction == "Custom instruction")
    }

    // ---- consent -----------------------------------------------------------

    @Test func grantConsentUsesTheInjectedClock() throws {
        let (service, settings, _) = makeService()
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try service.grantConsent(profileID: "a", host: "example.com", now: { fixedDate })

        let consent = try #require(settings.load().consents.first)
        #expect(consent.profileID == "a")
        #expect(consent.host == "example.com")
        #expect(consent.grantedAt == fixedDate)
    }

    @Test func grantConsentTwiceUpdatesInPlaceRatherThanDuplicating() throws {
        let (service, settings, _) = makeService()
        try service.grantConsent(profileID: "a", host: "example.com", now: { Date(timeIntervalSince1970: 1) })
        try service.grantConsent(profileID: "a", host: "example.com", now: { Date(timeIntervalSince1970: 2) })

        let consents = try settings.load().consents
        #expect(consents.count == 1)
        #expect(consents[0].grantedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func hasConsentReflectsGrantAndRevoke() throws {
        let (service, _, _) = makeService()
        #expect(try !service.hasConsent(profileID: "a", host: "example.com"))

        try service.grantConsent(profileID: "a", host: "example.com")
        #expect(try service.hasConsent(profileID: "a", host: "example.com"))

        try service.revokeConsent(profileID: "a", host: "example.com")
        #expect(try !service.hasConsent(profileID: "a", host: "example.com"))
    }

    @Test func revokeConsentIsANoOpWhenNoneExists() throws {
        let (service, _, _) = makeService()
        try service.revokeConsent(profileID: "a", host: "example.com") // must not throw
    }
}
