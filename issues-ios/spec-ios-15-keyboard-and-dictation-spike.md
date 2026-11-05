# Spec ios-15 — Keyboard and dictation spike

Status: done (report: spike-ios-15-report.md)
Phase: Keyboard K0 (spike, throwaway prototype)
Depends on: ios-14

## Problem Statement

The Kallilex Keyboard and on-device dictation (PLAN-keyboard.md) depend on
platform behavior that Apple doesn't document or that has changed between
iOS versions:

- what a keyboard can do without Full Access;
- how much memory it may use;
- whether a text view with a caret works inside a keyboard;
- whether it can open its container app;
- how host apps handle `selectedText`, `insertText` and `deleteBackward`;
- whether Parakeet runs well enough on an iPhone and how the model gets
  onto the device.

Several later specs (ios-16 to ios-21) make decisions that the answers can
overturn. They have to be answered first.

## Solution

Build two throwaway prototypes outside the shipped code:

1. **A spike keyboard** embedded in a minimal host app, with:
   - a few UIKit keys;
   - a `UITextView` Scratchpad;
   - one SwiftUI strip;
   - an `ActionRunner` call to a test server and to the on-device model;
   - logging of the measurements below.
2. **A Parakeet test app** that downloads the model, records audio and
   transcribes it with FluidAudio.

Record the results in `issues-ios/spike-ios-15-report.md`, one section per
unknown, with the same four-part structure as the ios-01 report (Method,
Result, Evidence, Consequence for later specs).

The spike code lives in `spikes/ios-15/` at the repo root and is never
committed. `spikes/` is already excluded locally through `.git/info/exclude`
(as for ios-01).

## User Stories

1. As the architecture owner, I want to know what works without Full Access
   (App Group reads, Keychain, on-device model, haptics), so that ios-19
   shows the right Full Access states.
2. As a developer, I want to know whether `NSFileCoordinator` with write
   intent fails on a read-only App Group, so that ios-16 adds the right
   read-only load.
3. As a developer, I want the keyboard's memory limit and our footprint
   measured on a device, so that ios-18 stays under budget.
4. As a developer, I want to know whether a `UITextView` can be first
   responder inside a keyboard and be edited by our own keys with a visible
   caret, so that ios-18 can use it or fall back to an append-only view.
5. As a product owner, I want to know per host app whether the selection
   arrives, whether Insert replaces it and whether Undo is exact, so that the
   main flow is viable and the hints are right.
6. As a product owner, I want to know whether the keyboard can still open
   the Kallilex app (dictation path B), so that ios-21 can plan it or drop
   it.
7. As a product owner, I want Parakeet's size, memory, speed and German
   accuracy on my iPhone, so that dictation is worth shipping and the right
   model is chosen.
8. As a release engineer, I want to know whether Apple-hosted Background
   Assets can deliver the model, so that no third-party download is needed.

## Implementation Decisions

### Unknowns (PLAN-keyboard.md §12)

| # | Unknown | Method |
|---|---|---|
| 1 | Foundation Models in a keyboard | Check `SystemLanguageModel.default.availability`; run a 300-word rewrite with Full Access on and off; record memory and time |
| 2 | Read-only App Group | With Full Access off, call a coordinated read with write intent (as `AppGroupSettingsStore.load()` does) and a read-only coordinated read; record errors |
| 3 | Keychain group without Full Access | Read a test item written by the host app, with Full Access off and on |
| 4 | Network with Full Access | Requests to a `.local` host, an RFC1918 IP, a Tailscale `100.x` IP over `http://`, and a public `https://` host; check whether the Local Network permission granted to the app is enough |
| 5 | Memory | Instruments / `os_proc_available_memory()` logging for: bare key grid; grid + `UITextView` + one `UIHostingController`; peak during a request; then allocate in steps until jetsam kills it. On the iPhone 16 (iOS 27) and, if available, an iOS 26 device |
| 6 | `selectedText` per host app | Select short (one sentence) and long (about 3,000 characters) text in each app of the matrix (below) and log what arrives |
| 7 | Opening apps | Try the responder-chain `openURL` to `kallilex-spike://dictate` and to the Settings URL; record whether each works on iOS 26 and 27 |
| 8 | `UITextView` in a keyboard | Make it first responder with `inputView = UIView()`; insert and delete through `UITextInput` from our keys; check that the caret and tap-to-place work and that the host's text field doesn't lose its connection |
| 9 | Height | Raise the keyboard height through a height constraint in steps (290, 320, 360 pt); note the limit and any layout jumps in the host |
| 10 | Lifecycle | Start a 10-second request, then trigger a host alert, switch keyboards, switch apps; record what survives |
| 11 | Undo Insert | Insert text with emoji, combining accents (`e\u{301}`) and newlines, then delete it with N `deleteBackward` calls; compare per app |
| 12 | Detecting the added keyboard | From the host app, check `UITextInputMode.activeInputModes` (and any other public way) for the keyboard's bundle id |
| 13 | Parakeet on the iPhone 16 | FluidAudio with `parakeet-tdt-0.6b-v3-coreml`: disk size, peak RAM while transcribing, first-run compile time, time to transcribe 30 s of German and of English. Same for the German fine-tune; read both model licenses |
| 14 | Model delivery | Try an Apple-hosted Background Assets asset pack with the model in a TestFlight-like build if the account allows it; otherwise document what's needed. Note the Hugging Face download as the fallback |
| 15 | Haptics and input clicks | `UIImpactFeedbackGenerator` and `UIDevice.current.playInputClick()` with Full Access off and on |

### Host-app matrix (unknowns 6 and 11)

Notes, Mail, Messages, Safari (address bar, a plain `<textarea>`, a
`contenteditable` editor), WhatsApp, Signal, Slack, Google Docs, Pages,
Gmail. Use whichever of these are installed on the device; note the ones that
aren't.

### German accuracy test (unknown 13)

The same five recordings for both models, each about 20–30 s: a dictated
email in German, a German message with English product names, short German
commands ("Mach das kürzer"), an English paragraph, and a mixed German and
English sentence. Record the transcripts and count obvious errors.

### Report structure

File: `issues-ios/spike-ios-15-report.md`, one `## Unknown N: …` section per
unknown with `### Method`, `### Result`, `### Evidence`, `### Consequence
for later specs`. A closing section lists which decisions in
PLAN-keyboard.md and in ios-16 to ios-21 change.

### Platform and prerequisites

- Xcode 27 with the iOS 26 deployment target.
- The product owner's iPhone 16 (iOS 27); an iOS 26 device if available.
- The free Personal Team is enough for everything except unknown 14, which
  may need the paid account. If so, unknown 14 is marked open with the
  fallback.
- A test HTTP server on the LAN and the Tailscale server.

### Acceptance criteria

- All 15 unknowns are in the report with a result or an explicit fallback.
- The report's closing section names every decision that changes.
- Nothing from `spikes/ios-15/` is committed.

## Testing Decisions

The spike is a one-off prototype; no automated tests. The measurements are
recorded by hand in the report.

## Out of Scope

- Production code, the real key layouts, the real UI.
- App Review submission.
- Background dictation (path C).

## Further Notes

- PLAN-keyboard.md §2 explains why each unknown matters; §14 lists the risks
  the answers feed into.
- Unknowns 5, 6, 8, 11 and 13 decide the most. If time is short, do them
  first.
