# Spec ios-04 — KallilexKit: models, settings store and secret store

Status: ready-for-agent
Phase: Phase 1 (Foundation)
Depends on: ios-02

## Problem Statement

The iOS app must store and load profiles, prompts, settings and API keys
following the desktop's schema, with camelCase JSON keys, schema migration
support, and atomic file coordination between the app and extension. Models
must be portable, equatable, sendable and Codable. Decoding must be tolerant
of missing fields, with sensible defaults. The app and extension share
settings through an App Group container and API keys through Keychain, both
keyed by information in Info.plist, so no hardcoded team IDs end up in source.

## Solution

Define portable model types in `KallilexKit/Sources/KallilexKit/Models/`:
`ProviderProfile`, `ProviderKind`, `CustomPrompt`, `HeaderEntry`, `AIConsent`
and `AppSettings`. Implement `SettingsStore` with a file-coordinated JSON
loader and `SecretStore` with Keychain access. Provide a `SettingsMigrator`
scaffold and seeded default prompts. All types use `CodingKeys` for camelCase
JSON parity with desktop.

## User Stories

1. As a developer, I want settings to round-trip through JSON with no data
   loss, so that users can export and import their configuration.
2. As a developer, I want API keys to live in the Keychain, not in the
   settings file, so that they stay secure and never appear in backups.
3. As a developer, I want the app and extension to load settings from the same
   App Group container, so that they see the same profiles and prompts without
   duplication.
4. As a developer, I want file coordination around settings.json reads and
   writes, so that the app and extension can run at the same time without
   corrupting the file or losing writes.
5. As a developer, I want to handle a corrupt settings file gracefully,
   rename it, use defaults, and show a user notice, so that the app recovers
   without crashing.
6. As an iOS user upgrading from the desktop, I want a settings.json with
   desktop fields (shortcut, popoverPosition, updateChannel) to load, keeping
   the profiles and prompts and silently dropping the extra fields, so that
   import becomes one file drop.
7. As a tester, I want concurrent writes from two store instances on the same
   file to succeed without losing data, so that extension + app real-world
   race conditions stay safe.
8. As a developer, I want default prompts in English text without translations
   baked in, and user-stored labels localized once at seeding time, so that
   models stay portable and user edits are respected.

## Implementation Decisions

### Models in `KallilexKit/Sources/KallilexKit/Models/Models.swift`

All types are `Codable, Equatable, Sendable`. JSON keys use `CodingKeys` to
map to camelCase, matching desktop exactly.

#### ProviderKind

```swift
enum ProviderKind: String, Codable, Equatable, Sendable {
    case openAICompatible
    case appleOnDevice
}
```

Raw string values. Default when the key is missing: `openAICompatible`.

#### ProviderProfile

```swift
struct ProviderProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var kind: ProviderKind
    var baseUrl: String
    var model: String
    var timeoutSecs: Int
    var customHeaders: [HeaderEntry]
    var enabled: Bool
    var hasApiKey: Bool
}
```

CodingKeys: `baseUrl`, `timeoutSecs`, `customHeaders`, `hasApiKey` (exact
desktop names). Defaults: `timeoutSecs` 30, `enabled` true, `hasApiKey`
false, `customHeaders` [], `kind` `.openAICompatible` when missing.

#### HeaderEntry

```swift
struct HeaderEntry: Codable, Equatable, Sendable {
    let name: String
    let value: String
}
```

CodingKeys: `name`, `value`.

#### CustomPrompt

```swift
struct CustomPrompt: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var instruction: String
}
```

Desktop `shortcut` field is decoded and dropped (not ported to iOS in this
phase).

#### AIConsent

```swift
struct AIConsent: Codable, Equatable, Sendable {
    let profileID: String
    let host: String
    let grantedAt: Date
}
```

CodingKeys: `profileId` (JSON), maps to `profileID` (Swift). Dates use
ISO-8601 coding.

#### AppSettings

The top-level persisted value. Replaces the plan's `IOSSettings` name.

```swift
struct AppSettings: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var activeProfileID: String?
    var profiles: [ProviderProfile]
    var prompts: [CustomPrompt]
    var autoRunFirstPrompt: Bool
    var autoCopyResult: Bool
    var onboardingCompleted: Bool
    var consents: [AIConsent]
}
```

CodingKeys: `activeProfileId` (JSON), maps to `activeProfileID` (Swift).
Defaults: `activeProfileID` nil, `profiles` [], `prompts` seeded via
`PromptDefaults.defaults(locale:)`, `autoRunFirstPrompt` false, `autoCopyResult`
false, `onboardingCompleted` false, `consents` []. Missing keys fall back
through `decodeIfPresent`.

`AppSettings` has `static func seeded(locale: Locale = .current) ->
AppSettings`: `schemaVersion` 1, prompts from
`PromptDefaults.defaults(locale:)`, every other field at its default.
`SettingsStore.load()` returns `AppSettings.seeded()` for a missing or
corrupt file. There is no `AppSettings.default`. The contract-fixture test
for default prompts (ios-05) calls `PromptDefaults.defaults(locale:
Locale(identifier: "en"))` so it doesn't depend on the runner's language.

### Consent host

**File:** `KallilexKit/Sources/KallilexKit/Models/ConsentHost.swift`

```swift
/// The canonical host used for every consent-host computation: here in
/// `saveProfile`'s host-change consent invalidation (this spec), in
/// `ActionRunner` (ios-05), and in `EditorSession` (ios-08).
func consentHost(for profile: ProviderProfile) -> String? {
    guard let url = URL(string: profile.baseUrl),
          let host = url.host(percentEncoded: false) else {
        return nil
    }
    let lower = host.lowercased()
    return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
}
```

### Default prompts

The three default prompts come from `contracts/default-prompts.json`, keyed by
id, instruction exactly as written. The label is localized at seeding time
only, using `String(localized:bundle: .module)`:

```swift
struct PromptDefaults {
    static func defaults(locale: Locale = .current) -> [CustomPrompt] {
        [
            CustomPrompt(
                id: "builtin-rewrite",
                label: String(localized: "prompt.default.rewrite",
                              bundle: .module, locale: locale),
                instruction: "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone."
            ),
            CustomPrompt(
                id: "builtin-shorten",
                label: String(localized: "prompt.default.shorten",
                              bundle: .module, locale: locale),
                instruction: "Make the user's text noticeably shorter while keeping its essential meaning and tone."
            ),
            CustomPrompt(
                id: "builtin-improve-clarity",
                label: String(localized: "prompt.default.improveClarity",
                              bundle: .module, locale: locale),
                instruction: "Make the user's text clearer and easier to understand without changing its meaning."
            ),
        ]
    }
}
```

English values for `prompt.default.*` keys are supplied here; German strings
are added in ios-11. The stored label is user data and never re-translated
(PLAN.md §11, Q8).

### Schema version and migration

`AppSettings.schemaVersion = 1`. Create a `SettingsMigrator` scaffold:

```swift
struct SettingsMigrator {
    static func migrate(
        _ raw: [String: Any],
        from version: Int
    ) -> [String: Any] {
        // Migrations go here for future versions.
        // Version 1: no migrations yet; pass through.
        raw
    }
}
```

Tests verify that version 1 passes through unchanged. This scaffold means
future migrations (version 2, 3, …) are added in one place.

### Info.plist keys for App Group and Keychain

The app reads `KallilexAppGroup` and `KallilexKeychainAccessGroup` from
Info.plist at runtime, so team-specific values are set once in build settings
and used by both the app and extension targets without being hardcoded in
source. **Add these two keys to the ios-02 skeleton's Info.plist:**

```xml
<key>KallilexAppGroup</key>
<string>$(PRODUCT_BUNDLE_IDENTIFIER).shared</string>

<key>KallilexKeychainAccessGroup</key>
<string>$(AppIdentifierPrefix)com.webcommits.kallilex.shared</string>
```

(In ios-02's CommonConfig.xcconfig, expand `PRODUCT_BUNDLE_IDENTIFIER` if it
is not yet set, or use `com.webcommits.kallilex` directly to be explicit.)

### SettingsStore protocol

```swift
protocol SettingsStore: Sendable {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
    func update(
        _ body: (inout AppSettings) throws -> Void
    ) throws -> AppSettings
}
```

The `update` method performs an atomic read-modify-write: load settings,
apply the closure (which can throw), save, return the result.

#### Production implementation: `AppGroupSettingsStore`

```swift
class AppGroupSettingsStore: SettingsStore {
    let appGroupId: String
    let keychainAccessGroup: String
    var lastLoadRecoveredFromCorruption: Bool { get }
    
    init(appGroupId: String, keychainAccessGroup: String) throws
    
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
    func update(_ body: (inout AppSettings) throws -> Void) throws
        -> AppSettings
}
```

Behavior:
- Uses `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
  to locate the App Group container.
- Reads and writes `settings.json` inside that container.
- Every read and write is wrapped in `NSFileCoordinator`.
- Writes use `.atomic` flag to prevent partial writes.
- If the file does not exist, `load()` returns seeded defaults (see
  `AppSettings` above) and does not write until the first `save()`.
- If the file is corrupt or undecodable, `load()` renames it to
  `settings.corrupt-<ISO8601>.json`, returns seeded defaults, and sets
  `lastLoadRecoveredFromCorruption = true`. The app can read this flag and
  show a one-time notice (implemented in ios-06).
- The `update` method uses a single coordinated write that reads the file,
  applies the closure, and writes the result. If the closure throws, no
  write happens.

#### In-memory store for tests: `InMemorySettingsStore`

A simple `Sendable` class wrapping an `AppSettings` value in a lock, with
synchronous `load()`, `save()` and `update()`.

### SecretStore protocol

```swift
protocol SecretStore: Sendable {
    func get(profileID: String) throws -> String?
    func set(_ key: String, profileID: String) throws
    func delete(profileID: String) throws
}
```

- `get` returns the key or `nil` if not found.
- `set` adds or updates (no distinction needed).
- `delete` is a no-op if the id does not exist.

#### Production implementation: `KeychainSecretStore`

Uses the Security framework:
- `kSecClassGenericPassword`
- `kSecAttrService = "com.webcommits.kallilex.provider-key"`
- `kSecAttrAccount = profileID`
- `kSecAttrAccessGroup = keychainAccessGroup` (passed at init)
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- `kSecAttrSynchronizable = false` (no sync, no backup)

On `set`: try to update first (the common case), then add if update fails.
On `delete`: `errSecItemNotFound` is not an error (no-op). Other OSStatus
errors throw `SecretStoreError.osStatus(status)`.

```swift
enum SecretStoreError: Error, Sendable {
    case osStatus(OSStatus)
}
```

#### In-memory store for tests: `InMemorySecretStore`

A simple `Sendable` class wrapping a `[String: String]` dictionary, with
synchronous get/set/delete.

### Profile and prompt operations as functions

Implement as free functions or a `SettingsService` (your choice, state which):
`saveProfile`, `deleteProfile`, `setActiveProfile`, `savePrompt`, `deletePrompt`,
`movePrompts(fromOffsets:toOffset:)`, `restoreDefaultPrompts`, `grantConsent`,
`revokeConsent`, `hasConsent`. Mirror desktop semantics:

- **saveProfile**: validate name non-blank after trimming, `timeoutSecs` ≥ 1;
  when `apiKey` is provided and non-empty, store it in `SecretStore` and set
  `hasApiKey`; when `apiKey` is explicitly nil (removal), delete it and clear
  the flag; no-op if the key didn't exist. On the first save, if no profile
  was active, activate it. If the profile's consent host changed (compare
  `consentHost(for:)` (above) before and after), remove every consent of
  this profile whose `host` no longer equals the new consent host
  (PLAN.md §10.1: a host change invalidates consent).
- **deleteProfile**: remove from `profiles`, delete its secret key, clear
  `activeProfileID` if it pointed at this profile, and remove its consents.
- **setActiveProfile**: set `activeProfileID` to the given id (or nil); verify
  the id exists if provided (or throw).
- **savePrompt**: validate label and instruction non-blank after trimming.
  Generate an id if empty.
- **deletePrompt**: remove it; no-op if missing.
- **movePrompts(fromOffsets:toOffset:)**: reorder the prompts list in-place.
- **restoreDefaultPrompts**: walk the default prompts from `PromptDefaults`,
  and for each id that is missing from the current list, append it. Never
  removes or re-adds user prompts.
- **grantConsent(profileID:host:)**: add or update the consent for this
  (profileID, host) pair with today's date.
- **revokeConsent(profileID:host:)**: remove the consent if present.
- **hasConsent(profileID:host:)**: return true iff a consent exists for this
  pair.
- **When a profile's baseUrl host changes:** remove all consents for that
  profileID from `consents`. Implement this check in `saveProfile` by parsing
  the old and new baseUrl and comparing hosts.

All operations use the `SettingsStore.update` seam to ensure atomicity.

### Decoding tolerance and desktop field compatibility

When decoding a `settings.json` written by the desktop (with fields like
`shortcut`, `popoverPosition`, `updateChannel`), all unknown keys are
ignored. Test this: load a desktop-shaped JSON snippet, verify profiles and
prompts are preserved, and extra fields disappear without error.

## Testing Decisions

- **JSON round-trip:** encode a model to JSON and decode it back; verify
  equality.
- **Desktop JSON compatibility:** load a desktop-shaped `settings.json`
  with `shortcut`, `popoverPosition`, `updateChannel` (etc.); verify
  `profiles`, `prompts` and `schemaVersion` are correct, and unknown keys
  are ignored.
- **Missing keys → defaults:** omit every optional field from a fixture
  and verify the decoded model uses the default.
- **Corrupt file recovery:** write an unparseable JSON to the container,
  call `load()`, verify it returns defaults and sets
  `lastLoadRecoveredFromCorruption = true`, and verify a `.corrupt-*`
  file was created.
- **Concurrent updates:** run two `update` calls from different store
  instances on the same temp directory (simulating app + extension).
  Verify that both writes succeed and neither is lost.
- **Keychain tests:** all simulator tests use the in-memory fake; add one
  integration test for `KeychainSecretStore` on simulator (mark it
  skipped in CI if it fails due to missing signing; access groups need a
  provisioning profile).

## Out of Scope

- Desktop sync or export/import (Phase 3).
- Encryption of settings.json (Phase 5).
- iCloud sync of profiles or prompts (Phase 3).
- Wayland or macOS-specific settings.

## Further Notes

- PLAN.md §7.1 and §7.6 describe the data model and storage seams.
- PLAN.md §6 specifies the App Group id and Keychain access group.
- The two Info.plist keys must be added to the ios-02 skeleton, and this
  spec must state that explicitly so the ios-02 implementer is aware.
- The `AIConsent` type is detailed in PLAN.md §10.1.
- Desktop prompt and profile CRUD semantics are in
  `src-tauri/src/core/prompts.rs` and `src-tauri/src/core/providers/mod.rs`
  (`save_profile_core`, `delete_profile_core`, `set_active_profile_core`).
