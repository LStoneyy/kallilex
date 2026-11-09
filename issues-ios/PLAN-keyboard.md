# Kallilex Keyboard for iOS — Implementation Plan

Status: decisions taken 2026-11-05 (§15); specs ios-15–23 cut; spike done (spike-ios-15-report.md)
Branch: `ios-plan`
Date: 2026-11-05
Builds on: [PLAN.md](PLAN.md) (iOS v1, specs ios-01 to ios-14)

This plan covers a custom keyboard extension, "Kallilex Keyboard", and the
on-device dictation it needs. It records the platform rules, the product
design, the architecture and what it reuses from the app, the technical
unknowns for a spike, and the specs to cut from it. Nothing here is built
yet.

The keyboard ships **in 1.0.0**, as part of the paid app (D1, D2). The
release spec ios-13 therefore waits for the keyboard specs (§13).

---

## 1. Goal

Kallilex Keyboard is **a Kallilex panel in keyboard form, not a general
typing keyboard**. It brings the app's Scratchpad into every app:

> **get text into the Scratchpad** (take the selection, type it, or dictate
> it) **→ tap a prompt → Insert** into the app you're in.

The desktop loop *select → shortcut → edit → Replace* becomes possible on
iPhone without copy and paste. The Share Extension and the app's Scratchpad
stay as they are.

## 2. Platform rules (research summary)

### 2.1 What a keyboard extension can do

| Capability | Without Full Access | With Full Access |
|---|---|---|
| Type into the host app (`textDocumentProxy.insertText`, `deleteBackward`) | Yes | Yes |
| Read the selection (`textDocumentProxy.selectedText`) | Yes | Yes |
| Read context around the cursor (`documentContextBeforeInput` / `AfterInput`) | Yes, a few hundred characters at most | Same |
| Network | **No** | Yes |
| App Group container | **Read-only** | Read and write |
| Shared Keychain access group | Assumed **no** (spike) | Yes |
| General pasteboard | No | Yes |
| **Microphone** | **No** | **No** |
| Haptics, input clicks | None in v1 | Yes |
| Apple on-device model (Foundation Models) | Unknown (spike) | Unknown (spike) |

- `RequestsOpenAccess = YES` makes the "Allow Full Access" switch appear in
  Settings, with a system warning that the keyboard "can transmit anything
  you type". The keyboard checks `hasFullAccess` at runtime.
- **No microphone, ever.** Apple doesn't let keyboard extensions record
  audio, on iOS 26 as before. Dictation keyboards (Wispr Flow and others)
  hand recording off to their container app and get the text back through
  the App Group. Kallilex does the same (§8).
- The keyboard doesn't appear in secure text fields or phone pads, and apps
  can block third-party keyboards. iOS falls back to the system keyboard
  there by itself.
- **No system keyboard inside the keyboard.** A text field inside a
  keyboard extension can't summon the iOS keyboard. Typing into the
  keyboard's own Scratchpad needs our own keys.
- **Memory.** The measured limit on iPhone 16 / iOS 27 is about **177 MB**; jetsam
  kills the keyboard silently above it. Target: **60 MB** (budget, about a
  third of the measured limit), measured on a device (§12).
- **Lifecycle.** The keyboard lives while it's on screen. Dismissing it,
  switching keyboards or switching apps suspends it and can kill it. A
  request in flight doesn't survive that.
- **Opening apps.** `extensionContext.open(_:)` doesn't work from
  keyboards. Dictation keyboards open their container app through the
  responder chain (`openURL` on the hosting `UIApplication`), which isn't
  public API (§12, unknown 7).

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

1. **Real keys are mandatory**, and they must be able to type into the host
   app. That's why the typing target can be switched (D6, §6.2).
2. **It works without Full Access:** typing, the Scratchpad, Insert and
   taking over a dictation all work. Prompts against network providers need
   Full Access; the keyboard says so and never blocks typing.
3. A **globe key** (`needsInputModeSwitchKey`, `handleInputModeList`).
4. **No emoji layer** (5.2.5 forbids Apple emoji); the globe key reaches the
   system emoji keyboard.
5. **Opening the Kallilex app for dictation conflicts with "must not launch
   other apps".** Comparable dictation keyboards are in the App Store, but
   it's the largest review risk. The plan has a review-safe path that never
   opens the app from the keyboard (§8.3, path A) and treats the direct jump
   (path B) as an add-on that can be dropped.
6. 5.1.2(i) (AI consent) applies here too: consent works inside the
   keyboard (§7.4).

## 3. Product scope

### In 1.0.0

1. **Keyboard layout "Scratchpad + Prompts, keys on demand"** (D3, §5):
   - a large **Scratchpad** on top;
   - the user's **prompt chips** below it;
   - an **action row**: 🌐, ⌨ (show the keys), 🎤 (dictation), the privacy
     badge, **Insert**.
   - ⌨ swaps the prompt chips and action row for the **keys**
     (QWERTZ/QWERTY), with a compact toolbar to switch back.
2. **Three ways into the Scratchpad:**
   - **take over the selection** from the host app;
   - **type** with the keyboard's own keys;
   - **dictate** (§8).
3. **Prompts** run on the Scratchpad text; the result replaces it in place,
   exactly like the app's Scratchpad (Undo, Retry, Copy).
4. **Insert** puts the Scratchpad text into the host app: it replaces the
   selection there if there still is one, otherwise it inserts at the
   cursor. **Undo Insert** afterwards, guarded (D8, §7.3).
5. **Switchable typing target** (D6): the keys type into the Scratchpad (the
   default) or straight into the host app.
6. **Typing keyboard:**
   - layouts: German QWERTZ and English QWERTY (D4); the default follows the
     device language and can be changed in the app;
   - shift and caps lock, a numbers and symbols layer, delete with key
     repeat, space, return, globe;
   - key popups, long-press accents (ä ö ü ß é …), automatic capitalization
     and "double space → period".
   - No autocorrect, no suggestions (D8).
7. **Dictation with Parakeet on the device** (D7, §8), in the app's
   Scratchpad and, through the app, for the keyboard.
8. **Consent** for providers that need it, inside the keyboard; **Full
   Access states** with a plain explanation.
9. **App:** an onboarding step and a Settings section "Keyboard" (how to add
   it, Full Access, layout), a test field, and the dictation model download.
10. **Localization** EN/DE and **accessibility** for everything above.

### Not in 1.0.0

- Custom instruction typed in the keyboard (D8; the internal typing makes
  it cheap later).
- Word suggestions and autocorrect (D8).
- Taking over the text before the cursor without a selection (D8).
- Recording in the background while the user stays in the host app
  (Wispr Flow style, §8.3 path C).
- Keeping the Scratchpad text across keyboard sessions on disk (§9).
- Swipe typing, emoji, themes, more layouts, the iPad split keyboard,
  streaming results.

## 4. User flows

### 4.1 Setup (app)

1. Onboarding gets a step "Kallilex Keyboard" (skippable), also reachable
   from Settings → Keyboard. It shows the path *Settings → General →
   Keyboard → Keyboards → Add New Keyboard → Kallilex → Allow Full Access*.
   A button opens the app's page in Settings
   (`UIApplication.openSettingsURLString`), which lists "Keyboards" one tap
   away.
2. Before the user sees Apple's warning, the step explains Full Access in
   plain words:
   - what it's needed for: sending the Scratchpad text to the user's own AI
     provider, Copy;
   - what Kallilex never does: record or send what the user types;
   - that typing, Insert and dictation work without it.
3. The app shows whether the keyboard is added (spike) and offers a test
   field.
4. **Dictation model:** the first time the user taps 🎤 in the app (or in
   the Settings → Dictation section), the app explains the download size
   and downloads the Parakeet model (§8.2).

### 4.2 Main flow: selected text

1. The user selects text and switches to Kallilex Keyboard (🌐).
2. The selection lands in the Scratchpad automatically if the Scratchpad is
   empty or still holds an earlier, unchanged selection. Otherwise a chip
   "Take selection" appears above the Scratchpad.
3. The user taps a prompt. The Scratchpad shows "Rewriting…" with Cancel,
   then the result.
4. **Insert** replaces the selection in the host app. The action row shows
   "Inserted" with **Undo**.

### 4.3 Typing into the Scratchpad

1. ⌨ shows the keys; the Scratchpad gets a cursor; the target switch shows
   "Scratchpad".
2. The user types a rough draft, taps ⌨ again (back to the prompts), runs a
   prompt, taps **Insert**.

The keys are a fallback for short corrections, not the main way in (D9).
Longer text is written with the system keyboard in the host app and taken
over as a selection (4.2).

### 4.4 Dictation

See §8.3 for both paths. The transcript lands in the Scratchpad; from there
it's the same as 4.2 from step 3.

### 4.5 Edge cases

- **The selection changed** between taking it over and Insert: Insert
  inserts at the current cursor or replaces the current selection; the
  label says which ("Insert" / "Replace selection").
- **The host reports no selection** although the user selected text (some
  web views): after a selection change without `selectedText`, a hint says
  "This app doesn't share the selection with keyboards. Type, dictate, or
  use Share → Kallilex."
- **Long text:** the existing 20,000-character soft warning; hosts may
  truncate `selectedText` (spike).
- **No provider configured:** "Set up a provider in the Kallilex app" (text
  only).
- **Full Access off:** prompts run only with the on-device provider, if the
  spike shows it works there; otherwise the chips show a Full Access card.
- **Keyboard dismissed while a prompt runs:** the run is cancelled; nothing
  is inserted.

## 5. Keyboard layout

All modes have the same height so the host app's layout doesn't jump. The
spike finds the usable height (target about 300 pt on an iPhone 16; the
system keyboard with its bar is about 290 pt).

```
Prompt mode (default)            Keys mode (⌨)
┌──────────────────────────┐     ┌──────────────────────────┐
│ Scratchpad               │     │ Scratchpad (3 lines) ▾   │
│ (selection / typed /     │     ├──────────────────────────┤
│  dictated text)          │     │ → Scratchpad | App   ⌨ ✓ │
│                          │     ├──────────────────────────┤
├──────────────────────────┤     │ q w e r t z u i o p ü    │
│ [Rewrite] [Shorten] …    │     │ a s d f g h j k l ö ä    │
├──────────────────────────┤     │ ⇧ y x c v b n m ⌫        │
│ 🌐  ⌨  🎤  ●Cloud [Insert]│     │ 123 🌐 [  space  ] ⏎     │
└──────────────────────────┘     └──────────────────────────┘
```

- **Prompt mode:** the Scratchpad takes the remaining height and scrolls.
  The editor controls from the app (Undo, Retry, Copy, "Show original")
  sit in a small row inside the Scratchpad's bottom edge, as in
  `EditorScreen`.
- **Keys mode:** the Scratchpad shrinks to three lines. A thin toolbar
  holds the typing target switch and ⌨ ✓ (back to prompts). When the target
  is "App", the Scratchpad stays visible but has no cursor.
- During a run and in the consent or error states, the chips row shows the
  status (`StatusBanner`), as in the editor.

## 6. The typing keyboard

### 6.1 Keys

- **Rows (DE):** `q w e r t z u i o p ü` / `a s d f g h j k l ö ä` /
  ⇧ `y x c v b n m` ⌫ / `123` 🌐 space `.` return. EN: 10/9/7 letters, no
  umlaut keys. Umlauts, ß and accents are on long-press in both.
- **Layers:** letters, numbers/punctuation (`123`), symbols (`#+=`).
- **Shift:** a single tap capitalizes the next letter, a double tap is caps
  lock. Auto-shift after `. ! ?` + space and at the start of the text,
  following the host's `autocapitalizationType` when typing into the app,
  and sentence-style in the Scratchpad.
- **Delete:** single delete, repeat after 0.5 s, word-wise after about 2 s.
- **Return:** a newline; when typing into the app, its label follows
  `returnKeyType` (Go, Search, Send …).
- **`keyboardType` hints** (target App): `@` and `.` in the bottom row for
  `.emailAddress`, `/` and `.com` for `.URL`.
- **Feedback:** key popups; input clicks and light haptics where allowed
  (spike).
- **Built in UIKit** (D5): a custom view that draws the keys and does its own
  hit testing, for latency and memory. It's driven by `KeyboardState`
  (§10.2).

### 6.2 Typing target and input routing

`KeyboardState` emits abstract edits (`insert("a")`, `deleteBackward`,
`newline`). A `TypingTarget` sends them either to the Scratchpad buffer or
to `textDocumentProxy`. The switch is a segmented control in the keys-mode
toolbar ("Scratchpad | App"). The last choice is remembered for the
keyboard session; a new session starts on "Scratchpad".

### 6.3 The Scratchpad text view

The Scratchpad is a UIKit `UITextView`, not a SwiftUI `TextEditor`
(memory). The user can tap to move the cursor and select text in it. Our keys
edit it through `UITextInput`. A `UITextView` inside a keyboard extension can be
first responder with an empty `inputView` without showing another keyboard
(spike unknown 8 confirmed). The iOS 26 scroll edge effects hide the text in a
short text view; hiding them with `topEdgeEffect.isHidden = true` (and bottom,
left, right) and setting `contentInsetAdjustmentBehavior = .never` fixes it.

## 7. The AI part

### 7.1 Reusing `EditorSession`

The keyboard Scratchpad behaves exactly like the app's Scratchpad: editable
text, run a prompt, the result replaces the text in place, Undo / Retry /
Copy / "Show original", consent and error states. So the keyboard **reuses
`EditorSession` unchanged** with a keyboard-specific `Pasteboard` (Copy
needs Full Access) and the existing `ConsentGranting`. The session's `text`
is the Scratchpad buffer.

### 7.2 The host bridge

A new `HostBridge` (KallilexUI) sits between the session and the host app:

- `selectionSnapshot()`: reads `selectedText` (on take-over and on
  `selectionDidChange`, length only for the status);
- `insert(_ text:)`: calls `insertText`, which replaces the host's
  selection, and remembers what was inserted and what it replaced;
- `undoInsert()`: §7.3;
- written against a `TextDocument` protocol that wraps `UITextDocumentProxy`,
  so tests use a fake.

### 7.3 Undo Insert

- **Undo** deletes the inserted text with `deleteBackward` and inserts the
  replaced selection again (or nothing, if there was none).
- It's offered only while it's safe:
  - `documentContextBeforeInput` ends with the inserted text (or its last
    200 characters);
  - no other edit, selection change or keyboard switch has happened since.
- The host's own undo (shake, three-finger swipe) works as well, because
  `insertText` goes through the host's undo stack.
- The number of `deleteBackward` calls must match how the host counts
  characters (grapheme clusters vs UTF-16, newlines in web views). The spike
  checks this per app (§12, unknown 11). If it's unreliable in an app class,
  the button is hidden there.

### 7.4 AI consent (5.1.2(i))

`.consentRequired(profile)` shows `ConsentView` in the chips area, in a
compact layout: the provider name, the host, "The text in the Scratchpad is
sent to <host> to be processed", **Allow** / **Not now**. Allow writes the
consent through `SettingsService`. Writing needs Full Access, but so does
every provider that needs consent, since they're all network providers.

## 8. Dictation with Parakeet

### 8.1 Engine

- **Model:** NVIDIA Parakeet TDT 0.6B v3, CoreML conversion by
  FluidInference (`parakeet-tdt-0.6b-v3-coreml`). It's multilingual: 25
  European languages including German and English, with the language
  detected automatically. It runs on the Neural Engine, offline after the
  download.
- **Runtime:** the FluidAudio Swift package (Apache-2.0), the first
  third-party dependency of the iOS app.
- **German quality:** the base v3 model sometimes decodes short German
  phrases as English. A German fine-tune (`parakeet-primeline-de-coreml`)
  exists; the spike compares both and checks its license (§12, unknown 13).
- **Licenses:** the model is CC-BY-4.0, so the Licenses screen and the
  website credit NVIDIA and FluidInference. FluidAudio's Apache-2.0 notice
  goes into the Licenses screen.
- **Only in the app.** The model needs several hundred MB on disk and a
  large share of RAM while it runs; that's far beyond a keyboard's limit,
  and keyboards can't record anyway. All recording and transcription happen
  in the Kallilex app.
- **Batch, not streaming, in 1.0.0:** record until Stop, then transcribe.
  A 30-second recording should take a few seconds on an iPhone 16 (spike).
  The first use compiles the model for the Neural Engine (reported ~15 s),
  so the app does that right after the download, not at the first
  dictation.

### 8.2 Getting the model onto the device

The model is too large to ship inside the app. Options, decided by the
spike:

1. **Apple-hosted Background Assets** (asset packs served by the App Store,
   iOS 26). No third-party server and no extra privacy disclosure; the
   download is managed by the system. **Preferred.**
2. A download from Hugging Face on first use: works today, but it's a
   network request to a third party, so it has to be disclosed in the
   privacy policy and app privacy details.

Either way, the download is explicit (the user taps "Download"), shows its
size and progress, can be cancelled, and the model can be deleted again in
Settings → Dictation.

### 8.3 Dictation from the keyboard

The keyboard can't record, so the transcript reaches it through the App
Group as a **pending transcript**: one small file holding the text and a
timestamp. The app writes it; the keyboard reads it (reading works without
Full Access) and deletes or ignores it after taking it over. It expires
after 10 minutes and is never kept longer.

- **Path A (review-safe, always built):**
  1. The user taps 🎤 in the keyboard.
  2. The keyboard explains: "Open Kallilex, dictate, then come back here."
     If there's a recent transcript, it offers **Take dictation** right
     away.
  3. In the app, a Dictation screen (also a tab action in the Scratchpad)
     records and transcribes, then shows "Done. Switch back to your app."
  4. Back in the host app (via the system's "◀ App" back link at the top
     left, or the app switcher), the keyboard reappears and offers **Take
     dictation**. One tap puts it into the Scratchpad.
- **Path B (comfort, add-on):** 🎤 opens the app directly into recording
  (`kallilex://dictate`) through the responder chain. After Stop the app
  shows "Go back" (the system back link). The keyboard takes the
  transcript over automatically when it reappears. The spike checks
  whether this still works on iOS 26/27 (§12, unknown 7). It ships only if
  it does, and App Review can veto it, in which case path A remains.
- **Path C (later, not planned for 1.0.0):** Wispr Flow-style recording that
  keeps running in the background while the user is back in the host app,
  with the keyboard showing a live "Listening…" and Stop. It needs the
  `audio` background mode and careful review justification.

### 8.4 Dictation in the app

The app's Scratchpad gets the 🎤 button too: recording and transcription
straight into the editor text. It's the same engine and the same Dictation
screen.

## 9. Privacy and security

- **No keystroke collection.** The keyboard never logs, stores or sends what
  the user types. Only the Scratchpad text, when the user taps a prompt,
  goes to the user's chosen provider. The host's text around the cursor is
  read locally only (auto-capitalization, the Undo guard).
- The Scratchpad text lives in memory only. The pending transcript is the
  only user text written to the App Group, and only for up to 10 minutes.
- **Audio** is recorded and transcribed on the device. Recordings are kept
  in memory or a temporary file that is deleted right after transcription.
  `NSMicrophoneUsageDescription` (app only).
- **Privacy manifests** for the keyboard target and an updated one for the
  app. The model download source (§8.2) decides whether anything new needs
  declaring.
- **Privacy policy** (EN/DE): sections "Kallilex Keyboard" (Full Access,
  what's read and when, what's never sent) and "Dictation" (on the device,
  no audio leaves the phone, the model download).
- **App Review notes:**
  - why Full Access is requested, and that the keyboard works without it;
  - how dictation works without keyboard microphone access (path A, and B
    if it ships);
  - consent per provider inside the keyboard;
  - how to test it (the on-device model or the reviewer key).
- ATS: the keyboard gets `NSAllowsArbitraryLoads` like the other bundles
  (ios-14); the CI check covers it.

## 10. Architecture

### 10.1 Targets

```
ios/
  KeyboardExtension/
    Info.plist        NSExtensionPointIdentifier com.apple.keyboard-service,
                      RequestsOpenAccess = YES, IsASCIICapable = YES,
                      PrimaryLanguage, PrefersRightToLeft = NO,
                      KallilexAppGroup, KallilexKeychainAccessGroup,
                      ATS keys as in ios-14
    KeyboardExtension.entitlements   App Group + Keychain group
    PrivacyInfo.xcprivacy
    Sources/KeyboardViewController.swift   UIInputViewController
    Resources/
  Config/KeyboardExtension.xcconfig  PRODUCT_BUNDLE_IDENTIFIER =
                                     $(KALLILEX_APP_ID).keyboard,
                                     APPLICATION_EXTENSION_API_ONLY = YES
```

- A third extension target in the pbxproj, in the same style as the
  ShareExtension: a synchronized folder, embedded by the app's "Embed App
  Extensions" phase, configured through its xcconfig.
- `KeyboardViewController` stays thin, like `ShareViewController`:
  - builds the stores and the session;
  - hosts the key grid and the SwiftUI parts;
  - forwards `textWillChange`, `textDidChange` and `selectionDidChange`.
- The app links FluidAudio; the keyboard and the ShareExtension don't.

### 10.2 New code

| Piece | Where | What it does |
|---|---|---|
| `KeyboardLayout` | new package target `KallilexKeyboardCore` (no UIKit) | Key rows for QWERTZ, QWERTY, numbers, symbols; long-press alternates; key widths |
| `KeyboardState` | `KallilexKeyboardCore` | Layer, shift/caps, auto-capitalization, double-space period, key repeat with an injected clock; emits abstract edits |
| `TypingTarget`, `TextDocument` | `KallilexKeyboardCore` | Routes edits to the Scratchpad or the host; `TextDocument` wraps `UITextDocumentProxy` for tests |
| `HostBridge` | `KallilexUI` | Selection take-over, Insert, guarded Undo Insert (§7.2–7.3) |
| `PendingTranscriptStore` | `KallilexKit` | Writes/reads/expires the pending transcript in the App Group (§8.3) |
| Keyboard SwiftUI parts | `KallilexUI` | Prompt mode chips + action row, status, compact consent, Full Access card; reuse `PromptChipsBar`, `PrivacyBadge`, `StatusBanner`, `ConsentView` |
| Key grid, Scratchpad text view | `KeyboardExtension` (UIKit) | §6.1, §6.3 |
| `DictationEngine` | app target (links FluidAudio) | Model management, record, transcribe; a protocol so tests and the UI-test stub don't load the model |
| Dictation screen, model download UI | app target | §8.2–8.4 |

### 10.3 Changes to existing code

- `AppGroupSettingsStore.load()` coordinates with **write intent** (for
  corruption recovery), which fails on a read-only container without Full
  Access (spike unknown 2). Add a **read-only load**: a plain `Data(contentsOf:)`
  read with no coordination, no rename of a corrupt file, corruption reported
  as a settings error. The app writes atomically, so a plain read sees either
  the old or the new file. The keyboard uses this while `hasFullAccess` is
  false.
- `KeychainSecretStore` read failures without Full Access already degrade to
  "no key". The keyboard shows the Full Access card instead of an "invalid
  key" error in that case.
- `ScratchpadView` (app) gets the 🎤 button.
- `EditorSession` stays unchanged (§7.1).

### 10.4 Memory budget (keyboard)

- UIKit keys and `UITextView`, one `UIHostingController` for the SwiftUI
  parts, no SwiftUI text input views.
- Target: **60 MB**. The measured limit is about 177 MB on iPhone 16 / iOS 27,
  and the budget is about a third of it, leaving room for older devices and
  iOS 26. ios-18 and ios-23 measure the real keyboard's peak.
- Settings load once per `viewWillAppear`, not per keystroke.

## 11. Testing

- **Unit tests (package):**
  - `KeyboardLayout` and `KeyboardState` (shift, caps, capitalization per
    type, double-space period, layers, repeat with a test clock);
  - `TypingTarget` routing;
  - `HostBridge` against a fake `TextDocument` (take-over rules, Insert with
    and without a selection, the Undo guard);
  - `PendingTranscriptStore` (write, read, expiry, read-only container);
  - the read-only settings load.
- **UI tests (simulator):** XCUITest can't add a third-party keyboard
  reliably, so the app gets a DEBUG-only **keyboard harness**
  (`-uiTestKeyboardHarness`, like the share harness): a host text view whose
  `inputViewController` is the real keyboard view controller, with the stub
  provider. Tests cover:
  - take selection, run a prompt, Insert, Undo;
  - typing into the Scratchpad and into the host;
  - the mode switch;
  - a stub pending transcript;
  - the accessibility audit on both modes.
- **Dictation:** `DictationEngine` behind a protocol; UI tests use a stub
  that returns a fixed transcript. The real model is tested by hand on a
  device (accuracy DE/EN, time per 30 s, memory).
- **Memory:** an Instruments run on a device before release, with the
  numbers in the release spec.
- **Manual host-app matrix** (device): Notes, Mail, Messages, Safari (text
  field and a `contenteditable` editor), WhatsApp, Signal, Slack, Google
  Docs, Pages, Gmail. Per app:
  - is the selection delivered;
  - does Insert replace the selection;
  - does Undo work;
  - is the keyboard blocked.
- **CI:** the existing `ios.yml` builds and tests the new target. New
  checks:
  - the keyboard appex is embedded;
  - it has the App Group and Keychain group;
  - `RequestsOpenAccess` is true;
  - the ATS keys match ios-14;
  - the privacy manifest is present.

## 12. Spike unknowns (ios-15)

The spike report (spike-ios-15-report.md) covers all of these and records the
results. See the report for answers and the "Changed decisions" table for the
implications for each spec.

1. **Foundation Models in a keyboard:** available, and does a rewrite run,
   with and without Full Access? Memory cost?
2. **Read-only App Group:** does write-intent coordination fail without Full
   Access? Does a read-only coordinated read work?
3. **Keychain group without Full Access:** readable? (Expected: no.)
4. **Network with Full Access:**
   - which hosts work: LAN (`.local`, RFC1918), Tailscale (`100.64/10`),
     public `http://` and `https://`;
   - does the app's Local Network permission cover the keyboard?
5. **Memory** on the iPhone 16 (iOS 27) and an iOS 26 device:
   - the bare key grid;
   - with `UITextView` and the SwiftUI parts;
   - the peak during a request;
   - where jetsam kills the keyboard.
6. **`selectedText` per app** (§11 matrix): delivered or `nil`; truncation of
   long selections.
7. **Opening the app from the keyboard** (path B): does the responder-chain
   `openURL` still work on iOS 26/27? Is there an allowed way to open
   Settings?
8. **`UITextView` as first responder inside a keyboard** with an empty
   `inputView`: can our keys edit it through `UITextInput` with a visible
   caret and selection?
9. **Usable height** and whether a height change causes host layout jumps.
10. **Lifecycle:** does a request survive a brief disappearance (a host
    alert)? What happens on app switch?
11. **Undo Insert:** do N `deleteBackward` calls remove exactly the inserted
    text in each matrix app (emoji, combining accents, newlines)?
12. **Detecting the added keyboard** from the app, for the setup step.
13. **Parakeet on the iPhone 16:**
    - model size on disk;
    - peak RAM while transcribing;
    - the first-run Neural Engine compile time;
    - transcription time for 30 s of German and English;
    - base v3 vs the German fine-tune (accuracy, license).
14. **Model delivery:** do Apple-hosted Background Assets work for a
    model of this size with automatic signing and TestFlight? What's the
    fallback download flow?
15. **Haptics and input clicks** without Full Access.

## 13. Phases and specs

Numbering continues after v1. The keyboard is part of 1.0.0, so the release
spec **ios-13 now also depends on ios-23**.

| Spec | Title | Depends on | Key content |
|---|---|---|---|
| ios-15 | Keyboard and dictation spike | ios-14 | §12, a throwaway keyboard and a Parakeet test in a scratch app |
| ios-16 | Keyboard target, CI, read-only settings | ios-15 | §10.1, §10.3 store change, CI checks, an empty keyboard with a globe key |
| ios-17 | Keyboard core: layouts, state, input routing | ios-16 | `KallilexKeyboardCore`, §6.1–6.2, unit tests |
| ios-18 | Keyboard UI: Scratchpad, prompts, keys | ios-17 | §5, §6.3, the UIKit key grid, mode switch, keyboard harness, `EditorSession` reuse |
| ios-19 | Host bridge: take selection, Insert, Undo, consent, Full Access states | ios-18 | §7, §4.5 |
| ios-20 | On-device dictation in the app (Parakeet) | ios-15 | §8.1, §8.2, §8.4, `DictationEngine`, model download, licenses |
| ios-21 | Dictation for the keyboard | ios-19, ios-20 | §8.3 path A, and path B if the spike allows it, `PendingTranscriptStore` |
| ios-22 | App setup for the keyboard | ios-19 | §4.1, Settings → Keyboard and Dictation, layout setting, test field |
| ios-23 | Keyboard polish: localization, accessibility, memory, privacy, review notes, website | ios-21, ios-22 | §9, host-app matrix, release checklist update |
| later | Custom instruction in the keyboard; suggestions; text before the cursor; background dictation (path C) | ios-23 | §3 "Not in 1.0.0" |

ios-20 depends only on the spike, so it can be built in parallel with
ios-16 to ios-19 by a second writer **in its own worktree** (it touches the
app target and a new package dependency, not the keyboard).

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| App Review rejects the keyboard (4.4.1) | 1.0.0 delayed | Real keys that type into the host, works without Full Access, path A for dictation, detailed review notes |
| Path B counts as "launching another app" | Rejection | Ship path A alone; B is optional |
| The keyboard pushes 1.0.0 back by weeks | Later launch | Accepted (D2). The spike comes first, so the scope can be cut early |
| Users don't trust "Allow Full Access" | Low use | Plain explanation before Apple's warning, policy section, open source |
| `selectedText` is `nil` in important apps | The selection path fails there | Typing and dictation as alternatives, a clear hint, the Share Extension |
| Keyboard memory limit | The keyboard disappears silently | UIKit keys and text view, device measurements |
| Insert or Undo misbehaves in some hosts | Lost or doubled text | Undo only when the guard passes; host undo as the fallback |
| Parakeet is too heavy or slow on older iPhones | Dictation unusable there | Measure in the spike; set a minimum device for dictation; Apple `SpeechTranscriber` as the fallback engine behind the same `DictationEngine` protocol |
| Model download fails or is large | Dictation never set up | Explicit download step with size and progress, retry, Background Assets |
| German misrecognized as English | Bad transcripts | Compare v3 with the German fine-tune; a language hint from the app language |
| First third-party dependency (FluidAudio) | Supply chain and maintenance | Pin the version, review updates, app target only |
| Fast typing on our keys drops letters (measured on iOS 27.0.1, 2026-11-09) | Typing on the keys feels unreliable | The missing taps never reach the extension's window: the same key grid embedded in the app loses none. It's outside our code. Keys stay a fallback (D9); the selection flow (4.2) is the main way in; retest on newer iOS versions |

## 15. Decisions (product owner, 2026-11-05)

| # | Question | Decision |
|---|---|---|
| D1 | Keyboard in the price or a separate purchase? | Part of the paid app, no in-app purchase |
| D2 | When? | **Before 1.0.0**; the keyboard ships in 1.0.0 |
| D3 | Layout? | Kallilex-only keyboard: a large Scratchpad on top, prompts and Insert below, keys on demand (§5) |
| D4 | Keyboard layouts? | German QWERTZ and English QWERTY |
| D5 | Keys in UIKit or SwiftUI? | UIKit keys, SwiftUI for the prompt and status parts |
| D6 | Where do the keys type? | Switchable: Scratchpad (default) or the host app |
| D7 | Dictation? | Parakeet on the device (FluidAudio), in the app; the keyboard gets the text through the app |
| D8 | Extras in 1.0.0? | Undo Insert: yes. Custom instruction, suggestions, text before the cursor: later |
| D9 | Role of the keys (2026-11-09) | Kept, because 4.4.1 requires real input, but only as a fallback behind ⌨ for short corrections. The main flow is: write in the host app, select, switch to Kallilex, run a prompt, Replace selection |

## 16. Sources

- App Review Guidelines 4.4.1, 5.2.5:
  <https://developer.apple.com/app-store/review/guidelines/>
- Apple: [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard),
  [Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard),
  [Handling text interactions in custom keyboards](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards),
  [App Extension Programming Guide: Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
  (no microphone in keyboards)
- Read-only App Group without open access:
  [Apple forums 728434](https://developer.apple.com/forums/thread/728434)
- Keyboard dictation hand-off:
  [Apple forums 800500](https://developer.apple.com/forums/thread/800500),
  [Muesli for iOS](https://github.com/Muesli-HQ/muesli-ios),
  [MacStories: limitations of custom keyboards](https://www.macstories.net/notes/on-the-limitations-of-ios-custom-keyboards/)
- Keyboard memory reports:
  [dev.to](https://dev.to/tbds_2dadf2b626f315902eae/the-three-hard-constraints-of-an-ios-keyboard-extension-46af),
  [Fleksy](https://fleksy.com/blog/limitations-of-custom-keyboards-on-ios)
- Parakeet / FluidAudio:
  [parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
  [FluidAudio benchmarks](https://docs.fluidinference.com/reference/benchmarks.md),
  [German fine-tune (CoreML)](https://huggingface.co/ValentinWeyer/parakeet-primeline-de-coreml)
- Apple `SpeechTranscriber` (fallback engine):
  [WWDC25 session 277](https://nonstrict.eu/wwdcindex/wwdc2025/277/)
- OWASP MASTG keyboard Full Access test:
  [MASTG-TEST-0390](https://mas.owasp.org/MASTG/tests/ios/MASVS-PLATFORM/MASTG-TEST-0390/)
