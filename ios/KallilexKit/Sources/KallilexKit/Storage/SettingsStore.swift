import Foundation

/// Errors surfaced by a `SettingsStore` implementation.
public enum SettingsStoreError: Error, Sendable, Equatable {
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// returned `nil` for the given App Group id — the entitlement is
    /// missing, or the id doesn't match the one in the provisioning
    /// profile.
    case appGroupUnavailable(String)
    /// The settings file's `schemaVersion` is higher than this build's
    /// `SettingsMigrator.currentVersion`. This is never treated as
    /// corruption: the file is left untouched (a newer build, or a
    /// downgrade, will see it again), rather than being renamed and
    /// silently replaced with seeded defaults.
    case unsupportedSchemaVersion(Int)
    /// Any other read/write failure (file I/O, file coordination, or
    /// encoding) with a human-readable description.
    case underlying(String)
    /// A write (`save`/`update`) was attempted on a store that can only
    /// read — `ReadOnlySettingsStore`, used by the keyboard without Full
    /// Access.
    case readOnly
}

/// Persistence seam for `AppSettings`. Implementations may be backed by a
/// file-coordinated App Group container (production,
/// `AppGroupSettingsStore`) or an in-memory fake (tests,
/// `InMemorySettingsStore`).
public protocol SettingsStore: Sendable {
    /// Loads the current settings, falling back to `AppSettings.seeded()`
    /// when nothing has been persisted yet, or when the persisted file is
    /// corrupt/undecodable (see `AppGroupSettingsStore`'s doc comment for
    /// the corruption-recovery behavior).
    func load() throws -> AppSettings

    /// Persists `settings`, replacing whatever was there before.
    func save(_ settings: AppSettings) throws

    /// Performs an atomic read-modify-write: loads the current settings,
    /// applies `body` (which may throw to abort — in that case, nothing is
    /// written), saves the result, and returns it. Implementations must
    /// perform this as a single coordinated operation so that two store
    /// instances (e.g. the app and the Share Extension) updating
    /// concurrently can never interleave and lose one update.
    @discardableResult
    func update(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings
}
