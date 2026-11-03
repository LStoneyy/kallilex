# Spike ios-01 Report — Platform constraints and unknowns

Date: 2026-11-03

## Setup (applies to all sections)

- Device: iPhone 16 (iPhone17,3), iOS 27.0.1, Apple Intelligence enabled. No
  iOS 26 device was available; results for iOS 26 are assumed, not observed.
- Build: Xcode 27.2 (27B52), iOS 27.2 SDK, deployment target iOS 26.0,
  Swift 6 language mode.
- Signing: free Personal Team, automatic provisioning through
  `xcodebuild -allowProvisioningUpdates`.
- Prototype: a container app plus two Share Extensions. Extension A is plain.
  Extension B adds `NSExtensionJavaScriptPreprocessingFile`.
  - Bundle IDs use the throwaway namespace `de.lschaffrath.kallilexspike*`, so
    `com.webcommits.kallilex` was never registered to the Personal Team.
  - The code lived in `spikes/ios-01/` and was excluded from git through
    `.git/info/exclude`. It is not committed.
- Measurement:
  - Every process appended JSON lines to a log in the App Group container,
    which was pulled with `xcrun devicectl device copy from`.
  - Memory is `phys_footprint` from `task_info(TASK_VM_INFO)`, the value
    jetsam uses, sampled every 100 ms.
  - Latency is wall-clock time around the call.
- Test server: a Python stdlib server on the Mac (`0.0.0.0:8080`, same
  Wi-Fi), returning a canned OpenAI chat-completions response.
- The log contains user text; only counts, codes and timings are quoted here.

## Unknown 1: Which host apps deliver the selected text as plain text?

### Method

Text was selected and shared to the extensions three times; one of these
shares was confirmed to come from Notes. For each share, the extension logged:
- every `NSExtensionItem`
- `attributedContentText`
- each attachment's `registeredTypeIdentifiers`
- the result of loading `public.plain-text`, `public.utf8-plain-text`,
  `public.rtf`, `public.url` and `com.apple.property-list`

### Result

- All three shares delivered one item with one attachment registered only as
  `public.plain-text`. It loaded as a Swift `String` whose length matched
  `attributedContentText`. No RTF and no URL arrived.
- Notes is confirmed. The host app was not tagged for the other two shares,
  so they are known to be "a text-editing app" but not which one.
- The user reported that the selected text appeared in the editor in every
  app they tried.
- Not tested:
  - Mail, Messages, WhatsApp, Pages, Google Docs and Chrome individually
  - Safari with a selection, and Safari without a selection (unknown 1b)

### Evidence

`share.attachment` → `registeredTypeIdentifiers: public.plain-text`.
`share.loadItem` → `swiftType: String`, `typeIdentifier: public.plain-text`.
`share.bestText` → `source: plainText`. Seen three times; for the confirmed
share, `hostApp: Notes` on `share.copyResult`.

### Consequence for later specs

- **ios-09:** keep `public.plain-text` as the primary path, with
  `attributedContentText` as the fallback.
- **ios-09:** keep the JS preprocessing file and its fallback design as
  specified, since 1b is unanswered. Verify Safari, with and without a
  selection, during ios-09 acceptance testing.
- **ios-12 and ios-13:** keep the per-app matrix in the manual test plan.

## Unknown 2: Local Network permission — app or extension, with or without ATS?

### Method

`NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES` and
`NSLocalNetworkUsageDescription` were set in all three targets. Three
requests were run from the extension and from the app:
- an mDNS POST to `http://<mac>.local:8080/v1/chat/completions`
- a LAN-IP POST to `http://192.168.0.159:8080/v1/chat/completions`
- an HTTPS GET to `https://www.apple.com/` as a control

The Local Network prompt was denied once in the app, and later allowed in
Settings.

### Result

- **ATS:** plain `http://` to `.local` and to a private IP is allowed with
  `NSAllowsLocalNetworking` alone. No ATS errors occurred.
- **Prompt location:** the Local Network prompt appeared only from the
  container app.
- **Extension before permission:** the extension reached both LAN targets,
  with status 200, before any permission had been granted. It showed no
  prompt.
- **App after denial:** the app's LAN requests failed with two different
  errors:

  | Target | Error | Time | Underlying stream error |
  |---|---|---|---|
  | LAN IP | `NSURLErrorDomain -1009` ("The Internet connection appears to be offline") | 2–5 ms | `_kCFStreamErrorDomainKey 1`, `_kCFStreamErrorCodeKey 50` (POSIX `ENETDOWN`) |
  | mDNS host | `NSURLErrorDomain -1001` (timed out) | after the full 15 s timeout | domain 4, code -2103 |

  The HTTPS control succeeded during the same window.
  `NSURLErrorNetworkUnavailableReasonKey` and an `_NSURLErrorNWPathKey`
  description were not present in `userInfo`.
- **After allowing:** once Local Network access was allowed in Settings, all
  targets succeeded from the app.
- **Not tested:** the extension's behavior while the app's permission is
  denied.

### Evidence

- Extension, before any prompt: `network.success` for mDNS (194 ms) and the
  LAN IP (96 ms).
- App, after denial: `network.failure` with `code -1001` (15301 ms) for mDNS
  and `code -1009` (5.1 ms, 2.5 ms) for the LAN IP, while the HTTPS control
  succeeded.
- App, after allowing: `network.success` for mDNS (65 ms) and the LAN IP
  (21 ms).

### Consequence for later specs

- **ios-05:** keep `localNetworkDenied`, but as a heuristic, not an exact
  mapping.
  - Map `URLError.notConnectedToInternet` (-1009) to `localNetworkDenied`
    when `classifyPrivacy(host)` is `lan` or `local`. A private address that
    fails as "offline" is the denied-permission case.
  - A timeout to a `.local` host cannot be told apart from a host that is
    down. Keep it as `timeout`.
  - Wording for ios-05: "map -1009 on a LAN/local host to
    `localNetworkDenied`; everything else unchanged".
- **ios-07:** onboarding must trigger the Local Network prompt from the
  container app. Test the connection when the user saves a LAN provider,
  because the extension never shows the prompt itself.
- **ios-09:** because the extension's behavior under denial is untested, the
  extension must show the `localNetworkDenied` message with a pointer to
  Settings → Privacy & Security → Local Network → Kallilex. It must not
  assume it can prompt.

## Unknown 3: Do Foundation Models work inside a Share Extension, and at what cost?

### Method

- **Symbols:** verified against the SDK's
  `FoundationModels.swiftinterface` (Xcode 27.2).
- **Calls:**
  - `SystemLanguageModel.default.availability`
  - `.contextSize`
  - `.tokenCount(for:)`, iOS 26.4+
  - one `LanguageModelSession().respond(to:)` with a German rewrite
    instruction plus the text
  - on iOS 27, `Response.usage`
- **Where:** in the app, with a sample business email of about 300 words,
  and twice inside a Share Extension, with shared text.

### Result

| Run | Input tokens (usage) | Output tokens | Latency | Memory before → peak → after |
|---|---|---|---|---|
| App, ~300-word email | 515 | 345 | 10.6 s | 20.1 → 22.1 → 21.7 MB |
| Extension B, short text | 133 | 69 | 2.1 s | 32.1 → 34.2 → 34.2 MB |
| Extension A, very short text | 80 | 15 | 1.6 s | 19.8 → 24.9 → 24.9 MB |

- **Availability:** `available` everywhere; `contextSize` 4096.
- **Works in the extension:** yes. Foundation Models run inside a Share
  Extension.
- **Where the model runs:** in a system process, not in-process. The
  extension's footprint grows by 2–5 MB during inference, which is far less
  than a language model would need in-process.
- **Token counts:** `tokenCount(for:)` on the prompt string was lower than
  `usage.input.totalTokenCount` (461 vs 515, 79 vs 133, 26 vs 80). The
  session adds about 54 tokens of overhead.
- **Speed:** output is about 33 tokens/s for the long run.

### Evidence

`foundationModels.rewrite` events in the app, `share` and `sharejs` logs, with
fields `latencyMs`, `memBeforeMB`, `memPeakMB`, `memAfterMB`,
`promptTokenCount`, `inputTotalTokenCount`, `outputTotalTokenCount` and
`contextSize`.

Verified symbols:
- `SystemLanguageModel.default.availability`: `.available`, or
  `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`
- `contextSize: Int`
- `tokenCount(for:) async throws -> Int`, iOS 26.4+
- `LanguageModelSession(instructions:)`
- `respond(to:) -> Response<String>`
- `Response.usage`, iOS 27.0+ only

### Consequence for later specs

- **ios-10:** ship the on-device provider in the extension in v1.
- **ios-10, context check:**
  - Use `contextSize` and `tokenCount(for:)`, both available from iOS 26.4.
  - Reserve about 64 tokens of session overhead, plus room for the output,
    before reporting `contextTooLong`.
  - On iOS 26.0–26.3 there is no `tokenCount`; fall back to a character
    estimate.
- **ios-10:** `Response.usage` is iOS 27+ only and must stay behind
  `#available`.
- **ios-10:** a full rewrite of about 300 words takes about 10 s, so the
  extension needs a visible progress state and Cancel during on-device runs.
  ios-08 already has these.
- **PLAN.md To-confirm:** the symbol names for the iOS 26.4 Foundation Models
  APIs are now confirmed.

## Unknown 4: Does `extensionContext.open(_:)` deep-link from a Share Extension to the app?

### Method

`extensionContext?.open(URL(string: "kallilexspike://settings/providers")!)`
was called from the extension seven times, and the completion `Bool` was
logged. The app registers the scheme and logs `onOpenURL`. No responder-chain
workaround was used.

### Result

No. The completion returned `false` every time, the app did not open, and
`onOpenURL` never fired.

### Evidence

Seven `share.openApp` events with `success: false`; no app event with the URL.

### Consequence for later specs

- **ios-09:** remove the "Open Kallilex" button from the "No provider
  configured" card. Show an instruction instead: "Open the Kallilex app to
  set up a provider." No `extensionContext.open` call, and no
  `UIApplication` or responder-chain workaround, which is an App Review risk.
- **ios-09:** the same applies to any other "open the app" affordance in the
  extension.
- **ios-12:** remove any review note that mentions deep linking from the
  extension.

## Unknown 5: Peak memory of the SwiftUI extension during a real HTTP request

### Method

The live `phys_footprint` sampler ran in the extension while the SwiftUI form
was shown. The extension ran the three network requests, including a
253 KB HTTPS response and two LAN chat-completions POSTs. It then ran an
on-device rewrite.

### Result

- **Network phase:** peak 36.0 MB in extension B (with JS preprocessing),
  after all network requests. Peak 34.2 MB after its on-device rewrite.
- **Extension A** (without the network phase): 19.8 MB at rest, 24.9 MB peak
  with an on-device rewrite.
- **Target:** both are well below the PLAN.md §8.3 target of 50 MB and the
  roughly 120 MB limit.
- **Isolation:** this is not an isolated "HTTP request only" peak. It
  includes the input dump, the SwiftUI UI and a 253 KB response, so it is an
  upper bound for the request phase.

### Evidence

`memory.mark` with `foundationModels.before`, in sharejs:
`currentMB 32.11, peakMB 36.03`, recorded after the network requests. In
share: `19.80`, then `peakMB 24.94`.

### Consequence for later specs

- **ios-09:** the 50 MB budget holds with SwiftUI.
- **ios-09:** no special memory work is needed beyond what is specified,
  such as not keeping large responses around.
- **ios-09:** keep the snippet `truncate(300)` for error bodies.

## Unknown 6: After Copy in the extension, does one Paste replace the original selection?

### Method

1. In Notes, select text and share it to extension A.
2. Run an on-device rewrite (20 characters of output).
3. Tap "Copy result & close", which sets `UIPasteboard.general.string` and
   then calls `completeRequest`.
4. Back in Notes, check the selection and paste.

An earlier attempt copied an empty result and was discarded.

### Result

- **Selection after return:** not kept. Back in Notes the selection was gone.
- **Single Paste:** does not replace the original text. The original text
  stays, and a Paste inserts at the cursor.
- **Workaround:** re-selecting the original text and then pasting inserts the
  rewritten text correctly. The clipboard write works.
- **Not tested:** Safari, Mail and Messages. This was spot-checked in one
  app only.

### Evidence

`share.copyResult` with `hostApp: Notes, length: 20`, plus the user's
observation on the device.

### Consequence for later specs

- **PLAN.md §8, flow step 5:** the assumption "the selection is usually still
  there; one Paste replaces it" is wrong for Notes on iOS 27. The core flow
  becomes select → Share → prompt → Copy → re-select → Paste.
- **ios-09:**
  - Change the "Copied" confirmation to tell the user to re-select and paste.
    Proposed text: "Copied. Select the original text and paste to replace
    it."
  - Make the first-run hint about re-selecting part of the extension's
    first-use tips.
- **ios-11:** add and translate the new string(s).
- **ios-12:**
  - Update the App Review notes walkthrough: "select the text again and tap
    Paste".
  - Update the website how-to.
- **ios-13:** keep the paste-back row in the device matrix and test Mail,
  Messages and Safari.
- **Later feature:** a custom keyboard extension remains the only path to
  automatic replace (PLAN.md §3). This finding strengthens the case for it.

## Unknown 7: Can a free Personal Team provision App Groups and Keychain sharing?

### Method

All three targets declared:
- `com.apple.security.application-groups = [group.de.lschaffrath.kallilexspike]`
- `keychain-access-groups = [$(AppIdentifierPrefix)de.lschaffrath.kallilexspike.shared]`

They were built for the device with automatic provisioning. The signed
entitlements were checked with `codesign -d --entitlements`. At runtime, the
app wrote a timestamp to App Group `UserDefaults`, to a file in the group
container and to a Keychain item with the shared access group. The extension
then read all three.

### Result

Yes. Both capabilities were provisioned on the free Personal Team for the app
and both extensions; there were no signing errors. At runtime, the extension
read back the value the app had just written from all three stores. Keychain
writes and reads returned `errSecSuccess`.

### Evidence

- The signed entitlements contained the App Group and
  `5TFR2L29DY.de.lschaffrath.kallilexspike.shared` for all three bundles.
- App: `sharedStore.write`, `keychainStatus 0`.
- Extension: `sharedStore.read` returned the same timestamp for `file`,
  `userDefaults` and `keychain`, with `keychainStatus 0`.

### Consequence for later specs

- **PLAN.md §18, Q2:** the paid account is not required for Phase 1 or
  Phases 2–5 development on a device. It is required for TestFlight and App
  Store distribution (ios-13).
- **Limits of the free team:**
  - Profiles expire after 7 days.
  - A limited number of App IDs can be registered per week, so avoid
    creating extra bundle IDs.
- **Before the paid account:** develop with a personal bundle ID prefix
  through `Local.xcconfig`. This avoids registering `com.webcommits.kallilex`
  to the Personal Team before the paid account exists.
- **ios-02** already reads the identifiers from xcconfig. Make sure the
  bundle ID prefix, App Group and Keychain group can all be overridden
  there, not just the team.

## Additional findings

- **Xcode version:** the toolchain on the development Mac is Xcode 27.2 with
  the iOS 27 SDK, not Xcode 26. Deployment target iOS 26.0 builds cleanly.
  Specs that say "Xcode 26" should read "Xcode 26 or later". The CI runner
  image must provide an iOS 26+ SDK.
- **Synchronized folders:** a hand-written `project.pbxproj` with
  `PBXFileSystemSynchronizedRootGroup`, objectVersion 77, works. One
  synchronized `Shared/` group can be compiled into several targets.
- **Hand-written Info.plist** (`GENERATE_INFOPLIST_FILE = NO`): it must
  contain `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundlePackageType`
  (`APPL` or `XPC!`), `CFBundleName` and `CFBundleInfoDictionaryVersion`.
  Without them the build succeeds, but `devicectl` refuses the install with
  "Failed to get the identifier for the app to be installed."
- **Pulling files from the App Group container:** `devicectl` can only read
  files under `Library/` there. Debug logs meant to be pulled from a device
  belong in `Library/Caches`.

## Open items

| Item | Status | Fallback |
|---|---|---|
| 1b, Safari without a selection (JS preprocessing) | Not tested | Keep the ios-09 design with the JS file. Verify during ios-09 acceptance. |
| 1, per-app delivery (Mail, Messages, WhatsApp, Pages, Google Docs, Chrome, Safari) | Notes confirmed; other apps untagged | Scratchpad fallback. Matrix in ios-13. |
| 2, extension LAN requests while the permission is denied | Not tested | The extension shows `localNetworkDenied` with a pointer to Settings. |
| 6, paste-back in Mail, Messages, Safari | Not tested | Assume re-selection is needed everywhere. |
| Behavior on an iOS 26 device | Not tested (iOS 27.0.1 only) | Test on an iOS 26 device or simulator during ios-09 and ios-10. |
