import Foundation

/// Migrates a raw, already-parsed settings dictionary from an older
/// `schemaVersion` up to the current one, before it is decoded into
/// `AppSettings`. This is a scaffold: version 1 has no migrations yet, so
/// it passes `raw` through unchanged. Future migrations (version 2, 3, …)
/// are added here, in one place, keeping `AppGroupSettingsStore`'s load
/// path itself migration-agnostic.
public enum SettingsMigrator {
    /// The current schema version this build understands.
    public static let currentVersion = 1

    public static func migrate(
        _ raw: [String: Any],
        from version: Int
    ) -> [String: Any] {
        // No migrations yet: version 1 is the only version that has ever
        // existed, so every raw value passes through unchanged.
        raw
    }
}
