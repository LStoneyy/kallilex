# Spec ios-07 — AI consent and onboarding

Status: ready-for-agent
Phase: Phase 2 (Container app)
Depends on: ios-06

## Problem Statement

App Review guideline 5.1.2(i) requires explicit user consent before sending
personal data to third-party AI services. The app must present a clear consent
screen that names the provider and host, explains what is sent (text and
instruction only), and gives the user an explicit Allow / Not now choice with
nothing pre-selected. First-time users must go through an onboarding flow that
walks them through choosing a provider, optionally testing it, granting consent
for cloud providers, and learning how to pin the app to the share sheet. The
onboarding must adapt to the provider kind: the on-device model skips the API
key and consent steps; local/LAN providers skip consent entirely.

## Solution

Create a new `KallilexUI` library target in `ios/KallilexKit/` with shared
SwiftUI components. Implement `ConsentView` for inline presentation in both
app and extension. Build an `OnboardingViewModel` that sequences steps based
on the chosen provider, with a `fullScreenCover` while `!onboardingCompleted`.
Implement `ShareSheetGuideView` showing the exact iOS 26 steps to pin the app,
with animations respecting Reduce Motion. All user-visible text uses
`String(localized:)` keys.

## User Stories

1. As a cloud AI user, I want to see a clear consent screen before sending text
   to a third-party provider so that I understand what I'm consenting to.
2. As a user, I want the consent screen to show the provider's name and host so
   that I know exactly where my text is going.
3. As a user, I want clear messaging that says only the text and instruction
   are sent (not metadata or identifiers) so that I trust the process.
4. As a user, I want Allow and Not now buttons with nothing pre-selected so that
   I make an intentional choice.
5. As a first-time user, I want a guided onboarding that walks me through setup
   so that I'm not confused about what to do next.
6. As a keyless-preset user (on-device or local), I want the onboarding to skip
   the API key step so that setup is faster.
7. As a local or on-device user, I want the onboarding to skip the consent step
   so that I can go straight to testing and using the app.
8. As a user, I want to be able to "Set up later" on any onboarding step so
   that I can finish onboarding without a provider and come back to setup later.
9. As a user, I want clear, animated instructions on how to pin Kallilex to my
   share sheet so that I don't miss the most important discovery step.
10. As a user, I want to access the share sheet guide from the Settings tab so
    that I can re-learn the steps anytime.

## Implementation Decisions

### KallilexUI library target

**File:** `ios/KallilexKit/Package.swift` (add product)

Add a new product to the Package.swift:

```swift
.library(name: "KallilexUI", targets: ["KallilexUI"])
```

Create `ios/KallilexKit/Sources/KallilexUI/` directory for all shared UI views.
The target depends on `KallilexKit` (the core logic). Both app and extension
link `KallilexUI` in Xcode build phases.

### ConsentView

**File:** `ios/KallilexKit/Sources/KallilexUI/ConsentView.swift`

```swift
struct ConsentView: View {
    let profile: ProviderProfile
    let host: String
    let onAllow: () async -> Void
    let onNotNow: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("consent.title \(profile.name)")
                .font(.headline)
            
            // Body: "When you run a prompt, the text you share and the prompt's
            // instruction are sent to <host> (<profile name>) to be processed.
            // Kallilex doesn't collect or store your text itself; the provider's
            // privacy policy applies."
            Text("consent.body")
                .font(.body)
            
            Spacer()
            
            HStack(spacing: 12) {
                Button("consent.notNow") {
                    onNotNow()
                }
                .buttonStyle(.plain)
                .foregroundColor(.gray)
                
                Button(action: {
                    Task {
                        await onAllow()
                    }
                }) {
                    Text("consent.allow")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

**Behavior:**
- Shows only for `openAICompatible` profiles whose privacy class is `.cloud`
  (see ios-05 `classifyPrivacy`).
- Title: `String(localized: "consent.title")` with the profile name interpolated:
  "Send text to <name>?"
- Body text: `String(localized: "consent.body")` — "When you run a prompt, the
  text you share and the prompt's instruction are sent to <host> (<profile name>)
  to be processed. Kallilex doesn't collect or store your text itself; the
  provider's privacy policy applies." (The <host> is extracted from the profile's
  baseUrl, and <profile name> is `profile.name`.)
- Buttons: **Allow** (primary, calls `onAllow`) and **Not now** (secondary, calls
  `onNotNow`). Nothing is pre-selected.

### OnboardingViewModel

**File:** `ios/KallilexKit/Sources/KallilexUI/OnboardingViewModel.swift`

```swift
@Observable @MainActor
class OnboardingViewModel {
    enum Step: Equatable {
        case welcome
        case chooseProvider
        case apiKey
        case testConnection
        case consent(ProviderProfile)
        case shareSheetGuide
        case done
    }
    
    var steps: [Step] = []
    var currentStepIndex: Int = 0
    var selectedProvider: ProviderProfile?
    var selectedPreset: ProviderPreset?
    var apiKey: String = ""
    var testConnectionResult: Result<Void, ProviderError>?
    var consentGranted: Bool = false
    
    func buildSteps(for preset: ProviderPreset) {
        // Sequence depends on preset kind and needsApiKey
        steps = [.welcome]
        steps.append(.chooseProvider)
        if preset.needsApiKey {
            steps.append(.apiKey)
        }
        steps.append(.testConnection)
        if classifyPrivacy(baseUrl: preset.baseUrl) == .cloud
            && preset.kind == .openAICompatible {
            steps.append(.consent(selectedProvider ?? ProviderProfile(...)))
        }
        steps.append(.shareSheetGuide)
        steps.append(.done)
        currentStepIndex = 0
    }
    
    func nextStep() {
        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
        }
    }
    
    func previousStep() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }
    
    func skipToEnd() {
        currentStepIndex = steps.count - 1
    }
    
    func currentStep() -> Step {
        guard currentStepIndex < steps.count else { return .done }
        return steps[currentStepIndex]
    }
}
```

**Step sequencing logic:**
- Start with Welcome.
- Add Choose Provider (always).
- Add API Key only if `preset.needsApiKey` is true.
- Add Test Connection (always).
- Add Consent only if `preset.kind == .openAICompatible` and
  `classifyPrivacy(baseUrl: preset.baseUrl) == .cloud`.
- Add Share Sheet Guide (always).
- End with Done.

### Onboarding UI flow

**File:** `ios/KallilexKit/Sources/KallilexUI/OnboardingView.swift`

The onboarding is presented as a `fullScreenCover` from `RootTabView` while
`!appEnv.settings.onboardingCompleted`. Implement six view components:

#### WelcomeView

A three-step illustration showing:
1. Select text in an app.
2. Tap Share.
3. Tap Kallilex.

Use SF Symbols only (no custom graphics). Example symbols:
- Step 1: `square.and.pencil` or `text.quote` for text selection.
- Step 2: `square.and.arrow.up` for Share.
- Step 3: A generic app icon symbol or `sparkles`.

Title: `String(localized: "onboarding.welcome.title")` — "Welcome to Kallilex"
Footer: `String(localized: "onboarding.welcome.subtitle")` — "Use AI to rewrite
text right in any app."

Buttons: Continue, Skip (skips to Done and completes onboarding).

#### ChooseProviderView

A list of presets from `providerPresets()`. Tapping a preset saves it as
`selectedProvider` and moves to the next step. The on-device preset is only
shown on eligible devices (check to be added in ios-10).

Title: `String(localized: "onboarding.provider.title")` — "Choose a provider"

Each preset shows its label. Tapping it selects it and opens the provider
editor inline (same form from ios-06's Providers tab) to fill in details
(URL, model, API key if needed).

Button: Continue (enabled when a provider is selected), Skip (completes onboarding
without a provider and sets `onboardingCompleted = true`).

#### APIKeyView (only if preset needs one)

Shows the preset's label and asks the user to paste their API key.

Title: `String(localized: "onboarding.apiKey.title")` — "Add your API key"
Body: `String(localized: "onboarding.apiKey.prompt")` — "Get a key from <preset name>."

A `SecureField` for pasting. The key is stored in memory for now; it's saved to
Keychain only when the profile is saved at the end of onboarding.

Button: Continue (enabled when non-empty), Skip (moves to next step without a key).

#### TestConnectionView (always)

Calls `appEnv.actionRunner.testConnection(profile:apiKey:)` (with
`selectedProvider` and `apiKey`) and shows the result:
- Loading spinner while the request is in flight.
- Success message: `String(localized: "onboarding.testConnection.success")` —
  "✓ Connection successful"
- Error message: `error.localizedDescription` (`ProviderError` conforms to
  `LocalizedError`, see ios-05).

Button: Continue (always enabled, even if test failed), Skip (skips to next step).

#### ConsentView (cloud providers only)

Reuses `ConsentView` (see above). The Allow button calls a closure that:
1. Calls `grantConsent(profileID:host:)`.
2. Moves to the next step.

Button: Not now (moves to the next step without granting consent; user can grant
later in Settings).

#### ShareSheetGuideView

A reusable guide showing the exact steps to pin Kallilex to the share sheet.
See `ShareSheetGuideView` section below.

Button: Continue.

#### DoneView

Title: `String(localized: "onboarding.done.title")` — "You're all set!"
Body: `String(localized: "onboarding.done.subtitle")` — "Kallilex is ready to
help. Return to any app, select text, tap Share, and choose Kallilex."

Button: Start using Kallilex (saves the profile, sets `onboardingCompleted = true`,
dismisses the cover).

### ShareSheetGuideView

**File:** `ios/KallilexKit/Sources/KallilexUI/ShareSheetGuideView.swift`

A numbered list of five steps (animated with Reduce Motion respected):

1. `String(localized: "shareSheetGuide.step1")` — "Select text in any app and
   tap Share."
2. `String(localized: "shareSheetGuide.step2")` — "Swipe the app row to the end
   and tap More."
3. `String(localized: "shareSheetGuide.step3")` — "Tap Edit."
4. `String(localized: "shareSheetGuide.step4")` — "Add Kallilex to Favorites."
5. `String(localized: "shareSheetGuide.step5")` — "Kallilex now appears at the
   front of the row."

Each step is shown with an SF Symbol and the text. Use animations like slide-in
or fade for each step (respect `@Environment(\.accessibilityReduceMotion)`).

**To confirm:** the exact wording and steps for iOS 26 by checking the spike
ios-01 report or Apple's official documentation.

### Onboarding entry point in RootTabView

```swift
struct RootTabView: View {
    @Environment(AppEnvironment.self) var appEnv
    @State var showOnboarding = false
    
    var body: some View {
        TabView {
            // Four tabs...
        }
        .fullScreenCover(isPresented: .constant(!appEnv.settings.onboardingCompleted)) {
            OnboardingNavigationView(
                isPresented: Binding(
                    get: { !appEnv.settings.onboardingCompleted },
                    set: { completed in
                        if !completed {
                            Task {
                                try? appEnv.saveSettings { $0.onboardingCompleted = false }
                            }
                        }
                    }
                )
            )
        }
    }
}
```

The onboarding auto-dismisses when `onboardingCompleted` becomes true.

### Provider preset labels (localization)

The preset function `providerPresets()` is defined in ios-05 (KallilexKit). Each
preset label uses `String(localized:bundle: .module)` with keys like
`"provider.apple.onDevice"` and `"provider.custom"`. English values are defined
in ios-05; German translations are added in ios-11. Example:

```swift
// From ios-05's providerPresets()
ProviderPreset(
    id: "appleOnDevice",
    label: String(localized: "provider.apple.onDevice", bundle: .module),
    kind: .appleOnDevice,
    baseUrl: "",
    needsApiKey: false
)
```

## Testing Decisions

### ConsentView unit tests

- When `classifyPrivacy(baseUrl)` returns `.cloud` and `kind == .openAICompatible`,
  the view is shown.
- When privacy class is `.local` or `.lan`, the view is not shown.
- Tapping Allow calls the onAllow closure and calls `grantConsent(profileID:host:)`.
- Tapping Not now calls the onNotNow closure and does not grant consent.
- The host is correctly extracted from the baseUrl and shown in the body text.

### OnboardingViewModel unit tests

- **Step sequencing for on-device preset:** build steps for the on-device preset,
  verify it includes Welcome, ChooseProvider, TestConnection, ShareSheetGuide,
  Done; no API Key or Consent steps.
- **Step sequencing for keyless local preset (Ollama):** build steps for Ollama
  (`.lan`, no API key), verify no API Key or Consent steps.
- **Step sequencing for cloud preset (OpenAI):** build steps for OpenAI
  (`.cloud`, needs key), verify API Key and Consent steps are included.
- **Skip to end:** call `skipToEnd()`, verify `onboardingCompleted` is set true
  without a profile.
- **Set up later on any step:** tapping Skip on any step except Done should set
  `onboardingCompleted = true` and dismiss the flow (the view model tracks this
  or the view observes it).

### XCUITest

- **First launch onboarding:** on first launch (clean `AppSettings` with
  `onboardingCompleted = false`), verify the onboarding appears.
- **Complete onboarding:** go through all steps (Welcome, Choose Preset, Test
  Connection, Share Sheet Guide, Done) with the stub provider (via
  `-uiTestStubProvider` launch argument), verify the app lands on the Scratchpad
  tab.
- **Skip onboarding:** on the Welcome step, tap Skip, verify onboarding dismisses
  and `onboardingCompleted` is true (check by relaunching; onboarding doesn't
  appear).

## Out of Scope

- Onboarding persistence across app updates (Phase 5).
- Animated step transitions or complex graphics.
- Localization of the Share Sheet guide steps (exact wording per iOS 26 version).
- A retry or back button in the TestConnection step (Test always happens; result
  is informational).

## Further Notes

- PLAN.md §4.1 covers the onboarding flow and steps.
- PLAN.md §10.1 covers AI consent and the App Review requirement 5.1.2(i).
- PLAN.md §11 covers localization (labels are English here; German added in
  ios-11).
- The spike ios-01 report must confirm the exact wording and steps for pinning
  to the share sheet on iOS 26.
- The on-device model availability is checked in ios-10; the onboarding respects
  the device eligibility flag when showing the on-device preset.
- ShareSheetGuideView is reusable: it appears in onboarding (ios-07) and can be
  presented from the Settings tab (ios-06) as a linked view.
