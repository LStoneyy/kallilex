import Foundation

/// Adapts `AppGroupSettingsStore.loadReadOnly()` to the `SettingsStore`
/// protocol, for callers that need an `any SettingsStore` to hand to
/// `ActionRunner` but must never write — the keyboard without Full Access
/// (ios-16). `save`/`update` throw `SettingsStoreError.readOnly` without
/// touching the file.
public struct ReadOnlySettingsStore: SettingsStore {
    private let store: AppGroupSettingsStore

    public init(store: AppGroupSettingsStore) {
        self.store = store
    }

    public func load() throws -> AppSettings {
        try store.loadReadOnly()
    }

    public func save(_ settings: AppSettings) throws {
        throw SettingsStoreError.readOnly
    }

    @discardableResult
    public func update(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings {
        throw SettingsStoreError.readOnly
    }
}
