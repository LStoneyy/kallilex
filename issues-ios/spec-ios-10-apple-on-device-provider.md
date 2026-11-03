# Spec ios-10 — Apple on-device model provider

Status: ready-for-agent
Phase: Phase 4 (Apple models)
Depends on: ios-05, ios-06

## Problem Statement

The iOS app must support Apple Intelligence's on-device Foundation Model via
the FoundationModels framework. The model is free, requires no API key, runs
on eligible devices, and has a small context window. The app must check
availability before offering it, pre-check context size (on iOS 26.4+),
map errors to the provider taxonomy, and show availability status in the UI.
Spike ios-01 (unknown 3) confirmed the model works inside the Share
Extension, so ios-10 implements a single code path shared by the app and
the extension.

## Solution

Implement `AppleOnDeviceProvider: TextProvider` using `FoundationModels`'s
`SystemLanguageModel`. Check availability, measure context, and map errors.
Wrap `SystemLanguageModel` and session creation behind small protocols so
tests inject fakes. Offer the on-device profile only on eligible devices,
and show availability status instead of URL/key/headers fields in the UI
(ios-06). The on-device profile behaves identically in the app and in the
Share Extension; no extension-specific branch is needed.

## User Stories

1. As an eligible user, I want the on-device model to appear as a provider
   option so that I can use Kallilex without an API key.
2. As a user on an ineligible device, I want Kallilex to not offer the
   on-device model, so that I know to use another provider.
3. As a user with Apple Intelligence disabled, I want to see why the
   on-device model is unavailable so that I can turn it on.
4. As a user whose device doesn't support the model yet, I want to see its
   availability status so that I know it's downloading or not yet ready.
5. As a developer, I want the on-device provider to check context size before
   sending a request, so that users see an upfront "too long" message instead
   of a model refusal.
6. As a developer, I want guardrail violations to map to `.declined` so that
   the UI can tell the user the model refused, not that the request failed.
7. As a developer, I want to inject fake availability and session objects for
   testing without a real model.
8. As a user in the Share Extension, I want the on-device model to work
   exactly as it does in the app, so that I don't need to switch to the app
   for on-device rewrites.
9. As a user running an on-device rewrite, I want to see progress and have a
   Cancel button, so that a ~10-second rewrite doesn't feel stuck.

## Implementation Decisions

### AppleOnDeviceProvider

**File:** `KallilexKit/Sources/KallilexKit/Providers/AppleOnDeviceProvider.swift`

```swift
struct AppleOnDeviceProvider: TextProvider {
    let model: any OnDeviceModel
    
    init(model: any OnDeviceModel = DefaultOnDeviceModel())
    
    func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String  // ProviderError or CancellationError (see ios-05)
}
```

Behavior:
- Check `model.availability` before doing anything; if not `.available`,
  map the reason to a localized `unavailable(reason)` message and return.
- Run the context check (below). If it would exceed the context size,
  return `contextTooLong` without sending a request.
- Create a new `OnDeviceSession(model: model, instructions: systemPrompt)`.
- Call `session.respond(to: userText)`.
- Apply `stripPadding` (from ios-05) to the result.
- Map errors: `exceededContextWindowSize` → `contextTooLong`, guardrail
  refusal (document the exact error type once the SDK is checked) →
  `declined`, unsupported language / locale → `unavailable(.unsupportedLanguage)`,
  rate limited / busy → `unavailable(.busy)`, anything else →
  `invalidResponse(description)`.

### Context check

Spike ios-01 measured `usage.input.totalTokenCount` as 54 tokens higher than
`tokenCount(for:)` of the prompt alone, consistently across all three runs.
Reserve 64 tokens for that session overhead (a few tokens of headroom over
the measured 54):

1. Build the full prompt (`systemPrompt` + `userText`, per ios-05's
   assembly rules).
2. On iOS 26.4+, call `model.tokenCount(for: prompt)` to get the input
   token count.
3. Compute `total = inputTokenCount + 64 (overhead reserve) + outputReserve`.
   This provider has no separate output-length setting, so the output
   reserve is the input token count itself, capped at 1024.
4. If `total > model.contextSize`, return `contextTooLong` without sending
   a request.
5. On iOS 26.0–26.3, `tokenCount(for:)` is unavailable. Fall back to a
   character-based estimate (`systemPrompt.count + userText.count`, a
   rough Unicode-scalar approximation of token count) in the same formula,
   and rely on the model's `exceededContextWindowSize` error as a backstop
   if the estimate is too optimistic.

### Protocols for testing

Abstract the model and session behind small protocols:

```swift
protocol OnDeviceModel: Sendable {
    var availability: SystemLanguageModel.Availability { get async }
    var contextSize: Int { get async }
    /// `nil` on iOS 26.0–26.3, where `tokenCount(for:)` is unavailable.
    func tokenCount(for text: String) async throws -> Int?
}

struct DefaultOnDeviceModel: OnDeviceModel {
    var availability: SystemLanguageModel.Availability {
        get async { SystemLanguageModel.default.availability }
    }
    
    // `SystemLanguageModel.default.contextSize: Int`, `@backDeployed` to
    // iOS 26.0 (not device-tested on iOS 26). Verified against the Xcode 27.2 SDK's
    // FoundationModels.swiftinterface.
    var contextSize: Int {
        get async { SystemLanguageModel.default.contextSize }
    }
    
    // `SystemLanguageModel.default.tokenCount(for:) async throws -> Int`,
    // iOS 26.4+. `String` is accepted directly.
    func tokenCount(for text: String) async throws -> Int? {
        guard #available(iOS 26.4, *) else { return nil }
        return try await SystemLanguageModel.default.tokenCount(for: text)
    }
}

protocol OnDeviceSession: Sendable {
    func respond(to: String) async throws -> String
}

struct DefaultOnDeviceSession: OnDeviceSession {
    // `LanguageModelSession(instructions:)`
    let session: LanguageModelSession
    
    func respond(to text: String) async throws -> String {
        // `session.respond(to: String) async throws ->
        // LanguageModelSession.Response<String>`; unwrap `.content`.
        let response = try await session.respond(to: text)
        if #available(iOS 27.0, *) {
            // `Response.usage` is iOS 27.0+ only, and optional for v1:
            // it is not required for the context check, which uses
            // `tokenCount(for:)` instead. Available for future telemetry.
            _ = response.usage
        }
        return response.content
    }
}
```

Real model calls only in a manual test plan on an eligible device. Fakes are
used for all automated tests (unit tests in CI).

### Profile configuration for on-device model

The on-device profile (when offered) has:
- `kind: .appleOnDevice`
- `baseUrl: ""` (unused)
- `model: ""` (unused)
- `hasApiKey: false` (no key needed)
- `privacyClass: .onDevice` (never needs consent)

At most one such profile exists in the profile list. The preset is only
offered unless `SystemLanguageModel.default.availability` is
`.unavailable(.deviceNotEligible)`. If unavailable for other reasons
(`.appleIntelligenceNotEnabled`, `.modelNotReady`), the preset is still
offered but the profile shows an availability status row when created.

### UI: availability status row

**Implemented in ios-06**, but specified here: in the Providers screen,
when a profile's `kind == .appleOnDevice`:
- Show an availability status row instead of URL, model, key, and custom
  headers fields.
- If available, show "Ready".
- If not available, show the reason and a user-friendly hint:
  - `.deviceNotEligible`: "This device doesn't support Apple Intelligence."
  - `.appleIntelligenceNotEnabled`: "Turn on Apple Intelligence in Settings."
  - `.modelNotReady`: "The model is still downloading or not yet ready."
  - Unknown reasons (`@unknown default`): a generic message.

This row is informational only (not editable).

### Extension behavior

Spike ios-01 (unknown 3) confirmed the on-device model works inside the
Share Extension on iOS 27.0.1. It runs in a system process, not in-process:
the extension's memory footprint grew by only 2–5 MB during inference,
which is far less than a language model would need in-process. A ~300-word
rewrite took about 10.6 s; a short text took about 2 s.

The on-device profile works identically in the app and in the extension.
Both can see and use the same profile, it has no extension-specific
restrictions, and no special handling (no runtime check, no inline "only
available in the app" card) is needed. `AppleOnDeviceProvider` and
`ActionRunner` run the same code path regardless of where the process
hosting them lives.

Because a full on-device rewrite takes about 10 s, the visible progress
state and Cancel button from ios-08 are essential for on-device runs, in
both the app and the extension.

### Error mapping

**Availability mapping.** Verified against the Xcode 27.2 SDK's
`FoundationModels.swiftinterface`: `SystemLanguageModel.Availability` has
exactly two cases, `.available` and `.unavailable(reason)`, where `reason`
is `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, or
`.modelNotReady`.

```swift
extension SystemLanguageModel.Availability {
    var providerError: ProviderError? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This device doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings.")
            case .modelNotReady:
                return .unavailable("The model is still downloading or not yet ready.")
            @unknown default:
                return .unavailable("Apple Intelligence is not available.")
            }
        }
    }
}
```

**`LanguageModelSession` errors:**

- `exceededContextWindowSize` → `contextTooLong`
- Guardrail refusal (**To confirm:** exact error type and property names;
  likely a `GenerationError` case; spike ios-01 did not verify this) →
  `declined`
- Unsupported language or locale → `unavailable(.unsupportedLanguage)`
- Rate limited / concurrent requests → `unavailable(.busy)`
- Anything else → `invalidResponse(error.localizedDescription)`

**Verified symbols** (spike ios-01, against the Xcode 27.2 SDK's
`FoundationModels.swiftinterface`):

- `SystemLanguageModel.default.availability: SystemLanguageModel.Availability`
  (cases above)
- `SystemLanguageModel.default.contextSize: Int` (`@backDeployed` to iOS 26.0
  in the SDK interface, returning 4096 before iOS 27; not device-tested on
  iOS 26)
- `SystemLanguageModel.default.tokenCount(for:) async throws -> Int`
  (iOS 26.4+; `String` is accepted directly)
- `LanguageModelSession(instructions:)`
- `session.respond(to: String) async throws ->
  LanguageModelSession.Response<String>`, with `.content`
- `Response.usage` (iOS 27.0+ only; stays behind `#available(iOS 27.0, *)`
  and is optional for v1)

**Not verified:** the guardrail/refusal error types noted above. Confirm
the exact error type and property names once a refusal can be triggered on
a real device.

### Manual test plan

Since the on-device provider cannot be tested in CI (it needs a real model
on a real eligible device), document a manual test plan:

- **Availability status:** on an eligible device with Apple Intelligence
  enabled, open the Providers screen and add an on-device profile. Verify
  it shows "Ready".
- **Availability disabled:** turn off Apple Intelligence in Settings; restart
  the app; verify the availability status shows "Turn on Apple Intelligence"
  and the preset is still offered.
- **Availability unavailable (downloading):** on a fresh eligible device
  still downloading the model, verify it shows "The model is downloading".
- **Successful request:** in English, run a prompt (~100 words) and verify
  the result. Run in German and verify the result (quality may be lower).
- **Too-long input:** enter a very long text (~5000 words); on iOS 26.4+,
  verify "too long" is returned without a request; on iOS < 26.4, verify
  the model refuses with "context exceeded".
- **Airplane mode:** enable airplane mode (no network needed for on-device).
  Run a prompt. Verify it succeeds (no network required).
- **Ineligible device:** on an ineligible device (or a simulator without the
  model), verify the on-device preset is not offered and "device not
  eligible" is the message if an on-device profile is manually created.

## Out of Scope

- Private Cloud Compute (iOS 27+, decided Q4). Implement with the same
  `TextProvider` seam when the PCC entitlement is available.
- Streaming output. The model returns text; streaming is a later enhancement.
- Structured generation or tool calling.
- Multilingual output quality (English is primary; German support comes with
  ios-11).

## Further Notes

- PLAN.md §2, §4.3, §7.3 and §17–18 describe the on-device model and
  extension behavior.
- PLAN.md §18 Q4 confirms that only the on-device model ships in v1;
  Private Cloud Compute is deferred.
- Spike ios-01 unknown 3 confirmed the model works in the Share Extension,
  at the cost of about 2–5 MB of extra memory and roughly 2–10.6 s of
  latency depending on text length; see "Extension behavior" above.
- The availability variants, `contextSize`, `tokenCount(for:)`, and the
  `LanguageModelSession` call shape are verified against the Xcode 27.2
  SDK's `FoundationModels.swiftinterface` (spike ios-01). The guardrail
  and refusal error types are still unverified; confirm them once a
  refusal can be triggered on a real device.
- The iOS 26 SDK provides a `SystemLanguageModel`, and iOS 26.4+ adds
  `tokenCount(for:)`. `contextSize` is `@backDeployed` to iOS 26.0 per the
  SDK interface (not device-tested on iOS 26).
  `Response.usage` is iOS 27.0+ only.
- Because a full on-device rewrite takes about 10 s (spike ios-01), the
  progress state and Cancel button from ios-08 are essential for on-device
  runs; this applies in the app and the extension alike.
