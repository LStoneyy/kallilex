import Foundation

/// Errors surfaced by a `SecretStore` implementation.
public enum SecretStoreError: Error, Sendable, Equatable {
    /// A Keychain operation failed with this `OSStatus` (never
    /// `errSecItemNotFound` — that's handled as a non-error by `get`/`delete`,
    /// and `set` retries as an add on `errSecItemNotFound` from its update
    /// attempt).
    case osStatus(OSStatus)
}

/// Persistence seam for API keys, keyed by profile id. Production:
/// `KeychainSecretStore`. Tests: `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    /// Returns the stored key, or `nil` if none exists for `profileID`.
    func get(profileID: String) throws -> String?
    /// Adds or updates the key for `profileID` — no distinction needed.
    func set(_ key: String, profileID: String) throws
    /// Removes the key for `profileID`. A no-op if none exists.
    func delete(profileID: String) throws
}
