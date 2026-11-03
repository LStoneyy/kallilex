# Spec ios-10 — Apple on-device model provider

Status: ready-for-agent
Phase: Phase 4 (Apple models)
Depends on: ios-05, ios-06, spike ios-01 (unknown 3)

## Problem Statement

The iOS app must support Apple Intelligence's on-device Foundation Model via
the FoundationModels framework. The model is free, requires no API key, runs
on eligible devices, and has a small context window. The app must check
availability before offering it, pre-check context size (on iOS 26.4+),
map errors to the provider taxonomy, and show availability status in the UI.
The extension's access to the on-device model is undocumented; the spike
must report whether it works, and ios-10 must implement both branches.

## Solution

Implement `AppleOnDeviceProvider: TextProvider` using `FoundationModels`'s
`SystemLanguageModel`. Check availability, measure context, and map errors.
Wrap `SystemLanguageModel` and session creation behind small protocols so
tests inject fakes. Offer the on-device profile only on eligible devices,
and show availability status instead of URL/key/headers fields in the UI
(ios-06). Handle extension unavailability with two code branches: one if the
model works in extensions, one if it doesn't.

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
8. As a user in the extension, I want to be told if the on-device model is
   only available in the app (if it cannot run in extensions), so that I can
   open the app.

## Implementation Decisions

### AppleOnDeviceProvider

**File:** `KallilexKit/Sources/KallilexKit/Providers/AppleOnDeviceProvider.swift`

```swift
struct AppleOnDeviceProvider: TextProvider {
    let model: OnDeviceModel
    
    init(model: OnDeviceModel = .default)
    
    func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String  // ProviderError or CancellationError (see ios-05)
}
```

Behavior:
- Check `model.availability` before doing anything; if not `.available`,
  map the reason to a localized `unavailable(reason)` message and return.
- On iOS 26.4+, call `model.contextSize()` to get the token limit (or a
  best-guess fallback). Pre-check `systemPrompt.count + userText.count` (a
  rough Unicode-scalar approximation; if the SDK provides token counting,
  use that). If it would exceed the limit, return `contextTooLong` without
  sending a request.
- On iOS < 26.4, skip the pre-check and rely on the `exceededContextWindowSize`
  error from the model.
- Create a new `OnDeviceSession(model: model, instructions: systemPrompt)`.
- Call `session.respond(to: userText)`.
- Apply `stripPadding` (from ios-05) to the result.
- Map errors: `exceededContextWindowSize` → `contextTooLong`, guardrail
  refusal (document the exact error type once the SDK is checked) →
  `declined`, unsupported language / locale → `unavailable(.unsupportedLanguage)`,
  rate limited / busy → `unavailable(.busy)`, anything else →
  `invalidResponse(description)`.

### Protocols for testing

Abstract the model and session behind small protocols:

```swift
protocol OnDeviceModel: Sendable {
    var availability: SystemLanguageModel.Availability { get async }
    func contextSize() async throws -> Int?
}

struct DefaultOnDeviceModel: OnDeviceModel {
    var availability: SystemLanguageModel.Availability {
        get async { SystemLanguageModel.default.availability }
    }
    
    func contextSize() async throws -> Int? {
        // iOS 26.4+ only; check the SDK for the exact API.
        // **To confirm:** exact symbol names in the iOS 26.4 SDK
        // (e.g., contextWindowSize, maxTokens, etc.)
        try? SystemLanguageModel.default.contextWindowSize()
    }
}

protocol OnDeviceSession: Sendable {
    func respond(to: String) async throws -> String
}

struct DefaultOnDeviceSession: OnDeviceSession {
    let session: LanguageModelSession
    
    func respond(to text: String) async throws -> String {
        try await session.respond(to: text)
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
offered when `SystemLanguageModel.default.availability != .deviceNotEligible`
(state the exact check). If unavailable for other reasons (not enabled,
downloading, etc.), the preset is still offered but the profile shows an
availability status row when created.

### UI: availability status row

**Implemented in ios-06**, but specified here: in the Providers screen,
when a profile's `kind == .appleOnDevice`:
- Show an availability status row instead of URL, model, key, and custom
  headers fields.
- If available, show "Ready".
- If not available, show the reason and a user-friendly hint:
  - `deviceNotEligible`: "This device doesn't support Apple Intelligence."
  - `notEnabled`: "Turn on Apple Intelligence in Settings."
  - `notAvailable`: "The model is still downloading or not yet ready."
  - Unknown reasons: a generic message.

This row is informational only (not editable).

### Extension behavior: two branches

The spike (ios-01 unknown 3) determines whether the on-device model is
usable in the Share Extension. ios-10 implements both branches:

#### Branch A: Model works in extensions

If `SystemLanguageModel` is available and works in the extension, no special
handling is needed. The extension runs prompts just like the app. Both app
and extension can see and use the same on-device profile (it has no
extension-specific restrictions). Implement normally.

#### Branch B: Model unavailable in extensions

If the model is not usable in the Share Extension (whether always or when
certain conditions apply — the spike report determines this), the extension
must tell the user:

**Inline card in the extension** (when the active profile is on-device and
the model is not available):

```
The on-device model is only available in the Kallilex app.
Use the Scratchpad in the app or set up another provider.
```

No request is sent. The user is guided to use the app's Scratchpad (PLAN.md
§17) instead.

Determine "are we in the extension" at runtime, not with a build flag, so
the same binary works correctly and the check is injectable for tests:

**File:** `KallilexKit/Sources/KallilexKit/Core/RuntimeContext.swift`

```swift
enum RuntimeContext {
    /// `true` when running inside an app extension (e.g. the Share
    /// Extension), `false` in the container app. Extension bundles always
    /// end in `.appex`.
    static var isAppExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }
}
```

`ActionRunner` (ios-05) takes an `isAppExtension: Bool = RuntimeContext.isAppExtension`
init parameter so tests can inject either value without touching the real
bundle. Implement the branch check as: in `ActionRunner.run`, before calling
the provider, if the profile is `appleOnDevice` and `isAppExtension` is true,
check whether the model is available. If not, return a dedicated error or a
new `RunOutcome` variant (specify which; alternatively, map it to
`.consentRequired` and special-case the display in ios-06).

Write both branches in the code with clear comments; the implementer picks
one based on the spike report. Example structure:

```swift
// Branch A: uncomment if model works in extensions
// let outcome = try await provider.complete(...)

// Branch B: uncomment if model does not work in extensions
// if isAppExtension && profile.kind == .appleOnDevice {
//     return .failed(.unavailable("model_not_in_extension"))
// }
```

Add unit tests for both branches by constructing `ActionRunner` with
`isAppExtension: true` and `isAppExtension: false` and asserting the
on-device profile is handled correctly in each case (Branch A: the request
proceeds; Branch B: a "model not in extension" error is returned without
calling the provider).

### Error mapping

**Availability mapping (exact API names to confirm from SDK):**

```swift
extension SystemLanguageModel.Availability {
    var providerError: ProviderError? {
        switch self {
        case .available:
            return nil
        case .notAvailable:
            return .unavailable("The model is downloading or not yet available.")
        case .notEnabled:
            return .unavailable("Turn on Apple Intelligence in Settings.")
        case .deviceNotEligible:
            return .unavailable("This device doesn't support Apple Intelligence.")
        @unknown default:
            return .unavailable("Apple Intelligence is not available.")
        }
    }
}
```

**`LanguageModelSession` errors:**

- `exceededContextWindowSize` → `contextTooLong`
- Guardrail refusal (**To confirm:** exact error type and property names;
  likely a `GenerationError` case) → `declined`
- Unsupported language or locale → `unavailable(.unsupportedLanguage)`
- Rate limited / concurrent requests → `unavailable(.busy)`
- Anything else → `invalidResponse(error.localizedDescription)`

**To confirm:** exact symbol names and error types in the FoundationModels
SDK for iOS 26.4+ (context size API, error cases, availability variants).

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
- The spike ios-01 unknown 3 answers whether the model works in Share
  Extensions. Both branches must be written with clear comments indicating
  which to use based on the spike report.
- Apple's FoundationModels documentation is the reference for availability
  variants, error types, and context-size APIs. The exact symbol names need
  confirmation from the iOS 26.4 SDK.
- The iOS 26 SDK provides a `SystemLanguageModel`, and iOS 26.4+ adds
  context-size APIs. Document the version cutoff.
