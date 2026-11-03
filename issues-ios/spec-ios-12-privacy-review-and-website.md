# Spec ios-12 — Privacy manifest, App Review package, and website

Status: ready-for-agent
Phase: Phase 5 (Polish)
Depends on: ios-09, ios-11

## Problem Statement

Before submitting to the App Store, the app must declare its privacy stance
to Apple via a privacy manifest, answer App Store's privacy questionnaire
accurately, and provide clear documentation to App Review. The developer's
website must describe privacy practices (both for compliance and user trust),
and the README must mention iOS availability. The privacy label must match
the actual data handling: the developer collects nothing; the user configures
the AI provider and the app sends text only to that provider. This spec
defines which required-reason APIs are actually used, what the privacy label
answers are, what review notes say, and what website pages and content are
needed.

## Solution

Create privacy manifests (`PrivacyInfo.xcprivacy`) for the app and the
extension, using the app's and extension's own bundle IDs, declaring no data
collection and only the required-reason APIs actually used. Write the App
Store privacy label: "Data not collected" (no developer tracking or
analytics). Create `ios/AppReview/review-notes.md` explaining the app's
purpose, the share flow, onboarding, and the test configuration (on-device
model on eligible devices, or a temporary reviewer key). Draft `ios/AppReview/metadata.md`
with app name, subtitle, description (English and German), keywords, category,
support and marketing URLs, copyright, and the six required 6.9" iPhone
screenshots. Add an English `website/privacy.html` (styled like
`website/datenschutz.html`) and an iOS privacy section to the German
`website/datenschutz.html`. Add an iOS teaser to `website/index.html`, update
`website/sitemap.xml`, and add an iOS section to the README describing the
app and the build-it-yourself path.

## User Stories

1. As a privacy-conscious user, I want the app to declare that it does not
   collect my data, so that I can trust it.
2. As a user reviewing App Store privacy, I want to see that my text goes
   only to the provider I configure (not to the developer), so that I
   understand where my data goes.
3. As a user in the EU, I want to know the app's privacy practices under the
   DSA and GDPR, so that I can make an informed choice.
4. As App Review, I want clear notes explaining what the app does and how to
   test it, so that I can approve it quickly without questions.
5. As a potential user browsing the website, I want to see the app's privacy
   policy and where my text goes, so that I decide to download it.
6. As a German user, I want the privacy policy in German, so that I
   understand it fully.
7. As a user finding the app on the App Store, I want the description to
   explain what it does and how it works, so that I understand what I am
   downloading.
8. As a developer building the app myself, I want the README to tell me how
   to build the iOS version, so that I can contribute.
9. As an App Review engineer testing on an ineligible device, I want a
   temporary API key to test the app, so that I can verify the functionality
   without an on-device model.
10. As a release engineer, I want a checklist that covers privacy gates, so
    that the release does not ship with privacy gaps.

## Implementation Decisions

### Privacy manifest (PrivacyInfo.xcprivacy)

**Files:**

- `ios/Kallilex/PrivacyInfo.xcprivacy` (app)
- `ios/ShareExtension/PrivacyInfo.xcprivacy` (extension)

**Content (both identical):**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <!-- Include only if actually used: -->
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <!-- If FileManager or NSFileCoordinator reads timestamps on the App Group
         container: -->
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSFileCoordinator</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>C617.1</string><!-- File timestamp APIs -->
      </array>
    </dict>
    <!-- If UserDefaults is used: -->
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>UserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>CA92.1</string><!-- Synchronizing app preferences -->
      </array>
    </dict>
  </array>
</dict>
</plist>
```

**Method:**

1. Archive a release build (ios-13).
2. Open the `.app` package and check for used APIs using Xcode's Privacy
   Report (Product → Archive → right-click on archive in Organizer →
   "Show in Finder", then `Xcode` → `Window` → `Organizer` → select build
   → read the Privacy Report).
3. Declare **only** the APIs listed in the report. Do not declare unused
   APIs (Apple rejects padding).
4. Expected: only file coordination (`C617.1`) if settings JSON uses
   `NSFileCoordinator`, and `UserDefaults` (`CA92.1`) only if it is used
   (ios-04 uses a JSON file in the App Group, not `UserDefaults`, so this
   may be absent).

**To confirm:** exact required-reason API codes and which framework
APIs the builds actually use (determine at ios-04/ios-05 implementation
time).

### App Store privacy label

**Questionnaire answers:**

When asked "Do you or your third-party partners collect, use, or share user
data?" answer **No**.

When asked about data types (name, email, phone, address, health, etc.):
answer **Not collected** for all of them.

**Rationale (for the spec and for App Review notes):**

- The app is purely a shell. It does not use analytics, crash reporting, or
  targeted ads. No first-party or third-party data collection.
- User text is sent only to a provider the user configures. The developer
  has no visibility into it — it goes directly from the user's device to
  that provider.
- API keys are stored in the iOS Keychain, on-device only. They are never
  uploaded to the developer's backend (there is none) or transmitted except
  in the HTTP requests the user initiates.
- Under Apple's App Store Connect privacy label rules, the "Data not
  collected" state means the developer (webcommits) collects nothing from the
  user. The provider (OpenAI, Ollama, Apple, etc.) is a separate entity and
  is not a developer partner for App Store purposes — the user chooses the
  provider and owns that relationship.

**To confirm:** answer reviewed against Apple's current definition of "Data
not collected" and third-party provider handling in the app store's privacy
framework (confirm once the privacy questionnaire is opened in App Store
Connect).

### App Review package

**Directory:** `ios/AppReview/` (committed to the repo, sans any real keys)

#### review-notes.md

```markdown
# Kallilex — App Review Notes

## What the app does

Kallilex is a text editing tool that lets users rewrite or check text with
an AI model. Instead of copying text to a chatbot or leaving the app they are
writing in, users select text in Mail, Notes, Safari, or any other app, tap
Share → Kallilex, run a prompt (like "Rewrite" or "Shorten"), and paste the
result back.

The app supports any OpenAI-compatible AI endpoint (local, LAN, or cloud —
such as Ollama, LM Studio, or OpenAI), and on supported devices it also
offers Apple's on-device Foundation Model, which requires no API key.

## How to test

### Eligibility

- Kallilex runs on any iPhone with iOS 26 or later.
- On a device that supports Apple Intelligence (iPhone 15 Pro / 15 Pro Max,
  iPhone 16 or later) with Apple Intelligence turned on, the on-device
  provider can be tested without any API key.
  This is the preferred test path.
- If the device does not support Apple Intelligence or the model is not
  available, use the OpenAI-compatible test key provided in the "Reviewer API
  Key" field below.

### Step-by-step

1. **Install the app** from TestFlight or the production build.
2. **Open the Kallilex app.**
3. **Onboarding:**
   - You will see a welcome screen explaining the share flow.
   - Choose a provider:
     - If Apple Intelligence is available, select "Apple Intelligence (on
       device)". It requires no key.
     - Otherwise, select "OpenAI" and paste the reviewer API key (see below).
   - Tap "Test connection" to confirm the provider works.
   - Tap "Allow" on the consent screen (which explains where your text will
       go).
   - You will see instructions on how to pin Kallilex to the share sheet.
4. **Test the Share Extension (the main feature):**
   - Open Notes (or Mail, Safari, Messages, etc.).
   - Select some text and tap Share.
   - Tap Kallilex (it may be under "More" if not pinned yet).
   - The Kallilex sheet opens with the selected text.
   - Tap a prompt (e.g., "Rewrite") — the text is sent to the provider and
     the result appears in the sheet.
   - Tap "Copy" — the result goes to the clipboard.
   - Go back to Notes, select the original text again and tap Paste — it
     is replaced with the rewritten text.
   - This is the core workflow: select → Share → prompt → Copy → select
     again → Paste.
5. **Test the Scratchpad (fallback editor):**
   - In the Kallilex app, tap the Scratchpad tab.
   - Paste some text (use the Paste button).
   - Tap a prompt.
   - Tap Copy.
   - The result is now in the clipboard, ready to paste elsewhere.
6. **Test providers and settings:**
   - Tap the Providers tab.
   - If using the on-device model, verify it shows "Ready" (if available).
   - Tap the Prompts tab and create a custom prompt.
   - Return to the Scratchpad and run it.
7. **Test errors:**
   - Disconnect the device from the network and try a cloud provider request
     — you should see "Unable to reach the provider" or similar.
   - Re-enable the network and confirm it works again.

### Reviewer API Key

A temporary, spend-limited OpenAI API key will be provided in the App Store
Connect review notes during submission (in the "Reviewer Notes" field). This
key is created right before submission and revoked immediately after the app
is approved or rejected.

**Do not commit this key to GitHub or the repository.** It is for review
testing only.

## Privacy and consent

The app's core feature is the share extension. On first use, the user sees a
consent screen that explains:

> "The text you share is sent to <host> to be processed."

This is in compliance with Apple's App Review guideline 5.1.2(i), which
requires explicit consent before sending personal data to a third-party
service.

The app collects no data itself — text goes directly to the provider the user
configured.

## Bundle IDs

- App: `com.webcommits.kallilex`
- Extension: `com.webcommits.kallilex.share`
```

#### metadata.md

```markdown
# Kallilex iOS — App Store Metadata

## App name

Kallilex

## Subtitle (EN, max 30 chars)

Rewrite text with AI

## Subtitle (DE, max 30 chars)

Text mit KI umschreiben

## Promotional text (EN, 170 chars max)

Bring your own AI and rewrite text without leaving the app you are writing
in. Share selected text from Notes, Mail, Safari, or any app, run a prompt,
and paste the result back.

## Promotional text (DE, 170 chars max)

Benutz dein eigenes KI-Modell, um Text umzuschreiben, ohne die App zu
verlassen. Teile Text aus Notes, Mail, Safari oder einer anderen App, führe
einen Prompt aus und füge das Ergebnis wieder ein.

## Description (EN, 4000 chars max)

Kallilex is a tiny text editing tool that brings AI rewriting to any app on
your iPhone. Select text in Notes, Mail, Safari, Messages, or anywhere else,
tap Share → Kallilex, choose a rewrite prompt, and paste the result back —
all without leaving your writing app.

**How it works:**

1. Select text in any app.
2. Tap Share → Kallilex (pin it to your favorites in the Share menu for easy
   access).
3. Choose a prompt: Rewrite, Shorten, Improve clarity, or a custom
   instruction.
4. Tap Copy to put the result on your clipboard.
5. Go back to your app, select the original text again, and paste.

**Bring your own AI provider:**

Kallilex works with any OpenAI-compatible endpoint:

- **On device (Apple Intelligence):** On supported iPhones with Apple
  Intelligence enabled, Kallilex offers an on-device model that requires no
  API key and sends nothing outside your device.
- **Local or LAN:** Ollama or LM Studio on your Mac, accessed over your home
  network.
- **Cloud:** OpenAI, Anthropic, or any other cloud provider that speaks the
  OpenAI chat-completions API.

You own your API keys. They are stored in your phone's Keychain and never
leave it except in the requests you make.

**Privacy:**

- Kallilex is free and open source.
- No accounts, no subscriptions, no telemetry.
- Your text goes directly to the provider you configure — Kallilex (the
  developer) never sees it.
- The app can be built and run from source (Apache-2.0 license) if you prefer.

## Description (DE, 4000 chars max)

Kallilex ist ein winziges Text-Bearbeitungstool, das dir KI-gestützte
Umschreibung in jeder App auf deinem iPhone bietet. Wähle Text in Notes,
Mail, Safari, Messages oder einer beliebigen anderen App aus, tippe Teilen →
Kallilex, wähle einen Umschreib-Prompt und füge das Ergebnis wieder ein —
alles ohne deine Schreib-App zu verlassen.

**So funktioniert es:**

1. Wähle Text in einer beliebigen App aus.
2. Tippe Teilen → Kallilex (pinne es in deinem Teilen-Menü an, um schnellen
   Zugriff zu haben).
3. Wähle einen Prompt: Umschreiben, Kürzen, Klarer formulieren oder eine
   eigene Anweisung.
4. Tippe Kopieren, um das Ergebnis in deine Zwischenablage zu legen.
5. Geh zurück zu deiner App, markiere den ursprünglichen Text erneut
   und füge ihn ein.

**Bring dein eigenes KI-Modell mit:**

Kallilex funktioniert mit jedem OpenAI-kompatiblen Endpunkt:

- **Auf dem Gerät (Apple Intelligence):** Auf unterstützten iPhones mit Apple
  Intelligence aktiviert bietet Kallilex ein lokal ausgeführtes Modell, das
  keinen API-Schlüssel benötigt und nichts außerhalb deines Geräts sendet.
- **Lokal oder im Netzwerk:** Ollama oder LM Studio auf deinem Mac, erreichbar
  über dein Heimnetzwerk.
- **Cloud:** OpenAI, Anthropic oder jeden anderen Cloud-Anbieter, der die
  OpenAI-Chat-Completions-API spricht.

Du besitzt deine API-Schlüssel. Sie werden in deinem iPhone-Keychain
gespeichert und verlassen ihn nur in den Anfragen, die du selbst initiierst.

**Datenschutz:**

- Kallilex ist kostenlos und Open Source.
- Keine Konten, keine Abos, keine Telemetrie.
- Dein Text geht direkt an den Anbieter, den du gewählt hast — Kallilex
  (der Entwickler) sieht ihn nicht.
- Die App kann aus dem Quellcode (Apache-2.0 Lizenz) gebaut und ausgeführt
  werden, falls du das bevorzugst.

## Keywords (EN)

AI, rewrite, text, editing, writing, prompts, OpenAI, local

## Keywords (DE)

KI, umschreiben, Text, Bearbeitung, Schreiben, Prompts, OpenAI, lokal

## Category

Productivity

## Support URL

https://kallilex.webcommits.info/

## Marketing URL

https://kallilex.webcommits.info/

## Copyright

webcommits

## Age rating

Content Restrictions: None. (The app is a text editor; it has no objectionable
content, no loot boxes, no social features, no unrestricted web access.)

## Screenshots (6 required for 6.9" iPhone, landscape OK, light mode preferred)

Template notes (for the release implementer):

1. Screenshot 1: Share sheet is open, Kallilex appears as an option.
2. Screenshot 2: Kallilex extension sheet, showing selected text and prompt
   chips (Rewrite, Shorten, etc.).
3. Screenshot 3: Result displayed in the extension after running a prompt.
4. Screenshot 4: Prompts tab in the app, showing the list of saved prompts.
5. Screenshot 5: Providers tab in the app, showing the list of configured
   providers.
6. Screenshot 6: Scratchpad tab, showing the fallback editor.

Each screenshot should be annotated with a caption (30 chars max per line)
describing what the user sees. Captions go into App Store Connect after
upload.

English captions:
- "Open the share sheet"
- "Kallilex opens with your text"
- "See the rewritten result"
- "Create and manage prompts"
- "Configure your AI provider"
- "Use the built-in Scratchpad"

German captions:
- "Öffne das Teilen-Menü"
- "Kallilex öffnet mit deinem Text"
- "Sieh das umgeschriebene Ergebnis"
- "Erstelle und verwalte Prompts"
- "Konfiguriere deinen KI-Anbieter"
- "Nutze den eingebauten Notizblock"
```

### Website updates

#### New file: website/privacy.html

Create as an English version of `website/datenschutz.html`, with an "iOS"
section added to it and its German counterpart. Content structure:

```html
<!-- Mimic the structure of datenschutz.html -->
<!-- Sections: -->
<!-- 1. Responsible entity -->
<!-- 2. Privacy at a glance -->
<!-- 3. Hosting (GitHub Pages) -->
<!-- 4. Release information (GitHub API) -->
<!-- 5. Email contact -->
<!-- 6. SSL/TLS encryption -->
<!-- 7. iOS app specifics: -->
<!--    - No data collected by the developer -->
<!--    - Text sent only to user-configured provider -->
<!--    - API keys stored in Keychain only -->
<!--    - No analytics, no tracking -->
<!-- 8. Your rights -->
```

#### Update: website/datenschutz.html

Add an iOS section (in German):

```markdown
## iOS App (Kallilex)

Die iOS-App Kallilex erfasst keine Daten. Der Text, den du mit der App
umschreibst, wird nur an den KI-Anbieter gesendet, den du selbst eingestellt
hast — nicht an den App-Entwickler.

- API-Schlüssel werden nur in deinem iPhone-Keychain gespeichert und
  verlassen ihn nie.
- Der Text wird direkt von deinem Gerät an den von dir konfigurierten
  Anbieter gesendet.
- Es gibt keine Telemetrie, kein Tracking und keine Analytics-Tools.
- Die App ist quelloffen (Apache-2.0 Lizenz).
```

#### Update: website/index.html

Add an iOS teaser section (after the "Install" section or in a new "Platforms"
section):

```html
<section class="platforms">
  <div class="container">
    <div class="section-heading">
      <h2>Also available on iPhone</h2>
      <svg class="squiggle" ...></svg>
    </div>
    <p>
      Kallilex is coming to iPhone. Select text in Notes, Mail, Safari, or
      any app, tap Share → Kallilex, run a prompt, and paste the result back
      — all without leaving your app. Bring your own AI provider or use
      Apple's on-device model.
    </p>
    <p>
      <strong>Coming to the App Store.</strong> Build it yourself from source
      (Apache-2.0) today or wait for the public release.
    </p>
  </div>
</section>
```

(This teaser replaces "Coming to iPhone" text. In ios-13, after the app is
released on the App Store, a link is added pointing to the App Store URL.)

#### Update: website/sitemap.xml

Add the privacy URL:

```xml
<url>
  <loc>https://kallilex.webcommits.info/privacy.html</loc>
</url>
```

### README updates

Add a new "iOS" section (after or before "Installation" sections):

```markdown
## iOS

Kallilex is also available for iPhone. The iOS version is a work in progress
and will be available on the App Store at `https://kallilex.webcommits.info/`
(link to be added after release).

**To build it yourself:**

The iOS app is located in the `ios/` directory. It requires:

- Xcode 26 or later
- iOS SDK 26
- Swift 6

To build and run:

1. Open `ios/Kallilex.xcodeproj` in Xcode.
2. In the project settings, under "Signing & Capabilities", set your team ID
   (create a `Local.xcconfig` in `ios/Config/` with `DEVELOPMENT_TEAM = <your
   team id>`).
3. Select the Kallilex scheme and run on a simulator or connected device.

The app uses a local Swift package (`ios/KallilexKit`) for shared logic, so
no external dependencies are needed beyond the standard library. The source
is Apache-2.0 licensed.
```

## Testing Decisions

### Privacy manifest lint

In the iOS CI workflow (`ios.yml`), add a step:

```bash
plutil -lint ios/Kallilex/PrivacyInfo.xcprivacy
plutil -lint ios/ShareExtension/PrivacyInfo.xcprivacy
```

This ensures the plist files are valid XML/property-list format and the build
does not fail.

### Manual website and privacy checks

**Before release (ios-13 checklist item):**

- [ ] Open `website/privacy.html` locally (or on the staging server) and
      verify it renders and reads correctly in both English and German.
- [ ] Check that the privacy policy URL
      (`https://kallilex.webcommits.info/privacy.html`) is reachable.
- [ ] Verify that links in the privacy policy (e.g., to the iOS Keychain
      documentation or Apple's privacy framework) are correct and active.
- [ ] Check that `website/datenschutz.html` includes the iOS section and
      reads correctly.
- [ ] Verify that `website/index.html` shows the iOS teaser (or, after
      release, the App Store link).

### Privacy label review

**Before submission:**

- [ ] Open the privacy questionnaire in App Store Connect (after creating the
      app record in ios-13).
- [ ] Confirm that "Data not collected" is selected for all data categories.
- [ ] Review the app's privacy label on a test device: Settings → Privacy &
      Security → App Privacy Report → Kallilex.
- [ ] Confirm that no unexpected APIs or data access are listed.

## Out of Scope

- GDPR/CCPA legal compliance checks (that is the product owner's
  responsibility).
- GDPR data-processing agreements with third-party providers (out of scope;
  the user chooses the provider).
- EU DSA (Digital Services Act) trader-status declaration setup (handled in
  ios-13, the product owner's responsibility).
- Code signing (the app is signed with the team's Apple distribution
  certificate via Xcode automatic signing; notarization does not apply to
  App Store iOS apps).

## Further Notes

- PLAN.md §10 covers privacy, permissions, and App Review requirements.
- PLAN.md §13 covers the release process, including app submission steps and
  the reviewer API key.
- The privacy manifest files must be kept in sync: both the app and the
  extension must declare the same required-reason APIs (or fewer in one if it
  is not used there).
- The review notes go into App Store Connect only (in the text field marked
  "Reviewer Notes"), not into the repo, except for the template markdown
  (ios/AppReview/review-notes.md).
- The metadata is a draft; the actual screenshots, captions, and descriptions
  are uploaded through App Store Connect's web interface during ios-13.
- Website changes (privacy.html, datenschutz.html updates, index.html teaser,
  sitemap.xml) are committed to the repo and live when the website is next
  deployed (separate from the app release).
