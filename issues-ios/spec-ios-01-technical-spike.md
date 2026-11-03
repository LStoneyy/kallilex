# Spec ios-01 — Technical spike

Status: ready-for-agent
Phase: spike (Phase 0, throwaway prototype)
Depends on: —

## Problem Statement

Seven platform constraints and unknowns must be answered before the iOS app
architecture can be finalized (PLAN.md §2, §15). A spike prototype built on a
free Apple Developer Account will test them and record the findings in a written
report.

## Solution

Build a throwaway prototype in Xcode targeting iOS 26+ that exercises each of
the seven unknowns and records the results and implications in a new document
`issues-ios/spike-ios-01-report.md`, structured as one section per unknown.

The spike code lives outside the repo (e.g., a local `spikes/` folder) or, if
kept locally in the repo, is added to `.gitignore` and never committed. The
report stays in the repo in `issues-ios/` as a record for later phases.

## User Stories

1. As an architecture owner, I want to know which host apps pass the selected
   text to the Kallilex Share Extension as plain text, and whether Safari needs
   a JavaScript preprocessor to extract text from a URL-only share, so that I
   can size the fallback Scratchpad feature.
2. As a developer implementing the Share Extension, I want to know whether the
   local network permission prompt fires from the extension or only the app, and
   exactly which error code appears when permission is denied, so that I can
   distinguish `localNetworkDenied` from `unreachable` and plan the onboarding
   flow correctly.
3. As an on-device-model user, I want to confirm that Foundation Models work
   inside a Share Extension, measure their memory cost, record whether they run
   in-process or in a system daemon, and measure latency for a realistic
   rewrite task, so that we can ship the feature in v1 if safe.
4. As a developer, I want to verify that `extensionContext.open(_:)` works to
   deep-link from the extension to the container app, so that we can route
   "not configured" users there.
5. As a release engineer, I want to measure the peak memory of the SwiftUI
   extension during a real HTTP request, so that we never hit the 120 MB hard
   limit (PLAN.md §8.3 target: below 50 MB).
6. As a user, I want to confirm that pasting back after a Copy still replaces
   the original selection in common host apps, so that the core workflow is
   viable.
7. As a platform architect, I want to know whether App Groups and Keychain
   sharing can be provisioned and used on a free Personal Team, so that I can
   decide whether the paid developer account (PLAN.md §18 Q2) is required
   before Phase 1 begins.

## Implementation Decisions

### Scope of the spike

The prototype covers the seven unknowns only:

1. **Host app text delivery (unknown 1, including 1b):** Create a share sheet
   with `NSExtensionActivationSupportsText` and
   `NSExtensionActivationSupportsWebURLWithMaxCount`. Receive input in
   `extensionContext.inputItems` and log which types (plainText, utf8PlainText,
   rtf, URL) carry text. Test on Safari (URL only, with selection), Mail,
   Notes, Messages, WhatsApp, Pages, Google Docs, Chrome.
   - **Unknown 1b (Safari preprocessor):** If Safari delivers only a URL
     without text, test a `NSExtensionJavaScriptPreprocessingFile` that returns
     `window.getSelection().toString()` and record whether it yields the
     selection text.

2. **Local networking and permissions (unknown 2):** Set
   `NSAllowsLocalNetworking` and `NSLocalNetworkUsageDescription` in
   `Info.plist` with correct nesting under `NSAppTransportSecurity`. From a
   physical iPhone on the same Wi-Fi as a Mac, make `http://` requests to:
   - `http://<mac-name>.local:8080/` (mDNS)
   - `http://<mac-LAN-IP>:8080/` (private IP)
   - An `https://` public host as control
   
   Test from both the app and the extension. Record for each URL and target:
   - Does ATS allow the request?
   - Does the Local Network permission prompt appear? From the app or extension?
   - If permission is denied or never granted in the extension: what is the
     exact error domain and code? (This determines whether `localNetworkDenied`
     can be told apart from `unreachable` in error reporting.)

3. **Foundation Models in extensions (unknown 3):** On a physical iOS 26+ device
   with Apple Intelligence enabled, use `SystemLanguageModel.default` to run a
   rewrite request (~300 German words) from the extension. Measure:
   - Peak memory using Xcode's memory gauge or Instruments Allocations on
     device (record whether the Foundation Model runs in-process or in a system
     daemon, visible as the extension's memory delta).
   - Latency for the inference.
   - Check `SystemLanguageModel.availability` (ready, downloading, unsupported,
     or other).

4. **Deep linking from extension (unknown 4):** Call
   `extensionContext.open(URL(string: "kallilex://settings/providers"))` from
   the extension and log the result.

5. **Extension memory peak (unknown 5):** Instrument the extension with memory
   profiling during a *real* HTTP request to an OpenAI-compatible endpoint
   (or the local LAN server serving a canned chat-completions JSON) with the
   SwiftUI UI shown. Use Xcode's memory gauge or Instruments Allocations on
   device. Record peak resident memory. Target (from PLAN.md §8.3): below
   50 MB.

6. **Pasting after Share (unknown 6):** Run the extension flow (select text →
   Share → Kallilex → run a prompt → Copy) in Safari, Mail, Notes, Messages
   and check whether the original selection is still in place after returning
   to the host app, and whether a single Paste replaces it.

7. **Free Personal Team capabilities (unknown 7):** Test whether App Groups and
   Keychain sharing can be provisioned on a free Personal Team. Write a value
   from the app to both the App Group container and the Keychain, then read
   it from the extension. Record success/failure for each. This determines
   whether the paid developer account must be created before Phase 1.

**Out of scope:** UI polish beyond a minimal placeholder, full app or extension
UI, the full popover, permanent storage beyond what is needed to test unknown 7,
production code. The extension has a minimal placeholder UI (a text editor, a
"Rewrite" button, Copy, and spinners for in-flight requests).

### Report structure

File: `issues-ios/spike-ios-01-report.md`

```
# Spike ios-01 Report — Platform constraints and unknowns

Date: [completion date]

## Unknown 1: Which host apps deliver the selected text as plain text?

### Method

[How the test was run; which devices and iOS versions]

### Result

[Which types arrived (plainText, utf8PlainText, rtf, URL, etc.); which apps
needed which types]

### Evidence

[Logs, code snippet, screenshots if visual]

### Consequence for later specs

[Impact on share-sheet activation rules, fallback Scratchpad design, docs]

## Unknown 2: Local Network permission — app or extension, with or without ATS?

### Method
[…]
### Result
[…]
### Evidence
[…]
### Consequence for later specs
[…]

[Repeat for unknowns 3, 4, 5, 6]
```

Each section answers exactly one unknown using the four-part structure above.
The report is written in plain English, concise and factual (no hypothesis or
speculation beyond "further testing needed"). It is the source of truth for
later phases.

### Platform and prerequisites

- Xcode 26+ on macOS 26+ (iOS 26 SDK is required for iOS 26 deployment target
  and Foundation Models).
- At least one physical iOS 26+ device with Apple Intelligence enabled
  (required for unknown 3; unknowns 1, 2, 4, 5, 6 can use simulator but unknown
  2 and 6 benefit from real devices and host apps).
- A free Apple Developer Account (creates a Personal Team with provisioning
  profiles that expire after 7 days; the app must be reinstalled from Xcode).
- For unknown 2, a Mac on the same Wi-Fi running a simple test HTTP server
  (e.g., `python3 -m http.server 8080 --bind 0.0.0.0`).

### Acceptance criteria for the spike

- All seven unknowns are addressed in the report (result + consequence for
  each).
- Any unknown that can be answered is answered; unknowns that remain open have a
  fallback plan stated (e.g., "if Foundation Models don't work in extensions,
  keep them in the app only").
- The report is committed to `issues-ios/spike-ios-01-report.md` on the
  `ios-plan` branch.
- The spike code is **not committed** to the repo at all; it lives locally
  (outside the repo, or in a `spikes/` folder at the repo root added to
  `.gitignore`) so that `ios/` starts clean in Phase 1.

## Testing Decisions

The spike is a one-off prototype. No automated tests are needed. Manual
verification covers all seven unknowns. Results are recorded by hand in the
report.

## Out of Scope

- Production code or architecture decisions beyond what the unknowns directly
  address.
- App Review compliance or full signing beyond what is necessary to build and
  run the app on device.
- The Scratchpad, onboarding, prompts, provider management, or full UI.
- Localization or accessibility.

## Further Notes

- PLAN.md §2 and §15 define the seven unknowns and their stakes.
- PLAN.md §17 (Risks and mitigations) shows why each unknown matters; the
  report feeds directly into mitigation decisions for Phases 1+.
- The free Personal Team's provisioning profiles on device expire after 7 days
  of first use (refresh by reinstalling from Xcode). If a fresh device is
  needed, the team can provision it again. The spike must complete before
  provisioning profiles expire, or unknown 7 results must be extrapolated from
  Xcode simulator tests. A paid Apple Developer Program account should be
  created before Phase 1 if unknown 7's answer is "paid account required"
  (PLAN.md §18, Q2).
- If a physical device is unavailable, unknowns 1 (1b needs Safari),
  3 (needs Apple Intelligence), 4, 5 (memory of extension) can proceed on
  simulator. Unknowns 2 (Local Network permission from extension), 6
  (paste-back in host apps) require real devices and host apps — defer if
  needed, test manually in Phase 1 as fallback.
- Unknown 7's result directly informs whether Phase 1 can proceed or whether a
  paid account must be enrolled first.
