# Kallilex Keyboard for iOS — Implementation Plan

Status: draft, awaiting product decisions (§14)
Branch: `ios-plan`
Date: 2026-11-05
Builds on: [PLAN.md](PLAN.md) (iOS v1, specs ios-01 to ios-14), §16 "Keyboard
extension"

This plan covers a custom keyboard extension, "Kallilex Keyboard". It is the
only way on iOS to put an AI result back into another app automatically. With
the Share Extension the user copies the result and pastes it by hand; the
keyboard can replace the selected text directly. The plan records the
platform rules, the product scope, the architecture and what it reuses from
v1, the technical unknowns for a spike, and the specs to cut from it. Nothing
here is built yet.

---

## 1. Goal

The desktop loop is *select → shortcut → edit → Replace*. The keyboard brings
the Replace step to iPhone:

> **select text → switch to Kallilex Keyboard (🌐) → tap a prompt → check the
> result → Replace**

The text is replaced in place in any app that allows third-party keyboards.
The Share Extension and the Scratchpad stay as they are. The keyboard is an
additional entry point, not a replacement.

The keyboard is **not** meant to become the user's main keyboard. It has to
be a usable typing keyboard (App Review requires it, §2.2), but the product
promise is "switch to it when you want AI, switch back afterwards". That
keeps the typing part deliberately simple: no autocorrect engine and no
word predictions in the first version (§3).

## 2. Platform rules (research summary)

### 2.1 What a keyboard extension can do

| Capability | Without Full Access | With Full Access |
|---|---|---|
| Type into the host app (`textDocumentProxy.insertText`, `deleteBackward`) | Yes | Yes |
| Read the selection (`textDocumentProxy.selectedText`, iOS 11+) | Yes | Yes |
| Read context around the cursor (`documentContextBeforeInput` / `AfterInput`) | Yes, limited to a few hundred characters, often only the current paragraph | Same |
| Move the cursor (`adjustTextPosition(byCharacterOffset:)`) | Yes | Yes |
| Network | **No** | Yes |
| App Group container | **Read-only** | Read and write |
| Shared Keychain access group | Unclear; assumed **no** (spike, §11) | Yes |
| General pasteboard | No | Yes |
| Haptics, input clicks | Unclear (spike) | Yes |
| Apple on-device model (Foundation Models) | Unknown (spike) | Unknown (spike) |

- `RequestsOpenAccess = YES` in the extension's `Info.plist` makes the
  "Allow Full Access" switch appear in Settings. Turning it on shows a
  system warning that the keyboard "can transmit anything you type". The
  keyboard checks `hasFullAccess` at runtime.
- The keyboard doesn't appear in secure text fields (passwords) or in phone
  pads, and apps can block third-party keyboards
  (`shouldAllowExtensionPointIdentifier`). iOS falls back to the system
  keyboard there by itself.
- **Memory.** Apple doesn't publish the limit. Reports range from about 30 MB
  (old iOS) to 50–60 MB (current), and jetsam kills the keyboard silently
  when it's crossed. Heavy SwiftUI text views (`TextEditor`, `TextField`)
  inside a keyboard are reported to spike memory. Target for Kallilex:
  **under 40 MB at peak**, measured on a device (§11).
- **Lifecycle.** The keyboard process lives while it's on screen. When the
  user dismisses the keyboard, switches keyboards or switches apps, it's
  suspended and can be killed. A request in flight doesn't survive that,
  the same as with the Share Extension.
- A keyboard can't open other apps, including its own container app
  (App Review, §2.2). Opening Settings is allowed, but
  `UIApplication.shared` isn't available in extensions, so even that needs
  a spike (§11, unknown 7).

### 2.2 App Review guideline 4.4.1 (verbatim)

Keyboard extensions **must**:

- provide keyboard input functionality (such as typed characters);
- follow the Sticker guidelines if the keyboard includes images or emoji;
- provide a method for progressing to the next keyboard;
- remain functional without full network access and without requiring full
  access;
- collect user activity only to enhance the functionality of the user's
  keyboard extension on the iOS device.

They **must not** launch other apps besides Settings, or repurpose keyboard
buttons for other behaviors.

Consequences for Kallilex:

1. **A full typing keyboard is mandatory.** A prompt bar without keys would
   be rejected. This is the largest single work item (§6).
2. **It must work without Full Access.** Typing works without it. The AI
   bar shows what it can offer without Full Access (the on-device model, if
   the spike confirms it works there) and otherwise explains why Full Access
   is needed for the other providers. It must never block typing.
3. **A globe key** (`needsInputModeSwitchKey`, `handleInputModeList`) is
   required.
4. **No Apple emoji** (5.2.5). Kallilex Keyboard has no emoji layer; the
   globe key reaches the system emoji keyboard.
5. **No "Open Kallilex" button** in the keyboard. Setup (providers, keys,
   prompts) stays in the app; the keyboard only explains where to find it.
6. 5.1.2(i) (AI consent) applies here too: the consent screen has to work
   inside the keyboard (§7.4).

## 3. Product scope

### Keyboard 1.0 (ships with app version 1.1.0)

1. **Typing keyboard** with the layouts below, shift and caps lock, a numbers
   and symbols layer, delete with key repeat, space, return (labelled after
   the host's `returnKeyType`), the globe key, key popups, long-press accents
   (ä ö ü ß é …), automatic capitalization after the host's
   `autocapitalizationType`, and "double space → period".
   - Layouts: **German QWERTZ** and **English QWERTY**. The default follows
     the device language; it can be changed in the app's settings.
   - Dark and light appearance after `keyboardAppearance` and the system
     appearance.
2. **AI bar** above the keys: the user's prompt chips (the same list and
   order as in the app), a privacy badge for the active provider, and a
   status line ("Select text to use a prompt", "123 characters selected").
3. **Result panel**, shown in place of the keys while a prompt runs or has a
   result: running state with Cancel, the result (scrollable, read-only),
   and **Replace**, **Copy**, **Retry**, **Discard**. After Replace, an
   **Undo** button for as long as it can work safely (§7.3).
4. **Consent inside the keyboard** for providers that need it (§7.4).
5. **Full Access states:** a short explanation card in the AI bar when Full
   Access is off, with the steps to turn it on.
6. **Container app:** an onboarding step and a Settings section "Keyboard":
   how to add the keyboard and allow Full Access, the layout choice, and a
   test field to try the keyboard right there.
7. **Localization** EN/DE and **accessibility** (VoiceOver for every key,
   Dynamic Type in the AI bar and the result panel).

### Not in keyboard 1.0

- **Autocorrect and word suggestions.** A keyboard without them is
  annoying for long typing, but Kallilex Keyboard is a "switch to it for AI"
  keyboard. `UITextChecker` suggestions in the bar are the obvious first
  follow-up.
- **Custom instruction typed in the keyboard.** It needs the keyboard to
  type into its own field instead of the host app (§7.5). Planned as an
  optional later spec; saved prompts cover the main flow.
- **Working without a selection** (whole field, sentence before the cursor).
  Reading a whole field means moving the cursor through the host's text
  with `adjustTextPosition`, which is fragile and slow. Later, if users ask.
- Swipe typing, dictation (the system dictation key is the host's, not
  ours), emoji, themes, more layouts (AZERTY, Swiss), iPad split keyboard.
- Streaming results into the host app as they arrive.
- A separate purchase. The keyboard is part of the paid app (decision D1).

## 4. User flows

### 4.1 Setup (container app)

1. After onboarding, and later from Settings → Keyboard, the app shows a
   short guide: *Settings → General → Keyboard → Keyboards → Add New
   Keyboard → Kallilex*, then *Kallilex → Allow Full Access*. A button opens
   the app's own page in Settings (`UIApplication.openSettingsURLString`),
   which lists "Keyboards" for apps with a keyboard extension, so the user
   lands one tap away.
2. The guide explains Full Access in plain words before the user sees
   Apple's warning: what it's needed for (sending the selected text to the
   user's own AI provider), what Kallilex never does (record or send what
   the user types), and that typing works without it.
3. The app shows whether the keyboard is added (by checking
   `UITextInputMode.activeInputModes` for our bundle id; spike) and offers a
   test field.

### 4.2 Main flow (in any app)

1. The user selects text and switches to Kallilex Keyboard with the globe
   key (or it's already active).
2. The AI bar shows "N characters selected" and the prompt chips are
   enabled. Without a selection they're disabled with the hint "Select text
   to use a prompt".
3. The user taps a chip. The keys give way to the result panel: "Rewriting…"
   with Cancel.
4. The result appears in the panel. The user taps **Replace**: the keyboard
   calls `insertText(result)`, which replaces the selection in the host app.
   The panel shows "Replaced" with **Undo** and **Done** (back to the keys).
5. **Retry** runs the same prompt again on the original text. **Copy** puts
   the result on the clipboard (Full Access needed). **Discard** returns to
   the keys without changing anything.

### 4.3 Edge cases

- **The selection changed while the prompt ran** (the user tapped into the
  host text): Replace checks that `selectedText` still equals the original
  (when the host reports it). If it doesn't, the panel says "The selection
  changed" and offers **Insert at cursor** and **Copy** instead of Replace.
- **The host reports no selection** although the user selected text (some
  web views): the hint changes after a selection-change event without
  `selectedText` to "This app doesn't share the selection with keyboards.
  Use Share → Kallilex instead."
- **Very long selections:** `selectedText` may be truncated by some hosts
  (spike). Above the existing 20,000-character soft limit the same
  long-text warning as in the editor appears.
- **No provider configured:** the AI bar says "Set up a provider in the
  Kallilex app" (text only, no button that opens the app).
- **Full Access off:** the chips run only with the on-device provider, if
  that works without Full Access (spike). Otherwise the bar shows the
  explanation card from §3 (5).
- **Consent missing:** §7.4.
- **Keyboard dismissed while running:** the run is cancelled; nothing is
  inserted later.

## 5. Architecture

### 5.1 New target

```
ios/
  KeyboardExtension/
    Info.plist              NSExtension: com.apple.keyboard-service,
                            RequestsOpenAccess = YES, PrimaryLanguage,
                            IsASCIICapable = YES, PrefersRightToLeft = NO
    KeyboardExtension.entitlements   App Group + Keychain access group
                                     (same as the ShareExtension)
    PrivacyInfo.xcprivacy
    Sources/
      KeyboardViewController.swift   UIInputViewController, principal class
    Resources/
  Config/KeyboardExtension.xcconfig  PRODUCT_BUNDLE_IDENTIFIER =
                                     $(KALLILEX_APP_ID).keyboard,
                                     APPLICATION_EXTENSION_API_ONLY = YES
```

- The pbxproj gets a third extension target in the same style as the
  ShareExtension: a synchronized folder, embedded by the app's "Embed App
  Extensions" phase, configured through its xcconfig. The `NSAppTransportSecurity`
  and `NSLocalNetworkUsageDescription` keys match the ShareExtension's
  (ios-14).
- `KeyboardViewController` stays thin, like `ShareViewController`: it builds
  the stores and the session, hosts the views, and forwards
  `textWillChange`/`textDidChange`/`selectionDidChange` to the session.

### 5.2 New code in `KallilexKit` / `KallilexUI`

Everything that can be tested without a running keyboard goes into the
package, so it's covered by `swift test`/`xcodebuild test` on the package:

| Piece | Where | What it does |
|---|---|---|
| `KeyboardLayout` | new target `KallilexKeyboardCore` (no UIKit) | The key rows for QWERTZ, QWERTY, numbers, symbols; long-press alternates; key widths |
| `KeyboardState` | `KallilexKeyboardCore` | The state machine: layer, shift/caps, auto-capitalization, double-space period, key repeat timing. Pure and unit-tested |
| `TextDocument` protocol | `KallilexKeyboardCore` | A minimal wrapper of `UITextDocumentProxy` (`selectedText`, contexts, `insertText`, `deleteBackward`, `adjustTextPosition`). A fake implements it in tests |
| `KeyboardSession` | `KallilexUI` | The AI part: the selection snapshot, run/cancel/retry through `ActionRunning`, the result, Replace and guarded Undo against a `TextDocument`, consent through `ConsentGranting`. Built like `EditorSession` and reusing its types |
| AI bar and result panel views | `KallilexUI` | SwiftUI, reusing `PromptChipsBar`, `PrivacyBadge`, `StatusBanner`, `ConsentView` (in a compact layout) |
| Key grid view | `KeyboardExtension` (UIKit) | The keys themselves, drawn and hit-tested in UIKit for latency and memory (decision D4). Driven by `KeyboardState` |

`KallilexKeyboardCore` is a separate library target so the layout and state
logic stays free of UIKit and SwiftUI and the keyboard can link only what it
needs.

### 5.3 Reuse from v1 and the changes it needs

- `ActionRunner`, providers, prompt assembly, privacy classification,
  `ConsentRequirement`, `ProviderError` and its messages: **reused as they
  are**.
- `AppGroupSettingsStore.load()` coordinates the file with **write intent**
  (for corruption recovery). Without Full Access the container is read-only,
  so this probably fails. Add a **read-only load** that coordinates for
  reading only, never renames a corrupt file, and reports corruption as a
  settings error. The keyboard uses it whenever `hasFullAccess` is false.
- `KeychainSecretStore`: when the read fails without Full Access, the
  runner must treat it as "no key" (it already degrades this way,
  `keyReadFailureDegradesToNoKeyAndStillCallsTheProvider`), and the bar
  shows the Full Access card instead of a misleading "invalid key" error.
- `EditorSession` stays as it is. `KeyboardSession` is a sibling, not a
  subclass: the editor owns an editable text, the keyboard owns a snapshot of
  someone else's text, and mixing the two would complicate both.
- `Pasteboard`: the keyboard's Copy uses the same protocol, enabled only
  with Full Access.

### 5.4 Memory budget

- The UIKit key grid plus one `UIHostingController` for the AI bar and panel.
  No `TextEditor`/`TextField` in the keyboard: the result is shown in a
  read-only `Text` in a `ScrollView`.
- The ShareExtension peaked at 36 MB with SwiftUI, networking and a rewrite
  (spike ios-01). The keyboard has to stay below about 40 MB with the keys
  added. The spike (§11) measures a bare UIKit grid, the grid plus the
  SwiftUI bar, and a request.
- Settings are loaded once per `viewWillAppear`, not on every keystroke.

## 6. The typing keyboard in detail

- **Rows (DE):** `q w e r t z u i o p ü` / `a s d f g h j k l ö ä` /
  ⇧ `y x c v b n m` ⌫ / `123` 🌐 space `.` return. The EN layout has 10/9/7
  letters and no umlaut keys; umlauts, ß and accents are on long-press in
  both.
- **Layers:** letters, numbers/punctuation (`123`), symbols (`#+=`).
- **Shift:** one tap = next letter capitalized; double tap = caps lock;
  auto-shift after `. ! ?` + space and at the start of a field, following
  `autocapitalizationType` (`.none`, `.words`, `.sentences`,
  `.allCharacters`).
- **Delete:** single delete, repeat after 0.5 s, word-wise after about 2 s.
- **Return:** inserts `"\n"`; its label follows `returnKeyType` (Go, Search,
  Send, Done…).
- **`keyboardType` hints:** for `.emailAddress` and `.URL` the bottom row
  shows `@` and `.` (and `/`, `.com` for URLs). Number pads and phone pads
  get the system keyboard anyway.
- **Feedback:** key popups on press; input clicks
  (`UIInputViewAudioFeedback`) and light haptics where available (spike:
  without Full Access).
- **Accessibility:** every key is an accessibility element with
  `.keyboardKey` trait and a spoken label ("shift", "delete", "Umlaut a").
  VoiceOver users type with the standard "touch typing" behavior.
- **Height:** the system default keyboard height plus the AI bar (about
  44 pt). The result panel uses the same height as the keys, so the host
  layout doesn't jump; long results scroll.

## 7. The AI part in detail

### 7.1 Selection snapshot

On `selectionDidChange`/`textDidChange`, `KeyboardSession` reads
`selectedText` and keeps only its length for the status line. The text
itself is read again at the moment the user taps a chip and is kept in
memory only for the run, Retry and Undo. Nothing is written to disk.

### 7.2 Run

The same `ActionRunner.run(text:action:)` the editor uses, with the same
profile, prompts and consent rules. Cancel and dismissal cancel the task.
The outcome maps to the panel states: running, result, failed (with the
`ProviderError` message), not configured, consent required.

### 7.3 Replace and Undo

- **Replace** calls `insertText(result)` while the original selection is
  still selected. This replaces the selection in standard UIKit text views
  and is recorded in the host's own undo stack (shake to undo works).
- **Undo** (our button) deletes the inserted result with `deleteBackward`
  and inserts the original again. It's offered only while it's safe:
  `documentContextBeforeInput` must end with the result (or its last 200
  characters), and nothing has changed since. Otherwise the button
  disappears. The number of `deleteBackward` calls has to match how the
  host counts characters (grapheme clusters vs. UTF-16, newlines in some
  web views); the spike checks this per app (§11, unknown 11). If it isn't
  reliable, the button is dropped and the panel points to the host's own
  undo.

### 7.4 AI consent (5.1.2(i))

- When `ActionRunner` returns `.consentRequired(profile)`, the panel shows
  `ConsentView` in a compact layout: the provider name, the host, the
  sentence "The text you select is sent to <host> to be processed", and
  **Allow** / **Not now**. Allow writes the consent through
  `SettingsService` into the App Group and runs the prompt.
- Writing needs Full Access, but so does every provider that needs consent
  (it's a network provider), so there's no extra case.

### 7.5 Custom instruction (later, optional)

A "Custom…" chip would open a one-line field in the bar. While it's focused,
key presses go into the field's buffer instead of `textDocumentProxy`. That
needs an input-routing switch in `KeyboardState` and a non-`TextField`
display (memory). It's planned as its own spec after keyboard 1.0.

## 8. Privacy and security

- **No keystroke collection.** The keyboard never logs, stores or sends what
  the user types. Only the selected text, at the moment the user taps a
  prompt, goes to the user's chosen provider, exactly as in the Share
  Extension. The document context is read locally only (for
  auto-capitalization and the Undo check).
- No analytics, no crash reporting SDK (same as v1).
- **Privacy manifest** for the keyboard target: no tracking, no collected
  data types, required-reason APIs as used (file timestamp/user defaults, if
  any).
- **Privacy policy** (website, EN and DE): a "Kallilex Keyboard" section
  covering Full Access, what is read and when, and what is never sent.
- **App Review notes:** why Full Access is requested, that the keyboard
  works without it, how to test (on-device model or the reviewer key), and
  that consent is asked per provider inside the keyboard.
- `NSAllowsArbitraryLoads` applies to the keyboard as in ios-14; the same CI
  check is extended to the third bundle.

## 9. Testing

- **Unit tests (package):** `KeyboardLayout` (rows per layout, alternates),
  `KeyboardState` (shift, caps lock, auto-capitalization per type,
  double-space period, layer switching, delete repeat timing with an
  injected clock), `KeyboardSession` against a fake `TextDocument` and a
  stub `ActionRunning` (selection snapshot, run/cancel, Replace, Undo guard,
  "selection changed", consent, Full Access off, read-only settings load).
- **UI tests (simulator):** XCUITest can't add a third-party keyboard in
  Settings reliably, so the app gets a DEBUG-only **keyboard harness**
  (`-uiTestKeyboardHarness`, like the share harness): a text view whose
  `inputViewController` is the real keyboard view controller, with the stub
  provider. UI tests type with it, select text, run a prompt, Replace, Undo,
  and run the accessibility audit on it.
- **Memory:** an Instruments run on a device for each release, with the
  numbers recorded in the release spec.
- **Manual host-app matrix** (device): Notes, Mail, Messages, Safari (text
  field and a `contenteditable` editor), WhatsApp, Signal, Slack, Google
  Docs, Pages, Gmail. Per app: is `selectedText` delivered, does Replace
  replace, does Undo work, is the keyboard blocked.
- **CI:** the keyboard target is built and tested by the existing
  `ios.yml`. New checks: the appex is embedded, it has the App Group and
  Keychain group, `RequestsOpenAccess` is true, the ATS keys match ios-14,
  the privacy manifest is present.

## 10. Phases

| Phase | Outcome | Exit criterion |
|---|---|---|
| **K0 — Spike** | A throwaway keyboard answers the unknowns in §11 | A spike report in `issues-ios/`, every unknown answered or with a fallback |
| **K1 — Foundation** | Target, CI, `KallilexKeyboardCore` with layouts and state, read-only settings load | CI green; an empty keyboard with working keys runs on a device |
| **K2 — Typing keyboard** | The full keyboard from §6 | Typing works in the harness and in Notes, Mail, Messages on a device |
| **K3 — AI bar and Replace** | §7.1–7.4 | The main flow works in Notes and Mail on a device, with and without Full Access |
| **K4 — App setup** | Onboarding step, Settings → Keyboard, test field | A new user can add the keyboard and allow Full Access from the guide alone |
| **K5 — Polish** | Localization, accessibility, memory audit, privacy manifest, policy, review notes | Checklist complete |
| **K6 — Release** | App 1.1.0 with the keyboard | Live in the App Store |

Keyboard work starts after 1.0.0 is submitted, so it doesn't delay the first
release (decision D2).

## 11. Spike unknowns (K0)

1. **Foundation Models in a keyboard:** does `SystemLanguageModel` report
   available, and does a rewrite run, with and without Full Access? Memory
   cost there?
2. **Read-only App Group:** does `NSFileCoordinator` with write intent fail
   without Full Access? Does a read-only coordinated read work?
3. **Keychain access group without Full Access:** can the keyboard read the
   API key? (Expected: no.)
4. **Network with Full Access:** LAN (`.local`, RFC1918), Tailscale
   (`100.64/10`) and public `http://`/`https://` from the keyboard. Does the
   Local Network permission granted to the app cover the keyboard, or does
   the keyboard need its own?
5. **Memory limit and our footprint** on the user's iPhone 16 (iOS 27) and
   one iOS 26 device: a bare UIKit grid, grid plus SwiftUI bar, peak during
   a request, and the point where jetsam kills it.
6. **`selectedText` per app** (the matrix in §9): delivered or `nil`, and
   whether long selections are truncated.
7. **Opening Settings from the keyboard:** is there an allowed API, or do we
   stay with instructions?
8. **Haptics and input clicks without Full Access.**
9. **Height:** how much height can the keyboard take, and does a height
   change between keys and panel cause host layout jumps?
10. **Lifecycle:** does a URLSession request survive a brief keyboard
    disappearance (e.g. a host alert)? What happens when the host app goes
    to the background?
11. **Undo by `deleteBackward`:** do N calls delete exactly the N characters
    we inserted in each matrix app (emoji, combining accents, newlines)?
12. **Detecting the added keyboard** from the app
    (`UITextInputMode.activeInputModes`), for the setup guide.

## 12. Proposed specs

Numbering continues after v1 (`spec-ios-NN-*.md`).

| Spec | Title | Depends on | Key content |
|---|---|---|---|
| ios-15 | Keyboard spike | ios-14 | §11 |
| ios-16 | Keyboard target, CI, read-only settings | ios-15 | §5.1, §5.3 store changes, CI checks |
| ios-17 | Keyboard core: layouts and state | ios-16 | `KallilexKeyboardCore`, §6 logic, unit tests |
| ios-18 | Typing keyboard UI | ios-17 | UIKit key grid, popups, long-press, repeat, globe, appearance, keyboard harness |
| ios-19 | AI bar, result panel, Replace and Undo | ios-18 | `KeyboardSession`, §7.1–7.4, Full Access states |
| ios-20 | App setup and settings for the keyboard | ios-19 | §4.1, layout setting, test field |
| ios-21 | Keyboard localization, accessibility and memory audit | ios-20 | EN/DE, VoiceOver keys, Dynamic Type, Instruments numbers |
| ios-22 | Keyboard privacy, review notes, website, release 1.1.0 | ios-21 | §8, host-app matrix, release checklist update |
| later | Custom instruction in the keyboard; suggestions bar; no-selection modes | ios-22 | §3 "Not in keyboard 1.0", §7.5 |

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| App Review rejects the keyboard (4.4.1, Full Access) | 1.1.0 delayed | A complete typing keyboard, works without Full Access, clear review notes, no app-launch buttons |
| Users don't trust "Allow Full Access" | Low adoption | Plain-language explanation before Apple's warning, privacy policy section, open source |
| `selectedText` is `nil` in important apps (web views) | The main flow fails there | Spike matrix, a clear hint that points to the Share Extension, document in the FAQ |
| Memory limit | The keyboard disappears silently | UIKit keys, no text views, device measurements per release |
| Replace or Undo misbehaves in some hosts | Lost or doubled text | Replace only on an unchanged selection; Undo only when the guard passes; host undo as the fallback |
| Typing quality without autocorrect | Users switch away quickly | Positioned as an AI keyboard to switch to; suggestions as the first follow-up |
| Foundation Models not available in keyboards | No AI without Full Access | Accept: typing works without Full Access, AI needs it; say so in the card |
| Scope creep into a full keyboard product | Months of work | Strict "not in 1.0" list (§3) |

## 14. Decisions needed (product owner)

| # | Question | Recommendation |
|---|---|---|
| D1 | Is the keyboard part of the paid app, or a separate purchase? | Part of the paid app, no in-app purchase (consistent with Q10) |
| D2 | When does keyboard work start? | After 1.0.0 is submitted; it ships as 1.1.0 |
| D3 | Layouts in 1.0? | German QWERTZ and English QWERTY, chosen in the app |
| D4 | Keys in UIKit or SwiftUI? | UIKit for the keys (latency, memory), SwiftUI for the AI bar and panel. The spike can overturn this if SwiftUI stays well under budget |
| D5 | Preview before Replace, or replace immediately? | Preview with a Replace button in 1.0; an "Replace immediately" setting later |
| D6 | Our own Undo button? | Yes, guarded (§7.3), dropped if the spike shows it's unreliable |
| D7 | Custom instruction in the keyboard in 1.0? | No, later (§7.5) |
| D8 | Autocorrect/suggestions in 1.0? | No; `UITextChecker` suggestions as the first follow-up |

## 15. Sources

- App Review Guidelines 4.4.1, 5.2.5:
  <https://developer.apple.com/app-store/review/guidelines/>
- Apple: [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard),
  [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard),
  [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards),
  [UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)
- Read-only App Group without open access:
  [Apple forums 728434](https://developer.apple.com/forums/thread/728434)
- Keyboard memory reports:
  [dev.to: hard constraints of a keyboard extension](https://dev.to/tbds_2dadf2b626f315902eae/the-three-hard-constraints-of-an-ios-keyboard-extension-46af),
  [Fleksy: limitations of custom keyboards](https://fleksy.com/blog/limitations-of-custom-keyboards-on-ios)
- OWASP MASTG keyboard Full Access test:
  [MASTG-TEST-0390](https://mas.owasp.org/MASTG/tests/ios/MASVS-PLATFORM/MASTG-TEST-0390/)
