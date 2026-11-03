import Foundation

/// How the provider editor's API-key field should affect the Keychain entry
/// on save, mapped by `apiKeyArgument` onto `SettingsService.saveProfile`'s
/// `apiKey: String?` parameter (`nil` keep / `""` remove / non-blank set).
public enum ProviderDraftAPIKeyIntent: Equatable, Sendable {
    /// Leave whatever key (or absence of one) is already stored untouched.
    case keep
    /// Store `key` as the new value.
    case replace(String)
    /// Delete the stored key.
    case remove
}

/// A reason `ProviderDraft` can't be saved yet.
public enum ProviderDraftValidationError: Equatable, Sendable, Hashable {
    case blankName
    case blankModel
    case invalidBaseUrl
}

extension ProviderDraftValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blankName:
            return String(
                localized: "provider.validation.blankName",
                defaultValue: "Name is required.",
                bundle: .module
            )
        case .blankModel:
            return String(
                localized: "provider.validation.blankModel",
                defaultValue: "Model is required.",
                bundle: .module
            )
        case .invalidBaseUrl:
            return String(
                localized: "provider.validation.invalidBaseUrl",
                defaultValue: "Enter a valid http:// or https:// URL.",
                bundle: .module
            )
        }
    }
}

/// Where the key for "Test connection" should come from — computed by
/// `ProviderDraft.testConnectionKeySource()` so the decision is unit-testable
/// in `KallilexKit` rather than living in the editor view (ios-06 review
/// fix: a stored key must never be sent to an address it wasn't saved
/// against).
public enum ProviderDraftTestKeySource: Equatable, Sendable {
    /// No key should be sent.
    case none
    /// Send this unsaved, typed-in key (`apiKeyIntent == .replace` with a
    /// non-blank value).
    case draftKey(String)
    /// Send the key already stored in the Keychain for this profile's id —
    /// safe only because `baseUrl` hasn't moved to a different host or
    /// scheme since the key was saved.
    case storedKey
    /// A key is stored, but `baseUrl` now points at a different host or
    /// scheme than when it was saved — withhold it rather than leak it to
    /// the new address. The editor shows an inline note and tests without
    /// a key.
    case storedKeyWithheld
}

/// A non-blocking inline notice shown below a field in the provider editor.
public enum ProviderDraftWarning: Equatable, Sendable, Hashable {
    /// `baseUrl` is `http://` and classifies as `.cloud` — iOS only allows
    /// plaintext HTTP to the local network (PLAN.md §10.3).
    case insecureHttpToCloud
    /// `baseUrl` classifies as `.lan` — iOS will prompt for Local Network
    /// permission the first time this provider is used.
    case localNetworkHint
}

extension ProviderDraftWarning: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureHttpToCloud:
            return String(
                localized: "provider.warning.insecureUrl",
                defaultValue: "iOS only allows http:// on your local network. Use https:// for this server.",
                bundle: .module
            )
        case .localNetworkHint:
            return String(
                localized: "provider.hint.localNetwork",
                defaultValue: "iOS will ask for Local Network access the first time you use this provider.",
                bundle: .module
            )
        }
    }
}

/// UI-free editing state for the provider editor sheet (ios-06). Backs every
/// field, validates them, computes inline warnings/hints, and builds the
/// `ProviderProfile` plus the `apiKey` argument to pass to
/// `SettingsService.saveProfile(_:apiKey:)`.
///
/// Changes apply only when the editor's Save button commits them — the
/// editor itself owns a `ProviderDraft` value and discards it on Cancel, so
/// this type carries no reference to the original profile.
public struct ProviderDraft: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseUrl: String
    public var model: String
    public var timeoutSecs: Int
    public var customHeaders: [HeaderEntry]
    public var enabled: Bool
    public var apiKeyIntent: ProviderDraftAPIKeyIntent

    /// Whether a key was already stored for this profile when the draft was
    /// created (`false` for a brand-new profile). Read-only: the editor uses
    /// this to decide between the "Paste and save" and the "saved, Replace/
    /// Remove" API-key UI.
    public let hasApiKeyStored: Bool

    /// `baseUrl` as it was when the draft was created from an existing
    /// profile (`nil` for a brand-new profile). Read-only: used only by
    /// `testConnectionKeySource()` to detect whether the user has since
    /// edited `baseUrl` to a different host or scheme, in which case the
    /// stored key must not be sent there.
    public let originalBaseUrl: String?

    public static let defaultTimeoutSecs = 30
    public static let timeoutRange = 1...300

    public init(
        id: String = "",
        name: String = "",
        kind: ProviderKind = .openAICompatible,
        baseUrl: String = "",
        model: String = "",
        timeoutSecs: Int = ProviderDraft.defaultTimeoutSecs,
        customHeaders: [HeaderEntry] = [],
        enabled: Bool = true,
        apiKeyIntent: ProviderDraftAPIKeyIntent = .keep,
        hasApiKeyStored: Bool = false,
        originalBaseUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseUrl = baseUrl
        self.model = model
        self.timeoutSecs = timeoutSecs
        self.customHeaders = customHeaders
        self.enabled = enabled
        self.apiKeyIntent = apiKeyIntent
        self.hasApiKeyStored = hasApiKeyStored
        self.originalBaseUrl = originalBaseUrl
    }

    /// Starts a draft from an existing profile, for editing. `apiKeyIntent`
    /// starts at `.keep`.
    public init(editing profile: ProviderProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            kind: profile.kind,
            baseUrl: profile.baseUrl,
            model: profile.model,
            timeoutSecs: profile.timeoutSecs,
            customHeaders: profile.customHeaders,
            enabled: profile.enabled,
            apiKeyIntent: .keep,
            hasApiKeyStored: profile.hasApiKey,
            originalBaseUrl: profile.baseUrl
        )
    }

    /// Starts a draft for a brand-new profile from `preset`'s defaults. The
    /// name starts out as the preset's label — a reasonable starting point
    /// the user can rename.
    public init(preset: ProviderPreset) {
        self.init(
            id: "",
            name: preset.label,
            kind: preset.kind,
            baseUrl: preset.baseUrl,
            model: "",
            apiKeyIntent: .keep,
            hasApiKeyStored: false,
            originalBaseUrl: nil
        )
    }

    /// Every validation failure blocking Save, in a stable order: name,
    /// then (for `.openAICompatible` only) model, then base URL.
    public var validationErrors: [ProviderDraftValidationError] {
        var errors: [ProviderDraftValidationError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.blankName)
        }
        guard kind == .openAICompatible else { return errors }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.blankModel)
        }
        let trimmedUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUrl.isEmpty, !Self.isValidHttpURL(trimmedUrl) {
            errors.append(.invalidBaseUrl)
        }
        return errors
    }

    public var canSave: Bool { validationErrors.isEmpty }

    /// Non-blocking inline notices for the current `baseUrl`, in a stable
    /// order. Only meaningful for `.openAICompatible` — always empty
    /// otherwise.
    public var warnings: [ProviderDraftWarning] {
        guard kind == .openAICompatible else { return [] }
        let trimmedUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty,
              let url = URL(string: trimmedUrl),
              let scheme = url.scheme?.lowercased() else {
            return []
        }
        let privacy = classifyPrivacy(baseUrl: trimmedUrl)
        var warnings: [ProviderDraftWarning] = []
        if scheme == "http", privacy == .cloud {
            warnings.append(.insecureHttpToCloud)
        }
        if privacy == .lan {
            warnings.append(.localNetworkHint)
        }
        return warnings
    }

    /// Whether "Use this provider" should be enabled: the profile must
    /// already be saved (a non-blank `id`) and `enabled`. Mirrors
    /// `canActivate(_:)` below, which applies the same "disabled profiles
    /// can't be active" rule to an already-saved `ProviderProfile`.
    public var canActivate: Bool {
        enabled && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds the `ProviderProfile` to pass to
    /// `SettingsService.saveProfile(_:apiKey:)`. `hasApiKey` here is purely
    /// informational — `saveProfile` recomputes it from `apiKeyArgument`.
    public func makeProfile() -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            kind: kind,
            baseUrl: baseUrl,
            model: model,
            timeoutSecs: timeoutSecs,
            customHeaders: customHeaders,
            enabled: enabled,
            hasApiKey: hasApiKeyStored
        )
    }

    /// Maps `apiKeyIntent` onto `SettingsService.saveProfile`'s `apiKey:
    /// String?` semantics: `.keep` → `nil` (leave untouched), `.remove` →
    /// `""` (deletes the key), `.replace(key)` → `key` (sets it).
    public var apiKeyArgument: String? {
        switch apiKeyIntent {
        case .keep:
            return nil
        case .remove:
            return ""
        case .replace(let key):
            return key
        }
    }

    /// Where "Test connection" should get its key from (ios-06 review fix).
    /// `.replace` with a non-blank key sends that typed-in value; `.remove`
    /// sends none. `.keep` sends the stored key only when `baseUrl` still
    /// resolves to the same consent host *and* scheme it had when the draft
    /// was created (`originalBaseUrl`) — a bare port change is still the
    /// same host (mirrors `consentHost(for:)`, which also ignores port), but
    /// a different host, or the same host downgraded from `https` to
    /// `http`, withholds the key instead of sending it to a new address.
    public func testConnectionKeySource() -> ProviderDraftTestKeySource {
        switch apiKeyIntent {
        case .remove:
            return .none
        case .replace(let key):
            return key.isEmpty ? .none : .draftKey(key)
        case .keep:
            guard hasApiKeyStored else { return .none }
            guard let originalBaseUrl,
                  let original = Self.hostAndScheme(for: originalBaseUrl),
                  let current = Self.hostAndScheme(for: baseUrl),
                  original == current else {
                return .storedKeyWithheld
            }
            return .storedKey
        }
    }

    /// The host `baseUrl` had when the draft was created from an existing
    /// profile, for the "saved key only sent to <host>" inline note. `nil`
    /// for a brand-new draft, or when `originalBaseUrl` doesn't parse.
    public var originalHost: String? {
        guard let originalBaseUrl else { return nil }
        return URL(string: originalBaseUrl)?.host(percentEncoded: false)
    }

    /// `URL(string:)` must parse `string` with an `http`/`https` scheme and
    /// a non-empty host.
    private static func isValidHttpURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty else {
            return false
        }
        return true
    }

    /// The `(host, scheme)` pair used to decide whether `baseUrl` still
    /// points at "the same place" a stored key was saved against: `host`
    /// uses `consentHost(for:)` (lowercased, trailing dot stripped, port
    /// ignored); `scheme` is compared case-insensitively alongside it so an
    /// `https` → `http` downgrade on the same host isn't treated as
    /// unchanged. `nil` when `baseUrl` doesn't parse into a URL with a host.
    private static func hostAndScheme(for baseUrl: String) -> (host: String, scheme: String)? {
        guard let url = URL(string: baseUrl), let scheme = url.scheme?.lowercased() else { return nil }
        let probe = ProviderProfile(id: "", name: "", baseUrl: baseUrl, model: "")
        guard let host = consentHost(for: probe) else { return nil }
        return (host, scheme)
    }
}

/// Whether `profile` can be made the active provider: disabled profiles
/// never can, mirroring `ActionRunner.activeProfile(in:)`'s own
/// `enabled`-only lookup — a provider the Providers list shows dimmed is
/// never a valid choice for "Use this provider" either.
public func canActivate(_ profile: ProviderProfile) -> Bool {
    profile.enabled
}
