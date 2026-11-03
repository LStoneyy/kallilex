# Spec ios-05 — KallilexKit: prompt assembly, privacy class, OpenAI-compatible provider, ActionRunner

Status: ready-for-agent
Phase: Phase 1 (Foundation)
Depends on: ios-03, ios-04

## Problem Statement

The iOS app must assemble prompts byte-identically to the desktop, classify
endpoint privacy from URLs (loopback, private IP, cloud), send requests to
OpenAI-compatible endpoints with the correct headers and error handling,
implement a TextProvider abstraction that covers both HTTP providers and
Foundation Models, and orchestrate the full run-action flow with consent
checks and task cancellation.

## Solution

Port prompt assembly and privacy classification from `src-tauri/src/core`
exactly, using contract fixtures as the arbiter. Implement `TextProvider`
as a protocol. Port `OpenAiCompatibleProvider` from `openai.rs` with
`URLSession` (ephemeral config) instead of `reqwest`. Implement `ActionRunner`
orchestration. Use typed throws for errors and mark Apple-specific provider
errors as extensions.

## User Stories

1. As a developer, I want prompt assembly to match the desktop exactly, so
   that a rewrite of "hello" produces the same result on both platforms.
2. As a developer, I want to classify a URL's privacy (cloud, LAN, local,
   on-device) without DNS resolution, so that I can decide whether consent is
   required before making a request.
3. As a developer, I want the OpenAI-compatible provider to send the exact
   request shape (headers, timeout, bearer token, model in body), so that
   it works with any OpenAI-compatible server (local Ollama, OpenAI, LM
   Studio).
4. As a developer, I want the provider to truncate HTTP error snippets the
   same way the desktop does, so that huge error responses don't flood the
   UI.
5. As a developer, I want response padding stripped identically to the
   desktop (leading blank lines and trailing whitespace gone, first line's
   indentation kept), so that formatting is preserved.
6. As a developer, I want to inject a custom URLSession and provider for
   testing, so that I can stub HTTP responses without a real server.
7. As a developer, I want cancellation to propagate through the provider
   call and surface as `.cancelled`, so that the UI's Cancel button works.
8. As a developer, I want the ActionRunner to check consent, read keys only
   when `hasApiKey` is set, and degrade gracefully on key-read failures, so
   that local models work even when the Keychain is slow or broken.
9. As a developer, I want a `testConnection` method that sends a minimal
   request without needing consent, so that the Providers screen can verify
   setup before going live.
10. As a developer, I want presets (Apple on-device, OpenAI, Ollama, LM
    Studio, Custom) so that users have a quick start without typing URLs.

## Implementation Decisions

### Prompt assembly

**File:** `KallilexKit/Sources/KallilexKit/Core/PromptAssembly.swift`

```swift
struct PromptAssembly {
    static let returnOnlyTextInstruction =
        "Return only the transformed text, with no preamble, commentary, "
        + "or surrounding quotes. Preserve the text's original language. "
        + "Preserve the text's structure and formatting exactly: keep "
        + "paragraph breaks, line breaks, list markers, indentation, and "
        + "any markup characters (e.g. Markdown) that appear in the input."
    
    static func systemPrompt(for action: Action) -> String {
        switch action {
        case .prompt(let instruction):
            return "\(instruction) \(returnOnlyTextInstruction)"
        case .custom(let instruction):
            return "Apply the following instruction to the user's text: "
                + "\(instruction) \(returnOnlyTextInstruction)"
        }
    }
}

enum Action: Equatable, Sendable {
    case prompt(instruction: String)
    case custom(instruction: String)
}
```

The text always travels as a separate user message, never folded into the
system prompt. Load the exact instruction from `contracts/return-only-text-instruction.txt`
to keep it in sync with the desktop.

### Privacy classification

**File:** `KallilexKit/Sources/KallilexKit/Core/PrivacyClass.swift`

```swift
enum PrivacyClass: String, Codable, Equatable, Sendable {
    case local      // loopback, localhost
    case lan        // private/link-local IPs, .local/.lan/.home/.internal, single-label
    case cloud      // public IPs and domains
    case onDevice   // Apple Foundation Model
}

func classifyPrivacy(baseUrl: String) -> PrivacyClass? {
    guard let url = URL(string: baseUrl),
          let host = url.host(percentEncoded: false) else {
        return nil
    }
    // IPv4: parse with IPv4Address (Network) only to get the raw bytes;
    // the ranges below are hand-rolled to match Rust std's
    // `Ipv4Addr::is_loopback`/`is_private`/`is_link_local` (used by the
    // desktop core), not Network's own `isPrivate`/`isLinkLocal`, which
    // draw slightly different boundaries.
    if let ipv4 = IPv4Address(host) {
        return classifyIPv4(ipv4.rawValue)
    }
    // IPv6: same approach via IPv6Address's raw bytes; `isUniqueLocal`
    // and `isLinkLocal` are not used, to mirror Rust std's
    // `Ipv6Addr::is_loopback` (only `::1`) and its `fc00::/7`/`fe80::/10`
    // ranges exactly. IPv4-mapped IPv6 addresses are not unmapped to
    // IPv4 first; they're classified as plain IPv6.
    if let ipv6 = IPv6Address(host) {
        return classifyIPv6(ipv6.rawValue)
    }
    // Domain: classify by suffix and labels
    let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if lower == "localhost" || lower.hasSuffix(".localhost") {
        return .local
    }
    if lower.hasSuffix(".local") || lower.hasSuffix(".lan")
        || lower.hasSuffix(".home") || lower.hasSuffix(".internal") {
        return .lan
    }
    if !lower.contains(".") { // single-label hostnames
        return .lan
    }
    return .cloud
}

private func classifyIPv4(_ rawValue: Data) -> PrivacyClass {
    let b = [UInt8](rawValue)
    if b[0] == 127 { return .local }                     // 127.0.0.0/8
    if b[0] == 10 { return .lan }                         // 10.0.0.0/8
    if b[0] == 172 && (b[1] & 0xF0) == 16 { return .lan } // 172.16.0.0/12
    if b[0] == 192 && b[1] == 168 { return .lan }         // 192.168.0.0/16
    if b[0] == 169 && b[1] == 254 { return .lan }         // 169.254.0.0/16
    return .cloud
}

private func classifyIPv6(_ rawValue: Data) -> PrivacyClass {
    let b = [UInt8](rawValue)
    if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 {
        return .local                                      // ::1 only
    }
    if (b[0] & 0xFE) == 0xFC { return .lan }                // fc00::/7
    if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .lan } // fe80::/10
    return .cloud
}
```

Contract fixtures (`contracts/privacy-classification.json`) are the arbiter.
Where Foundation's `URL.host` parsing differs from Rust's `url::Url`, adjust
Swift to match the fixtures.

### Consent host

`consentHost(for:)` is defined in ios-04 (`Models/ConsentHost.swift`). This
spec uses it in `ActionRunner` for the consent check; it is the only way a
consent host is computed anywhere.

### Provider error taxonomy

**File:** `KallilexKit/Sources/KallilexKit/Core/ProviderError.swift`

```swift
enum ProviderError: Error, Equatable, Sendable {
    case unreachable(String)
    case timeout(Int)
    case http(status: Int, snippet: String)
    case missingModel
    case invalidBaseUrl(String)
    case invalidResponse(String)
    case unavailable(reason: String)      // on-device unavailable
    case contextTooLong
    case declined                          // guardrail rejection
    case localNetworkDenied
}

extension ProviderError {
    /// Stable machine-readable discriminant for frontend matching.
    var kind: String {
        switch self {
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .http: "http"
        case .missingModel: "missingModel"
        case .invalidBaseUrl: "invalidBaseUrl"
        case .invalidResponse: "invalidResponse"
        case .unavailable: "unavailable"
        case .contextTooLong: "contextTooLong"
        case .declined: "declined"
        case .localNetworkDenied: "localNetworkDenied"
        }
    }
}

extension ProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return String(localized: "error.unreachable \(detail)", bundle: .module)
        case .timeout(let secs):
            return String(localized: "error.timeout \(secs)", bundle: .module)
        case .http(let status, let snippet):
            return String(localized: "error.http \(status) \(snippet)", bundle: .module)
        case .missingModel:
            return String(localized: "error.missingModel", bundle: .module)
        case .invalidBaseUrl(let detail):
            return String(localized: "error.invalidBaseUrl \(detail)", bundle: .module)
        case .invalidResponse(let detail):
            return String(localized: "error.invalidResponse \(detail)", bundle: .module)
        case .unavailable(let reason):
            return String(localized: "error.unavailable \(reason)", bundle: .module)
        case .contextTooLong:
            return String(localized: "error.contextTooLong", bundle: .module)
        case .declined:
            return String(localized: "error.declined", bundle: .module)
        case .localNetworkDenied:
            return String(localized: "error.localNetworkDenied", bundle: .module)
        }
    }
}
```

User-facing messages: every case has an actionable `String(localized:)` key
here (English), with German strings added in ios-11. Messages never just say
"failed". `ProviderError` conforms to `LocalizedError` so UI code (ios-06,
ios-08, ios-09) displays `error.localizedDescription` instead of defining
its own per-case mapping.

### TextProvider protocol

```swift
protocol TextProvider: Sendable {
    func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String  // ProviderError or CancellationError
}
```

Untyped `throws`, by decision: a typed `throws(ProviderError)` cannot
also carry Swift's `CancellationError`, and cancellation must stay
distinguishable from a provider failure. The contract is: a provider throws
either a `ProviderError` or a `CancellationError`, nothing else. It calls
`try Task.checkCancellation()` before sending and maps
`URLError.cancelled` to `CancellationError`; any other unexpected error is
wrapped as `ProviderError.invalidResponse(String(describing:))`. The
`ActionRunner` catches `CancellationError` first (→ `.cancelled`), then
`ProviderError` (→ `.failed`).

### OpenAI-compatible provider

**File:** `KallilexKit/Sources/KallilexKit/Providers/OpenAICompatibleProvider.swift`

```swift
struct OpenAICompatibleProvider: TextProvider {
    let profile: ProviderProfile
    let apiKey: String?
    let session: URLSession
    
    init(
        profile: ProviderProfile,
        apiKey: String?,
        session: URLSession
    )
    
    func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String  // ProviderError or CancellationError
}
```

Behavior (port from `openai.rs` exactly):
- **Endpoint building:** parse `baseUrl` with `URL(string:)`, reject
  non-http/https schemes, trim trailing slashes, append `/chat/completions`.
  Invalid base URL checked before missing model.
- **Missing model:** when `profile.model.trimmingCharacters(in: .whitespaces)`
  is empty, return `missingModel` before any request is sent.
- **Request building:** POST to the endpoint with:
  ```
  {
    "model": profile.model,
    "messages": [
      {"role": "system", "content": systemPrompt},
      {"role": "user", "content": userText}
    ],
    "stream": false
  }
  ```
- **Timeout:** `URLRequest.timeoutInterval = profile.timeoutSecs` (seconds).
- **Headers:** add `Authorization: Bearer <key>` when a key is given, then
  apply custom headers. Skip headers whose name is empty or not an RFC 7230
  token (matches `HeaderName::from_bytes` in reqwest), or whose value
  contains characters outside tab and 0x20–0x7E. Invalid headers are
  silently skipped, not errors.
- **Response parsing:** on success (2xx), deserialize the JSON body; extract
  `choices[0].message.content` (exact messages from contract fixtures:
  "response contained no choices", "message content was missing or null");
  call `stripPadding` on the text. Invalid JSON: `invalidResponse("invalid JSON: \(error)")`.
- **Non-2xx responses:** return `http(status, snippet)` with the body
  truncated to 300 Unicode scalars.
- **URLError mapping:** `.timedOut` → `timeout(profile.timeoutSecs)`,
  `.cancelled` → propagate as `CancellationError`, others →
  `unreachable(localizedDescription)`.
- **Local network error (from ios-01 spike):** write as "map the error
  identified in spike-ios-01-report.md (unknown 2); if it cannot be
  distinguished, fall back to `unreachable` and drop `localNetworkDenied`".

Helper function:

```swift
func stripPadding(_ content: String) -> String {
    let u = content.unicodeScalars
    guard let first = u.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    let lineStart = u[..<first].lastIndex(of: "\n").map { u.index(after: $0) } ?? u.startIndex
    var end = u.endIndex
    while end > lineStart, u[u.index(before: end)].properties.isWhitespace {
        end = u.index(before: end)
    }
    return String(u[lineStart..<end])
}
```

This implementation operates on Unicode scalars so `\r\n` behaves like Rust, and
`Unicode.Scalar.Properties.isWhitespace` is the same White_Space property as
Rust's `char::is_whitespace`. It drops leading blank lines, keeps the first
content line's indentation, and drops all trailing whitespace (including
newlines). Snippet truncation is `String(body.unicodeScalars.prefix(300))`
(counts Unicode scalars like Rust's `char`s).

### RunOutcome and ActionRunner

**File:** `KallilexKit/Sources/KallilexKit/Core/ActionRunner.swift`

```swift
enum RunOutcome: Equatable, Sendable {
    case ok(String)
    case notConfigured
    case consentRequired(ProviderProfile)
    case cancelled
    case failed(ProviderError)
}

struct ActionRunner {
    let settings: SettingsStore
    let secrets: SecretStore
    let makeProvider: @Sendable (
        ProviderProfile,
        String?
    ) -> any TextProvider
    let isAppExtension: Bool
    
    init(
        settings: SettingsStore,
        secrets: SecretStore,
        makeProvider: @escaping @Sendable (
            ProviderProfile,
            String?
        ) -> any TextProvider,
        isAppExtension: Bool = RuntimeContext.isAppExtension
    )
    
    func run(text: String, action: Action) async -> RunOutcome
    func testConnection(
        profile: ProviderProfile,
        apiKey: String?
    ) async -> Result<Void, ProviderError>
}
```

`isAppExtension` defaults to `RuntimeContext.isAppExtension` (ios-10) and is
injectable so tests can exercise both the app and extension branches of the
on-device model's extension-availability check without touching the real
bundle.

Behavior for `run`:
- Load settings fresh each time (no cache).
- Resolve active profile: find the id in `settings.activeProfileID`, match it
  in `settings.profiles`, and verify `enabled == true`. If not found or
  disabled, return `.notConfigured`.
- Check consent: if `classifyPrivacy(profile.baseUrl) == .cloud` and the
  profile is `openAICompatible`, check `hasConsent(profileID, host)` (where
  host is the parsed baseUrl host). If no consent, return
  `.consentRequired(profile)`.
- Read API key: only when `profile.hasApiKey` is true, call
  `secrets.get(profileID:)`. If it throws, swallow the error and treat as
  no key (desktop semantics: local models may not need one).
- Call provider: invoke `makeProvider(profile, key)` and call
  `complete(systemPrompt:userText:)`. On `CancellationError` (or when
  the task is cancelled), return `.cancelled`. On `ProviderError`, return
  `.failed(error)`. On success, return `.ok(text)`.

Behavior for `testConnection`:
- Does not check consent (no user text is sent, just a system prompt).
- Sends system prompt "Reply with the single word OK." and user text "Hello".
- Returns `.success(())` or `.failure(error)` from the provider.

### Provider presets

**File:** `KallilexKit/Sources/KallilexKit/Providers/ProviderPresets.swift`

```swift
struct ProviderPreset: Equatable, Sendable {
    let id: String
    let label: String
    let kind: ProviderKind
    let baseUrl: String
    let needsApiKey: Bool
}

func providerPresets() -> [ProviderPreset] {
    [
        ProviderPreset(
            id: "appleOnDevice",
            label: String(localized: "provider.apple.onDevice", bundle: .module),
            kind: .appleOnDevice,
            baseUrl: "",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "openai",
            label: "OpenAI",
            kind: .openAICompatible,
            baseUrl: "https://api.openai.com/v1",
            needsApiKey: true
        ),
        ProviderPreset(
            id: "ollama",
            label: "Ollama on your Mac",
            kind: .openAICompatible,
            baseUrl: "http://your-mac.local:11434/v1",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "lmstudio",
            label: "LM Studio on your Mac",
            kind: .openAICompatible,
            baseUrl: "http://your-mac.local:1234/v1",
            needsApiKey: false
        ),
        ProviderPreset(
            id: "custom",
            label: String(localized: "provider.custom", bundle: .module),
            kind: .openAICompatible,
            baseUrl: "",
            needsApiKey: false
        ),
    ]
}
```

The Apple on-device preset is the first and is offered only when the device
is eligible (check added in ios-10). Desktop presets use `localhost`, which
is meaningless on a phone, so iOS presets use `your-mac.local` as an
example the user edits. English labels here; localization added in ios-11.

## Testing Decisions

### Contract fixtures

Load and assert all fixtures from `contracts/` via `#filePath`:
- **default-prompts.json**: `PromptDefaults.defaults(locale:)` matches on id, label
  (English), instruction.
- **prompt-assembly.json**: `PromptAssembly.systemPrompt(for:)` matches
  expected for each action.
- **return-only-text-instruction.txt**: embed the exact string.
- **privacy-classification.json**: `classifyPrivacy(baseUrl)` matches
  expected for every case, including null cases.
- **openai-endpoint.json**: endpoint building matches or errors correctly.
- **openai-request.json**: request body and headers match (use a URLProtocol
  stub to intercept and verify).
- **openai-response.json**: response parsing and padding cases match, HTTP
  errors are handled correctly, invalid JSON is caught.

### ActionRunner tests

- **Not configured:** no active profile → `.notConfigured`.
- **Disabled active profile:** active id found but `enabled == false` →
  `.notConfigured`.
- **Consent required:** profile is `.openAICompatible`, host is `.cloud`,
  no consent → `.consentRequired(profile)`.
- **Consent granted:** same setup, consent exists → request proceeds.
- **Consent invalidated by host change:** save profile with new baseUrl host,
  old consent is cleared.
- **Key read only with hasApiKey:** when `hasApiKey == false`, key is not
  read; when true, it is read (test both hit and miss).
- **Key read failure degrades:** secret store throws, key is treated as nil,
  request proceeds.
- **Cancellation:** cancel the task during the provider call; runner returns
  `.cancelled`.
- **testConnection:** sends system "Reply with the single word OK." and user
  "Hello"; no consent required.

### URLProtocol stub for OpenAI provider

Create a custom `URLProtocol` that intercepts requests and serves fixtures:

```swift
class StubURLProtocol: URLProtocol {
    static var responses: [URL: (statusCode: Int, body: String)] = [:]
    
    override class func canInit(with request: URLRequest) -> Bool {
        return responses[request.url!] != nil
    }
    
    override func startLoading() {
        guard let (status, body) = Self.responses[request.url!] else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStorageAllowed: false)
        client?.urlProtocol(self, didLoad: body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {}
}
```

## Out of Scope

- Apple on-device and Private Cloud Compute (ios-10 and later).
- Streaming responses.
- Structured generation or tool calling.
- Prompt caching.

## Further Notes

- PLAN.md §7.2–§7.5 describe prompt assembly, privacy classification, the
  OpenAI provider and ActionRunner.
- PLAN.md §12.1 describes the testing strategy.
- Desktop implementations: `src-tauri/src/core/providers/mod.rs`
  (`assemble_prompt`, `classify_privacy`, `run_action`, `active_profile`),
  `src-tauri/src/core/providers/openai.rs`, `src-tauri/src/core/prompts.rs`.
- Contract fixtures are the single source of truth for byte-exact behavior.
  Where Swift's URL or IPv6Address behavior differs from Rust's `url::Url`
  or socket code, the fixtures guide which implementation is correct.
