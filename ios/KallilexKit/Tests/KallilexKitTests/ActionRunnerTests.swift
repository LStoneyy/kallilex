import Foundation
import Testing
import Synchronization
import KallilexKit

/// A `TextProvider` fake for `ActionRunnerTests`: records every call, and
/// can either return a canned result, throw a canned error, or block until
/// the enclosing `Task` is cancelled — via `withTaskCancellationHandler`,
/// never a real sleep, so the cancellation test is deterministic.
final class FakeTextProvider: TextProvider, @unchecked Sendable {
    struct Call: Sendable {
        let systemPrompt: String
        let userText: String
    }

    enum Behavior {
        case returning(String)
        case throwingError(ProviderError)
        case blockUntilCancelled
    }

    private let behavior: Behavior
    private let calls = Mutex<[Call]>([])
    private let pendingContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func recordedCalls() -> [Call] {
        calls.withLock { $0 }
    }

    func complete(systemPrompt: String, userText: String) async throws -> String {
        calls.withLock { $0.append(Call(systemPrompt: systemPrompt, userText: userText)) }
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

/// A `makeProvider` closure fake that records every `(profile, apiKey)`
/// pair it's called with and always hands back `provider`.
final class ProviderFactorySpy: @unchecked Sendable {
    struct Call: Sendable {
        let profile: ProviderProfile
        let apiKey: String?
    }

    private let provider: FakeTextProvider
    private let calls = Mutex<[Call]>([])

    init(provider: FakeTextProvider) {
        self.provider = provider
    }

    func recordedCalls() -> [Call] {
        calls.withLock { $0 }
    }

    func make(profile: ProviderProfile, apiKey: String?) -> any TextProvider {
        calls.withLock { $0.append(Call(profile: profile, apiKey: apiKey)) }
        return provider
    }
}

/// A `SecretStore` fake whose `get` always throws, to exercise
/// `ActionRunner`'s "a Keychain read failure degrades to no key" path.
private struct FailingSecretStore: SecretStore {
    enum Failure: Error { case boom }
    func get(profileID: String) throws -> String? { throw Failure.boom }
    func set(_ key: String, profileID: String) throws {}
    func delete(profileID: String) throws {}
}

/// Tests for `ActionRunner`. See
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`.
struct ActionRunnerTests {
    func sampleProfile(
        id: String = "a",
        kind: ProviderKind = .openAICompatible,
        baseUrl: String = "http://localhost:11434/v1",
        enabled: Bool = true,
        hasApiKey: Bool = false
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: "Profile \(id)",
            kind: kind,
            baseUrl: baseUrl,
            model: "llama3",
            enabled: enabled,
            hasApiKey: hasApiKey
        )
    }

    func makeRunner(
        settings: AppSettings,
        secrets: any SecretStore = InMemorySecretStore(),
        provider: FakeTextProvider = FakeTextProvider(.returning("result"))
    ) -> (ActionRunner, ProviderFactorySpy) {
        let spy = ProviderFactorySpy(provider: provider)
        let runner = ActionRunner(
            settings: InMemorySettingsStore(initial: settings),
            secrets: secrets,
            makeProvider: spy.make
        )
        return (runner, spy)
    }

    // ---- not configured --------------------------------------------------

    @Test func noActiveProfileIsNotConfigured() async {
        let settings = AppSettings(activeProfileID: nil, profiles: [], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .notConfigured)
        #expect(spy.recordedCalls().isEmpty)
    }

    @Test func disabledActiveProfileIsNotConfigured() async {
        let profile = sampleProfile(enabled: false)
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .notConfigured)
        #expect(spy.recordedCalls().isEmpty)
    }

    @Test func unmatchedActiveIdIsNotConfigured() async {
        let profile = sampleProfile(id: "a")
        let settings = AppSettings(activeProfileID: "missing", profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .notConfigured)
        #expect(spy.recordedCalls().isEmpty)
    }

    // ---- unknown provider kind --------------------------------------------

    @Test func unknownProviderKindFailsWithoutCallingMakeProvider() async {
        let profile = sampleProfile(kind: .unknown("applePrivateCloud"))
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        guard case .failed(let error) = outcome, error.kind == "unavailable" else {
            Issue.record("expected .failed(.unavailable), got \(outcome)")
            return
        }
        #expect(spy.recordedCalls().isEmpty)
    }

    // ---- consent -----------------------------------------------------------

    @Test func cloudProfileWithoutConsentRequiresConsent() async {
        let profile = sampleProfile(baseUrl: "https://api.openai.com/v1")
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .consentRequired(profile))
        #expect(spy.recordedCalls().isEmpty)
    }

    @Test func cloudProfileWithConsentProceeds() async {
        let profile = sampleProfile(baseUrl: "https://api.openai.com/v1")
        let consent = AIConsent(profileID: profile.id, host: "api.openai.com", grantedAt: Date())
        let settings = AppSettings(
            activeProfileID: profile.id,
            profiles: [profile],
            prompts: [],
            consents: [consent]
        )
        let (runner, spy) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .ok("result"))
        #expect(spy.recordedCalls().count == 1)
    }

    @Test func localAndLANProfilesNeverRequireConsent() async {
        let profile = sampleProfile(baseUrl: "http://localhost:11434/v1")
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, _) = makeRunner(settings: settings)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .ok("result"))
    }

    @Test func consentIsInvalidatedWhenTheProfilesHostChanges() async throws {
        let profile = sampleProfile(baseUrl: "https://api.openai.com/v1")
        let consent = AIConsent(profileID: profile.id, host: "api.openai.com", grantedAt: Date())
        let settingsStore = InMemorySettingsStore(
            initial: AppSettings(
                activeProfileID: profile.id,
                profiles: [profile],
                prompts: [],
                consents: [consent]
            )
        )
        let service = SettingsService(settings: settingsStore, secrets: InMemorySecretStore())

        var movedProfile = profile
        movedProfile.baseUrl = "https://api.anthropic.com/v1"
        try service.saveProfile(movedProfile, apiKey: nil)

        let spyProvider = FakeTextProvider(.returning("result"))
        let spy = ProviderFactorySpy(provider: spyProvider)
        let runner = ActionRunner(settings: settingsStore, secrets: InMemorySecretStore(), makeProvider: spy.make)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .consentRequired(movedProfile))
        #expect(spy.recordedCalls().isEmpty)
    }

    // ---- API key reading ----------------------------------------------------

    @Test func keyIsNotReadWhenHasApiKeyIsFalse() async {
        let profile = sampleProfile(hasApiKey: false)
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let secrets = InMemorySecretStore()
        try? secrets.set("sk-unused", profileID: profile.id)
        let (runner, spy) = makeRunner(settings: settings, secrets: secrets)

        _ = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(spy.recordedCalls().first?.apiKey == nil)
    }

    @Test func keyIsReadWhenHasApiKeyIsTrueAndPresent() async {
        let profile = sampleProfile(hasApiKey: true)
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let secrets = InMemorySecretStore()
        try? secrets.set("sk-secret", profileID: profile.id)
        let (runner, spy) = makeRunner(settings: settings, secrets: secrets)

        _ = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(spy.recordedCalls().first?.apiKey == "sk-secret")
    }

    @Test func keyIsNilWhenHasApiKeyIsTrueButNoKeyIsStored() async {
        let profile = sampleProfile(hasApiKey: true)
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings)

        _ = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(spy.recordedCalls().first?.apiKey == nil)
    }

    @Test func keyReadFailureDegradesToNoKeyAndStillCallsTheProvider() async {
        let profile = sampleProfile(hasApiKey: true)
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let (runner, spy) = makeRunner(settings: settings, secrets: FailingSecretStore())

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .ok("result"))
        #expect(spy.recordedCalls().first?.apiKey == nil)
    }

    // ---- success / failure mapping ------------------------------------------

    @Test func successfulCompletionMapsTextThrough() async {
        let profile = sampleProfile()
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let provider = FakeTextProvider(.returning("rewritten text"))
        let (runner, spy) = makeRunner(settings: settings, provider: provider)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .ok("rewritten text"))
        #expect(spy.recordedCalls().count == 1)
    }

    @Test func providerErrorMapsToFailed() async {
        let profile = sampleProfile()
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let provider = FakeTextProvider(.throwingError(.missingModel))
        let (runner, _) = makeRunner(settings: settings, provider: provider)

        let outcome = await runner.run(text: "hello", action: .prompt(instruction: "Do something"))

        #expect(outcome == .failed(.missingModel))
    }

    // ---- cancellation --------------------------------------------------------

    @Test func cancellingTheTaskDuringTheProviderCallReturnsCancelled() async {
        let profile = sampleProfile()
        let settings = AppSettings(activeProfileID: profile.id, profiles: [profile], prompts: [])
        let provider = FakeTextProvider(.blockUntilCancelled)
        let (runner, _) = makeRunner(settings: settings, provider: provider)

        let task = Task {
            await runner.run(text: "hello", action: .prompt(instruction: "Do something"))
        }
        // Give the task a chance to reach the provider call before
        // cancelling it; no fixed sleep duration is load-bearing here —
        // the provider itself blocks deterministically until cancelled.
        await Task.yield()
        task.cancel()

        let outcome = await task.value
        #expect(outcome == .cancelled)
    }

    // ---- testConnection ------------------------------------------------------

    @Test func testConnectionSendsTheExpectedPromptsWithoutConsent() async throws {
        let provider = FakeTextProvider(.returning("OK"))
        let spy = ProviderFactorySpy(provider: provider)
        let runner = ActionRunner(
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(),
            makeProvider: spy.make
        )
        let profile = sampleProfile(baseUrl: "https://api.openai.com/v1")

        let result = await runner.testConnection(profile: profile, apiKey: "sk-test")

        switch result {
        case .success:
            break
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
        let call = try #require(provider.recordedCalls().first)
        #expect(call.systemPrompt == "Reply with the single word OK.")
        #expect(call.userText == "Hello")
        #expect(spy.recordedCalls().first?.apiKey == "sk-test")
    }

    @Test func testConnectionReturnsTheProviderFailure() async {
        let provider = FakeTextProvider(.throwingError(.missingModel))
        let spy = ProviderFactorySpy(provider: provider)
        let runner = ActionRunner(
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(),
            makeProvider: spy.make
        )

        let result = await runner.testConnection(profile: sampleProfile(), apiKey: nil)

        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let error):
            #expect(error == .missingModel)
        }
    }

    // ---- defaultProviderFactory (ios-10) -------------------------------------

    @Test func defaultProviderFactoryReturnsAppleOnDeviceProviderForAppleOnDeviceKind() {
        let profile = sampleProfile(kind: .appleOnDevice, baseUrl: "")
        let provider = ActionRunner.defaultProviderFactory(profile, nil)
        #expect(provider is AppleOnDeviceProvider)
    }

    // ---- testConnection: AppleOnDeviceProvider special case (ios-10) --------

    /// `testConnection` checks on-device availability only — it never
    /// generates text, since a full round trip takes about 10 s (spike
    /// ios-01).
    @Test func testConnectionForAppleOnDeviceChecksAvailabilityOnlyWithoutGenerating() async {
        let session = FakeOnDeviceSession(.returning("should never be reached"))
        let model = FakeOnDeviceModel(availability: .available, session: session)
        let provider = AppleOnDeviceProvider(model: model)
        let runner = ActionRunner(
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(),
            makeProvider: { _, _ in provider }
        )

        let result = await runner.testConnection(profile: sampleProfile(kind: .appleOnDevice, baseUrl: ""), apiKey: nil)

        switch result {
        case .success:
            break
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
        #expect(session.respondCallCount == 0)
    }

    @Test func testConnectionForAppleOnDeviceSurfacesTheUnavailableReason() async {
        let model = FakeOnDeviceModel(availability: .appleIntelligenceNotEnabled)
        let provider = AppleOnDeviceProvider(model: model)
        let runner = ActionRunner(
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(),
            makeProvider: { _, _ in provider }
        )

        let result = await runner.testConnection(profile: sampleProfile(kind: .appleOnDevice, baseUrl: ""), apiKey: nil)

        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let error):
            #expect(Optional(error) == OnDeviceAvailability.appleIntelligenceNotEnabled.providerError)
        }
    }
}
