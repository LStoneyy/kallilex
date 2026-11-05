/// Holds the single process-wide `KeyboardModel` (and the concrete
/// `HostDocument`/`ScratchpadDocument` wrappers that back it), so it
/// survives a `KallilexKeyboardController` being deallocated and a new
/// one being created on every appearance (ios-15 spike, unknown 10;
/// ios-18 "Session and lifecycle"). Never persisted to disk — a fresh
/// extension process starts with no model and `modelOrMake` builds one
/// the first time a controller asks.
@MainActor
public final class KeyboardModelStore {
    public static let shared = KeyboardModelStore()

    public private(set) var model: KeyboardModel?
    public private(set) var hostDocument: HostDocument?
    public private(set) var scratchpadDocument: ScratchpadDocument?

    private init() {}

    /// Returns the existing model/documents, or builds them via `make`
    /// the first time this is called in the process's lifetime.
    @discardableResult
    public func modelOrMake(
        _ make: () -> (KeyboardModel, HostDocument, ScratchpadDocument)
    ) -> (KeyboardModel, HostDocument, ScratchpadDocument) {
        if let model, let hostDocument, let scratchpadDocument {
            return (model, hostDocument, scratchpadDocument)
        }
        let created = make()
        model = created.0
        hostDocument = created.1
        scratchpadDocument = created.2
        return created
    }

    /// Test-only / harness-only: clears the stored model so the next
    /// `modelOrMake` call builds a fresh one — part B's UI-test harness
    /// needs this between tests, since the app process (unlike the
    /// keyboard extension process) stays alive across launches.
    public func reset() {
        model = nil
        hostDocument = nil
        scratchpadDocument = nil
    }
}
