import Foundation
import Synchronization

/// In-memory `SettingsStore` fake for tests: wraps an `AppSettings` value
/// behind a `Mutex`, with synchronous `load()`/`save()`/`update()`. Starts
/// from `AppSettings.seeded()`, exactly like a fresh `AppGroupSettingsStore`
/// with no file on disk yet.
public final class InMemorySettingsStore: SettingsStore {
    private let state: Mutex<AppSettings>

    public init(initial: AppSettings = .seeded()) {
        self.state = Mutex(initial)
    }

    public func load() throws -> AppSettings {
        state.withLock { $0 }
    }

    public func save(_ settings: AppSettings) throws {
        state.withLock { $0 = settings }
    }

    @discardableResult
    public func update(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings {
        try state.withLock { current in
            try body(&current)
            return current
        }
    }
}
