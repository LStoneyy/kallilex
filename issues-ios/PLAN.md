# Kallilex for iOS — Implementation Plan

Status: approved 2026-11-03; decisions in §18
Branch: `ios-plan`
Date: 2026-11-03
Scope of this folder: `issues-ios/` holds the plan and, later, the specs for
the iOS variant only. Desktop specs stay in `issues/`.

This plan is the source the iOS specs will be cut from (see
[§15 Proposed specs](#15-proposed-specs)). It records the platform research,
the product scope, the architecture decisions with their reasons, and the
order of work. The product decisions taken on 2026-11-03 are in
[§18](#18-decisions-product-owner-2026-11-03).

---

## 1. Goal

Bring Kallilex's core loop to iPhone: take some text, run one of the user's
saved prompts (or a free-form instruction) against the user's own AI
provider, and hand the result back. The app is purely a tool for editing
text with AI; it doesn't store documents and doesn't have accounts.

The desktop loop is *select → shortcut → edit → Replace/Copy*. iOS doesn't
allow an app to read another app's selection or to type into it, so the iOS
loop becomes:

> **select → Share → Kallilex → tap a prompt → Copy → paste**

All of it happens inside the share sheet, without leaving the source app.

## 2. Platform constraints (research summary)

| Mechanism | Gets the text | Writes back into the source app | Role in this plan |
|---|---|---|---|
| **Share Extension** | Yes: the selected text arrives as `public.plain-text` in `extensionContext.inputItems` | No | **Core of v1** |
| Action Extension | Yes | Only if the *host app* consumes `completeRequest(returningItems:)`. Text-selection hosts (Mail, Notes, Safari, Messages) don't | Rejected: no gain over a Share Extension |
| **Custom keyboard** | Yes: `textDocumentProxy.selectedText` (unreliable in some apps) | Yes: `insertText(_:)` | **Later, optional** (§16): the only route to automatic Replace |
| Shortcuts / App Intents | Yes: through the share sheet or a Shortcut input | No, only the clipboard | Phase 3 extra (§16) |
| Apple Writing Tools | Only inside our own text views | Only inside our own app | No third-party provider API. iOS 27 "Extensions" for third-party models is reported, not confirmed for Writing Tools, and aimed at model vendors anyway. Watch item |
| Clipboard | — | — | *Writing* to `UIPasteboard.general` shows no prompt. Only *reading* does (since iOS 16). Kallilex only writes |

Other constraints that shape the design:

- **Extension memory limit.** Share extensions run under a hard limit of
  about 120 MB and are killed above it. That rules out a WebView/Tauri UI
  inside the extension. We use plain SwiftUI and keep heavy dependencies out.
- **The extension lives only while its sheet is open.** Dismissing it cancels
  everything in flight. There are no background requests.
- **Shared data between app and extension** needs an **App Group**
  container for settings and a **Keychain access group** for API keys.
- **App Transport Security (ATS):** plain `http://` is blocked except for
  local networking (`NSAllowsLocalNetworking`). Talking to a LAN Ollama or
  LM Studio also triggers the **Local Network** permission
  (`NSLocalNetworkUsageDescription`). Both need checking in the spike (§15,
  ios-01), especially whether the extension can trigger the permission prompt
  or only the app can.
- **App Review 5.1.2(i)** (November 2025): an app must say clearly when
  personal data goes to a third-party AI and ask for explicit permission
  first. Reviewers enforce this, and a generic onboarding blurb has been
  rejected repeatedly.
- **Distribution:** outside the EU, the App Store or TestFlight is the only
  realistic path. That needs a paid Apple Developer Program membership. The
  desktop's self-signed approach has no iOS equivalent.
- **Apple Foundation Models** (iOS 26+): an on-device model, free, with no
  key, on Apple Intelligence devices. Its context is small (4 K tokens on
  iOS 26; the iOS 26.4 API reports the actual size), and output in languages
  other than English is weaker. Since iOS 27 there is also a
  **Private Cloud Compute** model: 32 K context, needs an entitlement, no
  cost for developers under 2 M first-time downloads, a daily per-user quota.
  Its availability inside app extensions is undocumented and is spike item
  ios-01.

## 3. Product scope

### v1 (first TestFlight / App Store release)

1. **Share Extension "Kallilex"** for plain text: the selected text, prompt
   chips, a custom instruction, the result, Copy, and Retry.
2. **Container app** for setup only:
   - provider profiles and the API key
   - prompts: create, edit, delete, reorder
   - general settings
   - onboarding: how to pin Kallilex in the share sheet, plus AI consent
   - a **Scratchpad**: paste text, run prompts, copy. This is the fallback
     when a host app doesn't offer Share, and it also gives App Review a demo
     path.
3. **Providers:** any OpenAI-compatible endpoint, the same model as on
   desktop: base URL, model, optional key, custom headers, timeout.
4. **Apple on-device model** as a provider that needs no key, available when
   the device supports it. Private Cloud Compute is not in v1 (decided, Q4).
5. **Localization:** English and German.
6. **iPhone first.** iPad works through the same targets (the share sheet
   exists there too), but there is no iPad-specific layout in v1.

### Non-goals for v1

- Automatic Replace or paste-back (needs the keyboard, §16).
- Sync of prompts or profiles with the desktop app or between devices
  (decided, Q3: later, as an import/export format; API keys never sync).
- A custom spell-check engine. iOS text views already underline misspellings
  and offer corrections, and that is enough.
- Shortcut chords (`Mod+1` …), popover position, update channels, Wayland
  flags and the other desktop-only settings.
- Rich text. Attributed input is reduced to plain text.
- Images, files and URLs as input. A shared URL without text gets a friendly
  "share selected text instead" message.
- In-app purchases, accounts, analytics, and a hosted Kallilex backend.

## 4. User flows

### 4.1 First run (container app)

1. **Welcome:** what Kallilex does, shown as a three-step illustration of the
   share sheet.
2. **Choose a provider.** The presets are:
   - **Apple Intelligence (on device)**, shown only when available
   - **OpenAI**
   - **Ollama on your Mac**, for example `http://<mac>.local:11434/v1`
   - **LM Studio on your Mac**
   - **Custom (OpenAI-compatible)**

   The desktop presets point at `localhost`, which is meaningless on a phone,
   so the iOS presets need a host field.
3. **API key:** only for presets that need one. The key goes straight to the
   Keychain.
4. **Test connection:** a minimal request with a clear error from the error
   taxonomy (§7.4).
5. **AI data consent** (App Review 5.1.2(i)). It's a separate screen that
   names the provider and host and says *"The text you share is sent to
   <host> to be processed."* It has an explicit **Allow** button and a
   **Not now** button. Nothing is pre-checked.
   - Consent is stored per profile, keyed by profile id and base-URL host.
   - It isn't needed for the `local` and `lan` privacy classes or the
     on-device model.
6. **Pin Kallilex to the share sheet:** a short animated guide
   (Share → More → Edit → Kallilex → add to Favorites). This step matters
   most for discoverability; the extension is useless if nobody finds it.

### 4.2 Main loop (Share Extension)

1. The user selects text in any app and taps **Share** → **Kallilex**.
2. A sheet opens. The top shows the text, editable and spell-checked by the
   system. Below it is a horizontal row of prompt chips (the saved prompts in
   order) plus **Custom…**.
3. The user taps a chip:
   - a spinner appears together with a **Cancel** button
   - when the request finishes, the result replaces the original in the
     editor, with **Show original** to compare
4. The bottom toolbar offers:
   - **Copy**: writes the text to the clipboard, shows a short "Copied"
     confirmation, then closes the sheet
   - **Retry**: runs the same prompt again on the *original* text
   - **Undo**: brings the original back
5. Back in the source app, the selection is usually still there. The user
   taps **Paste**, and the selection is replaced.

Optional speed-ups (settings, all off by default):

- **Run the first prompt automatically** when the sheet opens.
- **Copy and close automatically** when a prompt succeeds. This mirrors the
  desktop's `autoCopyResult`.

### 4.3 Error and edge flows

| Situation | Behavior |
|---|---|
| No provider configured | Inline card "Set up a provider in the Kallilex app", with a button that opens `kallilex://settings/providers` if `extensionContext.open` works from a Share Extension (§8.4, spike item 4). Otherwise it shows instruction text |
| Consent missing for a cloud profile | The consent card shows inline in the extension. Allowing it stores the consent, and the prompt runs |
| Request error | Inline message from the error taxonomy (§7.4) with Retry |
| Input empty or not text | "Kallilex needs selected text" with no prompt chips |
| Input too long | Soft warning above about 20 000 characters. On-device model: block above its context size with "too long for the on-device model" |
| Sheet dismissed during a request | The request task is cancelled and nothing is copied |
| On-device model unavailable (device not eligible, Apple Intelligence off, model still downloading) | The profile shows as unavailable with the reason from `SystemLanguageModel.availability` |

## 5. Architecture decision: native Swift, no Rust/UniFFI, no Tauri

The first assessment (in chat) suggested reusing the Rust core through
UniFFI. A mapping of `src-tauri/src/core` reverses that recommendation.

**What is actually reusable** is small and pure:

- the OpenAI-compatible request and response handling (`core/providers/openai.rs`)
- prompt assembly with the return-only-text suffix (`assemble_prompt`,
  `RETURN_ONLY_TEXT_INSTRUCTION` in `core/providers/mod.rs`)
- the privacy classification (`classify_privacy`)
- prompt validation and the default prompts (`core/prompts.rs`)

That's a few hundred lines.

**What isn't reusable as-is:**

- `Settings` (`core/settings/mod.rs`) mixes shared fields with desktop-only
  ones: shortcuts, popover position, Wayland, updates. It imports
  `core::shortcuts` and `core::updates`.
- Settings persistence is `TauriStoreSettings`.
- Secrets go through the `keyring` crate.
- `core` is a module of the `kallilex` Tauri crate (`kallilex_lib`), not a
  separate crate.

UniFFI reuse would therefore need:

1. extracting a new workspace crate
2. splitting `Settings`
3. building an XCFramework for device and simulator
4. a tokio runtime inside a memory-limited extension
5. a second toolchain in iOS CI

All of that would save a few hundred lines of straightforward code.

**Decision:** the iOS app is **native Swift/SwiftUI**. The shared logic is
ported to a local Swift package `KallilexKit`. A **shared contract-fixture
suite** (§12.2) keeps it from drifting away from the Rust core.

Further reasons:

- `URLSession` and Swift concurrency fit the extension lifecycle natively.
- One Swift `Provider` abstraction can cover both the OpenAI-compatible HTTP
  path and Apple Foundation Models. The latter is Swift-only, so a Rust core
  would cover only half the providers anyway.
- No new toolchain in iOS CI.

**Rejected alternatives:**

- **Tauri 2 iOS.** It can build the container app, but the share extension
  has to be native anyway. A WebView in the extension risks the memory
  limit. The existing share-target plugins hand the text over to the main
  app through a deep link, which leaves the source app and breaks the flow.
- **Rust core via UniFFI.** See above. Revisit only if the shared logic
  grows a lot, for example if streaming, multiple provider APIs, or
  templating are added on both platforms.

## 6. Repository layout, targets and identifiers

```
ios/
  Kallilex.xcodeproj               # Xcode 26+ (iOS 26 SDK), synchronized folders (minimal pbxproj churn)
  Kallilex/                        # container app target (SwiftUI)
  ShareExtension/                  # Share Extension target (SwiftUI in a UIHostingController)
  KallilexKit/                     # local Swift package, linked by both targets
    Package.swift
    Sources/KallilexKit/
    Tests/KallilexKitTests/
  Config/                          # .xcconfig files (bundle ids, team id via env, versions)
  PrivacyInfo.xcprivacy            # one per target, see §10
contracts/                         # language-neutral fixtures shared by Rust + Swift tests (§12.2)
issues-ios/                        # this plan + iOS specs
```

| Item | Proposed value | Notes |
|---|---|---|
| App bundle id | `com.webcommits.kallilex` | Same as the desktop id, which keeps "universal purchase" possible later (decided, Q5) |
| Extension bundle id | `com.webcommits.kallilex.share` | Must be prefixed by the app id |
| App Group | `group.com.webcommits.kallilex` | Settings JSON, consent records |
| Keychain access group | `$(AppIdentifierPrefix)com.webcommits.kallilex.shared` | API keys |
| URL scheme | `kallilex://` | Deep links into settings |
| Minimum iOS | **iOS 26.0** | Foundation Models need 26 (decided, Q6) |
| Swift | 6, strict concurrency | |
| Version | Independent semver starting at `1.0.0`, tags `ios-v1.0.0` | See §13. This keeps it clear of the desktop `v*` tags |

## 7. KallilexKit (shared Swift package)

Pure logic plus storage seams, no UI. Both targets link it. Every type is
`Sendable`.

### 7.1 Models (mirroring the desktop JSON field names, camelCase)

```swift
struct ProviderProfile: Codable, Identifiable, Sendable {
    var id: String            // UUID string
    var name: String
    var kind: ProviderKind    // .openAICompatible | .appleOnDevice (enum stays open for a later .applePrivateCloud)
    var baseURL: String       // JSON key "baseUrl", like desktop; unused for apple*
    var model: String
    var timeoutSecs: Int      // default 30, min 1
    var customHeaders: [HeaderEntry]
    var enabled: Bool         // default true
    var hasAPIKey: Bool       // JSON key "hasApiKey"; marker only, key lives in Keychain
}

struct CustomPrompt: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var instruction: String
    // desktop's `shortcut` is ignored on iOS (decoded and dropped)
}

struct AppSettings: Codable, Sendable {
    var schemaVersion: Int    // explicit from day one (desktop has none)
    var activeProfileID: String?
    var profiles: [ProviderProfile]
    var prompts: [CustomPrompt]          // seeded with default prompts
    var autoRunFirstPrompt: Bool         // default false
    var autoCopyResult: Bool             // default false
    var onboardingCompleted: Bool
    var consents: [AIConsent]            // §10.1
}
```

`kind` is new on iOS. The desktop has only one kind of provider. It keeps
its JSON default, `openAICompatible`, so that exporting and importing
desktop profiles later stays possible (Q3).

### 7.2 Prompt assembly (port of `assemble_prompt`)

- `systemPrompt(for action: Action) -> String`:
  - for `.prompt(instruction)` it returns `"\(instruction) \(returnOnlyTextInstruction)"`
  - for `.custom(instruction)` it returns
    `"Apply the following instruction to the user's text: \(instruction) \(returnOnlyTextInstruction)"`
- The user text always travels as a separate user message, never folded
  into the system prompt. This matches the desktop.
- `returnOnlyTextInstruction` and the default prompts come from
  `contracts/` (§12.2) so that they can't drift.

### 7.3 Providers

```swift
protocol TextProvider: Sendable {
    func complete(systemPrompt: String, userText: String) async throws -> String
    // throws ProviderError, or CancellationError when the task is cancelled
}
```

- **`OpenAICompatibleProvider`**, a port of `openai.rs`:
  - `endpoint`: http/https only, trailing slashes trimmed, `/chat/completions` appended
  - an empty model fails with `missingModel` before any request is sent
  - a per-request timeout
  - `Authorization: Bearer <key>` when a key exists
  - custom headers, with invalid ones silently skipped
  - `stream: false`
  - reads `choices[0].message.content`
  - `strip_padding` semantics: drop leading blank lines and all trailing
    whitespace, keep the first line's indentation
  - the HTTP error snippet is truncated the same way as on desktop
  - `URLSession` uses an ephemeral configuration: no cache, no cookies
- **`AppleOnDeviceProvider`**: a `LanguageModelSession` with
  `instructions = systemPrompt`.
  - It checks `SystemLanguageModel.default.availability` first and maps the
    reasons onto `ProviderError.unavailable(reason)`.
  - It checks the token count against `contextSize` (iOS 26.4+) before
    sending.
  - It maps `exceededContextWindowSize` and guardrail errors onto the
    taxonomy.
- `ApplePrivateCloudProvider` (iOS 27+, `PrivateCloudComputeLanguageModel`,
  behind an entitlement) is **not in v1** (Q4). The `TextProvider` seam
  keeps it a drop-in addition later.
- **`ActionRunner`** is the iOS counterpart of `run_action`:
  - it resolves the active, enabled profile (`active_profile` semantics)
  - it checks consent (§10.1)
  - it reads the key from the `SecretStore` only when `hasAPIKey` is set,
    and a read failure degrades to "no key", as on desktop
  - it calls the provider
  - it returns `RunOutcome` (`.ok(text)`, `.notConfigured`, `.consentRequired(profile)`,
    `.cancelled`, `.error(kind, message)`)
  - it honors `Task` cancellation

### 7.4 Error taxonomy

The desktop kinds are kept 1:1:

- `unreachable`
- `timeout`
- `http`
- `missingModel`
- `invalidBaseUrl`
- `invalidResponse`

iOS adds:

- `unavailable`: the on-device model isn't ready (reason included)
- `contextTooLong`
- `declined`: the on-device model refused the text (guardrails)
- `localNetworkDenied`: a LAN host was refused because the Local Network
  permission is missing (spike ios-01 must show whether this can be told
  apart from `unreachable`)

Every message is actionable, localized in English and German, and never
just "failed".

### 7.5 Privacy classification

This is a port of `classify_privacy`: `local` (loopback, `localhost`),
`lan` (private and link-local IPs, `.local`, `.lan`, `.home`, `.internal`,
single-label hosts) and `cloud`.

The Apple on-device kind maps to a new class, `onDevice`. The popover's
"which endpoint, which privacy class" badge becomes a small badge in the
extension: *On device*, *This device* (`local`), *Your network*, or
*Cloud: <host>*.

### 7.6 Storage seams

- **`SettingsStore`**: a protocol with `load()` and `save(_:)`.
  - Production: one JSON file `settings.json` in the App Group container,
    written atomically. The extension only reads it, except for consent
    records.
  - Coordination: an `NSFileCoordinator` around reads and writes, because
    the app and the extension can run at the same time.
  - The extension reloads on every launch, so it never caches settings
    across launches.
  - `schemaVersion` drives migrations from v1 onward.
  - Tests use an in-memory store.
- **`SecretStore`**: a protocol with `get`, `set` and `delete`, keyed by
  profile id.
  - Production: Keychain generic passwords with
    `kSecAttrService = "com.webcommits.kallilex.provider-key"`,
    `kSecAttrAccount = profile.id`, the shared access group, and
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Keys never sync and
    never land in backups.
  - Tests use an in-memory store.
- **Prompt CRUD**: validation (label and instruction not blank after
  trimming), save, delete, reorder, and a reset to the defaults.

## 8. Share Extension

### 8.1 Activation (`Info.plist` → `NSExtensionAttributes`)

Use the dictionary form of the activation rule, not `TRUEPREDICATE`, which
App Review rejects. The goal: show up for text, and not for photos or files.

- `NSExtensionActivationSupportsText = YES`
- `NSExtensionActivationSupportsWebURLWithMaxCount = 1`. This exists only so
  that Safari shares with a selection still show Kallilex. The spike checks
  whether Safari passes the selection as text or only the URL. If only the
  URL arrives, a `NSExtensionJavaScriptPreprocessingFile` returns
  `window.getSelection().toString()`.
- No image, movie or file types.

### 8.2 Reading the input

1. Iterate `extensionContext.inputItems` → `attachments`.
2. Try the types in order: `UTType.plainText`, then `UTType.utf8PlainText`,
   then `UTType.rtf` (converted to a plain string), then the Safari JS
   preprocessing result, then the `attributedContentText` of the
   `NSExtensionItem`.
3. Normalize line endings to `\n` and keep all other whitespace.
4. If nothing yields text, show the empty state from §4.3.

### 8.3 UI and state machine

`ShareRootView` is SwiftUI, hosted by a `UIHostingController` subclass of
`UIViewController` (the extension's principal class).

States:

- `loadingInput`
- `ready(original)`
- `running(prompt, original)`
- `result(original, result, prompt)`
- `error(kind, message, original)`
- `notConfigured`
- `consentRequired(profile)`

Layout, top to bottom:

1. Header: "Kallilex", the privacy badge of the active profile, and **Close**.
2. The text editor, a `TextEditor` with system spell check and an
   accessibility label.
3. Prompt chips: a horizontal `ScrollView`. Long-pressing a chip shows its
   instruction.
4. A **Custom…** chip that expands a one-line field. Its Return key runs the
   instruction.
5. A bottom toolbar: **Undo** (back to the original), **Retry** and
   **Copy** (the primary action).

Behavior:

- A `ShareViewModel` (`@Observable`, `@MainActor`) owns the `Task` and
  cancels it on Close, on dismissal, and when a new prompt is tapped.
- Copy writes `UIPasteboard.general.string = text`, shows "Copied" for about
  0.8 s, then calls `extensionContext.completeRequest(returningItems: nil)`.
- Haptics: success or error feedback on completion.
- Keep memory low: no images apart from SF Symbols, and no large
  frameworks. A memory check in the spike and before release (target below
  50 MB peak during a request).

### 8.4 Opening the container app from the extension

Share extensions can't call `UIApplication.open`.

- `extensionContext.open(_:)` officially works only for Today and iMessage
  extensions.
- The spike checks whether `extensionContext.open` works from a Share
  Extension on iOS 26/27.
- If it doesn't, the "not configured" card explains the steps in text:
  "Open Kallilex and add a provider".
- Don't use responder-chain hacks; they get apps rejected.

## 9. Container app

A `TabView` (iPhone first) with these tabs; About is a section of
Settings:

1. **Scratchpad**: the same editor and chip UI as the extension, built from
   the same SwiftUI components, in the `KallilexUI` library target of the
   `ios/KallilexKit` package. It adds a **Paste** button. That is a
   `PasteButton`/`UIPasteControl`, so iOS shows no paste prompt.
2. **Prompts**:
   - a list with drag to reorder
   - add and edit (label plus a multi-line instruction)
   - delete with confirmation
   - "Restore default prompts"
3. **Providers**:
   - the list of profiles with an active marker and the privacy badge
   - an editor for name, preset, base URL, model, API key (a secure field,
     with "stored in Keychain"), timeout and custom headers
   - **Test connection**
   - an enable toggle
   - for the Apple kinds, the availability status in place of URL and key
     fields
4. **Settings**:
   - auto-run the first prompt
   - copy and close automatically
   - manage the AI consents (revoke per host)
   - show onboarding again
   - "How to pin Kallilex in the share sheet"
5. **About**: the version, a link to the website, the privacy policy,
   licenses (Apache-2.0, plus the Swift package licenses, if any) and the
   source-code link.

## 10. Privacy, permissions and App Review

### 10.1 AI consent (guideline 5.1.2(i))

- `AIConsent { profileID, host, grantedAt }`.
- Consent is required before the first request to any `cloud`-class host.
- It isn't required for `local`, `lan` or `onDevice`.
- If the base URL's host changes, the consent is invalid.
- The consent UI exists in both the app and the extension. The wording names
  the host and says what is sent (the selected text and the prompt
  instruction) and what isn't (nothing else, no identifiers).
- The App Review notes explain the flow and include a test configuration.
  App Review needs a working provider:
  - Apple on device, if the review device supports it, **and**
  - as a fallback, a temporary, spend-limited API key for an
    OpenAI-compatible provider, given in the review notes and revoked after
    the review (decided, Q7).

### 10.2 Privacy manifest and labels

- There is a `PrivacyInfo.xcprivacy` for the app and for the extension.
  `UserDefaults` is a required-reason API, if it's used at all. The plan
  uses a JSON file in the App Group, so declare only what is actually used.
  The file timestamp APIs used for coordination also need declaring.
- App Store privacy label: "Data not collected" by the developer. The text
  goes to a provider the user configures, which the label questionnaire
  covers under third-party processing. Answer carefully, and document the
  answers in the release spec.
- The privacy policy: extend `website/datenschutz.html` with an iOS section,
  and add an English version for App Store Connect.

### 10.3 Network

- `NSAllowsLocalNetworking = YES` (for LAN Ollama or LM Studio over http).
  Arbitrary loads stay off.
- `NSLocalNetworkUsageDescription`: "Kallilex connects to AI servers on your
  local network, such as Ollama on your Mac, when you set one up."
- Public `http://` hosts aren't supported on iOS: https only, a documented
  difference from the desktop.

## 11. Localization and accessibility

- String catalogs (`Localizable.xcstrings`) in English and German, for the
  app, the extension and the `KallilexKit` error messages.
- Default prompts (decided, Q8): the **labels** are localized ("Rewrite" →
  "Umschreiben", "Shorten" → "Kürzen", "Improve clarity" → "Klarer
  formulieren"); the **instructions** stay English, as on desktop, since
  the model already keeps the text's language. Labels are localized only
  when seeding; once stored, they are user data and are never re-translated.
- Dynamic Type up to the accessibility sizes. The prompt chips wrap into a
  vertical list at large sizes.
- VoiceOver labels on all chips and toolbar buttons. Request state changes
  are announced ("Rewriting…", "Done", the error message).
- Reduce Motion is respected for the "Copied" animation.

## 12. Testing strategy

### 12.1 KallilexKit unit tests (Swift Testing)

- Prompt assembly, validation, CRUD and reordering.
- `OpenAICompatibleProvider` against a `URLProtocol` stub:
  - the endpoint building cases
  - the missing model
  - the headers and the bearer token
  - timeout mapping
  - HTTP error snippet truncation
  - `strip_padding` cases
  - a missing or empty `choices`
  - cancellation
- `ActionRunner`:
  - not configured
  - a disabled profile
  - consent required and granted
  - the key read only when `hasAPIKey` is set
  - a secret-store failure degrading to no key
- Privacy classification: all host cases.
- `SettingsStore`: round-trip, unknown keys ignored, migration from the
  `schemaVersion` scaffold, concurrent writes under file coordination.
- Apple providers: availability mapping through an injected availability
  value. A real model call only runs in a manual test plan.

### 12.2 Contract fixtures shared with desktop (`contracts/`)

JSON fixtures that both the Rust tests (`cargo test`) and the Swift tests
load:

- `prompt-assembly.json`: the actions and their expected system prompts,
  with the exact `RETURN_ONLY_TEXT_INSTRUCTION`
- `default-prompts.json`: the ids, labels and instructions
- `privacy-classification.json`: the base URLs and their expected classes
- `openai-request.json` and `openai-response.json`: the expected request
  body, header rules, and response-parsing and padding cases

The desktop side only gains tests that read these files. Its production
code doesn't change. This is the only touchpoint with desktop code, and it
is a separate, small spec (ios-03).

### 12.3 Extension and app

- `ShareViewModel` unit tests with a fake runner: the state transitions,
  cancellation, the Copy side effect behind a `Pasteboard` protocol, and
  auto-run and auto-copy.
- Input extraction tests with synthetic `NSItemProvider`s for plain text,
  UTF-8 text, RTF, a URL only, and empty input.
- XCUITest smoke tests for the container app (onboarding, adding a profile,
  the Scratchpad flow with the stub provider through a launch argument).
- **A manual host-app matrix** before every release:
  - Safari (with a selection; page only)
  - Mail (compose and read)
  - Notes
  - Messages
  - WhatsApp
  - Pages
  - Google Docs
  - Chrome

  For each: does Kallilex appear, does the text arrive intact, and does
  pasting back replace the selection? The result is recorded in the release
  spec.

## 13. CI and release

- A **new workflow `.github/workflows/ios.yml`**, triggered on pushes and
  PRs that touch `ios/**` or `contracts/**`. It runs on `macos-latest` and
  runs `xcodebuild test` for `KallilexKit` and the app scheme on a simulator.
  It needs no signing.
- The desktop `ci.yml` also runs the contract fixture tests, through the
  normal `cargo test`.
- **Guard rails against cross-triggering:**
  - iOS tags are `ios-v*`. `release.yml` triggers on `v*`, and a glob anchors
    at the start, so `ios-v1.0.0` doesn't match. Verify this in a dry run.
  - **Don't publish GitHub Releases for iOS builds.** `homebrew.yml` runs on
    *any* published release and would bump the cask. If GitHub Releases are
    wanted for iOS, add a tag-prefix guard to `homebrew.yml` first. That is a
    desktop change, so it gets its own spec.
- **Release (decided, Q9: manual for v1):**
  - Archive and upload by hand from Xcode (Product → Archive → Distribute
    App → App Store Connect), using automatic signing with the team's
    distribution certificate. No signing secrets in GitHub.
  - Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the xcconfig,
    tag the release commit `ios-vX.Y.Z` (no GitHub Release).
  - Path: TestFlight internal → TestFlight external → App Store.
  - Automating the upload (GitHub Actions on `ios-v*` tags) is a later spec.
- **Paid app (decided, Q10: one-time price):**
  - Needs the Paid Apps agreement, banking and tax forms in App Store
    Connect, and (for EU storefronts) the DSA trader-status declaration,
    which publishes the seller's address and contact details.
  - The price tier is chosen in App Store Connect at release time.
  - No in-app purchases and no trial. The source stays Apache-2.0, so
    building it yourself remains possible. The README says so.
- A `docs/ios-release-checklist.md`, modeled on `docs/release-checklist.md`.

## 14. Phases

| Phase | Outcome | Exit criterion |
|---|---|---|
| **0 — Spike** | A throwaway prototype answers the technical unknowns (§15 ios-01) | A written spike report in `issues-ios/`. Every unknown is answered or has a fallback |
| **1 — Foundation** | The Xcode project, `KallilexKit` with models, stores, prompt assembly, the OpenAI provider, the contract fixtures, iOS CI | `xcodebuild test` is green in CI, and the fixtures pass in Rust and Swift |
| **2 — Container app** | Providers, prompts, settings, consent, onboarding, Scratchpad | The full loop works in the Scratchpad on a device |
| **3 — Share Extension** | The extension with all states from §8.3 | The manual host-app matrix passes for Safari, Mail, Notes and Messages |
| **4 — Apple models** | The on-device provider (PCC is out of v1, Q4) | It works on an eligible device and degrades cleanly on ineligible ones |
| **5 — Polish** | Localization, accessibility, a memory audit, privacy manifest, App Review notes, website and privacy policy | Checklist complete |
| **6 — Release** | TestFlight → App Store 1.0.0 | Live in the App Store |
| Later | App Intents, keyboard, sync (§16) | Separate plan |

Phases 2 and 3 can partly overlap after Phase 1, but **only one writing
agent at a time** works in the worktree. The shared editor and chip
components (§9) are built in Phase 2 and reused in Phase 3.

## 15. Proposed specs

These will be written next, in the format of `issues/spec-XX-*.md`
(Status, Phase, Depends on, Problem Statement, Solution, User Stories,
Implementation Decisions, Testing Decisions, Out of Scope, Further Notes). Numbering is
separate from desktop: `spec-ios-NN-*.md`.

| Spec | Title | Depends on | Key content |
|---|---|---|---|
| ios-01 | Technical spike | — | See the unknowns below |
| ios-02 | Project skeleton and iOS CI | ios-01 | §6 layout, xcconfigs, entitlements (App Group, Keychain group), `ios.yml`, an empty app and extension that launch |
| ios-03 | Contract fixtures | ios-02 | The `contracts/` JSON, the Rust test loader (tests only), the Swift test loader |
| ios-04 | KallilexKit: models, settings and secret stores | ios-02 | §7.1, §7.6, schema versioning, file coordination |
| ios-05 | KallilexKit: prompts, assembly, privacy class, OpenAI provider, ActionRunner | ios-03, ios-04 | §7.2–7.5 |
| ios-06 | Container app: providers, prompts, settings | ios-05 | §9 (2–5), Test connection |
| ios-07 | AI consent and onboarding | ios-06 | §4.1, §10.1; creates the `KallilexUI` library target |
| ios-08 | Shared editor UI and Scratchpad | ios-07 | §9 (1), components reused by ios-09 |
| ios-09 | Share Extension | ios-07, ios-08 | §8 in full |
| ios-10 | Apple on-device model provider | ios-05, ios-06 | §7.3 on-device provider, availability UI |
| ios-11 | Localization and accessibility | ios-09 | §11 |
| ios-12 | Privacy manifest, App Review package, website | ios-09 | §10.2, the privacy policy, review notes, screenshots |
| ios-13 | Manual release and 1.0.0 | ios-11, ios-12, paid developer account | §13: manual archive/upload, versioning and `ios-v*` tags, paid-app setup, `docs/ios-release-checklist.md`, host-app matrix |

The spike's (ios-01) unknowns:

1. Which host apps deliver the selected text to a Share Extension as text?
   For Safari: whether the JS preprocessing is needed.
2. Is `NSAllowsLocalNetworking` enough for `http://<host>.local` and for
   bare LAN IPs? Can the extension trigger the Local Network prompt, or only
   the app?
3. Is the on-device Foundation Model available inside a Share
   Extension, and what is the memory cost there?
4. Does `extensionContext.open(_:)` work from a Share Extension on iOS 26
   and 27?
5. The peak memory of the SwiftUI extension during a request.
6. Pasting back after Copy: does the selection survive the share sheet, so
   that one Paste replaces it? Spot-check four apps.
7. Can a free Personal Team provision App Groups and Keychain sharing? If
   not, the paid account (Q2) must exist before Phase 1, not only before
   TestFlight.

## 16. Later (outside v1)

- **App Intents / Shortcuts:** a "Run Kallilex prompt" intent (input text
  plus a prompt entity, returning text). It enables Shortcuts automations,
  the Action button, Back Tap and Siri. It's cheap once `KallilexKit`
  exists. It's the best follow-up.
- **Keyboard extension "Kallilex Keyboard":** a prompt bar that reads
  `selectedText` and calls `insertText`, the only route to automatic
  Replace.
  - It needs "Allow Full Access" for the network, with an alarming system
    warning.
  - It doesn't work in secure fields or in apps that block third-party
    keyboards.
  - `selectedText` is unreliable in some web views.
  - App Review is stricter for keyboards.

  It gets its own plan after v1 feedback.
- **Profile and prompt sync:** an iCloud key-value store or CloudKit between
  iOS devices, and/or an import and export file format shared with desktop
  (the same JSON field names make this cheap). Never sync API keys.
- **iOS 27 Apple Intelligence "Extensions":** if Apple opens Writing Tools
  to third-party providers, Kallilex could appear in the system Writing
  Tools menu. Re-evaluate once Apple's documentation exists.
- **iPad layout, Mac Catalyst:** not planned (the desktop app covers the
  Mac).

## 17. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| App Review rejects under 5.1.2(i) or for "minimum functionality" | Release delayed | An explicit per-host consent screen (§10.1), the Scratchpad as a standalone feature, detailed review notes with a working test provider |
| Some host apps don't pass the selected text | The core flow fails there | Spike item 1, the Safari JS preprocessing, the Scratchpad fallback, documented in the FAQ |
| Users don't find Kallilex in the share sheet | Low adoption | An onboarding step to pin it to Favorites, a "How to" in Settings |
| A LAN provider is blocked by ATS or Local Network | Ollama users are stuck | Spike item 2, a clear `localNetworkDenied` error with a link to Settings |
| Extension memory limit | The extension crashes | Plain SwiftUI, no heavy dependencies, a memory audit (Phase 5) |
| Swift port drifts from the Rust core | Inconsistent results across platforms | The contract fixtures (§12.2) in both CIs |
| Foundation Models unavailable in extensions or too weak in German | The keyless option disappears | Spike item 3. Ship OpenAI-compatible only, and keep the Apple provider in the app's Scratchpad only |
| iOS releases trigger desktop workflows | A wrong Homebrew bump or release | The `ios-v*` tags, no GitHub Releases, or a guard in `homebrew.yml` (§13) |
| Apple Developer Program cost and account setup | A blocker for any distribution | No account yet (Q2). The spike starts with a free Personal Team (7-day device builds) and records which capabilities (App Groups, Keychain sharing) need the paid account; enroll before Phase 1 if they do, at the latest before TestFlight |

## 18. Decisions (product owner, 2026-11-03)

| # | Question | Decision |
|---|---|---|
| Q1 | Where does the iOS code live? | This repo, under `ios/` |
| Q2 | Paid Apple Developer Program account? | Not yet; will be created. Spike runs on a free Personal Team |
| Q3 | Sync of prompts and profiles in v1? | No. Later as an import/export format; API keys never sync |
| Q4 | Apple models in v1? | On-device only. Private Cloud Compute later |
| Q5 | Bundle id? | `com.webcommits.kallilex` (same as desktop) |
| Q6 | Minimum iOS? | iOS 26.0 |
| Q7 | How does App Review test the app? | On-device model, plus a temporary, spend-limited reviewer API key as a fallback |
| Q8 | Localize default prompts? | Labels localized (EN/DE), instructions stay English |
| Q9 | Release automation? | Manual archive and upload from Xcode for v1; automation later |
| Q10 | Price? | Paid, one-time price; no in-app purchases |

## 19. Sources

- Apple: [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards),
  [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard),
  [UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)
- Apple: [Foundation Models](https://developer.apple.com/documentation/foundationmodels),
  [WWDC26 session 241 (Foundation Models, PCC)](https://developer.apple.com/videos/play/wwdc2026/241),
  [`exceededContextWindowSize`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/exceededcontextwindowsize(_:))
- Apple: [Dive deeper into Writing Tools (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/265/)
- Pasteboard: [UIPasteboard privacy change in iOS 16](https://sarunw.com/posts/uipasteboard-privacy-change-ios16/),
  [Apple forums: paste permission dialog](https://developer.apple.com/forums/thread/724160),
  [OWASP MASTG: Pasteboard](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-PLATFORM/MASTG-KNOW-0083/)
- Action Extension return values: [forScore extension docs](https://forscore.co/developers-extensions/)
- Extension memory: [React Native: App Extensions (120 MB)](https://reactnative.dev/docs/next/app-extensions)
- App Review 5.1.2(i): [TechCrunch, 2025-11-13](https://techcrunch.com/2025/11/13/apples-new-app-review-guidelines-clamp-down-on-apps-sharing-personal-data-with-third-party-ai),
  [Apple forums: rejection thread](https://developer.apple.com/forums/thread/820209)
- iOS 27 third-party model extensions (reported, unconfirmed): [Gadget Hacks](https://apple.gadgethacks.com/news/ios-27-ai-writing-tools-grammar-checker-what-apples-extensions-system-could-change/)
- Tauri share targets (rejected path): [tauri-plugin-mobile-sharetarget](https://docs.rs/tauri-plugin-mobile-sharetarget)
- Desktop code referenced: `src-tauri/src/core/providers/mod.rs`
  (`assemble_prompt`, `classify_privacy`, `run_action`, `presets`),
  `src-tauri/src/core/providers/openai.rs`, `src-tauri/src/core/prompts.rs`,
  `src-tauri/src/core/settings/mod.rs`
