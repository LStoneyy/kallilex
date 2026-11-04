# Kallilex — App Review Notes

## What the app does

Kallilex is a text editing tool that lets users rewrite or check text with an AI model. Instead of copying text to a chatbot or leaving the app they are writing in, users select text in Mail, Notes, Safari, Messages, or any other app, tap Share → Kallilex, run a prompt (like "Rewrite" or "Shorten"), and paste the result back.

The app supports any OpenAI-compatible AI endpoint (local, LAN, or cloud — such as Ollama, LM Studio, or OpenAI), and on supported devices it also offers Apple's on-device Foundation Model, which requires no API key.

## How to test

### Eligibility

- Kallilex runs on any iPhone with iOS 26 or later.
- On a device that supports Apple Intelligence (iPhone 15 Pro / 15 Pro Max, iPhone 16 or later) with Apple Intelligence turned on, the on-device provider can be tested without any API key. This is the preferred test path.
- If the device does not support Apple Intelligence or the model is not available, use the OpenAI-compatible test key provided in the "Reviewer API Key" field below.

### Step-by-step

1. **Install the app** from TestFlight or the production build.
2. **Open the Kallilex app.**
3. **Onboarding:**
   - You will see a welcome screen explaining the share flow ("Select text in any app. / Tap Share. / Tap Kallilex.").
   - Tap Continue.
   - Choose a provider:
     - If Apple Intelligence is available, select "Apple Intelligence (on device)". It requires no key.
     - Otherwise, select "OpenAI" and paste the reviewer API key (see below).
   - Edit the provider settings and tap Save.
   - Tap "Continue" to proceed to connection testing.
   - You will see "Testing your connection" with a progress indicator, then "✓ Connection successful".
   - Tap "Continue".
   - You will see the consent screen, which reads: "Send text to [provider name]? When you run a prompt, the text you share and the prompt's instruction are sent to [server host] ([provider name]) to be processed. Kallilex doesn't collect or store your text itself; the provider's privacy policy applies."
   - Tap "Allow" to grant consent.
   - You will see instructions on how to pin Kallilex to the share sheet (a guide showing the "Edit" button in the share menu).
   - Tap "Continue" to reach "You're all set!" and then "Start using Kallilex".
4. **Test the Share Extension (the main feature):**
   - Open Notes (or Mail, Safari, Messages, etc.).
   - Select some text and tap Share.
   - Tap Kallilex (it may be under "More" if not pinned yet).
   - The Kallilex sheet opens with the selected text and prompt buttons (Rewrite, Shorten, Improve clarity, Custom…).
   - Tap a prompt (e.g., "Rewrite") — the text is sent to the provider and the result replaces the original text in the sheet.
   - Tap "Copy & Close" to copy the result and close the sheet, or just "Copy" to copy without closing.
   - Go back to Notes, select the original text again and tap Paste — the rewritten text replaces it.
   - This is the core workflow: select → Share → prompt → Copy & Close → select → Paste.
5. **Test the Scratchpad (fallback editor):**
   - In the Kallilex app, tap the Scratchpad tab.
   - Tap the Paste button to paste some text from the clipboard.
   - Tap a prompt.
   - Tap Copy.
   - The result is now in the clipboard, ready to paste elsewhere.
6. **Test providers and settings:**
   - Tap the Providers tab.
   - If using the on-device model, verify it shows "Ready" (if available).
   - Tap the Prompts tab and create a custom prompt.
   - Return to the Scratchpad and run it.
   - Tap the Settings tab to view app options and the share sheet guide.
7. **Test errors:**
   - Disconnect the device from the network and try a cloud provider request — you should see "Can't reach the endpoint — is the server running?" or similar.
   - Re-enable the network and confirm it works again.

### Reviewer API Key

A temporary, spend-limited OpenAI API key will be provided in the App Store Connect review notes during submission (in the "Reviewer Notes" field). This key is created right before submission and revoked immediately after the app is approved or rejected.

**Do not commit this key to GitHub or the repository.** It is for review testing only.

## Privacy and consent

The app's core feature is the share extension. On first use, the user sees a consent screen before sending text to a cloud provider. The screen explains where the text will be sent and that the provider's privacy policy applies, in compliance with Apple's App Review guideline 5.1.2(i).

The app collects no data itself — text goes directly to the provider the user configured. API keys are stored in the iOS Keychain, on-device only, and never transmitted except in the requests the user initiates.

## Bundle IDs

- App: `com.webcommits.kallilex`
- Extension: `com.webcommits.kallilex.share`
