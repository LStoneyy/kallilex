import Foundation
import Synchronization

/// Production `SettingsStore`: a single `settings.json` file inside an App
/// Group container (or any directory, for tests), coordinated with
/// `NSFileCoordinator` so the app and the Share Extension can read and
/// write it concurrently without corrupting it or losing a write.
///
/// `Sendable` by construction: `directory`/`fileURL` are immutable `let`s,
/// and the only mutable state (the corruption flag behind
/// `consumeRecoveredFromCorruption()`) lives behind a `Mutex`. No
/// `@unchecked Sendable` is needed.
public final class AppGroupSettingsStore: SettingsStore {
    public let directory: URL
    private let fileURL: URL
    private let corruptionFlag = Mutex(false)

    /// For tests: reads and writes `settings.json` directly inside
    /// `directory`, which the caller is responsible for choosing (e.g. a
    /// temporary directory per test).
    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("settings.json")
    }

    /// Production entry point: resolves `appGroupId` to its container
    /// directory via `FileManager`.
    public convenience init(appGroupId: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            throw SettingsStoreError.appGroupUnavailable(appGroupId)
        }
        self.init(directory: container)
    }

    /// Returns whether the most recent `load()` had to recover from a
    /// corrupt/undecodable file (renamed it and fell back to seeded
    /// defaults), and atomically resets that flag to `false`. The app
    /// calls this once after launch to show a one-time notice (ios-06):
    /// consuming it (rather than a plain getter) means two callers can
    /// never both observe — and both act on — the same corruption event.
    public func consumeRecoveredFromCorruption() -> Bool {
        corruptionFlag.withLock { flag in
            let value = flag
            flag = false
            return value
        }
    }

    public func load() throws -> AppSettings {
        try ensureDirectoryExists()
        var coordinatorError: NSError?
        var result: Result<AppSettings, Error>!
        let coordinator = NSFileCoordinator()
        // Declares both read and write intent on the same file: a corrupt
        // file is recovered (renamed away) as part of this same call, so
        // that rename itself must be coordinated exactly like `update`'s
        // write — otherwise a concurrent reader/writer on another store
        // instance could observe (or race with) a half-renamed file.
        coordinator.coordinate(
            readingItemAt: fileURL,
            options: [],
            writingItemAt: fileURL,
            options: [],
            error: &coordinatorError
        ) { readingURL, writingURL in
            result = Result { try self.readSettings(readingAt: readingURL, writingAt: writingURL) }
        }
        if let coordinatorError {
            throw SettingsStoreError.underlying(coordinatorError.localizedDescription)
        }
        return try result.get()
    }

    public func save(_ settings: AppSettings) throws {
        try ensureDirectoryExists()
        var coordinatorError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            do {
                let data = try SettingsJSONCoding.makeEncoder().encode(settings)
                try data.write(to: url, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinatorError {
            throw SettingsStoreError.underlying(coordinatorError.localizedDescription)
        }
        if let thrown {
            throw thrown
        }
    }

    /// Reads settings without `NSFileCoordinator`, for callers that may not
    /// have Full Access (the keyboard, ios-16) — even a read-only
    /// coordinated access fails there (spike ios-15, unknown 2:
    /// `NSCocoaErrorDomain 256`). A plain `Data(contentsOf:)` tolerates
    /// this: the app always writes atomically, so a plain read sees either
    /// the old or the new file, never a half-written one.
    ///
    /// A missing file returns seeded defaults, like `load()`. A corrupt or
    /// undecodable file throws (wrapped as `.underlying`, or rethrown
    /// as-is for `.unsupportedSchemaVersion`) instead of recovering: this
    /// method has no write access to rename the file away, so it leaves it
    /// untouched for the app to repair, coordinated, on its next launch.
    /// The same `SettingsMigrator` step runs as part of `decode(_:)`, in
    /// memory only — the migrated result is never written back.
    public func loadReadOnly() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppSettings.seeded()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SettingsStoreError.underlying(error.localizedDescription)
        }
        do {
            return try decode(data)
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.underlying(error.localizedDescription)
        }
    }

    @discardableResult
    public func update(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings {
        try ensureDirectoryExists()
        var coordinatorError: NSError?
        var result: Result<AppSettings, Error>!
        let coordinator = NSFileCoordinator()
        // `.forMerging`: a single coordinated access that reads, mutates
        // and writes the same file, so a concurrent `update` from another
        // store instance (app + extension) can never interleave with this
        // one and lose a write. If `body` throws, `result` captures the
        // error and no write happens. This single URL already carries
        // write intent, so a corruption-recovery rename inside
        // `readSettings` is coordinated the same as any other write here.
        coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinatorError) { url in
            result = Result {
                var settings = try self.readSettings(readingAt: url, writingAt: url)
                try body(&settings)
                let data = try SettingsJSONCoding.makeEncoder().encode(settings)
                try data.write(to: url, options: .atomic)
                return settings
            }
        }
        if let coordinatorError {
            throw SettingsStoreError.underlying(coordinatorError.localizedDescription)
        }
        return try result.get()
    }

    // MARK: - Reading and corruption recovery

    /// Reads and decodes `settings.json`, inside an already coordinated
    /// accessor that declared both read and write intent (`load`'s own
    /// read+write coordination, or `update`'s single `.forMerging` write
    /// coordination). `readingURL` and `writingURL` are usually the same
    /// path; recovery renames `writingURL` specifically, since that's the
    /// one file-coordination guarantees is safe to mutate here.
    ///
    /// Missing file → seeded defaults, no write. A `schemaVersion` higher
    /// than this build understands → throws
    /// `SettingsStoreError.unsupportedSchemaVersion` and leaves the file
    /// untouched (never treated as corruption) — this is the *only* error
    /// that propagates instead of triggering recovery. Every other read or
    /// decode failure (unreadable file, invalid JSON, JSON that isn't an
    /// object, a field with the wrong type, …) is corruption: the file is
    /// renamed to `settings.corrupt-<timestamp>-<random>.json`, seeded
    /// defaults are returned, and the corruption flag is set (see
    /// `consumeRecoveredFromCorruption()`).
    private func readSettings(readingAt readingURL: URL, writingAt writingURL: URL) throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: readingURL.path) else {
            return AppSettings.seeded()
        }
        let data: Data
        do {
            data = try Data(contentsOf: readingURL)
        } catch {
            return try recoverFromCorruption(at: writingURL)
        }
        do {
            return try decode(data)
        } catch SettingsStoreError.unsupportedSchemaVersion(let version) {
            // The one read failure that is never corruption: propagate as-is.
            throw SettingsStoreError.unsupportedSchemaVersion(version)
        } catch {
            // Everything else — not a JSON object at all, a decode type
            // mismatch, malformed JSON — is corruption.
            return try recoverFromCorruption(at: writingURL)
        }
    }

    /// A decode failure that isn't itself a `SettingsStoreError` (so that
    /// `readSettings`'s `catch SettingsStoreError.unsupportedSchemaVersion`
    /// clause can't accidentally also match it and skip recovery).
    private struct NotAJSONObject: Error {}

    private func decode(_ data: Data) throws -> AppSettings {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAJSONObject()
        }
        let version = (json["schemaVersion"] as? Int) ?? 1
        if version > SettingsMigrator.currentVersion {
            throw SettingsStoreError.unsupportedSchemaVersion(version)
        }
        let migrated = SettingsMigrator.migrate(json, from: version)
        let migratedData = try JSONSerialization.data(withJSONObject: migrated)
        return try SettingsJSONCoding.makeDecoder().decode(AppSettings.self, from: migratedData)
    }

    private func recoverFromCorruption(at url: URL) throws -> AppSettings {
        // A short random suffix (rather than timestamp alone) means two
        // recoveries within the same second never collide and overwrite
        // each other's backup.
        let suffix = String(UUID().uuidString.prefix(8))
        let corruptURL = directory.appendingPathComponent(
            "settings.corrupt-\(Self.corruptionTimestamp())-\(suffix).json"
        )
        try FileManager.default.moveItem(at: url, to: corruptURL)
        corruptionFlag.withLock { $0 = true }
        return AppSettings.seeded()
    }

    /// ISO-8601 "basic" format (no `-`/`:` separators), which is also
    /// filename-safe on every platform: e.g. `20261103T152233Z`.
    private static func corruptionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func ensureDirectoryExists() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SettingsStoreError.underlying(error.localizedDescription)
        }
    }
}
