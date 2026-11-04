import Foundation

/// A testability seam over `ActionRunner.run(text:action:)` (ios-08):
/// `EditorSession` depends on `any ActionRunning` rather than the concrete
/// `ActionRunner`, so its tests can substitute a fake that resolves
/// deterministically (including "stays pending until released") instead of
/// going through real settings/secrets/network plumbing.
public protocol ActionRunning: Sendable {
    func run(text: String, action: Action) async -> RunOutcome
}

/// Outcome of a single `ActionRunner.run` call.
public enum RunOutcome: Equatable, Sendable {
    case ok(String)
    case notConfigured
    case consentRequired(ProviderProfile)
    case cancelled
    case failed(ProviderError)
}

/// A `TextProvider` that always fails with `.unavailable(reason:)`. Used by
/// `ActionRunner.defaultProviderFactory` for provider kinds this build
/// can't actually talk to yet: `.appleOnDevice` (ios-10 replaces this with
/// a real on-device implementation) and the unreachable fallback for
/// `.unknown`, which `ActionRunner` never actually calls into (see below).
public struct UnavailableProvider: TextProvider {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func complete(systemPrompt: String, userText: String) async throws -> String {
        throw ProviderError.unavailable(reason: reason)
    }
}

/// The iOS counterpart of the desktop's `run_action`
/// (`src-tauri/src/core/providers/mod.rs`): resolves the active, enabled
/// profile, checks consent, reads the API key, calls the provider, and
/// maps the result (or cancellation) onto `RunOutcome`.
public struct ActionRunner: ActionRunning, Sendable {
    public let settings: any SettingsStore
    public let secrets: any SecretStore
    public let makeProvider: @Sendable (ProviderProfile, String?) -> any TextProvider

    /// The reason text used for a provider `kind` this build doesn't
    /// recognize (`ProviderKind.unknown`) — treated the same as "no
    /// provider configured at all" everywhere else in the codebase.
    static let unsupportedProviderKindReason =
        "This provider type isn't supported by this version of Kallilex."

    /// The production provider factory: `.openAICompatible` talks to
    /// `OpenAICompatibleProvider`; `.appleOnDevice` is not implemented yet
    /// (ios-10) and always fails with `.unavailable`; `.unknown` is never
    /// actually passed to this closure — `run`/`testConnection` short-
    /// circuit it first — but still maps to a safe fallback rather than
    /// crashing if that ever changes.
    public static let defaultProviderFactory: @Sendable (
        ProviderProfile,
        String?
    ) -> any TextProvider = { profile, apiKey in
        switch profile.kind {
        case .openAICompatible:
            return OpenAICompatibleProvider(profile: profile, apiKey: apiKey, session: OpenAICompatibleProvider.defaultSession)
        case .appleOnDevice:
            return UnavailableProvider(reason: "Apple on-device AI isn't available yet.")
        case .unknown:
            return UnavailableProvider(reason: ActionRunner.unsupportedProviderKindReason)
        }
    }

    public init(
        settings: any SettingsStore,
        secrets: any SecretStore,
        makeProvider: @escaping @Sendable (ProviderProfile, String?) -> any TextProvider
            = ActionRunner.defaultProviderFactory
    ) {
        self.settings = settings
        self.secrets = secrets
        self.makeProvider = makeProvider
    }

    /// Resolves the active, enabled profile, mirroring the desktop's
    /// `active_profile`: the id in `settings.activeProfileID` must match a
    /// profile in `settings.profiles` that is also `enabled`.
    private func activeProfile(in settings: AppSettings) -> ProviderProfile? {
        guard let activeID = settings.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == activeID && $0.enabled }
    }

    /// Runs `action` against the currently active profile. Settings are
    /// loaded fresh on every call (no cache). A `settings.load()` failure
    /// degrades to `.notConfigured` — the app/extension UI surfaces store
    /// errors itself, this layer just treats "can't tell what's
    /// configured" the same as "nothing is configured".
    public func run(text: String, action: Action) async -> RunOutcome {
        let current: AppSettings
        do {
            current = try settings.load()
        } catch {
            return .notConfigured
        }

        guard let profile = activeProfile(in: current) else {
            return .notConfigured
        }

        if case .unknown = profile.kind {
            return .failed(.unavailable(reason: Self.unsupportedProviderKindReason))
        }

        if case .required = consentRequirement(for: profile, consents: current.consents) {
            return .consentRequired(profile)
        }

        let apiKey: String? = profile.hasApiKey ? (try? secrets.get(profileID: profile.id)) : nil

        let systemPrompt = PromptAssembly.systemPrompt(for: action)
        let provider = makeProvider(profile, apiKey)

        do {
            let result = try await provider.complete(systemPrompt: systemPrompt, userText: text)
            return .ok(result)
        } catch is CancellationError {
            return .cancelled
        } catch let providerError as ProviderError {
            return Task.isCancelled ? .cancelled : .failed(providerError)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(.invalidResponse(String(describing: error)))
        }
    }

    /// Sends a minimal round trip through `profile` without any user text
    /// and without a consent check (no user text is sent, just a system
    /// prompt), so the Providers screen can verify setup before going
    /// live.
    public func testConnection(
        profile: ProviderProfile,
        apiKey: String?
    ) async -> Result<Void, ProviderError> {
        let provider = makeProvider(profile, apiKey)
        do {
            _ = try await provider.complete(
                systemPrompt: "Reply with the single word OK.",
                userText: "Hello"
            )
            return .success(())
        } catch let providerError as ProviderError {
            return .failure(providerError)
        } catch {
            return .failure(.invalidResponse(String(describing: error)))
        }
    }
}
