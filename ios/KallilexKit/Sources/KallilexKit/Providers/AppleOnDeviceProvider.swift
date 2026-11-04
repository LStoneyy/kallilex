import Foundation
import FoundationModels

/// Every user-facing string this file needs, gathered in one place so
/// `OnDeviceAvailability`'s reason messages and `AppleOnDeviceProvider`'s
/// error mapping (whose `.assetsUnavailable` case reuses the same
/// "not ready" wording) share a single source of truth rather than two
/// separately maintained literals.
private enum OnDeviceMessages {
    static let ready = String(localized: "ondevice.status.ready", defaultValue: "Ready", bundle: .module)
    static let deviceNotEligible = String(
        localized: "ondevice.reason.deviceNotEligible",
        defaultValue: "This device doesn't support Apple Intelligence.",
        bundle: .module
    )
    static let appleIntelligenceNotEnabled = String(
        localized: "ondevice.reason.appleIntelligenceNotEnabled",
        defaultValue: "Turn on Apple Intelligence in Settings.",
        bundle: .module
    )
    static let modelNotReady = String(
        localized: "ondevice.reason.modelNotReady",
        defaultValue: "The model is still downloading or not yet ready.",
        bundle: .module
    )
    static let unavailableOther = String(
        localized: "ondevice.reason.unavailableOther",
        defaultValue: "Apple Intelligence is not available.",
        bundle: .module
    )
    static let unsupportedLanguage = String(
        localized: "ondevice.error.unsupportedLanguage",
        defaultValue: "This language isn't supported by the on-device model.",
        bundle: .module
    )
    static let busy = String(
        localized: "ondevice.error.busy",
        defaultValue: "The on-device model is busy right now. Try again in a moment.",
        bundle: .module
    )
}

/// Availability of the Apple on-device Foundation Model, independent of
/// `FoundationModels`'s own `SystemLanguageModel.Availability` (ios-10 "own
/// availability enum" decision): this keeps every caller outside this file
/// — tests, `AppEnvironment`, `ProviderEditor` — decoupled from the SDK
/// type, so fakes and UI code never need to import `FoundationModels`.
public enum OnDeviceAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// A reason this build doesn't recognize (`@unknown default` on
    /// `SystemLanguageModel.Availability.UnavailableReason`, which is not
    /// `@frozen`, unlike `Availability` itself).
    case unavailableOther
}

extension OnDeviceAvailability {
    /// Maps `SystemLanguageModel.Availability` onto this type. Verified
    /// against the Xcode 27.2 SDK's `FoundationModels.swiftinterface`
    /// (spike ios-01): `Availability` is `@frozen` with exactly `.available`
    /// and `.unavailable(reason:)`, so this switch is exhaustive without
    /// `@unknown default`; `UnavailableReason` is *not* `@frozen`, so its
    /// switch needs one. Kept `internal` (not `public`) on purpose: this is
    /// the only place in the module that needs to name
    /// `SystemLanguageModel.Availability` at all — every other caller only
    /// ever sees the plain `OnDeviceAvailability` this produces.
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                self = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                self = .appleIntelligenceNotEnabled
            case .modelNotReady:
                self = .modelNotReady
            @unknown default:
                self = .unavailableOther
            }
        }
    }
}

extension OnDeviceAvailability {
    /// `nil` when available; otherwise a complete, actionable
    /// `ProviderError.unavailable(reason:)`, matching that case's "`reason`
    /// is already a complete sentence" contract.
    public var providerError: ProviderError? {
        switch self {
        case .available:
            return nil
        case .deviceNotEligible:
            return .unavailable(reason: OnDeviceMessages.deviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return .unavailable(reason: OnDeviceMessages.appleIntelligenceNotEnabled)
        case .modelNotReady:
            return .unavailable(reason: OnDeviceMessages.modelNotReady)
        case .unavailableOther:
            return .unavailable(reason: OnDeviceMessages.unavailableOther)
        }
    }

    /// The text `ProviderEditor`'s availability row shows: "Ready" when
    /// available, else the same reason (which already reads as a
    /// user-facing hint, e.g. "Turn on Apple Intelligence in Settings.") as
    /// `providerError`.
    public var statusText: String {
        switch self {
        case .available:
            return OnDeviceMessages.ready
        case .deviceNotEligible:
            return OnDeviceMessages.deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return OnDeviceMessages.appleIntelligenceNotEnabled
        case .modelNotReady:
            return OnDeviceMessages.modelNotReady
        case .unavailableOther:
            return OnDeviceMessages.unavailableOther
        }
    }
}

/// Abstracts `SystemLanguageModel` (ios-10) so tests inject a fake instead
/// of a real model — the real one needs Apple Intelligence enabled on an
/// eligible device (spike ios-01). `Sendable`: `ActionRunner` calls this off
/// the main actor.
public protocol OnDeviceModel: Sendable {
    var availability: OnDeviceAvailability { get async }

    /// The model's maximum combined input+output token budget, backing the
    /// context check below.
    var contextSize: Int { get async }

    /// The token count of `text`, or `nil` on iOS 26.0–26.3, where
    /// `SystemLanguageModel.tokenCount(for:)` doesn't exist yet.
    func tokenCount(for text: String) async throws -> Int?

    /// A fresh session instructed with `instructions` (the assembled system
    /// prompt). `AppleOnDeviceProvider` calls this once per `complete` —
    /// no session is reused across requests.
    func makeSession(instructions: String) -> any OnDeviceSession
}

/// Abstracts `LanguageModelSession` (ios-10) so tests inject a canned
/// response, error, or cancellation without a real model.
public protocol OnDeviceSession: Sendable {
    func respond(to text: String) async throws -> String
}

/// The production `OnDeviceModel`, wrapping `SystemLanguageModel.default`.
public struct DefaultOnDeviceModel: OnDeviceModel {
    public init() {}

    public var availability: OnDeviceAvailability {
        get async { OnDeviceAvailability(SystemLanguageModel.default.availability) }
    }

    /// `SystemLanguageModel.default.contextSize: Int`. Verified against the
    /// Xcode 27.2 SDK's `FoundationModels.swiftinterface`: declared
    /// `@available(iOS 26.0, …)` with `@backDeployed(before: iOS 26.4, …)`
    /// — a fully iOS-26.0+ symbol, not gated to iOS 27 as the spec
    /// originally guessed. Still wrapped in `#if compiler(>=6.4)` (the
    /// Swift compiler Xcode 27.2 ships, per `xcrun swift --version`) purely
    /// as a defensive fallback in case CI's older Xcode 26.6 / iOS 26.5 SDK
    /// pairing doesn't carry this declaration; the `#else` branch returns
    /// the SDK interface's own documented pre-iOS-27 constant, 4096.
    public var contextSize: Int {
        get async {
            #if compiler(>=6.4)
            SystemLanguageModel.default.contextSize
            #else
            4096
            #endif
        }
    }

    /// `SystemLanguageModel.default.tokenCount(for:) async throws -> Int`,
    /// iOS 26.4+ — present in both the Xcode 27.2 and the CI iOS 26.5 SDKs.
    /// `String` conforms to `PromptRepresentable` and is accepted directly.
    /// `nil` before iOS 26.4, where this method doesn't exist yet.
    public func tokenCount(for text: String) async throws -> Int? {
        guard #available(iOS 26.4, *) else { return nil }
        return try await SystemLanguageModel.default.tokenCount(for: text)
    }

    public func makeSession(instructions: String) -> any OnDeviceSession {
        DefaultOnDeviceSession(instructions: instructions)
    }
}

/// The production `OnDeviceSession`. Stores only `instructions` (a
/// `Sendable` `String`) and creates the actual `LanguageModelSession` —
/// which is not itself `Sendable` — inside `respond(to:)`, so this type
/// needs no `@unchecked Sendable` escape hatch: the non-`Sendable` value
/// never crosses a concurrency boundary. A fresh `LanguageModelSession` is
/// created on every call, per the spec's "no session is reused" decision.
public struct DefaultOnDeviceSession: OnDeviceSession {
    public let instructions: String

    public init(instructions: String) {
        self.instructions = instructions
    }

    public func respond(to text: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        // `Response.usage` is iOS 27.0+ only, and isn't declared at all in
        // the iOS 26.5 SDK's `FoundationModels.swiftinterface` — not just
        // behind `#available` — so it must never be referenced here, even
        // under a runtime check: the context check below uses
        // `tokenCount(for:)` instead, and usage-based telemetry is
        // deferred to a future spec.
        let response = try await session.respond(to: text)
        return response.content
    }
}

/// `TextProvider` for Apple Intelligence's on-device Foundation Model
/// (ios-10). Checks availability, pre-checks context size, and maps every
/// `LanguageModelSession.GenerationError` case available from iOS 26.0
/// onward onto `ProviderError`. The exact same code path runs in the app
/// and the Share Extension — `ActionRunner.defaultProviderFactory` is the
/// only place that constructs this type, and both hosts share it.
public struct AppleOnDeviceProvider: TextProvider {
    public let model: any OnDeviceModel

    /// Session overhead reserve (spike ios-01 measured
    /// `usage.input.totalTokenCount` as 54 tokens higher than
    /// `tokenCount(for:)` of the prompt alone, consistently across three
    /// runs; this adds a few tokens of headroom over that).
    static let contextOverheadReserve = 64
    /// This provider has no separate output-length setting, so the output
    /// reserve is "as much as the input", capped here.
    static let maxOutputReserve = 1024
    /// Shown for errors this provider doesn't map to a specific case. A
    /// fixed text rather than the SDK's own description, whose free-form
    /// diagnostic context isn't guaranteed to be free of request content.
    static let unexpectedErrorDetail = "The on-device model reported an unexpected error."

    public init(model: any OnDeviceModel = DefaultOnDeviceModel()) {
        self.model = model
    }

    public func complete(systemPrompt: String, userText: String) async throws -> String {
        try Task.checkCancellation()

        if let error = await model.availability.providerError {
            throw error
        }

        // Re-checked after each pre-flight await: a Cancel tapped while
        // availability or the token count is being resolved must stop the
        // run before the ~10 s generation starts.
        try Task.checkCancellation()

        if try await exceedsContextSize(systemPrompt: systemPrompt, userText: userText) {
            throw ProviderError.contextTooLong
        }
        try Task.checkCancellation()

        let session = model.makeSession(instructions: systemPrompt)
        let raw: String
        do {
            raw = try await session.respond(to: userText)
        } catch is CancellationError {
            throw CancellationError()
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            // `Task.isCancelled` first: an unrelated-looking error thrown
            // while the enclosing task was already cancelled is treated as
            // cancellation, not a provider failure — mirrors
            // `ActionRunner.run`'s own `Task.isCancelled ? .cancelled :
            // .failed(...)` pattern.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw Self.map(error)
        }

        // Consistent with `OpenAICompatibleProvider`: padding is stripped
        // from the raw text, but unlike that provider (which only ever
        // sees an empty string from a server that explicitly sent one), an
        // on-device response that's empty or pure whitespace after
        // stripping is itself unexpected — the model normally either
        // refuses (mapped to `.declined` above) or answers with content.
        let stripped = OpenAICompatibleProvider.stripPadding(raw)
        guard !stripped.isEmpty else {
            throw ProviderError.invalidResponse("empty response after stripping padding")
        }
        return stripped
    }

    /// Availability-only check for `ActionRunner.testConnection`: a full
    /// on-device round trip takes about 10 s (spike ios-01), so "Test
    /// connection" checks availability alone rather than generating text.
    public func checkAvailability() async -> ProviderError? {
        await model.availability.providerError
    }

    // MARK: - Context check

    /// `total = input + 64 (overhead reserve) + min(input, 1024) (output
    /// reserve)`. On iOS 26.4+, `input` is `model.tokenCount(for:)` of the
    /// assembled prompt (`systemPrompt + userText`); before that — or if
    /// `tokenCount` throws for any other reason — `input` falls back to the
    /// character-count estimate `systemPrompt.count + userText.count`,
    /// relying on the model's own `exceededContextWindowSize` error as a
    /// backstop if the estimate turns out too optimistic.
    ///
    /// Cancellation is rethrown rather than treated as "no token count".
    private func exceedsContextSize(systemPrompt: String, userText: String) async throws -> Bool {
        let fullPrompt = systemPrompt + userText
        let counted: Int?
        do {
            counted = try await model.tokenCount(for: fullPrompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            counted = nil
        }
        let inputTokenCount = counted ?? fullPrompt.count
        let outputReserve = min(inputTokenCount, Self.maxOutputReserve)
        let total = inputTokenCount + Self.contextOverheadReserve + outputReserve
        let contextSize = await model.contextSize
        return total > contextSize
    }

    // MARK: - Error mapping

    /// Maps `LanguageModelSession.GenerationError` onto `ProviderError`.
    /// Every case named below is available from iOS 26.0 and only
    /// *deprecated* (not removed) at iOS 27.0, so all of them compile and
    /// run unchanged against the CI 26.5 SDK with a 26.0 deployment target.
    /// No iOS-27-only case (e.g. the newer `LanguageModelError`) is named
    /// here. `unsupportedGuide` and `decodingFailure` (structured-generation
    /// errors; this provider never asks for a schema) and anything else —
    /// including a `GenerationError` case a future SDK adds — fall through
    /// to `default`.
    private static func map(_ error: Error) -> ProviderError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .invalidResponse(Self.unexpectedErrorDetail)
        }
        switch generationError {
        case .exceededContextWindowSize:
            return .contextTooLong
        case .guardrailViolation, .refusal:
            return .declined
        case .unsupportedLanguageOrLocale:
            return .unavailable(reason: OnDeviceMessages.unsupportedLanguage)
        case .rateLimited, .concurrentRequests:
            return .unavailable(reason: OnDeviceMessages.busy)
        case .assetsUnavailable:
            // Same user-facing message as `OnDeviceAvailability
            // .modelNotReady` — the model's assets aren't ready, whether
            // that's discovered up front (the availability check) or only
            // once generation was actually attempted.
            return .unavailable(reason: OnDeviceMessages.modelNotReady)
        default:
            return .invalidResponse(Self.unexpectedErrorDetail)
        }
    }
}
