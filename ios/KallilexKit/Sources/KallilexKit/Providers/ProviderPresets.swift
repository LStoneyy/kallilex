import Foundation

/// A bundled starting point offered when creating a new profile (PLAN.md
/// §7.3). Mirrors the desktop's `Preset`
/// (`src-tauri/src/core/providers/mod.rs`), adapted for iOS: `your-mac.local`
/// instead of `localhost` (meaningless on a phone), plus the Apple
/// on-device preset — offered only when the device is eligible, a check
/// ios-10 adds.
public struct ProviderPreset: Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: ProviderKind
    public let baseUrl: String
    public let needsApiKey: Bool

    public init(
        id: String,
        label: String,
        kind: ProviderKind,
        baseUrl: String,
        needsApiKey: Bool
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseUrl = baseUrl
        self.needsApiKey = needsApiKey
    }
}

/// The five v1 presets, in display order. Every label is localized
/// (English values live in `Resources/Localizable.xcstrings`; German is
/// added in ios-11).
public func providerPresets() -> [ProviderPreset] {
    [
        ProviderPreset(
            id: "appleOnDevice",
            label: String(localized: "provider.apple.onDevice", bundle: .module),
            kind: .appleOnDevice,
            baseUrl: "",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "openai",
            label: String(localized: "provider.openai", bundle: .module),
            kind: .openAICompatible,
            baseUrl: "https://api.openai.com/v1",
            needsApiKey: true
        ),
        ProviderPreset(
            id: "ollama",
            label: String(localized: "provider.ollama", bundle: .module),
            kind: .openAICompatible,
            baseUrl: "http://your-mac.local:11434/v1",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "lmstudio",
            label: String(localized: "provider.lmstudio", bundle: .module),
            kind: .openAICompatible,
            baseUrl: "http://your-mac.local:1234/v1",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "custom",
            label: String(localized: "provider.custom", bundle: .module),
            kind: .openAICompatible,
            baseUrl: "",
            needsApiKey: false
        ),
    ]
}

/// `providerPresets()`, filtered to the ones actually worth offering right
/// now (ios-10). Every `.openAICompatible` preset is always offered; the
/// `appleOnDevice` preset is offered unless `onDeviceAvailability` is
/// `.deviceNotEligible` (PLAN.md §18 Q4: the preset still shows up when
/// Apple Intelligence is merely disabled or still downloading, so the user
/// can create the profile and see why from its availability status row),
/// or a profile of that kind already exists — at most one on-device
/// profile at a time. Shared by `ProviderPresetPickerView` (the Providers
/// tab's "Add provider" sheet) and `OnboardingView`'s "choose a provider"
/// step, so the two pickers can never disagree.
public func offeredProviderPresets(
    existingProfiles: [ProviderProfile],
    onDeviceAvailability: OnDeviceAvailability
) -> [ProviderPreset] {
    providerPresets().filter { preset in
        guard preset.kind == .appleOnDevice else { return true }
        guard onDeviceAvailability != .deviceNotEligible else { return false }
        return !existingProfiles.contains { $0.kind == .appleOnDevice }
    }
}
