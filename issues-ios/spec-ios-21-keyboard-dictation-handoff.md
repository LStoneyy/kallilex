# Spec ios-21 — Dictation for the keyboard

Status: todo (deferred 2026-11-09, not part of 1.0.0)
Phase: Keyboard K4 (dictation)
Depends on: ios-19, ios-20

> **Deferred** together with ios-20 (decision D10 in PLAN-keyboard.md).
> Until then the keyboard's 🎤 stays hidden.

## Problem Statement

Keyboard extensions can't use the microphone, and the Parakeet model can
only run in the app. To dictate into the keyboard's Scratchpad, the
recording has to happen in the Kallilex app and the text has to come back to
the keyboard. Opening the app from a keyboard is the largest App Review risk
(4.4.1 "must not launch other apps"), so there must be a path that never
does that.

## Solution

- A **pending transcript** in the App Group: the app writes it, the keyboard
  reads it. Reading works without Full Access.
- **Path A** (always built): the keyboard's 🎤 explains how to dictate in
  the app. When the keyboard reappears, it offers **Take dictation**.
- **Path B** (only if the spike confirms it works): 🎤 opens the app
  straight into recording through the `kallilex://dictate` URL. When the
  user comes back, the keyboard takes the transcript over automatically.

## User Stories

1. As a user, I want to dictate text for the keyboard's Scratchpad, even
   though keyboards can't record.
2. As a user, I want to find my dictation in the keyboard when I come back,
   with one tap to take it.
3. As a user, I want 🎤 to open Kallilex straight into recording if iOS
   allows it, so that it takes fewer steps.
4. As a user, I want a transcript that I didn't use to disappear by itself,
   so that old dictations don't show up later.
5. As a user without Full Access, I want dictation for the keyboard to work
   anyway.

## Implementation Decisions

### `PendingTranscriptStore` (KallilexKit)

```swift
public struct PendingTranscript: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
}

public final class PendingTranscriptStore: Sendable {
    public init(directory: URL, now: @Sendable () -> Date = Date.init)
    public func write(_ text: String) throws           // app only
    public func current() -> PendingTranscript?        // nil if missing, unreadable or older than 10 min
    public func markTaken(_ id: UUID)                  // deletes the file if writable; otherwise remembers the id in memory
    public func clear() throws                         // app only
}
```

- **The file:** `pending-transcript.json` in the App Group, written
  atomically with file coordination, like `AppGroupSettingsStore`.
- **Reading:** the keyboard reads with a plain `Data(contentsOf:)`, no file
  coordination. The app writes atomically (spike unknown 2), so a plain read
  sees either the old or the new file. This is the only way the keyboard
  can read without Full Access.
- **Expiry:** 10 minutes after `createdAt`, enforced on read. The app also
  deletes expired files at launch and when it goes to the background.
- **Without Full Access the keyboard can't delete the file.** It keeps the
  taken id in memory for its session, and the app deletes the file on its
  next launch or after expiry. That's acceptable: the text never leaves the
  App Group and expires anyway.
- **No other user text** goes into the App Group.

### App side

- The Dictation screen (ios-20) gets a **keyboard mode**, used when it's
  opened by the `kallilex://dictate` URL or from the new **Dictate for
  keyboard** entry. That entry is a button in the app's Scratchpad menu and
  a home-screen quick action ("Dictate", `UIApplicationShortcutItem`).
- In keyboard mode, **Use** writes the transcript to the
  `PendingTranscriptStore` instead of the editor. The screen then shows
  "Done. Go back to your app; the text is waiting in the Kallilex keyboard."
  and a hint about the "◀" back link at the top left.
- **URL scheme:**
  - `CFBundleURLTypes` with `kallilex`;
  - the route `kallilex://dictate` opens the Dictation sheet in keyboard
    mode and starts recording at once if the model is ready and the
    microphone permission is granted;
  - any other route is ignored.

### Keyboard side

- 🎤 in the action row (`keyboard.dictate`):
  - **Path A:**
    - a short panel in the chips area: "Keyboards can't use the
      microphone. Open Kallilex → Dictate, then come back here." (DE:
      "Tastaturen können das Mikrofon nicht nutzen. Öffne Kallilex →
      Diktieren und komm dann hierher zurück.");
    - **Take dictation** if a pending transcript exists.
  - **Path B** (feature flag `KeyboardFeatures.opensAppForDictation`, off in
    1.0.0, tested in TestFlight before shipping):
    - 🎤 opens `kallilex://dictate` through the responder chain. The spike
      (unknown 7) confirmed this works: the responder chain call returns true
      and the app opens with the URL.
    - 1.0.0 ships with `KeyboardFeatures.opensAppForDictation` off; path B is
      built but inactive, and path A is the only active path.
    - If the call fails, show the path A panel.
    - Path B needs App Review: 4.4.1 forbids launching apps other than
      Settings. TestFlight will show whether the review risk is acceptable.
- **Taking a dictation:** on `viewWillAppear`, if `current()` returns a
  transcript newer than the keyboard's last taken id:
  - after path B within the last 3 minutes: put it into the Scratchpad
    automatically (appended at the end, with a space) and `markTaken`;
  - otherwise show the chip **Take dictation** (`keyboard.takeDictation`),
    which does the same on tap.
- Undo in the Scratchpad (`EditorSession`) removes a taken dictation like
  any other edit.

### App Review

- `review-notes.md` describes path A, and path B if it ships.
- Path B can be switched off by flipping the feature flag in a point
  release, without other changes.

## Testing Decisions

- **Unit tests** (`PendingTranscriptStoreTests`, temp directory, injected
  clock):
  - write then read;
  - expiry at 10 min;
  - `markTaken` deletes when writable;
  - on a read-only directory it keeps the id in memory and `current()`
    returns nil for that id;
  - a corrupt file reads as nil;
  - `clear()`.
- **App tests:**
  - URL routing (`kallilex://dictate` opens keyboard mode, other routes are
    ignored);
  - expired files are cleaned at launch.
- **UI tests:**
  - **App:** with `-uiTestStubDictation`, Dictate for keyboard → record →
    stop → Use writes a pending transcript, checked by launching the
    keyboard harness next.
  - **Keyboard harness:** with a pending transcript present, the Take
    dictation chip appears; tapping it puts the text into
    `keyboard.scratchpad`.
  - **Keyboard harness, path A panel:** 🎤 shows the panel.
- **Manual (device):**
  - path A from Notes: open Kallilex via the home screen or app switcher,
    dictate, go back, take the dictation;
  - path B, if enabled, from Notes and Mail;
  - both with Full Access off.

## Out of Scope

- Background recording while staying in the host app (path C).
- Opening the app for anything other than dictation.

## Further Notes

- PLAN-keyboard.md §8.3, §2.2 (point 5).
