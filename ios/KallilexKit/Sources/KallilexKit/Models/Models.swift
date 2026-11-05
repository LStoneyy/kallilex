import Foundation

/// Which kind of AI provider a [`ProviderProfile`] talks to. Stays open for
/// a later `.applePrivateCloud` case (PLAN.md §7.3, Q4). The desktop has
/// only one kind of provider, so its exported profiles always decode as
/// `.openAICompatible` (the default when the JSON key is missing).
///
/// Not a raw-value enum: a present-but-unrecognized string (e.g. a profile
/// written by a newer build with a kind this build doesn't know yet, such
/// as a future `applePrivateCloud`) decodes into `.unknown(rawValue)`
/// rather than throwing and losing every other profile and prompt in the
/// file to corruption recovery. Encoding writes `.unknown`'s raw string
/// back out unchanged, so round-tripping a settings file through an older
/// build never loses the value. Callers (e.g. `ActionRunner`, ios-05) must
/// treat `.unknown` as unusable — the same as no provider configured at
/// all — never guess at its behavior.
public enum ProviderKind: Codable, Equatable, Sendable, Hashable {
    case openAICompatible
    case appleOnDevice
    case unknown(String)

    private static let openAICompatibleRaw = "openAICompatible"
    private static let appleOnDeviceRaw = "appleOnDevice"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case Self.openAICompatibleRaw:
            self = .openAICompatible
        case Self.appleOnDeviceRaw:
            self = .appleOnDevice
        default:
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .openAICompatible:
            try container.encode(Self.openAICompatibleRaw)
        case .appleOnDevice:
            try container.encode(Self.appleOnDeviceRaw)
        case .unknown(let raw):
            try container.encode(raw)
        }
    }
}

/// A single custom HTTP header sent with every request for a profile.
/// Mirrors the desktop's `HeaderEntry` (`src-tauri/src/core/providers/mod.rs`).
public struct HeaderEntry: Codable, Equatable, Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A named connection to an AI endpoint. The API key itself never lives
/// here — see `hasApiKey` — it is looked up separately through
/// `SecretStore`, keyed by `id`. Mirrors the desktop's `ProviderProfile`
/// (`src-tauri/src/core/providers/mod.rs`), plus the iOS-only `kind` field.
public struct ProviderProfile: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseUrl: String
    public var model: String
    public var timeoutSecs: Int
    public var customHeaders: [HeaderEntry]
    public var enabled: Bool
    public var hasApiKey: Bool

    public init(
        id: String,
        name: String,
        kind: ProviderKind = .openAICompatible,
        baseUrl: String,
        model: String,
        timeoutSecs: Int = 30,
        customHeaders: [HeaderEntry] = [],
        enabled: Bool = true,
        hasApiKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseUrl = baseUrl
        self.model = model
        self.timeoutSecs = timeoutSecs
        self.customHeaders = customHeaders
        self.enabled = enabled
        self.hasApiKey = hasApiKey
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseUrl, model, timeoutSecs, customHeaders, enabled, hasApiKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .openAICompatible
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        model = try container.decode(String.self, forKey: .model)
        timeoutSecs = try container.decodeIfPresent(Int.self, forKey: .timeoutSecs) ?? 30
        customHeaders = try container.decodeIfPresent([HeaderEntry].self, forKey: .customHeaders) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hasApiKey = try container.decodeIfPresent(Bool.self, forKey: .hasApiKey) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encode(model, forKey: .model)
        try container.encode(timeoutSecs, forKey: .timeoutSecs)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(hasApiKey, forKey: .hasApiKey)
    }
}

/// A user-manageable prompt: the label shown on its action chip, and the
/// instruction sent to the AI provider as the system prompt. Mirrors the
/// desktop's `CustomPrompt` (`src-tauri/src/core/prompts.rs`), minus its
/// `shortcut` field, which is decoded (so desktop settings files still
/// load) and silently dropped — not ported to iOS in this phase.
public struct CustomPrompt: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var instruction: String

    public init(id: String, label: String, instruction: String) {
        self.id = id
        self.label = label
        self.instruction = instruction
    }

    // Deliberately excludes `shortcut`: a keyed container only decodes the
    // keys listed here, so a desktop `shortcut` field is ignored rather
    // than tripping an "unknown field" error.
    enum CodingKeys: String, CodingKey {
        case id, label, instruction
    }
}

/// A user's one-time consent to send text to a specific profile's host
/// (PLAN.md §10.1). Invalidated when the profile's host changes — see
/// `consentHost(for:)`.
public struct AIConsent: Identifiable, Codable, Equatable, Sendable {
    public let profileID: String
    public let host: String
    public let grantedAt: Date

    /// A composite of `profileID` and `host` — never just `host` alone,
    /// since two different profiles can share a host (e.g. the same cloud
    /// endpoint configured twice) and would otherwise collide as SwiftUI
    /// `ForEach` identities.
    public var id: String { "\(profileID)\n\(host)" }

    public init(profileID: String, host: String, grantedAt: Date) {
        self.profileID = profileID
        self.host = host
        self.grantedAt = grantedAt
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profileId"
        case host
        case grantedAt
    }
}

/// The top-level persisted settings value, shared between the app and the
/// Share Extension through the App Group container (see
/// `AppGroupSettingsStore`). Replaces PLAN.md's placeholder `IOSSettings`
/// name. `schemaVersion` is explicit from day one (the desktop has none —
/// a desktop-written `settings.json` has no `schemaVersion` key at all and
/// decodes with it defaulting to `1`).
public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var activeProfileID: String?
    public var profiles: [ProviderProfile]
    public var prompts: [CustomPrompt]
    public var autoRunFirstPrompt: Bool
    public var autoCopyResult: Bool
    public var onboardingCompleted: Bool
    public var consents: [AIConsent]
    /// The keyboard's letter layout, as a raw `KeyboardLayoutID.rawValue`
    /// ("qwertz"/"qwerty"). `nil` means "follow the device language"
    /// (German → QWERTZ, everything else → QWERTY) — see
    /// `KallilexKeyboardCore.KeyboardLayoutID.resolve`. `KallilexKit` can't
    /// depend on `KallilexKeyboardCore`, so this stays a `String?` here;
    /// that target maps it to the enum. Additive, iOS-only, no schema
    /// version bump: older builds ignore the key (`Codable` skips unknown
    /// keys), and it's encoded with `encodeIfPresent` so a `nil` value
    /// doesn't add a key at all, keeping existing settings files untouched.
    public var keyboardLayout: String?

    public init(
        schemaVersion: Int = 1,
        activeProfileID: String? = nil,
        profiles: [ProviderProfile] = [],
        prompts: [CustomPrompt],
        autoRunFirstPrompt: Bool = false,
        autoCopyResult: Bool = false,
        onboardingCompleted: Bool = false,
        consents: [AIConsent] = [],
        keyboardLayout: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.prompts = prompts
        self.autoRunFirstPrompt = autoRunFirstPrompt
        self.autoCopyResult = autoCopyResult
        self.onboardingCompleted = onboardingCompleted
        self.consents = consents
        self.keyboardLayout = keyboardLayout
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeProfileID = "activeProfileId"
        case profiles
        case prompts
        case autoRunFirstPrompt
        case autoCopyResult
        case onboardingCompleted
        case consents
        case keyboardLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)
        profiles = try container.decodeIfPresent([ProviderProfile].self, forKey: .profiles) ?? []
        // A *missing* `prompts` key has no opinion, so it falls back to the
        // seeded defaults, mirroring desktop's `Settings::prompts` default.
        // An explicitly empty array (the user deleted every prompt) is
        // decoded and kept as-is by `decodeIfPresent`.
        prompts = try container.decodeIfPresent([CustomPrompt].self, forKey: .prompts)
            ?? PromptDefaults.defaults()
        autoRunFirstPrompt = try container.decodeIfPresent(Bool.self, forKey: .autoRunFirstPrompt) ?? false
        autoCopyResult = try container.decodeIfPresent(Bool.self, forKey: .autoCopyResult) ?? false
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        consents = try container.decodeIfPresent([AIConsent].self, forKey: .consents) ?? []
        keyboardLayout = try container.decodeIfPresent(String.self, forKey: .keyboardLayout)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(prompts, forKey: .prompts)
        try container.encode(autoRunFirstPrompt, forKey: .autoRunFirstPrompt)
        try container.encode(autoCopyResult, forKey: .autoCopyResult)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try container.encode(consents, forKey: .consents)
        try container.encodeIfPresent(keyboardLayout, forKey: .keyboardLayout)
    }

    /// A freshly seeded value for a brand-new install or a missing/corrupt
    /// settings file: `schemaVersion` 1, the three default prompts
    /// localized for `locale`, and every other field at its default.
    public static func seeded(locale: Locale = .current) -> AppSettings {
        AppSettings(schemaVersion: 1, prompts: PromptDefaults.defaults(locale: locale))
    }
}
