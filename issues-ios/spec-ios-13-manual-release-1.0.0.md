# Spec ios-13 — Manual release and 1.0.0

Status: ready-for-agent (the agent writes the checklist and docs; the
product owner performs the App Store Connect and upload steps)
Phase: Phase 6 (Release)
Depends on: ios-11, ios-12, and a paid Apple Developer Program membership

## Problem Statement

The iOS app is feature-complete after Phase 5 (Polish). The developer must
enroll in the Apple Developer Program, register bundle IDs and app groups,
set up billing and tax forms for a paid app, create the App Store Connect
app record, build an archive, validate it, upload it to TestFlight, conduct
internal and external testing against a manual host-app matrix, submit for
review with the review notes and temporary reviewer API key, and finally
release it manually after App Review approval. A checklist must gate every
step so that nothing is skipped, and the release matrix must be recorded for
future reference. Version bumps are manual in the `ios/Config/Common.xcconfig`
file, and release tags follow the pattern `ios-vX.Y.Z` to avoid triggering
desktop CI.

## Solution

Write a `docs/ios-release-checklist.md` modeled on `docs/release-checklist.md`
with sections for gates (CI green, German catalog complete, privacy report
reviewed, README/website describe only shipped behavior), version bumps,
archive and upload, TestFlight (internal and external), manual App Review
submission, and post-release steps (tag, push tag, confirm desktop CI does
not run, revoke reviewer key). The prerequisite section lists the one-time
Apple Developer Program enrollment, bundle ID registration, agreements, and
tier selection, marked as product owner responsibility. Define a manual
host-app matrix template that documents results for Safari, Mail, Notes,
Messages, WhatsApp, Pages, Google Docs, and Chrome across appear/text
intact/paste-back categories. Record the 1.0.0 matrix results in a filled
copy at `issues-ios/release-ios-1.0.0-matrix.md`. No CI automation or
fastlane; all steps are manual or run locally.

## User Stories

1. As a product owner, I want a step-by-step checklist for releasing the
   iOS app, so that I do not forget any gates or submission steps.
2. As a product owner, I want to enroll in the Apple Developer Program once
   and have all prerequisites documented, so that I can set up the account
   before engineering begins.
3. As a developer, I want to bump the version number and tag the release
   commit in a simple, reproducible way, so that every release is consistent.
4. As a tester, I want a matrix that documents which apps the share flow
   works with, so that we know where the app is confirmed to work and where
   to investigate issues.
5. As a developer, I want the release process to be manual (no CI automation),
   so that I have full control and visibility into each step.
6. As a developer, I want to confirm that iOS release tags do not trigger
   desktop CI, so that desktop users do not see unexpected updates.
7. As App Review, I want to test the app with a temporary API key that is
   revoked after approval, so that no permanent credentials are exposed.
8. As a future releaser, I want a template and recorded results from the 1.0.0
   release, so that I can repeat the matrix for later versions.
9. As an App Store user, I want the app to be listed as a paid app with a
   clear one-time price, so that I know what I am buying.
10. As a developer, I want no fastlane, no GitHub Actions automation for
    upload, and no complex tooling, so that the process is transparent and
    easy to troubleshoot.

## Implementation Decisions

### Prerequisites (product owner, one-time)

Before engineering begins on Phase 1 or ios-02, the product owner must:

**Checklist of one-time account setup:**

- [ ] **To confirm:** Individual or organization developer account?
  (Organization "webcommits" requires a D-U-N-S number; this decides the
  seller name on the App Store.)
- [ ] Enroll in the Apple Developer Program (`developer.apple.com`). Cost:
  $99 USD per year.
- [ ] Register the app's bundle ID: `com.webcommits.kallilex`.
- [ ] Register the extension's bundle ID: `com.webcommits.kallilex.share`.
- [ ] Register the App Group: `group.com.webcommits.kallilex`.
- [ ] Register the Keychain sharing group:
  `$(AppIdentifierPrefix)com.webcommits.kallilex.shared`.
- [ ] Create the App Store Connect app record for "Kallilex" (bundle ID
  `com.webcommits.kallilex`). Category: Productivity. Pricing: Paid (one-time
  purchase).
- [ ] Complete the Paid Apps Agreement in App Store Connect (requires Apple's
  own contact details and the organization/individual address).
- [ ] Complete banking and tax forms in App Store Connect (W-9 for US, tax ID
  for other regions).
- [ ] **To confirm:** Choose price tier and territories. (Single price tier
  or region-specific prices?)
- [ ] (For EU storefronts) Complete the DSA (Digital Services Act) trader
  status declaration in App Store Connect. This publishes the account holder's
  address, email, and phone number as the "trader" responsible for the app.

**Note:** The paid app setup is required before TestFlight can be released
(TestFlight respects the Paid Apps agreement status). Do not skip this.

### Version and build number bumps

**File:** `ios/Config/Common.xcconfig`

```
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 1
```

For each release or TestFlight build:

1. Increment `CURRENT_PROJECT_VERSION` by 1 (internal build number, used for
   ordering builds in TestFlight and App Store).
2. Update `MARKETING_VERSION` only for public releases (the version users
   see: 1.0.0, 1.0.1, 1.1.0, etc.).

Example progression:

| Release phase | MARKETING_VERSION | CURRENT_PROJECT_VERSION | Purpose |
|---|---|---|---|
| Spike (ios-01) | 1.0.0-dev | — | Internal only (no release) |
| Phase 1–5 (development) | 1.0.0-dev | — | Internal only (no release) |
| TestFlight internal | 1.0.0 | 1 | First build sent to testers |
| TestFlight internal (re-test) | 1.0.0 | 2 | Incremented for each build |
| TestFlight external (beta) | 1.0.0 | 3 | Optional beta review |
| App Store 1.0.0 | 1.0.0 | 4 | Final release build |
| 1.0.1 patch | 1.0.1 | 5 | Next patch release |

Commit the version bump before archiving.

### Archive, validate, and upload

**Steps (all manual, all in Xcode):**

1. In Xcode, open `ios/Kallilex.xcodeproj`.
2. Select the **Kallilex** scheme (not ShareExtension).
3. Set the destination to **Any iOS Device** (not a simulator).
4. **Product → Archive.**
   - Xcode builds the app and extension and opens the Organizer when done.
5. In the Organizer, select the newest archive.
6. Click **Validate App** (not Distribute).
   - Choose App Store Connect as the distribution method.
   - Select Automatic signing.
   - Wait for the validation to complete (usually 1–2 minutes).
   - If validation fails, fix the errors and re-archive.
7. Once validation passes, click **Distribute App**.
   - Choose **App Store Connect**.
   - Choose **Upload**.
   - Select Automatic signing.
   - Xcode uploads the app to App Store Connect. This can take 5–15 minutes
     depending on upload speed.

**Do not** use command-line `xcodebuild` for this; the web interface in
Xcode's Organizer is standard.

**Note:** No code-signing secrets in the repo. Xcode fetches certificates and
provisioning profiles from the developer account during signing.

### TestFlight internal

**Purpose:** In-house testing before external beta or public release.

**Steps:**

1. After upload completes in App Store Connect, navigate to
   TestFlight → **Internal Testing**.
2. The new build appears in the list. Click it to review.
3. Accept the EULA and any warnings.
4. Add internal testers (team members' Apple IDs).
5. Testers receive an email invite; they install TestFlight and download the
   build.
6. Conduct the manual host-app matrix (see below).

**Expected behavior before release:**

- The app installs and launches without crashing.
- All tabs (Scratchpad, Prompts, Providers, Settings, About) are
  functional.
- The share extension appears in the share sheet and handles text correctly.
- Onboarding works and consent screens appear.
- Running a prompt with the on-device model (if eligible) works and shows a
  result.
- Running a prompt with a cloud provider (using the reviewer API key)
  works.
- The memory peak stays below 50 MB during a request (use Xcode's memory
  profiler on a device).

### Manual host-app matrix (ios-13 gate and release checklist)

**Purpose:** Verify that the share extension works correctly in real apps
across selection, text integrity, and paste-back.

**Template:** `issues-ios/release-ios-1.0.0-matrix.md`

```markdown
# iOS Release 1.0.0 — Host App Matrix

Release: 1.0.0
Date: 2026-11-XX
Tester: [Name]
Device: [iPhone model, iOS version]
Kallilex build: [MARKETING_VERSION / CURRENT_PROJECT_VERSION]

## Instructions

For each app in the list:

1. **Appear:** Does Kallilex appear in the share sheet?
2. **Text intact:** Is the selected text passed to Kallilex without corruption
   or loss?
3. **Paste-back:** Does pasting the result back into the app replace the
   selection?

Mark each cell with:
- ✓ Pass
- ✗ Fail (describe the issue)
- — N/A (the app doesn't support share, or text selection is not available)

## Matrix

| App | Appear | Text intact | Paste-back | Notes |
|---|---|---|---|---|
| Safari (with text selection) | | | | |
| Safari (page only, no selection) | | | | |
| Mail (compose) | | | | |
| Mail (read) | | | | |
| Notes | | | | |
| Messages | | | | |
| WhatsApp | | | | |
| Pages | | | | |
| Google Docs | | | | |
| Chrome | | | | |

## Summary

- Total apps tested: 10
- Passes: [number]
- Failures: [number]
- N/A: [number]

## Issues found

(List any failures with reproduction steps and workarounds, if any.)

## Sign-off

**Tester:** [Name]
**Date:** 2026-11-XX
**Status:** Ready for release / Requires fixes
```

The tester copies this template to
`issues-ios/release-ios-1.0.0-matrix.md` and fills it in after the
TestFlight internal run. Results are recorded only from an actual run;
the spec deliberately contains no example results.

### TestFlight external (beta)

**Purpose:** Optional external beta testing before public release.

**Tester note:** ios-13 may ship with internal testing only (the product
owner decides). If external beta is desired, follow the same steps as
internal testing but invite external testers from the "External Testing"
section.

**Expected:** Same as internal testing, plus confirmation from a broader
audience that the app is stable.

### App Review submission

**Steps:**

1. In App Store Connect, navigate to the app's record.
2. Go to **TestFlight** and select the build you want to submit.
3. Click **Submit for Review** (or **Send for Review** depending on the
   interface).
4. Complete the review information:
   - **Export Compliance:** Select "No" if the app does not use cryptography
     beyond HTTPS (Kallilex does not; SSL/TLS is standard). Answer other
     export questions as needed.
   - **Content Rights:** Confirm you own or have permission for the content.
   - **Advertising Identifier:** Not used (no ads). Select "No".
   - **Notes for Review:** Paste the contents of
     `ios/AppReview/review-notes.md` (see ios-12).
     - Include the temporary reviewer API key here, if needed:
       `Reviewer API Key (valid until [date]): sk-...`. Create this key
       right before submission and revoke it immediately after approval or
       rejection.
5. Review the app's metadata (name, description, screenshots, etc.) for
   accuracy.
6. Click **Submit for Review**.
7. App Store Connect confirms the submission. The review queue is typically
   1–2 days.

**After approval or rejection:**

- If **approved:** The app is moved to "Ready for Sale". You can manually
  release it (see below) or schedule it for a specific date.
- If **rejected:** App Review sends a detailed reason. Fix the issues and
  re-submit.

**Note:** Revoke the reviewer API key immediately after the review decision
(approval or rejection), regardless of the outcome.

### Manual release to App Store

**Steps (after App Review approval):**

1. In App Store Connect, navigate to the app's **App Store** section.
2. The approved build appears in the "Builds" section.
3. Click the build to select it.
4. If you want to schedule the release, set a release date.
5. Otherwise, click **Release** to publish immediately.
6. Confirm the release. The app is now live on the App Store.

**Note:** Kallilex is a paid app. Ensure that the price tier and territories
are correctly set in App Store Connect before release (configured in the
"Pricing and Availability" section). The release cannot be undone easily, so
verify the metadata one more time before releasing.

### Post-release steps (within hours)

**Immediately after releasing:**

1. **Tag the release commit:**

```bash
git tag ios-v1.0.0 [commit-hash]
git push origin ios-v1.0.0
```

Use the format `ios-vX.Y.Z`, not `vX.Y.Z` (which would be a desktop tag).

2. **Verify that desktop CI does not run:**

Go to **GitHub** → **Actions** → look for the `release.yml` workflow. It
should **not** have been triggered by the `ios-v1.0.0` tag (its filter is
`tags: ["v*"]`, which matches `v1.0.0` but not `ios-v1.0.0`).

If `release.yml` *did* run, that is a bug — the tag filter is wrong. Fix it
and re-run a test tag.

3. **Revoke the reviewer API key:**

Log in to the OpenAI dashboard (or whatever provider supplied the key) and
revoke the key. Do not leave it active.

4. **Update the website:**

- Replace the "Coming to iPhone" teaser in `website/index.html` with the
  App Store link:

```html
<a href="https://apps.apple.com/app/kallilex/...">Download on the App Store</a>
```

(Get the actual App Store URL from App Store Connect.)

- Update `website/sitemap.xml` if needed (no changes usually required).
- Deploy the website.

5. **Update the README:**

Add the iOS App Store link to the iOS section:

```markdown
## iOS

Kallilex is available on the App Store:

[Download on the App Store](https://apps.apple.com/app/kallilex/...)

You can also build it yourself from source (see the instructions above).
```

Commit and push to `main`.

### Release checklist (docs/ios-release-checklist.md)

Create a comprehensive, formatted checklist document that mirrors
`docs/release-checklist.md` in structure. Key sections:

1. **Release-candidate gates** (all must pass before TestFlight):
   - [ ] `ios.yml` CI is green.
   - [ ] Contract fixture tests pass (Rust + Swift).
   - [ ] German string catalog is complete (no "new" or "needs review"
         states).
   - [ ] Privacy report reviewed and PrivacyInfo.xcprivacy files are valid.
   - [ ] README and website describe only shipped behavior.
   - [ ] Memory audit passed (< 50 MB peak).

2. **Manual host-app matrix** (conducted during TestFlight internal).
   - Template provided (above).

3. **Version and build bumps** (before archive):
   - [ ] Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
         `ios/Config/Common.xcconfig`.
   - [ ] Commit the bump.

4. **Archive and upload** (Xcode):
   - [ ] Archive the app.
   - [ ] Validate the archive.
   - [ ] Upload to App Store Connect.

5. **TestFlight internal** (gate):
   - [ ] Build appears in TestFlight internal testing.
   - [ ] App installs and launches without crash.
   - [ ] All tabs are functional.
   - [ ] Onboarding and consent work.
   - [ ] Share extension works in Safari, Mail, Notes, Messages.
   - [ ] Running a prompt works (on-device or cloud).
   - [ ] Manual host-app matrix results recorded in
         `issues-ios/release-ios-1.0.0-matrix.md`.

6. **TestFlight external (optional):**
   - [ ] External beta invite sent (if desired).
   - [ ] Feedback from beta testers reviewed.

7. **App Review submission:**
   - [ ] Review notes prepared (`ios/AppReview/review-notes.md`).
   - [ ] Metadata reviewed (name, description, screenshots, keywords).
   - [ ] Export compliance answered.
   - [ ] Temporary reviewer API key created and provided in review notes.
   - [ ] Build submitted for review.

8. **After approval:**
   - [ ] App Review approves the build.
   - [ ] Build is released to the App Store (manually).

9. **Post-release:**
   - [ ] Tag the commit `ios-vX.Y.Z` and push the tag.
   - [ ] Verify that `release.yml` (desktop) did **not** run.
   - [ ] Revoke the reviewer API key.
   - [ ] Update `website/index.html` with the App Store link.
   - [ ] Update README with the App Store link.
   - [ ] Deploy the website and push the README updates.

## Testing Decisions

The release checklist itself is the test: every gate is a concrete, verifiable
step. The release matrix is recorded and filed as a permanent record.

**Automated:**

- CI gates (ios.yml must pass; contract fixtures must pass).
- Privacy manifest lint (plutil validation).

**Manual:**

- Host-app matrix (documented in the filled template).
- Memory audit (Xcode Instruments on a device).
- App Review testing (the review team at Apple).
- Metadata review (human check before submission).

## Out of Scope

- CI automation for archive and upload (manual for v1).
- Fastlane (too much machinery for a small first release; manual is clearer).
- Signing in GitHub Actions (signing is Xcode automatic signing with the
  team's Apple distribution certificate, done locally).
- Notarization: it applies only to Developer ID software outside the App
  Store, never to App Store iOS apps.
- Automating TestFlight builds (each one is a deliberate step; no auto-builds
  from CI).
- Automating App Review resubmission (retry is manual and intentional).

## Further Notes

- PLAN.md §13 describes the release architecture: manual archive/upload, no
  CI automation, paid app with a one-time price, `ios-v*` tags.
- PLAN.md §18 Q2 confirms the Apple Developer Program account is not yet
  created (done before Phase 1). Q9 confirms release is manual for v1. Q10
  confirms one-time pricing.
- Test devices may run iOS 26 or 27; the deployment target stays iOS 26.0
  (PLAN.md §18 Q6). Archive with the current Xcode 26.x.
- The `docs/ios-release-checklist.md` file lives in the main repo and is
  committed alongside this spec. It is the definitive gate for every release.
- Future releases (1.0.1, 1.1.0, etc.) follow the same checklist; only the
  version numbers change.
- The filled `issues-ios/release-ios-1.0.0-matrix.md` becomes a template and
  reference for future releases.
