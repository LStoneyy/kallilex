# Spec ios-06 — Container app: providers, prompts, settings

Status: ready-for-agent
Phase: Phase 2 (Container app)
Depends on: ios-05

## Problem Statement

The container app is the setup and fallback interface for users. They manage
provider profiles, save and reorder prompts, configure settings like
auto-run and auto-copy, grant and revoke AI data sharing consent, and access
onboarding, about information, and the Scratchpad as a fallback when the
share sheet is unavailable. The app must load settings on launch and when
it becomes active (in case the extension wrote consents).

## Solution

Build a four-tab app (`TabView` on iPhone): Scratchpad (placeholder until
ios-08), Prompts, Providers, Settings. Root composition via `AppEnvironment`
(`@Observable`, `@MainActor`) injected through `.environment(_:)`. Prompts
tab has drag-to-reorder and swipe-to-delete. Providers tab lists profiles
with privacy badges and enables editing, testing connections, and enabling/
disabling. Settings tab manages auto-run/auto-copy toggles, consent records,
onboarding reset, and about information. A one-time alert shows if the app
recovered from file corruption.

## User Stories

1. As a user, I want the app to show four tabs (Scratchpad, Prompts,
   Providers, Settings) so that I can navigate between all setup areas.
2. As a user, I want to create, edit, delete and reorder prompts so that I
   can build a personal library.
3. As a user, I want to add a provider by choosing a preset or entering
   custom details so that I can connect to any OpenAI-compatible endpoint.
4. As a user, I want the app to show a provider's privacy class (On device,
   This device, Your network, Cloud: <host>) so that I know where my text goes.
5. As a user, I want to test a provider connection before using it so that I
   know it's reachable and correctly configured.
6. As a user, I want to enable and disable providers so that I can quickly
   switch between favorites without deleting them.
7. As a user, I want to see which provider is active (marked with a checkmark)
   and choose a different one so that I can change providers.
8. As a user on an eligible device, I want to see the on-device Apple model
   as an option so that I can use Kallilex without an API key.
9. As a user, I want toggles for "Run the first prompt automatically" and
   "Copy and close automatically" so that I can speed up the share-sheet flow.
10. As a user, I want to view and revoke my AI data sharing consents so that
    I can take back permission at any time.
11. As a user, I want to access the onboarding guide again so that I can
    re-learn how to pin Kallilex to the share sheet.
12. As a user, I want to see the version, website, privacy policy, source code
    link and licenses so that I know where to get help and understand the app.
13. As a user, I want a notice if the app couldn't read its settings so that
    I understand why I might have lost data.

## Implementation Decisions

### App shell and root composition

**File:** `Kallilex/Sources/KallilexApp.swift`

```swift
@main
struct KallilexApp: App {
    @State private var appEnv: AppEnvironment
    
    init() {
        let settingsStore = AppGroupSettingsStore(
            appGroupId: InfoPlist.kallilexAppGroup,
            keychainAccessGroup: InfoPlist.kallilexKeychainAccessGroup
        )
        let secretStore = KeychainSecretStore(
            accessGroup: InfoPlist.kallilexKeychainAccessGroup
        )
        let runner = ActionRunner(
            settings: settingsStore,
            secrets: secretStore,
            makeProvider: { profile, key in
                OpenAICompatibleProvider(
                    profile: profile,
                    apiKey: key
                )
            }
        )
        appEnv = AppEnvironment(
            settingsStore: settingsStore,
            secretStore: secretStore,
            actionRunner: runner
        )
    }
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appEnv)
        }
    }
}
```

**File:** `Kallilex/Sources/AppEnvironment.swift`

`AppEnvironment` lives in the app target, not `KallilexKit`, which stays
UI-free (PLAN.md §7):

```swift
@Observable @MainActor
final class AppEnvironment: Sendable {
    let settingsStore: SettingsStore
    let secretStore: SecretStore
    let actionRunner: ActionRunner
    
    var settings: AppSettings
    
    init(
        settingsStore: SettingsStore,
        secretStore: SecretStore,
        actionRunner: ActionRunner
    ) throws {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.actionRunner = actionRunner
        self.settings = try settingsStore.load()
    }
    
    func reload() throws {
        settings = try settingsStore.load()
    }
    
    func saveSettings(_ body: (inout AppSettings) throws -> Void) throws {
        settings = try settingsStore.update(body)
    }
}
```

`AppEnvironment` reads Info.plist keys `KallilexAppGroup` and
`KallilexKeychainAccessGroup` at init time.

**File:** `Kallilex/Sources/RootTabView.swift`

A `TabView` with four tabs: Scratchpad, Prompts, Providers, Settings. Each
tab is a separate view with its own navigation. The tab labels use
`String(localized:)` keys: `"tab.scratchpad"`, `"tab.prompts"`,
`"tab.providers"`, `"tab.settings"`.

`RootTabView` reloads settings whenever the app becomes active, so it picks
up consents or settings the share extension wrote while the app was
backgrounded:

```swift
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        TabView {
            // Scratchpad, Prompts, Providers, Settings tabs
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                try? appEnv.reload()
            }
        }
    }
}
```

### Prompts tab

**File:** `Kallilex/Sources/PromptListView.swift` and `PromptEditor.swift`

- A `List` displaying all prompts in order.
- Each row shows the label and a truncated preview of the instruction.
- `onMove` to reorder prompts; the closure calls `appEnv.saveSettings` and
  `movePrompts(fromOffsets:toOffset:)`.
- Swipe-to-delete with a confirmation alert: "Delete <label>?" with Cancel
  and Delete buttons.
- A toolbar button "Add" opens a sheet with `PromptEditor`.
- Tapping a row opens the editor sheet for that prompt.
- An empty state message: `String(localized: "prompt.empty.message")` —
  "No prompts yet. Tap Add to create one."
- A toolbar menu with one item: "Restore default prompts", which calls
  `restoreDefaultPrompts()` and shows a confirmation.

**PromptEditor (modal sheet):**

- A form with two fields:
  - `TextField` for the label, placeholder
    `String(localized: "prompt.label.placeholder")` — "Prompt name"
  - Multi-line `TextEditor` for the instruction, placeholder
    `String(localized: "prompt.instruction.placeholder")` — "What should Kallilex do?"
- Inline validation: both fields trimmed must be non-blank. If either is blank
  after trim, disable the Save button and show a red validation message:
  `String(localized: "prompt.validation.blank")` — "Both label and instruction
  are required."
- A Save button calls `savePrompt` and dismisses the sheet. A Cancel button
  dismisses without saving.

### Providers tab

**File:** `Kallilex/Sources/ProviderListView.swift` and `ProviderEditor.swift`

**Provider list:**

- A `List` of all profiles.
- Each row shows:
  - The profile's `name` (bold).
  - The privacy badge (see PrivacyBadge view below).
  - A checkmark next to the active provider's name.
  - Dimmed appearance if `enabled == false`.
- Tapping a row opens the editor sheet for that profile.
- Swipe-to-delete with a confirmation: "Delete <name>?" with a warning
  "The API key stored on this device will also be deleted." (if `hasApiKey`)
  or no warning (if not). Cancel and Delete buttons.
- A toolbar button "Add provider" opens a preset picker (see below).
- An empty state: `String(localized: "provider.empty.message")` —
  "No providers yet. Tap Add to set one up."

**Add provider: preset picker**

The preset picker is a sheet showing a list of available presets from
`providerPresets()`. The on-device preset is hidden from the picker until
ios-10 adds an eligibility check; in ios-10, it is shown only when
`SystemLanguageModel.default.availability != .deviceNotEligible`.
Tapping a preset opens the editor for a new profile pre-filled with the
preset's defaults. The editor is the same form as for editing an existing
profile (see below).

**Provider editor (modal sheet):**

- Fields (in order):
  1. **Name** (TextField): required, non-blank after trim.
  2. **Base URL** (TextField, if `kind == .openAICompatible`):
     - Keyboard: URL type (no autocapitalization, no autocorrection).
     - Placeholder: `String(localized: "provider.baseUrl.placeholder")` —
       "https://api.example.com/v1"
     - Optional field (empty is allowed while editing; validation only on save).
  3. **Model** (TextField, if `kind == .openAICompatible`):
     - Placeholder: `String(localized: "provider.model.placeholder")` —
       "gpt-4-turbo"
     - Required, non-blank after trim.
  4. **Availability** (informational row, if `kind == .appleOnDevice`):
     - Shows status instead of URL/model/key fields.
     - "Ready", "Turn on Apple Intelligence", etc. (from ios-10).
  5. **API Key** (SecureField, if `kind == .openAICompatible` and `needsApiKey`
     from the preset):
     - Placeholder: `String(localized: "provider.apiKey.placeholder")` —
       "Paste your API key"
     - Two sub-cases:
       - **No key stored yet:** a button "Paste and save" opens the field
         for input. On save, the key is stored in `SecretStore` and
         `hasApiKey` is set to true.
       - **Key already stored** (`hasApiKey == true`): a read-only row showing
         `String(localized: "provider.apiKey.saved")` — "API key saved on this
         device", with two buttons:
         - **Replace** opens a SecureField to paste a new key.
         - **Remove** calls `SecretStore.delete()` and clears `hasApiKey`.
  6. **Timeout** (Stepper, if `kind == .openAICompatible`):
     - Range: 1–300 seconds (default 30).
     - Label: `String(localized: "provider.timeout")` — "Request timeout (s)"
  7. **Custom Headers** (if `kind == .openAICompatible`):
     - A list of name/value rows with add and remove buttons.
     - Each row: name and value TextFields.
     - Add button appends a blank row.
     - Swipe-to-delete removes a row.
  8. **Enabled** (Toggle):
     - Label: `String(localized: "provider.enabled")` — "Enabled"
     - Disabled rows appear dimmed in the list.
  9. **Active provider** (Button):
     - Label: `String(localized: "provider.setActive")` — "Use this provider"
     - Calls `setActiveProfile(profile.id)`.
  10. **Test connection** (Button):
      - Label: `String(localized: "provider.testConnection")` —
        "Test connection"
      - Calls `await appEnv.actionRunner.testConnection(profile:apiKey:)` and
        shows inline result below the button:
        - Success: `String(localized: "provider.testConnection.success")` —
          "✓ Connection successful"
        - Failure: `error.localizedDescription` (`ProviderError` conforms to
          `LocalizedError`, see ios-05).

- Save and Cancel buttons at the bottom. Validation: name and model must be
  non-blank; base URL must be valid (use `URL(string:)` check when non-empty).
  Inline warning (not a save blocker) when URL is `http://` and privacy class
  is `.cloud`: `String(localized: "provider.warning.insecureUrl")` —
  "iOS only allows http:// on your local network. Use https:// for this server."
- Inline hint for `.lan` hosts: `String(localized: "provider.hint.localNetwork")`
  — "iOS will ask for Local Network access the first time you use this provider."

### Settings tab

**File:** `Kallilex/Sources/SettingsView.swift`

A `Form` with sections:

1. **Auto-run & Copy** section:
   - Toggle: "Run the first prompt automatically"
     (`autoRunFirstPrompt`). Key: `String(localized: "settings.autoRun")`.
   - Toggle: "Copy and close automatically" (`autoCopyResult`).
     Key: `String(localized: "settings.autoCopy")`.
   - Footer: `String(localized: "settings.auto.footer")` — "In the share sheet
     only."

2. **AI data sharing** section:
   - Heading: `String(localized: "settings.consents.heading")` — "AI data sharing"
   - If consents are empty: `String(localized: "settings.consents.empty")` —
     "No active consents."
   - Each consent row shows:
     - Profile name, host, and grant date (in short form).
     - Swipe-to-delete with confirmation: "Revoke consent for <host>?" with
       Cancel and Revoke buttons.
     - Calls `revokeConsent(profileID:host:)`.

3. **Onboarding** section:
   - Button: "Show setup again"
     (`String(localized: "settings.showOnboarding")`)
   - Sets `onboardingCompleted = false` and resets the onboarding state (see
     ios-07).

4. **How to add Kallilex to your share sheet** section:
   - Button: opens a sheet with `ShareSheetGuideView` (implemented in ios-07).

5. **About** section:
   - Version: "Version X.Y.Z (build N)" from Bundle.main.
   - Website: a Link to `https://kallilex.webcommits.info/`
   - Privacy Policy: a Link (URL to be filled in ios-12).
   - Source Code: a Link to `https://github.com/LStoneyy/kallilex`.
   - Licenses: a NavigationLink to a `LicensesView` showing Apache-2.0 text
     bundled in the app (static for now; any Swift package licenses added later).

### One-time corruption recovery alert

After `AppEnvironment.init()`, check `AppGroupSettingsStore.lastLoadRecoveredFromCorruption`.
If true, show a one-time alert (in `RootTabView` or `KallilexApp` body):

```
Kallilex couldn't read its settings and started fresh. Your old settings file
was kept for troubleshooting.
```

Buttons: OK (dismisses, sets a flag so it doesn't show again on the next launch).

### PrivacyBadge view

**File:** `Kallilex/Sources/PrivacyBadge.swift` (or in KallilexUI if shared)

A small badge displaying the privacy class of a provider:
- `.onDevice`: "On device"
- `.local`: "This device"
- `.lan`: "Your network"
- `.cloud`: "Cloud: <host>" (extract host from `baseUrl`)

Different colors or SF Symbol for each class. Tapping shows the full description
in a tooltip or a help sheet.

### Info.plist integration

The app reads Info.plist keys at runtime:
- `KallilexAppGroup`: used by `AppGroupSettingsStore`.
- `KallilexKeychainAccessGroup`: used by `KeychainSecretStore`.

These are already defined in ios-02.

## Testing Decisions

### Unit tests

- **Prompt editor validation:** both fields blank → save disabled; one blank →
  disabled; both filled → enabled.
- **Provider editor validation:** name required, model required, URL must parse
  when non-empty.
- **Privacy badge logic:** `.local` shows "This device", `.cloud` shows host.
- **Test connection result display:** success shows checkmark, error shows
  message.
- **Provider enable/disable:** disabled profile is dimmed and cannot be made active.
- **Consent revoke:** swiping a consent, tapping Revoke, re-loading settings
  removes it.
- **Prompt reorder:** moving prompts updates the list and persists.

### XCUITest smoke tests

- **Add a prompt:** tap Add, enter label and instruction, save, verify it
  appears in the list.
- **Reorder prompts:** drag one to a new position, reload settings, verify
  the order persists.
- **Add a custom provider:** tap Add provider, select Custom, enter name, URL,
  model, API key, save, verify it appears in the list.
- **Test connection (stub):** with a `-uiTestStubProvider` launch argument,
  the ActionRunner returns a stub provider that returns the input uppercased.
  Test a connection through the Providers tab and verify "✓ Connection
  successful" appears.
- **Set provider active:** add two providers, set the second as active, reload,
  verify the checkmark moved.
- **Auto-run/auto-copy toggles:** toggle both on, verify they persist across
  app restart.
- **Corruption alert:** write an invalid settings.json before launch,
  launch the app, verify the alert appears and doesn't show again.

## Out of Scope

- Sync of prompts or profiles with the desktop or between devices.
- Import/export format.
- Editing the on-device model's properties (no URL/key/timeout for on-device).
- App Store privacy manifest labels or consent records for third-party SDKs
  (Phase 5, ios-12).
- Localization of all strings (Phase 5, ios-11 adds German).

## Further Notes

- PLAN.md §9 covers the container app structure and tabs.
- PLAN.md §4.1 covers the provider presets and onboarding flow (detailed in
  ios-07).
- PLAN.md §10.1 covers AI consent (displayed here in the Settings tab).
- PLAN.md §10.3 covers the local network hint.
- The `AppEnvironment` is injected through `.environment(_:)` and shared by all
  tabs and child views.
- The Scratchpad tab is a placeholder in ios-06; ios-08 implements it.
- The Share Sheet Guide is a separate view implemented in ios-07 and reused in
  Settings.
- The on-device model availability display is specified in ios-10 but the UI
  (availability status row) is implemented here in the Providers editor.
