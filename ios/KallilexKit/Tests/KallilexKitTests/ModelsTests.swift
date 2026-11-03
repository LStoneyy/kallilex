import Foundation
import Testing
import KallilexKit

/// Round-trip, tolerant-decoding and desktop-compatibility tests for the
/// model types in `Models.swift`. See
/// `issues-ios/spec-ios-04-models-and-stores.md`.
struct ModelsTests {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // ---- JSON round-trip --------------------------------------------------

    @Test func headerEntryRoundTrips() throws {
        let value = HeaderEntry(name: "X-Test", value: "abc")
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(HeaderEntry.self, from: data)
        #expect(decoded == value)
    }

    @Test func providerProfileRoundTrips() throws {
        let value = ProviderProfile(
            id: "p1",
            name: "My Profile",
            kind: .appleOnDevice,
            baseUrl: "http://localhost:11434/v1",
            model: "llama3",
            timeoutSecs: 45,
            customHeaders: [HeaderEntry(name: "X-A", value: "1")],
            enabled: false,
            hasApiKey: true
        )
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(ProviderProfile.self, from: data)
        #expect(decoded == value)
    }

    @Test func customPromptRoundTrips() throws {
        let value = CustomPrompt(id: "c1", label: "Translate", instruction: "Translate to French")
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(CustomPrompt.self, from: data)
        #expect(decoded == value)
    }

    @Test func aiConsentRoundTrips() throws {
        let value = AIConsent(profileID: "p1", host: "example.com", grantedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(AIConsent.self, from: data)
        #expect(decoded == value)
    }

    @Test func aiConsentUsesProfileIdJsonKey() throws {
        let value = AIConsent(profileID: "p1", host: "example.com", grantedAt: Date(timeIntervalSince1970: 0))
        let data = try Self.makeEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["profileId"] as? String == "p1")
        #expect(json?["profileID"] == nil)
    }

    @Test func appSettingsRoundTrips() throws {
        let value = AppSettings(
            schemaVersion: 1,
            activeProfileID: "p1",
            profiles: [ProviderProfile(id: "p1", name: "A", baseUrl: "http://localhost/v1", model: "m")],
            prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")],
            autoRunFirstPrompt: true,
            autoCopyResult: true,
            onboardingCompleted: true,
            consents: [AIConsent(profileID: "p1", host: "localhost", grantedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        )
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == value)
    }

    // ---- Missing keys → defaults -------------------------------------------

    @Test func providerProfileMissingOptionalKeysUsesDefaults() throws {
        let json = """
        { "id": "p1", "name": "A", "baseUrl": "http://localhost/v1", "model": "m" }
        """
        let decoded = try Self.makeDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        #expect(decoded.kind == .openAICompatible)
        #expect(decoded.timeoutSecs == 30)
        #expect(decoded.customHeaders == [])
        #expect(decoded.enabled == true)
        #expect(decoded.hasApiKey == false)
    }

    @Test func appSettingsMissingOptionalKeysUsesDefaults() throws {
        let json = "{}"
        let decoded = try Self.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.activeProfileID == nil)
        #expect(decoded.profiles == [])
        #expect(decoded.prompts.map(\.id) == PromptDefaults.defaults().map(\.id))
        #expect(decoded.autoRunFirstPrompt == false)
        #expect(decoded.autoCopyResult == false)
        #expect(decoded.onboardingCompleted == false)
        #expect(decoded.consents == [])
    }

    @Test func appSettingsExplicitEmptyPromptsStaysEmpty() throws {
        let json = """
        { "prompts": [] }
        """
        let decoded = try Self.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.prompts.isEmpty)
    }

    @Test func providerKindDefaultsWhenMissing() throws {
        struct Wrapper: Decodable { let kind: ProviderKind? }
        let json = "{}"
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        #expect(decoded.kind == nil) // confirms the key truly is absent; `ProviderProfile` supplies the default.
    }

    // ---- Desktop JSON compatibility ----------------------------------------

    @Test func desktopShapedSettingsJsonDecodesPreservingProfilesAndPrompts() throws {
        let json = """
        {
            "activeProfileId": "p1",
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [
                { "id": "p1", "name": "Ollama", "baseUrl": "http://localhost:11434/v1", "model": "llama3", "timeoutSecs": 30, "customHeaders": [], "enabled": true, "hasApiKey": false }
            ],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false,
            "onboardingCompleted": false,
            "popoverPosition": { "x": 10, "y": 20 },
            "prompts": [
                { "id": "builtin-rewrite", "label": "Rewrite", "instruction": "Rewrite the text.", "shortcut": "Mod+1" }
            ],
            "updateChannel": "stable",
            "updateCheckFrequency": "daily",
            "popoverShortcuts": { "replace": "Mod+Enter" },
            "promptShortcutsSeeded": true
        }
        """
        let decoded = try Self.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.activeProfileID == "p1")
        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].id == "p1")
        #expect(decoded.prompts.count == 1)
        #expect(decoded.prompts[0].id == "builtin-rewrite")
        #expect(decoded.prompts[0].label == "Rewrite")
        // `schemaVersion` doesn't exist on desktop at all.
        #expect(decoded.schemaVersion == 1)
    }

    @Test func providerProfileWithoutKindDecodesAsOpenAICompatible() throws {
        let json = """
        { "id": "p1", "name": "Ollama", "baseUrl": "http://localhost:11434/v1", "model": "llama3" }
        """
        let decoded = try Self.makeDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        #expect(decoded.kind == .openAICompatible)
    }

    // ---- ProviderKind.unknown ------------------------------------------

    @Test func unrecognizedKindDecodesAsUnknown() throws {
        let json = """
        { "id": "p1", "name": "Future", "kind": "applePrivateCloud", "baseUrl": "http://x/v1", "model": "m" }
        """
        let decoded = try Self.makeDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        #expect(decoded.kind == .unknown("applePrivateCloud"))
    }

    @Test func settingsFileWithAnUnknownKindKeepsEveryOtherProfileAndPromptIntact() throws {
        let json = """
        {
            "profiles": [
                { "id": "a", "name": "A", "baseUrl": "http://x/v1", "model": "m" },
                { "id": "b", "name": "B", "kind": "applePrivateCloud", "baseUrl": "http://y/v1", "model": "m2" }
            ],
            "prompts": [
                { "id": "c1", "label": "L", "instruction": "I" }
            ]
        }
        """
        let decoded = try Self.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.profiles.count == 2)
        #expect(decoded.profiles[0].kind == .openAICompatible)
        #expect(decoded.profiles[1].kind == .unknown("applePrivateCloud"))
        #expect(decoded.prompts.map(\.id) == ["c1"])
    }

    @Test func unknownKindRoundTripsTheSameRawString() throws {
        let value = ProviderProfile(id: "p1", name: "Future", kind: .unknown("applePrivateCloud"), baseUrl: "http://x/v1", model: "m")
        let data = try Self.makeEncoder().encode(value)
        let decoded = try Self.makeDecoder().decode(ProviderProfile.self, from: data)
        #expect(decoded.kind == .unknown("applePrivateCloud"))

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "applePrivateCloud")
    }

    @Test func customPromptDropsDesktopShortcutField() throws {
        let json = """
        { "id": "c1", "label": "L", "instruction": "I", "shortcut": "Mod+9" }
        """
        let decoded = try Self.makeDecoder().decode(CustomPrompt.self, from: Data(json.utf8))
        #expect(decoded.id == "c1")
        #expect(decoded.label == "L")
        #expect(decoded.instruction == "I")

        // And it never resurfaces on encode.
        let reencoded = try Self.makeEncoder().encode(decoded)
        let json2 = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(json2?["shortcut"] == nil)
    }

    // ---- AppSettings.seeded() ----------------------------------------------

    @Test func seededHasSchemaVersionOneAndDefaultPrompts() {
        let seeded = AppSettings.seeded(locale: Locale(identifier: "en"))
        #expect(seeded.schemaVersion == 1)
        #expect(seeded.prompts.map(\.id) == PromptDefaults.defaults(locale: Locale(identifier: "en")).map(\.id))
        #expect(seeded.activeProfileID == nil)
        #expect(seeded.profiles.isEmpty)
        #expect(seeded.consents.isEmpty)
    }
}
