import Testing
import KallilexKit

/// Tests for `providerPresets()`. See
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`.
struct ProviderPresetsTests {
    @Test func returnsTheFiveV1PresetsInOrder() {
        let presets = providerPresets()
        #expect(presets.map(\.id) == ["appleOnDevice", "openai", "ollama", "lmstudio", "custom"])
    }

    @Test func appleOnDeviceIsFirstAndNeedsNoApiKey() {
        let preset = providerPresets()[0]
        #expect(preset.kind == .appleOnDevice)
        #expect(preset.needsApiKey == false)
        #expect(preset.baseUrl.isEmpty)
    }

    @Test func openAIPresetNeedsAnApiKeyAndPointsAtTheRealEndpoint() {
        let preset = providerPresets().first { $0.id == "openai" }!
        #expect(preset.kind == .openAICompatible)
        #expect(preset.needsApiKey)
        #expect(preset.baseUrl == "https://api.openai.com/v1")
    }

    @Test func localPresetsUseYourMacLocalNotLocalhost() {
        for id in ["ollama", "lmstudio"] {
            let preset = providerPresets().first { $0.id == id }!
            #expect(preset.kind == .openAICompatible)
            #expect(preset.needsApiKey == false)
            #expect(preset.baseUrl.contains("your-mac.local"))
            #expect(!preset.baseUrl.contains("localhost"))
        }
    }

    @Test func customPresetIsBlankAndNeedsNoApiKey() {
        let preset = providerPresets().first { $0.id == "custom" }!
        #expect(preset.kind == .openAICompatible)
        #expect(preset.needsApiKey == false)
        #expect(preset.baseUrl.isEmpty)
    }

    @Test func everyLabelIsNonEmpty() {
        for preset in providerPresets() {
            #expect(!preset.label.isEmpty, "\(preset.id) has an empty label")
        }
    }
}
