import Foundation
import Security
import Testing
import KallilexKit

/// Tests for `InMemorySecretStore` and `KeychainSecretStore`. The Keychain
/// integration test only runs when a probe write/delete succeeds (no
/// signing/provisioning-profile access-group entitlement is available for
/// `xcodebuild test` on the simulator without one) — see
/// `issues-ios/spec-ios-04-models-and-stores.md`, decision 6.
struct SecretStoreTests {
    // ---- InMemorySecretStore -----------------------------------------------

    @Test func getReturnsNilForAnUnknownProfile() throws {
        let store = InMemorySecretStore()
        #expect(try store.get(profileID: "missing") == nil)
    }

    @Test func setThenGetRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.set("sk-secret", profileID: "p1")
        #expect(try store.get(profileID: "p1") == "sk-secret")
    }

    @Test func setTwiceUpdatesInPlace() throws {
        let store = InMemorySecretStore()
        try store.set("sk-old", profileID: "p1")
        try store.set("sk-new", profileID: "p1")
        #expect(try store.get(profileID: "p1") == "sk-new")
    }

    @Test func deleteIsANoOpForAnUnknownProfile() throws {
        let store = InMemorySecretStore()
        try store.delete(profileID: "missing") // must not throw
    }

    @Test func deleteRemovesTheKey() throws {
        let store = InMemorySecretStore()
        try store.set("sk-secret", profileID: "p1")
        try store.delete(profileID: "p1")
        #expect(try store.get(profileID: "p1") == nil)
    }

    // ---- KeychainSecretStore integration -----------------------------------

    /// A quick add/delete probe with no access group, under a disposable
    /// service name, to detect whether this test environment (signing,
    /// sandboxing) permits Keychain access at all.
    static func keychainProbeSucceeds() -> (succeeded: Bool, status: OSStatus) {
        let service = "com.webcommits.kallilex.keychain-probe"
        let account = "probe-\(UUID().uuidString)"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("probe".utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        return (addStatus == errSecSuccess, addStatus)
    }

    static let probeResult = keychainProbeSucceeds()

    @Test(.enabled(if: SecretStoreTests.probeResult.succeeded))
    func keychainSecretStoreSetGetDeleteRoundTrips() throws {
        // A unique per-run service name so repeated runs (and parallel
        // runs) never collide, and so this test cleans up fully after
        // itself regardless of outcome.
        let service = "com.webcommits.kallilex.provider-key.test-\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service, accessGroup: nil)
        let profileID = "p1"
        defer { try? store.delete(profileID: profileID) }

        #expect(try store.get(profileID: profileID) == nil)

        try store.set("sk-secret", profileID: profileID)
        #expect(try store.get(profileID: profileID) == "sk-secret")

        try store.set("sk-updated", profileID: profileID)
        #expect(try store.get(profileID: profileID) == "sk-updated")

        try store.delete(profileID: profileID)
        #expect(try store.get(profileID: profileID) == nil)

        // Deleting again is a no-op, not an error.
        try store.delete(profileID: profileID)
    }
}
