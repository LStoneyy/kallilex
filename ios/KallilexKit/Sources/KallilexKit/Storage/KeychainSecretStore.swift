import Foundation
import Security

/// Production `SecretStore`: Keychain generic passwords, shared between the
/// app and the Share Extension through `accessGroup`
/// (`InfoPlist.kallilexKeychainAccessGroup` in production; tests pass `nil`
/// to omit `kSecAttrAccessGroup`, since the shared access group needs a
/// provisioning profile this build may not have). Keys are
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never
/// synchronizable: they never sync and never land in backups.
public final class KeychainSecretStore: SecretStore {
    /// The Keychain service used for provider API keys.
    public static let defaultService = "com.webcommits.kallilex.provider-key"

    private let service: String
    private let accessGroup: String?

    public init(
        service: String = KeychainSecretStore.defaultService,
        accessGroup: String?
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func get(profileID: String) throws -> String? {
        var query = baseQuery(account: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.osStatus(status)
        }
    }

    public func set(_ key: String, profileID: String) throws {
        let data = Data(key.utf8)

        let updateQuery = baseQuery(account: profileID)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(account: profileID)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.osStatus(addStatus)
            }
        default:
            throw SecretStoreError.osStatus(updateStatus)
        }
    }

    public func delete(profileID: String) throws {
        let query = baseQuery(account: profileID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.osStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
