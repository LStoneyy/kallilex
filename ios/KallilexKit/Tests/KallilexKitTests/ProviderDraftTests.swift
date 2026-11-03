import Foundation
import Testing
import KallilexKit

/// Tests for `ProviderDraft`'s validation, warnings, API-key argument
/// mapping, and the `canActivate` rules. See
/// `issues-ios/spec-ios-06-container-app-settings.md`.
struct ProviderDraftTests {
    func validDraft(baseUrl: String = "https://api.example.com/v1") -> ProviderDraft {
        ProviderDraft(name: "My Provider", baseUrl: baseUrl, model: "gpt-4-turbo")
    }

    // ---- validation ----------------------------------------------------

    @Test func blankNameIsRejected() {
        var draft = validDraft()
        draft.name = "   "
        #expect(draft.validationErrors.contains(.blankName))
        #expect(!draft.canSave)
    }

    @Test func blankModelIsRejectedForOpenAICompatible() {
        var draft = validDraft()
        draft.model = "  "
        #expect(draft.validationErrors.contains(.blankModel))
        #expect(!draft.canSave)
    }

    @Test func modelIsNotRequiredForNonOpenAICompatibleKinds() {
        var draft = validDraft()
        draft.kind = .appleOnDevice
        draft.model = ""
        draft.baseUrl = ""
        #expect(draft.canSave)
    }

    @Test func anEmptyBaseUrlIsAllowed() {
        var draft = validDraft()
        draft.baseUrl = ""
        #expect(draft.canSave)
    }

    @Test func aNonEmptyBaseUrlMustParseAsHttpOrHttps() {
        var draft = validDraft()
        draft.baseUrl = "not a url"
        #expect(draft.validationErrors.contains(.invalidBaseUrl))
        #expect(!draft.canSave)
    }

    @Test func aFtpUrlIsRejected() {
        var draft = validDraft()
        draft.baseUrl = "ftp://example.com/v1"
        #expect(draft.validationErrors.contains(.invalidBaseUrl))
    }

    @Test func aValidHttpsUrlIsAccepted() {
        let draft = validDraft(baseUrl: "https://api.openai.com/v1")
        #expect(draft.canSave)
    }

    @Test func aValidHttpUrlIsAccepted() {
        let draft = validDraft(baseUrl: "http://your-mac.local:11434/v1")
        #expect(draft.canSave)
    }

    // ---- warnings --------------------------------------------------------

    @Test func httpToACloudHostWarns() {
        let draft = validDraft(baseUrl: "http://api.example.com/v1")
        #expect(draft.warnings.contains(.insecureHttpToCloud))
    }

    @Test func httpsToACloudHostDoesNotWarn() {
        let draft = validDraft(baseUrl: "https://api.example.com/v1")
        #expect(!draft.warnings.contains(.insecureHttpToCloud))
    }

    @Test func aLanHostHintsAboutLocalNetworkPermission() {
        let draft = validDraft(baseUrl: "http://your-mac.local:11434/v1")
        #expect(draft.warnings.contains(.localNetworkHint))
    }

    @Test func aLocalHostHasNoWarnings() {
        let draft = validDraft(baseUrl: "http://localhost:11434/v1")
        #expect(draft.warnings.isEmpty)
    }

    @Test func anEmptyBaseUrlHasNoWarnings() {
        var draft = validDraft()
        draft.baseUrl = ""
        #expect(draft.warnings.isEmpty)
    }

    @Test func warningsAreEmptyForNonOpenAICompatibleKinds() {
        var draft = validDraft(baseUrl: "http://api.example.com/v1")
        draft.kind = .appleOnDevice
        #expect(draft.warnings.isEmpty)
    }

    // ---- API key argument mapping ----------------------------------------

    @Test func keepIntentMapsToNil() {
        var draft = validDraft()
        draft.apiKeyIntent = .keep
        #expect(draft.apiKeyArgument == nil)
    }

    @Test func removeIntentMapsToAnEmptyString() {
        var draft = validDraft()
        draft.apiKeyIntent = .remove
        #expect(draft.apiKeyArgument == "")
    }

    @Test func replaceIntentMapsToTheNewKey() {
        var draft = validDraft()
        draft.apiKeyIntent = .replace("sk-test")
        #expect(draft.apiKeyArgument == "sk-test")
    }

    // ---- test connection key source (ios-06 review fix) -------------------

    func savedProfile(baseUrl: String = "https://api.example.com/v1") -> ProviderProfile {
        ProviderProfile(id: "a", name: "Mine", baseUrl: baseUrl, model: "gpt-4-turbo", hasApiKey: true)
    }

    @Test func aNewDraftWithNoStoredKeyNeverSendsOne() {
        let draft = validDraft()
        #expect(draft.testConnectionKeySource() == .none)
    }

    @Test func keepWithAStoredKeyAndAnUnchangedUrlSendsTheStoredKey() {
        let draft = ProviderDraft(editing: savedProfile())
        #expect(draft.testConnectionKeySource() == .storedKey)
    }

    @Test func keepWithAStoredKeyAndAPortOnlyChangeStillSendsTheStoredKey() {
        var draft = ProviderDraft(editing: savedProfile(baseUrl: "https://api.example.com:443/v1"))
        draft.baseUrl = "https://api.example.com:8443/v1"
        #expect(draft.testConnectionKeySource() == .storedKey)
    }

    @Test func keepWithAStoredKeyAndAChangedHostWithholdsTheKey() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.baseUrl = "https://other.example.com/v1"
        #expect(draft.testConnectionKeySource() == .storedKeyWithheld)
    }

    @Test func keepWithAStoredKeyDowngradedFromHttpsToHttpOnTheSameHostWithholdsTheKey() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.baseUrl = "http://api.example.com/v1"
        #expect(draft.testConnectionKeySource() == .storedKeyWithheld)
    }

    @Test func keepWithoutAStoredKeySendsNone() {
        var draft = ProviderDraft(editing: ProviderProfile(id: "a", name: "Mine", baseUrl: "https://api.example.com/v1", model: "m", hasApiKey: false))
        draft.apiKeyIntent = .keep
        #expect(draft.testConnectionKeySource() == .none)
    }

    @Test func replaceWithANonBlankKeySendsTheDraftKey() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.apiKeyIntent = .replace("sk-new")
        #expect(draft.testConnectionKeySource() == .draftKey("sk-new"))
    }

    @Test func replaceWithABlankKeySendsNone() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.apiKeyIntent = .replace("")
        #expect(draft.testConnectionKeySource() == .none)
    }

    @Test func removeSendsNone() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.apiKeyIntent = .remove
        #expect(draft.testConnectionKeySource() == .none)
    }

    @Test func originalHostReflectsTheProfilesBaseUrlAtEditingTime() {
        var draft = ProviderDraft(editing: savedProfile())
        draft.baseUrl = "https://other.example.com/v1"
        #expect(draft.originalHost == "api.example.com")
    }

    @Test func originalHostIsNilForANewDraft() {
        let draft = validDraft()
        #expect(draft.originalHost == nil)
    }

    // ---- preset / profile initializers ------------------------------------

    @Test func initFromAPresetCopiesItsDefaults() {
        let preset = ProviderPreset(
            id: "custom", label: "Custom", kind: .openAICompatible, baseUrl: "", needsApiKey: false
        )
        let draft = ProviderDraft(preset: preset)
        #expect(draft.id.isEmpty)
        #expect(draft.name == "Custom")
        #expect(draft.kind == .openAICompatible)
        #expect(draft.hasApiKeyStored == false)
        #expect(draft.apiKeyIntent == .keep)
    }

    @Test func initFromAnExistingProfileCopiesItsFields() {
        let profile = ProviderProfile(
            id: "a", name: "Mine", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo",
            timeoutSecs: 45, enabled: false, hasApiKey: true
        )
        let draft = ProviderDraft(editing: profile)
        #expect(draft.id == "a")
        #expect(draft.name == "Mine")
        #expect(draft.timeoutSecs == 45)
        #expect(draft.enabled == false)
        #expect(draft.hasApiKeyStored == true)
        #expect(draft.apiKeyIntent == .keep)
    }

    // ---- makeProfile --------------------------------------------------

    @Test func makeProfileBuildsAMatchingProfile() {
        let draft = ProviderDraft(
            id: "a", name: "Mine", baseUrl: "https://api.example.com/v1", model: "gpt-4-turbo",
            timeoutSecs: 45, customHeaders: [HeaderEntry(name: "X-Test", value: "1")], enabled: false
        )
        let profile = draft.makeProfile()
        #expect(profile.id == "a")
        #expect(profile.name == "Mine")
        #expect(profile.timeoutSecs == 45)
        #expect(profile.customHeaders == [HeaderEntry(name: "X-Test", value: "1")])
        #expect(profile.enabled == false)
    }

    // ---- canActivate ----------------------------------------------------

    @Test func enabledSavedProfilesCanBeActivated() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "", model: "", enabled: true)
        #expect(canActivate(profile))
    }

    @Test func disabledProfilesCannotBeActivated() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "", model: "", enabled: false)
        #expect(!canActivate(profile))
    }

    @Test func anUnsavedNewDraftCannotBeActivatedEvenIfEnabled() {
        var draft = validDraft()
        draft.enabled = true
        #expect(draft.id.isEmpty)
        #expect(!draft.canActivate)
    }

    @Test func aSavedEnabledDraftCanBeActivated() {
        var draft = validDraft()
        draft.id = "a"
        draft.enabled = true
        #expect(draft.canActivate)
    }

    @Test func aSavedDisabledDraftCannotBeActivated() {
        var draft = validDraft()
        draft.id = "a"
        draft.enabled = false
        #expect(!draft.canActivate)
    }
}
