import Foundation

/// A validation failure reason from a `SettingsService` operation.
public enum SettingsServiceValidationReason: Sendable, Equatable {
    case blankProfileName
    case invalidTimeout
    case blankPromptLabel
    case blankPromptInstruction
}

/// Errors from the `SettingsService` operations below, which compose
/// `SettingsStore` and `SecretStore`. Mirrors the desktop's
/// `ProfileOpError`/`PromptOpError` (`src-tauri/src/core/providers/mod.rs`,
/// `src-tauri/src/core/prompts.rs`).
public enum SettingsServiceError: Error, Sendable, Equatable {
    case validation(SettingsServiceValidationReason)
    case profileNotFound(String)
}

/// Profile, prompt and consent operations composed from a `SettingsStore`
/// and a `SecretStore`. Every mutation goes through `settings.update`'s
/// atomic read-modify-write seam. Mirrors the desktop's `save_profile_core`
/// / `delete_profile_core` / `set_active_profile_core`
/// (`src-tauri/src/core/providers/mod.rs`) and its prompt CRUD
/// (`src-tauri/src/core/prompts.rs`), adapted for consent invalidation
/// (PLAN.md §10.1), which the desktop has no equivalent of.
public struct SettingsService: Sendable {
    public let settings: any SettingsStore
    public let secrets: any SecretStore

    public init(settings: any SettingsStore, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    // MARK: - Profiles

    /// Validates `profile` (non-blank name, `timeoutSecs >= 1` — the same
    /// two checks as desktop's `validate_profile`; `baseUrl`/`model` are
    /// deliberately not validated here either, for the same reason as
    /// desktop: an empty or malformed value still saves and instead fails
    /// at request time with a more specific provider error), generates an
    /// id when `profile.id` is empty, and upserts it by id.
    ///
    /// `apiKey`'s effect on the Keychain entry mirrors
    /// `save_profile_core` exactly: `nil` leaves the existing key (and
    /// `hasApiKey`) untouched (`false` for a brand-new profile); blank
    /// after trimming deletes the key and clears `hasApiKey`; non-blank
    /// sets the key and `hasApiKey`.
    ///
    /// If this is the first profile and no profile is currently active, it
    /// becomes the active profile. If the profile's consent host changed
    /// (`consentHost(for:)` before vs. after), every consent of this
    /// profile whose host no longer matches the new host is removed (a
    /// `nil` new host removes every consent of this profile) — a change to
    /// only the path or port never invalidates consent, because
    /// `consentHost(for:)` ignores both.
    ///
    /// The Keychain write happens before `settings.json` is rewritten
    /// (inside the same `update` closure, before the closure returns),
    /// mirroring desktop's ordering. If the Keychain write throws, the
    /// closure throws before mutating anything, so no settings write
    /// happens at all. If the Keychain write succeeds but the subsequent
    /// settings write fails (e.g. disk full), the key is left behind
    /// orphaned under this profile id — harmless, since it is never read
    /// without a matching `hasApiKey: true` profile, and gets overwritten
    /// or deleted the next time this id is saved or deleted.
    @discardableResult
    public func saveProfile(_ profile: ProviderProfile, apiKey: String?) throws -> [ProviderProfile] {
        var profile = profile
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsServiceError.validation(.blankProfileName)
        }
        guard profile.timeoutSecs >= 1 else {
            throw SettingsServiceError.validation(.invalidTimeout)
        }
        if profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.id = UUID().uuidString
        }

        let updated = try settings.update { current in
            let existing = current.profiles.first { $0.id == profile.id }
            let oldHost = existing.flatMap { consentHost(for: $0) }

            switch apiKey {
            case nil:
                profile.hasApiKey = existing?.hasApiKey ?? false
            case .some(let key) where key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                try self.secrets.delete(profileID: profile.id)
                profile.hasApiKey = false
            case .some(let key):
                try self.secrets.set(key, profileID: profile.id)
                profile.hasApiKey = true
            }

            let wasEmpty = current.profiles.isEmpty
            if let index = current.profiles.firstIndex(where: { $0.id == profile.id }) {
                current.profiles[index] = profile
            } else {
                current.profiles.append(profile)
            }

            if wasEmpty, current.activeProfileID == nil {
                current.activeProfileID = profile.id
            }

            let newHost = consentHost(for: profile)
            if oldHost != newHost {
                current.consents.removeAll { consent in
                    guard consent.profileID == profile.id else { return false }
                    guard let newHost else { return true }
                    return consent.host != newHost
                }
            }
        }
        return updated.profiles
    }

    /// Removes the profile with `id` (a no-op if absent), its Keychain
    /// entry (missing is not an error), clears `activeProfileID` if it
    /// pointed at this profile, and removes every consent for this
    /// profile.
    @discardableResult
    public func deleteProfile(id: String) throws -> [ProviderProfile] {
        let updated = try settings.update { current in
            current.profiles.removeAll { $0.id == id }
            try self.secrets.delete(profileID: id)
            if current.activeProfileID == id {
                current.activeProfileID = nil
            }
            current.consents.removeAll { $0.profileID == id }
        }
        return updated.profiles
    }

    /// Sets `activeProfileID`. `id` must reference an existing profile, or
    /// this throws `SettingsServiceError.profileNotFound`; `nil` clears the
    /// active profile unconditionally.
    public func setActiveProfile(id: String?) throws {
        try settings.update { current in
            if let id {
                guard current.profiles.contains(where: { $0.id == id }) else {
                    throw SettingsServiceError.profileNotFound(id)
                }
            }
            current.activeProfileID = id
        }
    }

    // MARK: - Prompts

    /// Validates `prompt` (label and instruction non-blank after
    /// trimming), generates an id when empty, and upserts it by id.
    @discardableResult
    public func savePrompt(_ prompt: CustomPrompt) throws -> [CustomPrompt] {
        var prompt = prompt
        guard !prompt.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsServiceError.validation(.blankPromptLabel)
        }
        guard !prompt.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsServiceError.validation(.blankPromptInstruction)
        }
        if prompt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt.id = UUID().uuidString
        }
        let updated = try settings.update { current in
            if let index = current.prompts.firstIndex(where: { $0.id == prompt.id }) {
                current.prompts[index] = prompt
            } else {
                current.prompts.append(prompt)
            }
        }
        return updated.prompts
    }

    /// Removes the prompt with `id`. A no-op (not an error) if missing.
    @discardableResult
    public func deletePrompt(id: String) throws -> [CustomPrompt] {
        let updated = try settings.update { current in
            current.prompts.removeAll { $0.id == id }
        }
        return updated.prompts
    }

    /// Reorders the prompt list in place, with the same
    /// remove-then-reinsert semantics as SwiftUI's `List.onMove` (so a
    /// view model can pass its `onMove` offsets straight through).
    @discardableResult
    public func movePrompts(fromOffsets offsets: IndexSet, toOffset destination: Int) throws -> [CustomPrompt] {
        let updated = try settings.update { current in
            current.prompts = Self.moved(current.prompts, fromOffsets: offsets, toOffset: destination)
        }
        return updated.prompts
    }

    /// Appends every default prompt (`PromptDefaults.defaults()`) whose id
    /// is missing from the current list. Never removes or re-adds a prompt
    /// the user already has — including a user-edited copy of a default
    /// id, and including a default the user deleted outright (its id is
    /// "missing", so this brings it right back; that mirrors the intent of
    /// "restore defaults" as an additive reset, not a destructive one, same
    /// as the desktop has no equivalent "remove extra" step either).
    @discardableResult
    public func restoreDefaultPrompts(locale: Locale = .current) throws -> [CustomPrompt] {
        let updated = try settings.update { current in
            let existingIDs = Set(current.prompts.map(\.id))
            for seed in PromptDefaults.defaults(locale: locale) where !existingIDs.contains(seed.id) {
                current.prompts.append(seed)
            }
        }
        return updated.prompts
    }

    // MARK: - Consent (PLAN.md §10.1)

    /// Adds or updates the consent for `(profileID, host)` with `now()`'s
    /// date. `now` is injectable so tests can assert an exact
    /// `grantedAt` deterministically.
    public func grantConsent(
        profileID: String,
        host: String,
        now: @Sendable () -> Date = Date.init
    ) throws {
        try settings.update { current in
            let grantedAt = now()
            if let index = current.consents.firstIndex(where: { $0.profileID == profileID && $0.host == host }) {
                current.consents[index] = AIConsent(profileID: profileID, host: host, grantedAt: grantedAt)
            } else {
                current.consents.append(AIConsent(profileID: profileID, host: host, grantedAt: grantedAt))
            }
        }
    }

    /// Removes the consent for `(profileID, host)`, if present.
    public func revokeConsent(profileID: String, host: String) throws {
        try settings.update { current in
            current.consents.removeAll { $0.profileID == profileID && $0.host == host }
        }
    }

    /// Returns `true` iff a consent exists for `(profileID, host)`.
    public func hasConsent(profileID: String, host: String) throws -> Bool {
        Self.hasConsent(profileID: profileID, host: host, in: try settings.load())
    }

    /// The same consent predicate as `hasConsent(profileID:host:)`, against
    /// an already-loaded `AppSettings` value. `ActionRunner` (ios-05) uses
    /// this to check consent without a second, redundant `settings.load()`
    /// call — this is the only consent-check predicate anywhere, shared
    /// rather than duplicated.
    public static func hasConsent(profileID: String, host: String, in settings: AppSettings) -> Bool {
        settings.consents.contains { $0.profileID == profileID && $0.host == host }
    }

    // MARK: - Helpers

    /// The same remove-then-reinsert algorithm SwiftUI's `List.onMove`
    /// uses: every index in `offsets` is removed first, then the moved
    /// items are reinserted together at `destination`, adjusted for
    /// however many of the removed indices were smaller than `destination`
    /// in the original array.
    private static func moved<T>(_ array: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        let itemsToMove = offsets.map { array[$0] }
        var result = array
        for offset in offsets.sorted(by: >) {
            result.remove(at: offset)
        }
        let adjustedDestination = destination - offsets.filter { $0 < destination }.count
        result.insert(contentsOf: itemsToMove, at: adjustedDestination)
        return result
    }
}
