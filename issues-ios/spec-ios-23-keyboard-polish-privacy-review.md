# Spec ios-23 — Keyboard polish: localization, accessibility, memory, privacy, review

Status: ready-for-agent
Phase: Keyboard K6 (polish, before the 1.0.0 release)
Depends on: ios-22 (ios-21 is deferred)

> Dictation is deferred (D10 in PLAN-keyboard.md): skip every dictation
> item below (Dictation screen, review notes, privacy, matrix) until
> ios-20/ios-21 are picked up again.

## Problem Statement

The keyboard and dictation add new surfaces that the v1 polish specs
(ios-11, ios-12) didn't cover:

- strings and VoiceOver for a custom keyboard;
- a strict memory limit;
- the microphone;
- a model download;
- Full Access;
- a third extension for App Review.

All of it has to be finished before 1.0.0 (ios-13), which now also ships
the keyboard.

## Solution

One pass over the keyboard and dictation features covering:

- the remaining localization and accessibility gaps;
- a device memory audit;
- the privacy manifests and the privacy policy;
- the App Review notes and metadata;
- the website;
- the release checklist and host-app matrix.

## User Stories

1. As a German user, I want every keyboard and dictation string in German.
2. As a VoiceOver user, I want to type, run a prompt, insert and dictate
   with VoiceOver.
3. As a user with large text, I want the prompt mode and the guide to stay
   usable.
4. As a user, I want the keyboard never to disappear because it ran out of
   memory.
5. As a privacy-conscious user, I want the privacy policy to say exactly
   what the keyboard reads and what dictation does with my voice.
6. As the release owner, I want App Review to understand Full Access, the
   dictation hand-off and how to test the keyboard.

## Implementation Decisions

### Localization

- Audit all new keys (KallilexUI, KallilexKeyboardCore labels if any, the
  app, `InfoPlist.xcstrings` for `NSMicrophoneUsageDescription` and the
  keyboard's display name) for EN and DE. No key may fall back to its
  default value in German.
- The German UI tests (from ios-11) get a keyboard-harness case: switch the
  app language to German, check the placeholder, the target switch and the
  Insert label.

### Accessibility

- Every key: `.keyboardKey` trait, a spoken label, and the shifted state
  ("Großbuchstabe A") in the label when shift is on.
- **Prompt mode:**
  - chips, Insert, Undo Insert, the target switch and 🎤 have labels and
    hints;
  - a successful run announces "Done. The result is ready." (the existing
    `editor.done.announcement`);
  - Insert announces "Inserted" ("Eingefügt").
- **Dynamic Type:**
  - the keys don't scale (system keyboards don't either);
  - the Scratchpad text, the chips and the status do, up to
    `.accessibility2`;
  - above that, the chips row becomes one scrolling row with a fixed
    height. The keyboard's height can't grow, so the vertical chip
    stacking from ios-11 doesn't apply here.
- **Audits:**
  - `AccessibilityUITests` gets keyboard-harness tests for both modes;
  - the same for the Dictation screen and `KeyboardGuideView`;
  - the same audit types as the existing tests.

### Memory audit

- An Instruments (Allocations + VM Tracker) run of the real keyboard on the
  iPhone 16, recording:
  - idle in prompt mode;
  - keys mode while typing;
  - a cloud prompt;
  - an on-device prompt (if supported);
  - taking a long selection (about 20,000 characters).
- Memory budget: **60 MB** at peak. The numbers go into
  `issues-ios/release-ios-1.0.0-matrix.md`.
- If a number exceeds the budget, fix it before release (e.g. trim the
  hosting controller, lazy-load the settings).

### Privacy

- **Privacy manifests:**
  - the keyboard's `PrivacyInfo.xcprivacy` (no tracking, no collected
    data, required-reason APIs as actually used);
  - the app's manifest gains any APIs FluidAudio or the recording code uses;
  - FluidAudio's own manifest, if it ships one, is bundled.
- The CI step "Verify the privacy manifests" covers all three bundles
  (ios-16).
- **App Store privacy details:**
  - "Data Not Collected" stays true: audio and text are processed on the
    device or sent to the user's own provider, never to us;
  - if the model is downloaded from Hugging Face (ios-20 fallback), check
    whether that counts as a disclosure and update the details.
- **Privacy policy** (`website/privacy.html`, `website/datenschutz.html`,
  Sie-form in German as on that page), with new sections:
  - **Kallilex Keyboard:**
    - Full Access and why it's requested;
    - what the keyboard reads: the selection when the user takes it, the
      text around the cursor, locally only;
    - what it sends: only the Scratchpad text, to the user's provider, when
      the user taps a prompt;
    - what it never does: log or send keystrokes;
    - the pending transcript in the App Group, deleted after 10 minutes.
  - **Dictation:**
    - the microphone is used only while recording;
    - audio is transcribed on the device and deleted right after;
    - the speech model download: its source (Hugging Face) and size (483 MB).

### App Review package

`ios/AppReview/review-notes.md`, new sections:

- **Keyboard:**
  - what it does;
  - that it provides typing (QWERTZ/QWERTY);
  - that it works without Full Access;
  - why Full Access is requested;
  - that it never opens other apps except Kallilex for dictation (path B,
    if shipped);
  - test steps:
    - add the keyboard;
    - open Notes;
    - select text;
    - switch to Kallilex;
    - tap Rewrite (on-device model or the reviewer key);
    - Replace selection.
- **Dictation:**
  - on device;
  - the microphone permission text;
  - how to test (download the model in Settings → Dictation first).

`ios/AppReview/metadata.md`:

- the description and keywords mention the keyboard and dictation;
- new screenshots: the keyboard in prompt mode, the keyboard in keys mode,
  the Dictation screen.

### Website and README

- `website/index.html`: the iOS teaser mentions the keyboard and on-device
  dictation.
- `README.md` iOS section: the same, plus the FluidAudio and Parakeet
  credits.

### Release

- **`docs/ios-release-checklist.md`** gets:
  - the keyboard host-app matrix;
  - the memory audit;
  - the Full Access off/on checks;
  - the dictation checks (model download on cellular and Wi-Fi, offline
    transcription, microphone denied);
  - the review-note sections.
- **`issues-ios/release-ios-1.0.0-matrix.md`** gets the keyboard and
  dictation tables (unfilled).

## Testing Decisions

- The UI tests and audits named above.
- The manual memory audit and host-app matrix are recorded in the matrix
  file.
- The website pages are checked locally in a browser, EN and DE.

## Out of Scope

- New features.
- The release itself (ios-13).

## Further Notes

- PLAN-keyboard.md §9, §11.
- After this spec, ios-13 (manual release) covers the whole 1.0.0 including
  the keyboard.
