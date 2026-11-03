import Foundation
import Testing
import KallilexKit

struct SettingsMigratorTests {
    @Test func versionOnePassesThroughUnchanged() {
        let raw: [String: Any] = ["schemaVersion": 1, "foo": "bar", "profiles": []]
        let migrated = SettingsMigrator.migrate(raw, from: 1)
        #expect(NSDictionary(dictionary: migrated) == NSDictionary(dictionary: raw))
    }
}
