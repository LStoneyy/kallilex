# Spike ios-15 Report — Keyboard and dictation

Date: 2026-11-05

## Setup (applies to all sections)

- **Device:** iPhone 16 (iPhone17,3) on iOS 27, the same device as ios-01.
  No iOS 26 device was available, so iOS 26 results are assumed, not
  observed.
- **Build:**
  - Xcode 27.2, iOS 27.2 SDK, deployment target iOS 26.0;
  - the free Personal Team, automatic signing.
- **Prototype:** a container app "KX Spike 15" and a keyboard extension
  "KX Keys".
  - **The keyboard** has:
    - a status line;
    - a `UITextView` Scratchpad with `inputView = UIView()`;
    - a SwiftUI probe strip in one `UIHostingController`;
    - a small UIKit key grid with a 🌐 key.
  - **The app** has setup, test, log and dictation tabs. The dictation tab
    uses FluidAudio 0.18.2.
  - **Bundle IDs:** `de.lschaffrath.kallilexspike` and `….keyboard`, with
    App Group `group.de.lschaffrath.kallilexspike`.
  - The code lived in `spikes/ios-15/`, excluded from git; it isn't
    committed.
- **Measurement:**
  - **Logging:** JSON lines, written to the App Group when that's writable,
    otherwise to the process's own Documents. Both were pulled with
    `xcrun devicectl device copy from` (domains `appGroupDataContainer` and
    `appDataContainer` for the keyboard's bundle id).
  - **Memory:** `phys_footprint` and `os_proc_available_memory()`.
  - **Privacy:** the log holds only lengths, booleans, timings and error
    codes, no typed or selected text. Dictation transcripts are of the
    spike's own scripted texts.
- **Test server:** a Python stdlib server on the Mac (port 8081, same Wi-Fi
  and Tailscale), returning a canned chat completion with an optional
  `?delay=N`.
- **Rounds:**
  - Round A ran with Full Access on;
  - Round B ran with Full Access off;
  - Round C was dictation in the app.
- **Personal Team limits hit during setup:**
  - **App Group not assigned:** `xcodebuild -allowProvisioningUpdates`
    registered the keyboard's App ID with the App Groups capability but
    without the group. It doesn't assign a group to a new App ID, not even
    a brand-new group name. One tick in Xcode (target → Signing &
    Capabilities → App Groups) fixed it. ios-16 needs the same step.
  - **Install limit:** a device takes at most three apps signed with a free
    profile. Another test app had to be removed first.

## Unknown 1: Foundation Models in a keyboard

### Method

`SystemLanguageModel.default.availability`, then a rewrite of a ~300-word
German text through `LanguageModelSession`, with Full Access on and off.

### Result

- Available in both states (`contextSize 4096`).
- **The rewrite works with and without Full Access:**
  - 12.5 s with Full Access, 10.3 s without;
  - output about 1,750 characters.
- The keyboard's footprint grew by only 2–5 MB (18.8 → 23.6 MB; 39.0 →
  41.3 MB). Like in the Share Extension (ios-01), the model runs out of
  process.

### Evidence

`foundationModels.availability` → `available`. `foundationModels.rewrite` →
`latencyMs 12548.7, memBeforeMB 18.81, memPeakMB 23.61` (Full Access) and
`latencyMs 10341.1, memBeforeMB 38.97, memPeakMB 41.25` (no Full Access).

### Consequence for later specs

- **ios-19:** the on-device provider runs without Full Access. It never
  shows the Full Access card.
- Memory isn't a concern for on-device runs.

## Unknown 2: Read-only App Group

### Method

The app wrote `spike15-settings.json` and App Group `UserDefaults`. The
keyboard then read them four ways:
- a coordinated read;
- a coordinated write-intent access (`.forMerging`, as
  `AppGroupSettingsStore.load()` does);
- a plain `Data(contentsOf:)`;
- `UserDefaults(suiteName:)`.

It also attempted a write. All of this ran with Full Access on, then off.

### Result

| Access | Full Access on | Full Access off |
|---|---|---|
| Coordinated read (`NSFileCoordinator`, no options) | ok | **fails** (`NSCocoaErrorDomain 256`) |
| Coordinated write intent | ok | **fails** (`NSCocoaErrorDomain 512`) |
| Plain `Data(contentsOf:)` | ok | ok |
| `UserDefaults(suiteName:)` read | ok | ok |
| File write | ok | **fails** (`NSCocoaErrorDomain 513`, no permission) |

- `UserDefaults` writes return without an error in both states. Without Full
  Access they don't reach the shared container: the keyboard's log never
  appeared in the group.
- Without Full Access, the keyboard's own container (`Documents`) is
  writable. The spike's log landed there.

### Evidence

`appGroup.read.readonly` / `.writeIntent` → `ok false` with the errors above
(no Full Access); `appGroup.read.plain` / `.defaults` → `ok true`;
`appGroup.write` → `fileError … Code=513`.

### Consequence for later specs

- **ios-16:** `AppGroupSettingsStore.loadReadOnly()` must not use
  `NSFileCoordinator` at all; even a read-only coordinated read fails
  without Full Access. Use a plain `Data(contentsOf:)` and tolerate a
  half-written file. The app writes atomically, so a plain read sees either
  the old or the new file.
- **ios-21:**
  - `PendingTranscriptStore.current()` uses the same plain read;
  - `markTaken` can't delete without Full Access, as planned.

## Unknown 3: Keychain group without Full Access

### Method

The app wrote a generic-password item into the shared access group. The
keyboard read it with Full Access on and off.

### Result

- With Full Access: `errSecSuccess`, value present.
- Without: `-25291` (`errSecNotAvailable`).

### Evidence

`keychain.read` → `status 0, valueNil false` (Full Access) and
`status -25291, valueNil true` (no Full Access).

### Consequence for later specs

ios-19 as planned. Without Full Access there's no API key. Show the Full
Access card instead of an authentication error.

## Unknown 4: Network with Full Access

### Method

From the keyboard, requests to:
- `http://<mac>.local:8081`;
- `http://192.168.0.167:8081`;
- `http://100.126.248.33:8081` (Tailscale);
- `https://www.apple.com`.

The app had run the same targets first, which raised the Local Network
prompt for the app.

### Result

- **With Full Access:** all four succeeded on the first try, including
  mDNS and plain `http://` to the Tailscale address (16–131 ms). The
  keyboard showed no Local Network prompt of its own: the app's permission
  covered it.
- **Without Full Access:** every request failed at once with
  `NSPOSIXErrorDomain 1` ("Operation not permitted"), while the path was
  `satisfied`.
- **The app's first mDNS request** timed out (`-1001`, 15 s) while the
  Local Network prompt was open. It succeeded right after the prompt was
  answered.

### Evidence

`network.success` × 4 from the keyboard (mDNS 91 ms, LAN 16 ms, Tailscale
25 ms, HTTPS 131 ms); `network.failure` → `NSPOSIXErrorDomain#1` without
Full Access.

### Consequence for later specs

- ios-14's "HTTP to any server" works from the keyboard.
- **ios-19:** without Full Access a network run fails with
  `NSPOSIXErrorDomain 1`. Map this error to the Full Access card as well.
- **ios-22:** the onboarding should make sure the app has asked for Local
  Network access before the user tries a LAN provider from the keyboard.

## Unknown 5: Memory

### Method

- Live `phys_footprint` / `os_proc_available_memory()` in the status line.
- Then "Alloc until killed": +5 MB touched every 300 ms, each step logged.
- Run with Full Access, in Mail.

### Result

- **Idle:**
  - 19–31 MB: key grid, `UITextView`, one `UIHostingController`;
  - 23–41 MB after a Foundation Models run.
- **Available while idle:** `os_proc_available_memory()` reported 135–158 MB.
- **The kill:** the last logged step was at **174.7 MB** with 2.3 MB
  available. The keyboard was killed on the next step. The practical limit
  on this device is about **177 MB**, about three times the commonly quoted
  50–60 MB.
- **Not measured:** an iOS 26 device, and a smaller-RAM device.

### Evidence

`memory.allocStep` from `currentMB 119.5 / availableMB 57.5` up to
`currentMB 174.72 / availableMB 2.28`, then no further events.

### Consequence for later specs

- **ios-18 / ios-23:** the old 40 MB target was set for an assumed 50–60 MB
  limit. Raise the budget to **60 MB** for all measured scenarios, about a
  third of the measured limit, which leaves room for older devices and
  iOS 26.
- No special trimming (lazy settings, avoiding SwiftUI) is needed.

## Unknown 6: `selectedText` per host app

### Method

Text was selected in host apps, then the keyboard logged `selectedText`
(nil / empty / length) and the context lengths on `textDidChange` and on a
manual read.

### Result

- **Notes:** a 13-character selection arrived complete.
- **The spike app's `UITextView`:** selections of 4, 7, 29 and 688
  characters arrived complete. The 688 characters were one paragraph of the
  long sample; the user didn't select the whole ~2,700-character text, so
  the 3,000-character case is **not tested**.
- **With a selection,** `documentContextBeforeInput` and `AfterInput` are
  empty or very short; the selection doesn't appear in the context.
- **Mail:** only Insert/Undo was tested (unknown 11), not the selection.
- **Not tested:** Messages, Safari (address bar, `<textarea>`,
  `contenteditable`), WhatsApp, Signal, Slack, Google Docs, Pages, Gmail.

### Evidence

`selection.manualRead` → `selectedTextLength 13` (Notes) and `688` (spike
app).

### Consequence for later specs

- The main flow works in native text views.
- **ios-19:**
  - its manual host-app matrix must cover the untested apps and a
    selection of about 3,000 characters;
  - the "app doesn't share the selection" hint stays as planned.

## Unknown 7: Opening apps

### Method

From the keyboard, each on its own button:
- the responder-chain `UIApplication.open(_:options:completionHandler:)` to
  `kallilex-spike://dictate`, to `UIApplication.openSettingsURLString` and
  to `App-prefs:root`;
- `extensionContext.open(_:completionHandler:)` to the first two.

### Result

| Method | `kallilex-spike://dictate` | App settings URL | `App-prefs:root` |
|---|---|---|---|
| Responder chain | opens the app; it receives the URL | opens the Settings app | opens the Settings app |
| `extensionContext.open` | `false`, nothing opens | `false`, nothing opens | not tried |

The container app logged `app.openURL` with host `dictate`. iOS 26 wasn't
tested.

### Evidence

`openURL.responderChain` → `foundApplication true, completionSuccess true`
for all three; `app.openURL` → `scheme kallilex-spike, host dictate`;
`openURL.extensionContext` → `success false` for both.

### Consequence for later specs

- **ios-21:** path B (🎤 opens Kallilex straight into recording) is
  technically possible through the responder chain. It still needs App
  Review: 4.4.1 forbids launching apps other than Settings. Keep it behind
  `KeyboardFeatures.opensAppForDictation`, as planned.
  - Recommendation: ship 1.0.0 with path A only and the flag off.
  - Try path B in a TestFlight build first.
- **ios-19:** the Full Access card may get a **Settings** button. Opening
  Settings is allowed by 4.4.1 and works through the responder chain with
  `openSettingsURLString`, which opens the containing app's Settings page.
  Use only the public `openSettingsURLString`, never `App-prefs:`.

## Unknown 8: `UITextView` in a keyboard

### Method

The Scratchpad is a `UITextView` with `inputView = UIView()`. "Focus SP"
makes it first responder. The key grid edits it through
`insertText`/`deleteBackward`. A host ping inserts and deletes "x" in the
host afterwards.

### Result

- **Focus and editing:** it becomes first responder (`isFirstResponder
  true`) without summoning another keyboard. The caret is visible and moves
  with typing; tapping places it. Editing works.
- **The host connection survives:** `documentIdentifier` stays the same,
  and the host ping and Insert keep working.
- **iOS 26 scroll edge effect:**
  - in the first build, the text was invisible or cut off;
  - the view hierarchy showed a `ScrollEdgeEffectView` and `BackdropView`
    over the whole 68 pt text view;
  - at that height the top and bottom edge effects meet in the middle and
    hide the text;
  - hiding all four edge effects (`topEdgeEffect.isHidden = true` etc.)
    fixed it.
- **Content insets:** `contentInsetAdjustmentBehavior = .never` is also set.
  The offset and insets were 0 before and after, so it's a precaution.

### Evidence

`textView.focusScratchpad` → `isFirstResponder true`;
`textView.scratchpadEdit` → `sameDocumentIdentifierAsInitial true`;
`textView.dump` → `ScrollEdgeEffectView f=(0,0,317,68)` and a
`UIStandardTextCursorView` inside the text view.

### Consequence for later specs

- **ios-18:** use the `UITextView` Scratchpad with `inputView = UIView()`.
  - The append-only fallback isn't needed and can be dropped.
  - Hide all four scroll edge effects and set
    `contentInsetAdjustmentBehavior = .never`.
  - Add a UI test that the Scratchpad text is visible (hittable label value).

## Unknown 9: Height

### Method

A height constraint on the input view, set to 260, 290, 320, 360 and
420 pt.

### Result

- Every value was applied. The next measurement showed the previous request
  in effect, because layout lags by one pass.
- The host's layout didn't jump.
- 420 pt worked, so the limit is above that.

### Evidence

`height.set` → resulting bounds 260 → 290 → 320 → 360 → 420.

### Consequence for later specs

ios-18 keeps a fixed height of about 300 pt. A taller prompt mode is
possible if needed.

## Unknown 10: Lifecycle

### Method

- A 10-second request (`?delay=10`) was started.
- During it, the user switched keyboards and apps.
- The keyboard logged view callbacks, `deinit` and the
  `NSExtensionHost…` notifications.

### Result

- **Notifications:** `hostWillResignActive`, `hostDidEnterBackground`,
  `hostWillEnterForeground` and `hostDidBecomeActive` arrive when the host
  app goes to the background and back, and when the keyboard opens another
  app (unknown 7).
- **Disappearing:** the `UIInputViewController` is deallocated (`deinit`)
  within about 1 s of disappearing, whether by switching keyboards, opening
  an app or dismissing the keyboard. Each appearance creates a new
  controller (`viewDidLoad`).
- **In-flight requests:** a request in flight when the keyboard switched
  still finished (`slowRequest.finish success true`, 10.0 s). The
  controller was deallocated right after, so the result had nowhere to go.

### Evidence

`lifecycle.slowRequest.start` → `network.success … durationMs 10062` →
`keyboard.deinit` one second later.

### Consequence for later specs

- **ios-18:**
  - keep the keyboard state (`KeyboardModel`, Scratchpad text, the last
    result) in a process-wide object, not in the controller, so that it
    survives a new controller while the process lives;
  - don't persist it to disk.
- **ios-19:**
  - on `viewWillDisappear`, cancel an in-flight run, or let it finish into
    the process-wide state;
  - the Undo guard is invalidated on disappear as planned.

## Unknown 11: Undo Insert

### Method

- Inserted three test strings:
  - `"Test 😀 e\u{301} 👨‍👩‍👧\nZeile2"` (17 `Character`s);
  - an ASCII string;
  - a single newline.
- Then called `deleteBackward()` once per `Character`.
- Compared the context before insert and after delete, immediately and
  after 600 ms.

### Result

- **Notes, Mail and the spike app's `UITextView`:** the context after
  deleting matched the context before inserting, immediately and after
  600 ms. This held for the emoji, the combining accent, the ZWJ family
  emoji and the newline, with Full Access on and off. One `deleteBackward()`
  removes one `Character` (grapheme cluster) in these hosts.
- **Not tested:** the other apps of the matrix, web views among them.

### Evidence

`undo.delete` → `contextEndsWithInsertedBeforeDelete true,
postDeleteMatchesPreInsertImmediate true, postDeleteMatchesPreInsertAfter600ms
true, settledLengthDelta 0` (Notes, Mail, spike app).

### Consequence for later specs

- **ios-19:** the Undo Insert design stands. Count deletions in
  `Character`s.
- The web-view and third-party cases move to ios-19's manual matrix. If any
  of them miscounts, disable Undo for those characters, as planned.

## Unknown 12: Detecting the added keyboard

### Method

The app read `UITextInputMode.activeInputModes`:
- the public `primaryLanguage`;
- for comparison only, the private KVC key `identifier`.

### Result

- **The public API** gives only language codes (four modes active), which
  can't tell our keyboard apart.
- **The private key** `identifier` lists the bundle id
  (`foundOurs true`).
- There's no public way.

### Evidence

`setup.checkKeyboardAdded` → `modeCount 4, foundOurs true` (via the private
key).

### Consequence for later specs

ios-22: no "Added / Not added" status row. Show only the guide, the layout
picker and the test field. The private key must not ship.

## Unknown 13: Parakeet on the iPhone 16

### Method

FluidAudio 0.18.2 in the app, two models:
- `FluidInference/parakeet-tdt-0.6b-v3-coreml` ("v3"), through FluidAudio's
  own downloader;
- the German fine-tune `ValentinWeyer/parakeet-primeline-de-coreml` ("de"),
  hand-downloaded into a folder named `parakeet-tdt-0.6b-v3` and loaded with
  `AsrModels.load(from:version:.v3, encoderPrecision:.int8,
  encoderComputeUnits:.cpuAndNeuralEngine)`.

Five scripted recordings, 15–23 s each, 16 kHz mono, were each transcribed
by both models. Word error rate (WER) is a word-level Levenshtein distance,
lowercased, with punctuation stripped. The offline test was done in
airplane mode after a fresh app start.

### Result

| | v3 | de (German fine-tune) |
|---|---|---|
| Download | 483 MB in 33–42 s (Wi-Fi) | 1.22 GB in 25 s |
| First load (Neural Engine compile) | 33 s | **203 s** |
| Later loads | 9–26 s | not measured |
| Memory while loaded | 0.5 GB (first run); 1.4–1.7 GB (second run, see below) | 0.6–0.87 GB |
| Peak during download + first load | up to 2.35 GB | not measured |
| Time for ~20 s of audio | 0.1–0.3 s (first run), ~1.0 s (second run) | 0.5–2.2 s |
| WER: German email | 1.5 % | 0 % |
| WER: German with product names | 6.8 % | 6.8 % |
| WER: short German commands | 3.1 % | 3.1 % |
| WER: English paragraph | 1.7 % | 1.7 % |
| WER: mixed German/English | 0 % | 0 % |

- **Error sources:**
  - part of the 6.8 % is the speaker's own repetition;
  - the only real model error in v3 was "Test Flight" for "TestFlight";
  - both models got "Slack", "Google Docs", "iPhone", "GitHub", "Pull
    Request" and "README" right.
- **Offline:** transcription works in airplane mode after a fresh app
  start.
  - FluidAudio doesn't need the network once the files are complete.
  - If files are missing, its load falls back to a download and fails with
    `NSURLErrorDomain -1009`.
- **Memory differed between runs:**
  - first run: v3 loaded at about 0.5 GB and transcribed 20 s in 0.2 s;
  - second run, after a delete and fresh download: 1.4–1.7 GB and about
    1 s.

  That suggests the second load didn't run on the Neural Engine, but this
  wasn't confirmed. The app's memory limit on this 8 GB device wasn't
  reached.
- **Licenses:** both models are CC-BY-4.0. FluidAudio is Apache-2.0.
- **API changes:** FluidAudio 0.18.2 renamed `DownloadUtils.enforceOffline`
  to `ModelHub.offlineMode`.
- **Spike bug:** the first offline attempt failed because of a bug in the
  spike app. Several SwiftUI `Button`s in one `List` row all fired on one
  tap, so "Load" also deleted the model. `.buttonStyle(.borderless)` fixed
  it. The real Dictation settings must avoid the same trap.

### Evidence

- `dictation.download` → `bytes 483257242` (v3) and `1223797601` (de).
- `dictation.load` → `seconds 32.9, afterMB 506.3` (v3, first) and
  `seconds 202.8, afterMB 613.0` (de).
- `dictation.transcribe` → v3 `transcribeMs 108–274`, de `545–2234`;
  offline `transcribeMs 994–1143, peakMB ~1688`.
- `dictation-results.json` for the WER values.

### Consequence for later specs

- **ios-20, model choice:** use **v3**. The German fine-tune is no more
  accurate on these recordings, but more than twice as large, six times
  slower to compile on first load, and slower to transcribe.
- **ios-20, memory:**
  - dictation needs 0.5–1.7 GB while the model is loaded, with a peak of up
    to 2.35 GB during download and first load;
  - load the model only on the Dictation screen, and unload it when the
    screen closes and on a memory warning;
  - drop the "keep loaded for 2 minutes" idea: later loads take 9–26 s, so
    the screen needs a visible "Preparing…" state each time.
- **ios-20, follow-ups:**
  - investigate why the second run used three times the memory: compute
    units, CoreML's compile cache after a delete;
  - check whether `encoderComputeUnits: .cpuAndNeuralEngine` should be set
    explicitly for v3 too;
  - test on a 6 GB device (iPhone 15 / 16e class) before 1.0.0.
- **ios-20, downloader:** FluidAudio's downloader fetches from Hugging Face
  at revision `main`. For a pinned, verified download (SHA-256), ios-20
  needs its own downloader into FluidAudio's expected folder layout, as the
  spike did for "de", or a pinned revision if FluidAudio supports one.
- **ios-20, first load:** the first load (33 s) belongs right after the
  download, as planned.

## Unknown 14: Model delivery through Apple-hosted Background Assets

### Method

Documentation and forum research only. Apple-hosted asset packs are
configured and uploaded in App Store Connect, which the free Personal Team
can't use.

### Result

- **Open.**
- Apple-hosted packs need a paid developer account and an App Store Connect
  app record, with a TestFlight build for testing. Apple's forums cite
  limits of 200 GB and 100 packs per app.
- Developers reported managed-pack download failures on iOS 26.4 and later
  (unconfirmed).

### Evidence

No device evidence. Apple Developer Forums threads 810659 and 804377, and
the `BackgroundAssets` `AssetPack.downloadSize` documentation.

### Consequence for later specs

- **ios-20:** build the Hugging Face download (pinned, SHA-256-checked) as
  the shipping path for 1.0.0.
- Re-evaluate Apple-hosted packs once the paid account exists (ios-13), and
  switch only if a TestFlight build confirms it works.
- **ios-23:** the privacy policy names Hugging Face as the model's download
  source.

## Unknown 15: Haptics and input clicks

### Method

`UIImpactFeedbackGenerator(style: .medium)` and
`UIDevice.current.playInputClick()`, the latter with `UIInputViewAudioFeedback`
and `enableInputClicksWhenVisible = true`. Run with Full Access on (silent
mode on) and off (sound on).

### Result

- The user felt no haptic and heard no click in either state.
- The calls didn't fail.
- The generator wasn't `prepare()`d and wasn't retained, so a faulty probe
  can't be ruled out.

### Evidence

`haptics.impact`, `haptics.click`, and the user's statement after both
rounds.

### Consequence for later specs

- **ios-17 / ios-18:** no key haptics or click sounds in v1. They're not
  needed for the main flow.
- If wanted later, retest with a prepared, retained generator and with the
  "Keyboard Feedback" system settings on.

## Changed decisions

| Where | Before | After |
|---|---|---|
| PLAN-keyboard.md §2 / §14, ios-18, ios-23 | Memory limit ~50–60 MB, target < 40 MB | Measured limit ~177 MB (iPhone 16, iOS 27); budget **60 MB** |
| ios-16 | `loadReadOnly()` with a read-only coordinated read | **No `NSFileCoordinator`** in the keyboard; plain `Data(contentsOf:)` (coordinated reads fail without Full Access) |
| ios-18 | `UITextView` Scratchpad with an append-only fallback | `UITextView` works; drop the fallback; hide the iOS 26 scroll edge effects, `contentInsetAdjustmentBehavior = .never` |
| ios-18 | State in the controller | State in a process-wide object; the controller is deallocated on every disappearance |
| ios-17 / ios-18 | Haptics and input clicks open | None in v1 |
| ios-19 | On-device without Full Access depends on the spike | Runs without Full Access |
| ios-19 | Full Access card for 401/403 or no key | Also for `NSPOSIXErrorDomain 1` (network blocked) |
| ios-19 | Settings button only if allowed | Settings button through the responder chain with `openSettingsURLString` |
| ios-19 | Host matrix from the spike | Native views verified; Messages, Safari (3 kinds), WhatsApp, Signal, Slack, Google Docs, Pages, Gmail and a ~3,000-character selection move to ios-19's manual matrix |
| ios-20 | v3 or the German fine-tune | **v3**; the fine-tune is rejected |
| ios-20 | Unload 2 minutes after the last use | Load on the Dictation screen, unload when it closes and on a memory warning; 0.5–1.7 GB while loaded |
| ios-20 | Background Assets preferred | Pinned Hugging Face download for 1.0.0; Background Assets later |
| ios-21 | Path B only if the spike confirms it | Technically works; ship 1.0.0 with the flag off and test path B in TestFlight |
| ios-22 | Status row if a public check exists | No status row (only a private key exists) |
| ios-16 | — | Setup note: tick App Groups once in Xcode for the new keyboard App ID |

## Open items

- An iOS 26 device for unknowns 5 and 7.
- The rest of the host-app matrix (unknowns 6 and 11), in ios-19.
- Apple-hosted Background Assets (unknown 14), after the paid account
  exists.
- The cause of the higher memory of v3 in the second run (unknown 13), in
  ios-20.
