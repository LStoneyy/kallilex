import Foundation
import Synchronization

/// In-memory `SecretStore` fake for tests: a `[String: String]` dictionary
/// keyed by profile id, behind a `Mutex`.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: String]>([:])

    public init() {}

    public func get(profileID: String) throws -> String? {
        storage.withLock { $0[profileID] }
    }

    public func set(_ key: String, profileID: String) throws {
        storage.withLock { $0[profileID] = key }
    }

    public func delete(profileID: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: profileID) }
    }
}
