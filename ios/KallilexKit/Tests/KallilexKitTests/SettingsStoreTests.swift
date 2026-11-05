import Foundation
import Testing
import KallilexKit

private struct Boom: Error {}

/// Tests for `AppGroupSettingsStore` and `InMemorySettingsStore`. See
/// `issues-ios/spec-ios-04-models-and-stores.md`.
struct SettingsStoreTests {
    func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "KallilexKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    // ---- AppGroupSettingsStore: missing file -------------------------------

    @Test func missingFileLoadsSeededDefaultsWithoutWriting() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)

        let loaded = try store.load()

        #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
    }

    // ---- Round trip ----------------------------------------------------

    @Test func saveThenLoadRoundTrips() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)
        let settings = AppSettings(
            activeProfileID: "p1",
            profiles: [ProviderProfile(id: "p1", name: "A", baseUrl: "http://localhost/v1", model: "m")],
            prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")]
        )

        try store.save(settings)
        let loaded = try store.load()

        #expect(loaded == settings)
    }

    // ---- Corrupt file recovery ------------------------------------------

    @Test func corruptFileIsRenamedAndSeededDefaultsAreReturned() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        try Data("not valid json {{{".utf8).write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)
        let loaded = try store.load()

        #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.contains { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") })

        // Consuming returns the flag and resets it.
        #expect(store.consumeRecoveredFromCorruption())
        #expect(!store.consumeRecoveredFromCorruption())
    }

    @Test func nonObjectJsonIsRecoveredAsCorruption() throws {
        for body in ["[]", "42", "\"just a string\"", "true"] {
            let dir = freshTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("settings.json")
            try Data(body.utf8).write(to: fileURL)

            let store = AppGroupSettingsStore(directory: dir)
            let loaded = try store.load()

            #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")), "body=\(body)")
            #expect(store.consumeRecoveredFromCorruption(), "body=\(body)")
            #expect(!FileManager.default.fileExists(atPath: fileURL.path), "body=\(body)")
        }
    }

    @Test func wrongFieldTypeAtTopLevelIsRecoveredAsCorruption() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        try Data(#"{"profiles": "x"}"#.utf8).write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)
        let loaded = try store.load()

        #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")))
        #expect(store.consumeRecoveredFromCorruption())
    }

    @Test func wrongFieldTypeInsideAProfileIsRecoveredAsCorruption() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        let json = #"""
        {"profiles": [{"id": "a", "name": "A", "baseUrl": "http://x/v1", "model": "m", "timeoutSecs": "not a number"}]}
        """#
        try Data(json.utf8).write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)
        let loaded = try store.load()

        #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")))
        #expect(store.consumeRecoveredFromCorruption())
    }

    @Test func twoRecoveriesInARowProduceTwoDistinctBackupFiles() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        let store = AppGroupSettingsStore(directory: dir)

        try Data("not valid json {{{".utf8).write(to: fileURL)
        _ = try store.load()

        try Data("still not valid json {{{".utf8).write(to: fileURL)
        _ = try store.load()

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") }
        #expect(backups.count == 2)
        #expect(Set(backups).count == 2)
    }

    @Test func unknownProviderKindLoadsWithoutCorruptionRecovery() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        let json = #"""
        {"profiles": [{"id": "a", "name": "A", "kind": "applePrivateCloud", "baseUrl": "http://x/v1", "model": "m"}]}
        """#
        try Data(json.utf8).write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)
        let loaded = try store.load()

        #expect(loaded.profiles.count == 1)
        #expect(loaded.profiles[0].kind == .unknown("applePrivateCloud"))
        #expect(!store.consumeRecoveredFromCorruption())
    }

    // ---- Higher schemaVersion -------------------------------------------

    @Test func higherSchemaVersionThrowsAndLeavesFileUntouched() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"schemaVersion": 999, "profiles": []}"#.utf8)
        try original.write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)

        #expect(throws: SettingsStoreError.unsupportedSchemaVersion(999)) {
            try store.load()
        }
        #expect(!store.consumeRecoveredFromCorruption())
        let stillThere = try Data(contentsOf: fileURL)
        #expect(stillThere == original)
    }

    // ---- loadReadOnly(): missing file -----------------------------------

    @Test func loadReadOnlyMissingFileReturnsSeededDefaultsWithoutWriting() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)

        let loaded = try store.loadReadOnly()

        #expect(loaded == AppSettings.seeded(locale: Locale(identifier: "en")))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
    }

    // ---- loadReadOnly(): valid file matches load() ----------------------

    @Test func loadReadOnlyValidFileMatchesLoad() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)
        let settings = AppSettings(
            activeProfileID: "p1",
            profiles: [ProviderProfile(id: "p1", name: "A", baseUrl: "http://localhost/v1", model: "m")],
            prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")]
        )
        try store.save(settings)

        let readOnlyLoaded = try store.loadReadOnly()
        let loaded = try store.load()
        #expect(readOnlyLoaded == loaded)
        #expect(readOnlyLoaded == settings)
    }

    // ---- loadReadOnly(): corrupt file throws, unchanged, not renamed ----

    @Test func loadReadOnlyCorruptFileThrowsAndLeavesFileInPlace() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        try Data("not valid json {{{".utf8).write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)

        #expect(throws: (any Error).self) {
            try store.loadReadOnly()
        }
        // Unchanged and not renamed away: no "settings.corrupt-*" sibling,
        // and the original file is still right there under its own name.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["settings.json"])
        #expect(try Data(contentsOf: fileURL) == Data("not valid json {{{".utf8))
        // Recovery never ran, so there is nothing to consume.
        #expect(!store.consumeRecoveredFromCorruption())
    }

    // ---- loadReadOnly(): old schema is migrated in memory only ----------

    @Test func loadReadOnlyMigratesAnOlderSchemaInMemoryWithoutRewritingTheFile() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        // No `schemaVersion` key at all: the oldest possible shape, which
        // `decode(_:)` treats as version 1 and migrates (a no-op today,
        // since 1 is still `SettingsMigrator.currentVersion`) before
        // decoding.
        let original = Data(#"{"prompts": [{"id": "c1", "label": "L", "instruction": "I"}]}"#.utf8)
        try original.write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)
        let loaded = try store.loadReadOnly()

        #expect(loaded.prompts == [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        // Never written back: the file on disk is byte-for-byte the same.
        #expect(try Data(contentsOf: fileURL) == original)
    }

    // ---- loadReadOnly(): a read-only directory still loads --------------

    @Test func loadReadOnlySucceedsWhenTheDirectoryItselfIsReadOnly() throws {
        let dir = freshTempDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = AppGroupSettingsStore(directory: dir)
        let settings = AppSettings(prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        try store.save(settings)

        // Simulates an App Group container without Full Access: no write
        // permission on the directory itself, as `NSFileCoordinator` would
        // need for even a read-only coordinated access (spike ios-15,
        // unknown 2).
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        #expect(try store.loadReadOnly() == settings)
    }

    // ---- higherSchemaVersion propagates the same way as load() ----------

    @Test func loadReadOnlyHigherSchemaVersionThrowsAndLeavesFileUntouched() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"schemaVersion": 999, "profiles": []}"#.utf8)
        try original.write(to: fileURL)

        let store = AppGroupSettingsStore(directory: dir)

        #expect(throws: SettingsStoreError.unsupportedSchemaVersion(999)) {
            try store.loadReadOnly()
        }
        let stillThere = try Data(contentsOf: fileURL)
        #expect(stillThere == original)
    }

    // ---- ReadOnlySettingsStore ---------------------------------------------

    @Test func readOnlyStoreLoadDelegatesToLoadReadOnly() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = AppGroupSettingsStore(directory: dir)
        let settings = AppSettings(prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        try backing.save(settings)

        let readOnly = ReadOnlySettingsStore(store: backing)
        #expect(try readOnly.load() == settings)
    }

    @Test func readOnlyStoreSaveThrowsAndDoesNotTouchTheFile() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = AppGroupSettingsStore(directory: dir)
        let initial = AppSettings(prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        try backing.save(initial)

        let readOnly = ReadOnlySettingsStore(store: backing)
        #expect(throws: SettingsStoreError.readOnly) {
            try readOnly.save(AppSettings(prompts: []))
        }
        #expect(try backing.load() == initial)
    }

    @Test func readOnlyStoreUpdateThrowsAndDoesNotTouchTheFile() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = AppGroupSettingsStore(directory: dir)
        let initial = AppSettings(prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        try backing.save(initial)

        let readOnly = ReadOnlySettingsStore(store: backing)
        #expect(throws: SettingsStoreError.readOnly) {
            try readOnly.update { $0.autoCopyResult = true }
        }
        #expect(try backing.load() == initial)
    }

    // ---- update(): closure throwing leaves the file unchanged ------------

    @Test func updateClosureThrowingLeavesTheFileUnchanged() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)
        let initial = AppSettings(prompts: [CustomPrompt(id: "c1", label: "L", instruction: "I")])
        try store.save(initial)

        #expect(throws: Boom.self) {
            try store.update { _ in throw Boom() }
        }

        #expect(try store.load() == initial)
    }

    @Test func updateAppliesTheClosureAndReturnsTheResult() throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppGroupSettingsStore(directory: dir)

        let result = try store.update { current in
            current.autoCopyResult = true
        }

        #expect(result.autoCopyResult)
        #expect(try store.load().autoCopyResult)
    }

    // ---- Concurrent updates from two store instances ----------------------

    @Test func concurrentUpdatesFromTwoStoreInstancesLoseNoWrites() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeA = AppGroupSettingsStore(directory: dir)
        let storeB = AppGroupSettingsStore(directory: dir)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                let store = i.isMultiple(of: 2) ? storeA : storeB
                group.addTask {
                    _ = try? store.update { current in
                        current.prompts.append(CustomPrompt(id: "p-\(i)", label: "L\(i)", instruction: "I\(i)"))
                    }
                }
            }
            await group.waitForAll()
        }

        let final = try storeA.load()
        for i in 0..<50 {
            #expect(final.prompts.contains { $0.id == "p-\(i)" }, "missing p-\(i)")
        }
        // The three seeded defaults plus the 50 appended prompts.
        #expect(final.prompts.count == AppSettings.seeded().prompts.count + 50)
    }

    // ---- InMemorySettingsStore --------------------------------------------

    @Test func inMemoryStoreStartsSeeded() throws {
        let store = InMemorySettingsStore()
        #expect(try store.load() == AppSettings.seeded(locale: Locale(identifier: "en")))
    }

    @Test func inMemoryStoreSaveThenLoadRoundTrips() throws {
        let store = InMemorySettingsStore()
        let settings = AppSettings(prompts: [], autoCopyResult: true)
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    @Test func inMemoryStoreUpdateThrowingLeavesStateUnchanged() throws {
        let store = InMemorySettingsStore()
        let before = try store.load()
        #expect(throws: Boom.self) {
            try store.update { _ in throw Boom() }
        }
        #expect(try store.load() == before)
    }
}
