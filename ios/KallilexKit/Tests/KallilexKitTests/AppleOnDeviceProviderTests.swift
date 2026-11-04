import Foundation
import Testing
import Synchronization
import FoundationModels
@testable import KallilexKit

/// An `OnDeviceSession` fake for `AppleOnDeviceProviderTests` (and
/// `ActionRunnerTests`'s on-device `testConnection` tests): records how
/// many times `respond(to:)` was called, and can return a canned result,
/// throw a canned error, or block until the enclosing `Task` is cancelled —
/// via `withTaskCancellationHandler`, never a real sleep. Mirrors
/// `ActionRunnerTests.FakeTextProvider`'s own cancellation technique.
final class FakeOnDeviceSession: OnDeviceSession, @unchecked Sendable {
    enum Behavior {
        case returning(String)
        case throwingError(Error)
        case blockUntilCancelled
    }

    private let behavior: Behavior
    private let callCount = Mutex<Int>(0)
    private let pendingContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var respondCallCount: Int { callCount.withLock { $0 } }

    func respond(to text: String) async throws -> String {
        callCount.withLock { $0 += 1 }
        switch behavior {
        case .returning(let text):
            return text
        case .throwingError(let error):
            throw error
        case .blockUntilCancelled:
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pendingContinuation.withLock { $0 = continuation }
                }
            } onCancel: {
                pendingContinuation.withLock { stored in
                    stored?.resume()
                    stored = nil
                }
            }
            throw CancellationError()
        }
    }
}

/// An `OnDeviceModel` fake for `AppleOnDeviceProviderTests` and
/// `ActionRunnerTests`'s on-device `testConnection` tests.
final class FakeOnDeviceModel: OnDeviceModel, @unchecked Sendable {
    private struct Boom: Error {}

    let availability: OnDeviceAvailability
    let contextSize: Int
    private let tokenCountResult: Result<Int?, Error>
    private let session: FakeOnDeviceSession

    init(
        availability: OnDeviceAvailability = .available,
        contextSize: Int = 4096,
        tokenCountResult: Result<Int?, Error> = .success(nil),
        session: FakeOnDeviceSession = FakeOnDeviceSession(.returning(""))
    ) {
        self.availability = availability
        self.contextSize = contextSize
        self.tokenCountResult = tokenCountResult
        self.session = session
    }

    func tokenCount(for text: String) async throws -> Int? {
        try tokenCountResult.get()
    }

    func makeSession(instructions: String) -> any OnDeviceSession {
        session
    }
}

/// Tests for `OnDeviceAvailability`, `AppleOnDeviceProvider`, and the
/// `SystemLanguageModel.Availability` mapping between them. See
/// `issues-ios/spec-ios-10-apple-on-device-provider.md`.
struct AppleOnDeviceProviderTests {
    // MARK: - SystemLanguageModel.Availability -> OnDeviceAvailability

    @Test func mapsAvailableToAvailable() {
        #expect(OnDeviceAvailability(SystemLanguageModel.Availability.available) == .available)
    }

    @Test func mapsDeviceNotEligible() {
        #expect(OnDeviceAvailability(.unavailable(.deviceNotEligible)) == .deviceNotEligible)
    }

    @Test func mapsAppleIntelligenceNotEnabled() {
        #expect(OnDeviceAvailability(.unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceNotEnabled)
    }

    @Test func mapsModelNotReady() {
        #expect(OnDeviceAvailability(.unavailable(.modelNotReady)) == .modelNotReady)
    }

    // MARK: - OnDeviceAvailability -> ProviderError / statusText

    @Test func availableHasNoProviderErrorAndReadyStatusText() {
        #expect(OnDeviceAvailability.available.providerError == nil)
        #expect(OnDeviceAvailability.available.statusText == "Ready")
    }

    @Test func deviceNotEligibleProviderErrorAndStatusText() {
        let expected = "This device doesn't support Apple Intelligence."
        #expect(OnDeviceAvailability.deviceNotEligible.providerError == .unavailable(reason: expected))
        #expect(OnDeviceAvailability.deviceNotEligible.statusText == expected)
    }

    @Test func appleIntelligenceNotEnabledProviderErrorAndStatusText() {
        let expected = "Turn on Apple Intelligence in Settings."
        #expect(OnDeviceAvailability.appleIntelligenceNotEnabled.providerError == .unavailable(reason: expected))
        #expect(OnDeviceAvailability.appleIntelligenceNotEnabled.statusText == expected)
    }

    @Test func modelNotReadyProviderErrorAndStatusText() {
        let expected = "The model is still downloading or not yet ready."
        #expect(OnDeviceAvailability.modelNotReady.providerError == .unavailable(reason: expected))
        #expect(OnDeviceAvailability.modelNotReady.statusText == expected)
    }

    @Test func unavailableOtherProviderErrorAndStatusText() {
        let expected = "Apple Intelligence is not available."
        #expect(OnDeviceAvailability.unavailableOther.providerError == .unavailable(reason: expected))
        #expect(OnDeviceAvailability.unavailableOther.statusText == expected)
    }

    // MARK: - complete(): availability gate

    @Test func unavailableAvailabilitySkipsGenerationEntirely() async throws {
        let session = FakeOnDeviceSession(.returning("should never be reached"))
        let model = FakeOnDeviceModel(availability: .modelNotReady, session: session)
        let provider = AppleOnDeviceProvider(model: model)

        do {
            _ = try await provider.complete(systemPrompt: "sys", userText: "hi")
            Issue.record("expected an unavailable error")
        } catch let error as ProviderError {
            #expect(error == OnDeviceAvailability.modelNotReady.providerError)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(session.respondCallCount == 0)
    }

    // MARK: - complete(): context check

    @Test func withinContextLimitSendsTheRequest() async throws {
        let session = FakeOnDeviceSession(.returning("hello"))
        // input 10, overhead 64, output reserve min(10, 1024) = 10 -> total 84.
        let model = FakeOnDeviceModel(contextSize: 1000, tokenCountResult: .success(10), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let result = try await provider.complete(systemPrompt: "sys", userText: "hi")

        #expect(result == "hello")
        #expect(session.respondCallCount == 1)
    }

    @Test func overContextLimitReturnsContextTooLongWithoutSendingARequest() async throws {
        let session = FakeOnDeviceSession(.returning("should never be reached"))
        // input 2000, overhead 64, output reserve min(2000, 1024) = 1024 -> total 3088.
        let model = FakeOnDeviceModel(contextSize: 100, tokenCountResult: .success(2000), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        do {
            _ = try await provider.complete(systemPrompt: "sys", userText: "hi")
            Issue.record("expected contextTooLong")
        } catch let error as ProviderError {
            #expect(error == .contextTooLong)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(session.respondCallCount == 0)
    }

    @Test func tokenCountNilFallsBackToCharacterEstimate() async throws {
        let session = FakeOnDeviceSession(.returning("hello"))
        // "sys" + "hi" = 5 characters; overhead 64, output reserve 5 -> total 74.
        let model = FakeOnDeviceModel(contextSize: 1000, tokenCountResult: .success(nil), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let result = try await provider.complete(systemPrompt: "sys", userText: "hi")

        #expect(result == "hello")
        #expect(session.respondCallCount == 1)
    }

    @Test func tokenCountThrowingAlsoFallsBackToCharacterEstimate() async throws {
        struct Boom: Error {}
        let session = FakeOnDeviceSession(.returning("hello"))
        let model = FakeOnDeviceModel(contextSize: 1000, tokenCountResult: .failure(Boom()), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let result = try await provider.complete(systemPrompt: "sys", userText: "hi")

        #expect(result == "hello")
        #expect(session.respondCallCount == 1)
    }

    @Test func outputReserveIsCappedAt1024EvenForAMuchLargerInput() async throws {
        let withinCap = FakeOnDeviceSession(.returning("hello"))
        // input 5000, overhead 64, output reserve capped at 1024 -> total 6088.
        let withinCapModel = FakeOnDeviceModel(contextSize: 6088, tokenCountResult: .success(5000), session: withinCap)
        let withinCapProvider = AppleOnDeviceProvider(model: withinCapModel)
        let result = try await withinCapProvider.complete(systemPrompt: "sys", userText: "hi")
        #expect(result == "hello")

        let overCap = FakeOnDeviceSession(.returning("should never be reached"))
        let overCapModel = FakeOnDeviceModel(contextSize: 6087, tokenCountResult: .success(5000), session: overCap)
        let overCapProvider = AppleOnDeviceProvider(model: overCapModel)
        do {
            _ = try await overCapProvider.complete(systemPrompt: "sys", userText: "hi")
            Issue.record("expected contextTooLong")
        } catch let error as ProviderError {
            #expect(error == .contextTooLong)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(overCap.respondCallCount == 0)
    }

    // MARK: - complete(): GenerationError mapping

    private func context(_ debugDescription: String = "test") -> LanguageModelSession.GenerationError.Context {
        LanguageModelSession.GenerationError.Context(debugDescription: debugDescription)
    }

    private func makeProvider(throwing error: Error) -> (AppleOnDeviceProvider, FakeOnDeviceSession) {
        let session = FakeOnDeviceSession(.throwingError(error))
        let model = FakeOnDeviceModel(session: session)
        return (AppleOnDeviceProvider(model: model), session)
    }

    @Test func exceededContextWindowSizeMapsToContextTooLong() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.exceededContextWindowSize(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected contextTooLong")
        } catch let error as ProviderError {
            #expect(error == .contextTooLong)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func guardrailViolationMapsToDeclined() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.guardrailViolation(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected declined")
        } catch let error as ProviderError {
            #expect(error == .declined)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func refusalMapsToDeclined() async throws {
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.refusal(refusal, context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected declined")
        } catch let error as ProviderError {
            #expect(error == .declined)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func unsupportedLanguageOrLocaleMapsToUnavailable() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            #expect(error == .unavailable(reason: "This language isn't supported by the on-device model."))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func rateLimitedMapsToUnavailableBusy() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.rateLimited(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func concurrentRequestsMapsToUnavailableBusy() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.concurrentRequests(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func assetsUnavailableMapsToTheSameMessageAsModelNotReady() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.assetsUnavailable(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected unavailable")
        } catch let error as ProviderError {
            #expect(error == OnDeviceAvailability.modelNotReady.providerError)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func unsupportedGuideFallsBackToInvalidResponse() async throws {
        let (provider, _) = makeProvider(throwing: LanguageModelSession.GenerationError.unsupportedGuide(context()))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected invalidResponse")
        } catch let error as ProviderError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func anUnrecognizedErrorMapsToInvalidResponse() async throws {
        struct Boom: Error {}
        let (provider, _) = makeProvider(throwing: Boom())
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected invalidResponse")
        } catch let error as ProviderError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - complete(): cancellation

    @Test func cancellationPropagatesUnchangedWhenAlreadyCancelled() async throws {
        let session = FakeOnDeviceSession(.returning("should never be reached"))
        let model = FakeOnDeviceModel(session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let task = Task {
            try await provider.complete(systemPrompt: "s", userText: "u")
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func cancellationDuringRespondPropagatesUnchanged() async throws {
        let session = FakeOnDeviceSession(.blockUntilCancelled)
        let model = FakeOnDeviceModel(session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let task = Task {
            try await provider.complete(systemPrompt: "s", userText: "u")
        }
        // Give the task a chance to reach `session.respond` before cancelling.
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// A cancellation surfacing from the token count (the pre-flight
    /// context check) propagates as cancellation and never starts the
    /// generation, rather than being treated as "no token count" and
    /// falling back to the character estimate.
    @Test func cancellationDuringTheTokenCountNeverStartsTheGeneration() async {
        let session = FakeOnDeviceSession(.returning("never"))
        let model = FakeOnDeviceModel(tokenCountResult: .failure(CancellationError()), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(session.respondCallCount == 0)
    }

    /// The caller's task is cancelled while the pre-flight checks run:
    /// the generation must not start. The token count throws an ordinary
    /// error here, so only the explicit cancellation checks can stop it.
    @Test func aTaskCancelledBeforeTheGenerationNeverStartsIt() async {
        struct Unrelated: Error {}
        let session = FakeOnDeviceSession(.returning("never"))
        let model = FakeOnDeviceModel(tokenCountResult: .failure(Unrelated()), session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.complete(systemPrompt: "s", userText: "u")
        }
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(session.respondCallCount == 0)
    }

    /// Errors this provider doesn't map specifically surface a fixed
    /// detail, never the SDK's own free-form description.
    @Test func unmappedErrorsUseAFixedDetail() async {
        struct Opaque: Error, CustomStringConvertible {
            var description: String { "secret user text" }
        }
        let model = FakeOnDeviceModel(session: FakeOnDeviceSession(.throwingError(Opaque())))
        let provider = AppleOnDeviceProvider(model: model)

        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected invalidResponse")
        } catch let error as ProviderError {
            #expect(error == .invalidResponse(AppleOnDeviceProvider.unexpectedErrorDetail))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - complete(): stripPadding

    @Test func stripsPaddingFromTheResponse() async throws {
        let session = FakeOnDeviceSession(.returning("\n\nHello there  "))
        let model = FakeOnDeviceModel(session: session)
        let provider = AppleOnDeviceProvider(model: model)

        let result = try await provider.complete(systemPrompt: "s", userText: "u")

        #expect(result == "Hello there")
    }

    @Test func allWhitespaceResponseAfterStrippingMapsToInvalidResponse() async throws {
        let session = FakeOnDeviceSession(.returning("   \n  "))
        let model = FakeOnDeviceModel(session: session)
        let provider = AppleOnDeviceProvider(model: model)

        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected invalidResponse")
        } catch let error as ProviderError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - checkAvailability()

    @Test func checkAvailabilityReturnsNilWhenAvailable() async {
        let model = FakeOnDeviceModel(availability: .available)
        let provider = AppleOnDeviceProvider(model: model)
        #expect(await provider.checkAvailability() == nil)
    }

    @Test func checkAvailabilityReturnsTheMappedErrorWhenUnavailable() async {
        let model = FakeOnDeviceModel(availability: .deviceNotEligible)
        let provider = AppleOnDeviceProvider(model: model)
        #expect(await provider.checkAvailability() == OnDeviceAvailability.deviceNotEligible.providerError)
    }
}
