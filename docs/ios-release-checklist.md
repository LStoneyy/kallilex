# iOS Release Checklist

A concise, repeatable checklist for releasing Kallilex to the App Store. Work through the sections in order; do not submit for review or release until every gate passes.

## 1. Release-candidate gates

- [ ] CI is green: `ios.yml` passes on `main` (contract fixtures, KallilexKit, app, and UI tests all pass).
- [ ] String catalog is complete: no "new" or "needs review" states in Xcode (verified by `StringCatalogTests` in KallilexKit package tests).
- [ ] Privacy report reviewed: Xcode's privacy report for the archive is checked, and all declared APIs match what the privacy manifests declare (neither more nor less). Check `ios/Kallilex/Resources/PrivacyInfo.xcprivacy`, `ios/ShareExtension/Resources/PrivacyInfo.xcprivacy`, and `ios/KeyboardExtension/Resources/PrivacyInfo.xcprivacy` for validity.
- [ ] README and website describe only shipped behavior: no features promised that are not present, no version references that do not match the release being cut.
- [ ] Memory audit passed: the app and share extension stay below 50 MB peak memory during active use. The keyboard extension stays below 60 MB peak during the audit scenarios (use Xcode Instruments on a device; record results in `issues-ios/release-ios-1.0.0-matrix.md`).
  - [ ] Keyboard scenarios: idle in prompt mode, keys mode while typing, a cloud prompt, an on-device prompt, taking a long selection (~20,000 characters).

## 2. Product-owner prerequisites (one-time, before first release)

**Note:** These must be completed before TestFlight can be released. Do not skip these.

- [ ] **Confirm:** Individual or organization developer account? (Organization "webcommits" requires a D-U-N-S number; this decides the seller name on the App Store.)
- [ ] Enrolled in the Apple Developer Program (`developer.apple.com`). Cost: $99 USD per year.
- [ ] Registered bundle IDs:
  - [ ] App bundle ID: `com.webcommits.kallilex`
  - [ ] Share extension bundle ID: `com.webcommits.kallilex.share`
- [ ] Registered App Group: `group.com.webcommits.kallilex`
- [ ] Registered Keychain sharing group: `$(AppIdentifierPrefix)com.webcommits.kallilex.shared`
- [ ] Local.xcconfig does not override `KALLILEX_ID_PREFIX` (release builds must use `com.webcommits`).
- [ ] Created the App Store Connect app record for "Kallilex" (bundle ID `com.webcommits.kallilex`). Category: Productivity.
- [ ] Completed the Paid Apps Agreement in App Store Connect (requires Apple's own contact details and the organization/individual address).
- [ ] Completed banking and tax forms in App Store Connect (W-9 for US, tax ID for other regions).
- [ ] Set the price (paid app, one-time purchase) and territories in "Pricing and Availability".
- [ ] (For EU storefronts) Completed the DSA (Digital Services Act) trader status declaration in App Store Connect.
- [ ] App Store description and website say the iPhone app is a one-time purchase and nowhere call it free (the desktop app stays free).

## 3. Version and build bumps

**File:** `ios/Config/Common.xcconfig`

Keys to update:
- `MARKETING_VERSION` — the version users see (e.g., 1.0.0, 1.0.1, 1.1.0).
- `CURRENT_PROJECT_VERSION` — the internal build number (incremented for each build).

**For each release or TestFlight build:**

1. Increment `CURRENT_PROJECT_VERSION` by 1.
2. Update `MARKETING_VERSION` only for public releases (not for intermediate TestFlight builds).

**Example:**
| Phase | MARKETING_VERSION | CURRENT_PROJECT_VERSION | Purpose |
|-------|-------------------|-------------------------|---------|
| TestFlight internal | 1.0.0 | 1 | First internal tester build |
| TestFlight internal re-test | 1.0.0 | 2 | Incremented for retest |
| TestFlight external (optional) | 1.0.0 | 3 | Optional beta review |
| App Store 1.0.0 | 1.0.0 | 4 | Final release build |
| 1.0.1 patch | 1.0.1 | 5 | Next patch release |

- [ ] Bump `MARKETING_VERSION` and/or `CURRENT_PROJECT_VERSION` in `ios/Config/Common.xcconfig`.
- [ ] Commit the version bump (message: e.g., "Bump iOS version to 1.0.0 (build 4)").

## 4. Archive, validate, and upload

**All steps are manual in Xcode; no command-line `xcodebuild`.**

- [ ] Open `ios/Kallilex.xcodeproj` in Xcode.
- [ ] Select the **Kallilex** scheme (not ShareExtension).
- [ ] Set the destination to **Any iOS Device** (not a simulator).
- [ ] Product → Archive.
  - [ ] Xcode builds the app and extension and opens the Organizer when done.
- [ ] In the Organizer, select the newest archive.
- [ ] Click **Validate App** (not Distribute).
  - [ ] Choose App Store Connect as the distribution method.
  - [ ] Select Automatic signing.
  - [ ] Wait for validation to complete (usually 1–2 minutes). If it fails, fix errors and re-archive.
- [ ] Once validation passes, click **Distribute App**.
  - [ ] Choose **App Store Connect**.
  - [ ] Choose **Upload**.
  - [ ] Select Automatic signing.
  - [ ] Xcode uploads to App Store Connect (5–15 minutes depending on speed).

**Note:** No code-signing secrets in the repo. Xcode fetches certificates and provisioning profiles from the developer account during signing.

## 5. TestFlight internal

- [ ] New build appears in App Store Connect → TestFlight → **Internal Testing**.
- [ ] Review and accept EULA and any warnings for the build.
- [ ] Add internal testers (team members' Apple IDs).
- [ ] Testers receive email invites; they install TestFlight and download the build.
- [ ] Run the manual host-app matrix (see section 6 and `issues-ios/release-ios-1.0.0-matrix.md`):
  - [ ] App installs and launches without crashing.
  - [ ] All tabs (Scratchpad, Prompts, Providers, Settings) are functional.
  - [ ] Share extension appears in the share sheet and handles text correctly.
  - [ ] Onboarding works and consent screens appear.
  - [ ] Running a prompt with the on-device model (if eligible) works.
  - [ ] Running a prompt with a cloud provider (using the reviewer API key) works.
- [ ] Keyboard Full Access checks (record results in `issues-ios/release-ios-1.0.0-matrix.md`):
  - [ ] Full Access off: typing, Insert, Replace selection, on-device prompt all work.
  - [ ] Full Access on: typing, Insert, Replace selection, on-device prompt, cloud prompt, copy result all work.
- [ ] Keyboard host-app matrix (see section 6 and `issues-ios/release-ios-1.0.0-matrix.md`): test across apps (Notes, Mail, Messages, Safari, WhatsApp, Signal, Slack, Google Docs, Pages, Gmail).
- [ ] Manual gates (carry over from earlier specs; test on a real device):
  - [ ] VoiceOver pass through the share flow and keyboard in real apps (Notes, Mail, Safari).
  - [ ] Contrast check in light and dark mode with the Accessibility Inspector.
  - [ ] Dynamic Type at the largest accessibility size works.
  - [ ] On-device model test on an Apple Intelligence device, including a refusal case (if applicable).
  - [ ] Share extension and keyboard memory use during a long run stays reasonable (< 50 MB for app and share, < 60 MB for keyboard).
  - [ ] Paste button and pasteboard behavior work on a real device.
  - [ ] Safari text selection via the share sheet works.
  - [ ] Keyboard typing and selection take-over in Safari address bar and web textareas.
  - [ ] German UI with device language set to German displays correctly.

## 6. Manual host-app matrix

- [ ] Share extension host-app matrix results recorded in `issues-ios/release-ios-1.0.0-matrix.md`.
  - [ ] Template copied and filled in after TestFlight internal run.
  - [ ] All test cases run: Safari (text selection and page only), Mail (compose and read), Notes, Messages, WhatsApp, Pages, Google Docs, Chrome.
  - [ ] Each app tested for: Appear in share sheet, Text intact, Paste-back.
  - [ ] Summary counts recorded: total apps tested, passes, failures, N/A.
  - [ ] Issues found and workarounds documented.
  - [ ] Tester sign-off with name and date.
- [ ] Keyboard host-app matrix results recorded in `issues-ios/release-ios-1.0.0-matrix.md`.
  - [ ] Keyboard added and Full Access enabled.
  - [ ] All apps tested: Notes, Mail (compose), Messages, Safari (address bar and textareas), WhatsApp, Signal, Slack, Google Docs, Pages, Gmail.
  - [ ] Each app tested for: Take-over selection into Scratchpad, Replace selection, Undo immediately after Insert, Undo restores original text exactly.
  - [ ] Test with ~3,000-character selection in at least one app.
  - [ ] Issues and workarounds documented.
  - [ ] Tester sign-off with name and date.

## 7. TestFlight external (optional)

**Only if external beta testing is desired; otherwise skip to section 8.**

- [ ] External beta invite sent from App Store Connect → TestFlight → **External Testing**.
- [ ] Feedback from external testers reviewed and addressed.

## 8. App Review submission

- [ ] Review notes prepared in `ios/AppReview/review-notes.md`.
- [ ] Metadata reviewed for accuracy:
  - [ ] App name, description, screenshots, keywords match the app.
  - [ ] Website privacy URL: https://kallilex.webcommits.info/privacy.html (German: datenschutz.html).
- [ ] In App Store Connect, open the app record → **App Store** → the version being released, and under **Build** select the TestFlight build.
- [ ] Click **Submit for Review** (or **Send for Review**).
- [ ] Complete review information:
  - [ ] Export Compliance: the app only uses standard encryption (HTTPS via URLSession), which is exempt; answer accordingly.
  - [ ] Content Rights: Confirm you own or have permission.
  - [ ] Advertising Identifier: "No".
  - [ ] Notes for Review: Paste `ios/AppReview/review-notes.md` contents. If a temporary reviewer API key is needed, include it in the format: `Reviewer API Key (valid until [date]): sk-...`
- [ ] **Create temporary reviewer API key** (before submission):
  - [ ] Generate a new API key with a short expiry (e.g., 7 days) from the provider dashboard.
  - [ ] Include the key in the review notes above.
- [ ] Click **Submit for Review**.
- [ ] App Store Connect confirms submission. Review queue is typically 1–2 days.

## 9. After App Review

- [ ] App Review approves or rejects the build.
  - [ ] If **approved:** Build moves to "Ready for Sale". You can manually release it (see section 10).
  - [ ] If **rejected:** App Review sends a detailed reason. Fix issues and re-submit.
- [ ] **Revoke the temporary reviewer API key immediately** after the review decision (approval or rejection).

## 10. Manual release to App Store

- [ ] In App Store Connect, navigate to the app → **App Store** section.
- [ ] Approved build appears in the "Builds" section.
- [ ] Click the build to select it.
- [ ] (Optional) Set a release date to schedule the release.
- [ ] Otherwise, click **Release** to publish immediately.
- [ ] Confirm the release. The app is now live on the App Store.

**Note:** Verify price tier and territories are correctly set in "Pricing and Availability" before releasing.

## 11. Post-release

**Immediately after releasing:**

- [ ] Tag the release commit with the format `ios-vX.Y.Z`:
  ```bash
  git tag ios-v1.0.0 [commit-hash]
  git push origin ios-v1.0.0
  ```
- [ ] Verify desktop CI does not run: check GitHub → Actions for `release.yml` workflow. It should **not** have been triggered (its filter is `tags: ["v*"]`, which does not match `ios-v*`).
- [ ] Revoke the temporary reviewer API key if not already done.
- [ ] Update the website:
  - [ ] Replace "Coming to iPhone" teaser in `website/index.html` with the App Store link (get the actual URL from App Store Connect).
  - [ ] Update `website/sitemap.xml` if needed.
  - [ ] Deploy the website.
- [ ] Update README:
  - [ ] Add iOS App Store link to the iOS section.
  - [ ] Commit and push to `main`.

**Done.** The iOS app 1.0.0 is now live.
