# Spec ios-20 — On-device dictation in the app (Parakeet)

Status: draft (confirm against the ios-15 report, unknowns 13, 14)
Phase: Keyboard K4 (dictation)
Depends on: ios-15

## Problem Statement

The user wants to dictate text instead of typing it, in the app's Scratchpad
and, through the app, for the keyboard (PLAN-keyboard.md §8). It has to run
on the device, like the rest of Kallilex's local options, with good German
and English. Parakeet TDT 0.6B v3 (FluidAudio, CoreML) fits, but:

- the model is several hundred MB, too large to ship inside the app;
- it needs a lot of RAM while it runs;
- it's compiled for the Neural Engine on first use;
- it's the app's first third-party dependency.

## Solution

- A **`DictationEngine`** protocol in the app target, with:
  - a **`ParakeetDictationEngine`** built on FluidAudio;
  - a stub for UI tests.
- An explicit **model download** flow and a **Dictation screen**: record,
  stop, transcribe.
- A 🎤 button in the app's Scratchpad that dictates into the editor text.
- A Settings → Dictation section to manage the model.

The keyboard hand-off is ios-21.

## User Stories

1. As a user, I want to tap 🎤 in the Scratchpad, speak, and get the text in
   the editor, so that I can run a prompt on spoken text.
2. As a user, I want dictation to run on my iPhone, so that my voice never
   leaves the device.
3. As a user, I want to know how big the download is before I agree to it,
   and to see its progress.
4. As a user, I want to delete the model in Settings to free space.
5. As a German speaker, I want German transcribed correctly, including
   English product names.
6. As a user, I want a clear message when I've denied microphone access,
   with a link to Settings.
7. As a developer, I want UI tests that don't need the model or a
   microphone.

## Implementation Decisions

### Dependency

- Add FluidAudio as a Swift Package dependency of the **app target only**,
  not `KallilexKit`, not the extensions.
- Pin an exact version (`exact:`), and record the version and its license
  (Apache-2.0) in the Licenses screen.
- **Model:** `parakeet-tdt-0.6b-v3-coreml` (CC-BY-4.0), or the German
  fine-tune if the spike shows it's clearly better and its license allows
  redistribution (unknown 13). The choice and its attribution are recorded
  in `ios/AppReview/review-notes.md` and the Licenses screen ("Speech model:
  NVIDIA Parakeet TDT 0.6B v3, CoreML conversion by FluidInference,
  CC-BY-4.0").

### `DictationEngine`

```swift
protocol DictationEngine: AnyObject, Sendable {
    var modelState: DictationModelState { get async }  // notInstalled(sizeBytes), downloading(progress), preparing, ready, failed(DictationError)
    func downloadModel() async throws
    func cancelDownload()
    func deleteModel() async throws
    func prepare() async throws          // loads and compiles; first run is slow
    func transcribe(_ audio: URL, languageHint: Locale?) async throws -> String
}
```

- **`ParakeetDictationEngine`** keeps the model in the app's Application
  Support directory, **not** the App Group: the keyboard never needs it, and
  it shouldn't count against the group container.
- **`prepare()`** runs right after the download, with the status
  "Preparing the speech model…". This keeps the first dictation from taking
  about 15 s longer. It runs again after an app update if FluidAudio
  requires it.
- **Memory:** load the model on first use per app session. Unload it
  (`didReceiveMemoryWarning`, or 2 minutes after the last transcription) to
  give the RAM back.
- **`languageHint`:** the app language. If the spike shows hints don't
  improve v3, it's ignored.
- **Errors (`DictationError`):** `microphoneDenied`, `modelMissing`,
  `downloadFailed`, `notEnoughSpace`, `transcriptionFailed`, `tooLong`.
  Each has a localized message, in the style of the `ProviderError`
  messages.

### Model delivery

- **Preferred:** an Apple-hosted Background Assets asset pack, if the spike
  confirms it works (unknown 14). Then:
  - the pack is configured in the project;
  - the download goes through the Background Assets API;
  - no third-party server is involved.
- **Fallback:** a download from the model's Hugging Face URL:
  - pinned to a fixed revision and checked against a SHA-256 list in the
    app;
  - over `URLSession` with a progress callback;
  - resumable;
  - the privacy policy and the App Store privacy details mention the
    download (ios-23).
- **Either way:**
  - the user starts the download explicitly;
  - the confirmation shows the size ("Download the speech model
    (~N MB)?");
  - a warning appears on cellular;
  - the download can be cancelled;
  - failures can be retried;
  - a free-space check runs first.

### Recording

- `AVAudioEngine` with 16 kHz mono (resampled if needed), written to a
  temporary file in `tmp/`. The file is deleted right after transcription
  or when the screen closes.
- Limit: 3 minutes per recording. At 2:45 the screen shows a countdown; at
  3:00 it stops and transcribes.
- **`NSMicrophoneUsageDescription`** in the app's `Info.plist` (EN/DE via
  InfoPlist strings): "Kallilex uses the microphone for dictation. Audio is
  transcribed on your iPhone and never leaves it."
- The first 🎤 tap asks for permission. A denied permission shows the
  `microphoneDenied` message with a button that opens the app's Settings
  page.
- An audio session category of `.record` while recording; deactivate it
  afterwards with `.notifyOthersOnDeactivation`.

### UI

- **Dictation screen** (`DictationView`, sheet), opened from the
  Scratchpad's 🎤 (identifier `scratchpad.dictate`):
  - a large record/stop button (`dictation.record`, `dictation.stop`);
  - elapsed time and a simple level meter;
  - after Stop, "Transcribing…";
  - the transcript in a read-only preview;
  - **Use** (`dictation.use`) and **Discard**.
- **Use** appends the transcript to the Scratchpad text: at the cursor if
  the editor has one, otherwise at the end with a separating space. The
  editor's Undo removes it again.
- **Without the model:** the sheet shows the download step first (size,
  Download, Cancel), then preparation, then recording.
- **Settings → Dictation** section (`settings.dictation`):
  - the model state;
  - the size on disk;
  - Download / Delete;
  - the model name and its license line.
- All strings EN/DE in the app's String Catalog.

### Stub for UI tests

- `-uiTestStubDictation` replaces the engine with a stub:
  - the model state is `ready`;
  - no microphone use;
  - Stop returns the fixed transcript "Dictated test text".
- `-uiTestStubDictationNoModel` starts in `notInstalled`, and Download
  finishes at once.

## Testing Decisions

- **Unit tests** (app tests or a small test target, with fake FluidAudio
  wrappers behind the protocol):
  - the model state transitions (not installed → downloading → preparing →
    ready; download failure; cancel; delete);
  - the free-space check;
  - SHA-256 verification in the fallback path;
  - the unload timer.
- **UI tests:**
  - with `-uiTestStubDictation`, the Scratchpad's 🎤, record, stop, the
    transcript shown, Use: the editor contains "Dictated test text";
  - Discard leaves the editor unchanged;
  - with `-uiTestStubDictationNoModel`, the download step appears first;
  - Settings → Dictation shows the state and Delete;
  - the accessibility audit on the Dictation screen.
- **Manual (device):**
  - the real download;
  - the preparation time;
  - five test recordings in DE/EN (the same set as the spike);
  - the transcription time for 30 s;
  - the peak memory in Instruments;
  - microphone denied, then allowed in Settings;
  - airplane mode after the download (dictation works offline).

## Out of Scope

- The keyboard hand-off (ios-21).
- Streaming transcription while speaking, background recording.
- Apple `SpeechTranscriber` as a second engine. It's the documented
  fallback if Parakeet turns out too heavy (PLAN-keyboard.md §14); the
  `DictationEngine` protocol keeps that change local.
- Punctuation commands ("Komma", "neue Zeile") beyond what the model does
  by itself.

## Further Notes

- PLAN-keyboard.md §8.1, §8.2, §8.4.
- This spec doesn't touch the keyboard and can be built in its own worktree
  in parallel with ios-16 to ios-19.
- FluidAudio is the first third-party dependency. Review its updates
  before bumping the pinned version.
