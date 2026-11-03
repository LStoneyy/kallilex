import Foundation

/// Platform-agnostic seam for talking to an AI provider. The one
/// production implementation for v1 is `OpenAICompatibleProvider`; ios-10
/// adds an on-device implementation. Tests use fakes.
///
/// Untyped `throws`, by decision: a typed `throws(ProviderError)` can't
/// also carry Swift's `CancellationError`, and cancellation must stay
/// distinguishable from a provider failure. The contract every conforming
/// type must honor: a call to `complete` throws either a `ProviderError`
/// or a `CancellationError`, nothing else. Implementations call
/// `try Task.checkCancellation()` before sending and map
/// `URLError.cancelled` (or their own cancellation signal) to
/// `CancellationError`; any other unexpected error is wrapped as
/// `ProviderError.invalidResponse(String(describing:))`. `ActionRunner`
/// catches `CancellationError` first (→ `.cancelled`), then `ProviderError`
/// (→ `.failed`).
public protocol TextProvider: Sendable {
    func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String
}
