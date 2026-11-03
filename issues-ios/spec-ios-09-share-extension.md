# Spec ios-09 — Share Extension

Status: ready-for-agent
Phase: Phase 3 (Share Extension)
Depends on: ios-07, ios-08

## Problem Statement

The Share Extension is Kallilex's primary interface: a user selects text in any
app, taps Share, chooses Kallilex, and the extension immediately presents an
editor with the selected text, prompt chips, and tools to rewrite and copy the
result back. The extension runs under a 120 MB memory limit, is killed when the
sheet closes, and cannot open the container app (spike ios-01 confirmed
`extensionContext.open(_:)` fails from a Share Extension). It must extract
text from many source types (plain text,
RTF, URLs, Safari selections), handle setup errors gracefully, show inline
consent for cloud providers, and support auto-run and auto-copy settings.

## Solution

Build a `ShareViewController: UIViewController` that reads input via
`extensionContext.inputItems`, extracts text via `InputExtractor`, and hosts
the shared editor UI from ios-08 in a `UIHostingController`. A fresh
`EditorSession` drives the flow. State transitions cover input loading,
editor use, and results. Error states handle not-configured profiles,
missing consent, and connection failures. Auto-run and auto-copy settings
speed up the workflow for returning users. The extension reaches < 50 MB peak
memory by avoiding heavy dependencies and keeping only SF Symbols in the UI.

## User Stories

1. As a user in any app with selected text, I want to tap Share → Kallilex and
   see the text immediately in the extension so that I can start editing right
   away.
2. As a user, I want the extension to show my saved prompts as chips so that I
   can run them with one tap.
3. As a user, I want to type a custom instruction and run it without saving it
   so that I can try something experimental.
4. As a user, I want to see a Cancel button while a request runs so that I can
   stop it if I change my mind.
5. As a user, Copy writes the text to the clipboard, shows "Copied" briefly,
   and closes the sheet; a hint tells me to select the original text again
   and paste.
6. As a user with auto-copy enabled, I want the result to copy and close
   automatically so that the flow is seamless.
7. As a user with auto-run enabled, I want the first prompt to run as soon as
   the sheet opens so that I don't have to tap anything.
8. As a user without a provider set up, I want a clear message telling me to
   open the Kallilex app so that I know what to do next.
9. As a cloud-provider user who hasn't consented yet, I want the consent screen
   to appear inline so that I can allow it without leaving the sheet.
10. As a Safari user, I want the selected text from a webpage to arrive in the
    extension so that the flow works as expected.
11. As a user with very long text, I want a soft warning so that I know the AI
    might struggle or refuse.
12. As a user, I want the extension to keep memory low so that it doesn't crash
    due to memory limits.

## Implementation Decisions

### ShareViewController principal class

**File:** `ios/ShareExtension/Sources/ShareViewController.swift`

```swift
class ShareViewController: UIViewController {
    private var editorSession: EditorSession?
    private var hostingController: UIViewController?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let extensionContext = extensionContext else { return }
        
        // Read App Group and Keychain identifiers from Info.plist
        // via KallilexKit's InfoPlist helper (ios-04). It calls
        // `preconditionFailure` if a value is missing, so there is no
        // hard-coded fallback here.
        let appGroupId = InfoPlist.kallilexAppGroup
        let keychainAccessGroup = InfoPlist.kallilexKeychainAccessGroup
        
        // Build stores and runner
        let settingsStore = AppGroupSettingsStore(
            appGroupId: appGroupId,
            keychainAccessGroup: keychainAccessGroup
        )
        let secretStore = KeychainSecretStore(
            accessGroup: keychainAccessGroup
        )
        let runner = ActionRunner(
            settings: settingsStore,
            secrets: secretStore,
            makeProvider: { profile, key in
                OpenAICompatibleProvider(
                    profile: profile,
                    apiKey: key
                )
            }
        )
        
        // Extract input
        Task {
            let extractor = InputExtractor()
            let text = await extractor.extract(from: extensionContext.inputItems)
            
            let editorSession = EditorSession(
                actionRunner: runner,
                pasteboard: ExtensionPasteboard(context: extensionContext),
                consentGranting: SettingsStoreConsentGranter(
                    settingsStore: settingsStore
                )
            )
            editorSession.text = text
            self.editorSession = editorSession
            
            // `load()` failing is not silently papered over with defaults:
            // it means the shared settings file is unreadable, so an error
            // card is shown instead of a fresh, empty configuration.
            let settings: AppSettings
            do {
                settings = try settingsStore.load()
            } catch {
                self.hostingController = self.host(
                    SettingsLoadErrorView(
                        message: String(localized: "extension.settingsError.message")
                        // "Kallilex couldn't read its settings. Open the
                        // Kallilex app to fix this."
                    )
                )
                return
            }
            
            // Build and host the root view
            let rootView = ShareRootView(
                session: editorSession,
                extensionContext: extensionContext,
                settings: settings,
                settingsStore: settingsStore,
                onDismiss: { [weak self] in
                    self?.extensionContext?.cancelRequest(
                        withError: NSError(
                            domain: NSCocoaErrorDomain,
                            code: NSUserCancelledError
                        )
                    )
                }
            )
            
            self.hostingController = host(rootView)
            
            // Auto-run first prompt if enabled
            if settings.autoRunFirstPrompt,
               let firstPrompt = settings.prompts.first {
                await editorSession.run(.prompt(
                    instruction: firstPrompt.instruction
                ))
            }
        }
    }
    
    private func host<V: View>(_ rootView: V) -> UIHostingController<V> {
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.constrainToFill(self.view)
        hosting.didMove(toParent: self)
        return hosting
    }
}

struct SettingsLoadErrorView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)
            Text(message)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension UIView {
    func constrainToFill(_ parent: UIView) {
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
}

struct ExtensionPasteboard: Pasteboard {
    let context: NSExtensionContext
    
    func setString(_ string: String) {
        UIPasteboard.general.string = string
    }
}
```

Register `ShareViewController` as the principal class in the extension's
Info.plist (set in ios-02): `NSExtensionPrincipalClass`.

### InputExtractor

**File:** `ios/KallilexKit/Sources/KallilexKit/Core/InputExtractor.swift`

```swift
struct InputExtractor {
    func extract(from items: [NSExtensionItem]) async -> String {
        for item in items {
            guard let attachments = item.attachments else { continue }
            
            for attachment in attachments {
                // Try types in order
                if let text = await tryLoad(
                    attachment: attachment,
                    type: .plainText
                ) {
                    return text
                }
                
                if let text = await tryLoad(
                    attachment: attachment,
                    type: .utf8PlainText
                ) {
                    return text
                }
                
                if let text = await tryLoad(
                    attachment: attachment,
                    type: .rtf
                ) {
                    return text
                }
                
                // Safari JS preprocessing. Ship this path unconditionally;
                // spike ios-01 did not test Safari (open items), so this is
                // verified during ios-09 acceptance testing instead.
                if let text = await trySafariPreprocessing(
                    attachment: attachment
                ) {
                    return text
                }
                
                // NSExtensionItem.attributedContentText
                if let text = await tryAttributedContent(
                    from: item
                ) {
                    return text
                }
            }
        }
        
        return ""
    }
    
    private func tryLoad(
        attachment: NSItemProvider,
        type: UTType
    ) async -> String? {
        guard attachment.hasItemConformingToTypeIdentifier(type.identifier) else {
            return nil
        }
        
        let result = await attachment.loadItem(
            forTypeIdentifier: type.identifier,
            options: nil
        ) as? String?
        
        return result?.normalized() ?? nil
    }
    
    private func trySafariPreprocessing(
        attachment: NSItemProvider
    ) async -> String? {
        // The companion JS file (NSExtensionJavaScriptPreprocessingFile,
        // registered in ios-02's Info.plist) returns
        // `window.getSelection().toString()` and the page URL. Parse the
        // results dictionary under NSExtensionJavaScriptPreprocessingResultsKey.
        guard attachment.hasItemConformingToTypeIdentifier(
            UTType.propertyList.identifier
        ) else {
            return nil
        }
        
        let item = await attachment.loadItem(
            forTypeIdentifier: UTType.propertyList.identifier,
            options: nil
        )
        guard
            let dictionary = item as? [String: Any],
            let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
                as? [String: Any],
            let selection = results["selection"] as? String,
            !selection.isEmpty
        else {
            return nil
        }
        
        return selection.normalized()
    }
    
    private func tryAttributedContent(
        from item: NSExtensionItem
    ) async -> String? {
        guard let attributed = item.attributedContentText else {
            return nil
        }
        return attributed.string.normalized()
    }
}

extension String {
    func normalized() -> String {
        // Normalize line endings: \r\n and \r → \n
        self.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
```

**Behavior:**
- Iterate `extensionContext.inputItems` → `attachments`.
- Try types in order: `plainText`, `utf8PlainText`, `rtf` (parse via
  `NSAttributedString`), Safari JS preprocessing result, then
  `attributedContentText`.
- Normalize line endings (`\r\n` and `\r` → `\n`); preserve all other
  whitespace.
- If nothing yields text, return empty string (which triggers an empty-state
  message in the UI).

**Safari JS preprocessing:** spike ios-01 did not test Safari (it is listed
in the report's open items), so ship the
`NSExtensionJavaScriptPreprocessingFile` unconditionally rather than
guessing. It returns `window.getSelection().toString()` and the page URL;
the extension parses the `NSExtensionJavaScriptPreprocessingResultsKey`
dictionary, keeping the priority order above. During ios-09 acceptance
testing, verify Safari both with and without a text selection. Remove the
JS file only if that testing shows Safari delivers `public.plain-text` on
its own in both cases.

### ShareRootView

**File:** `ios/KallilexKit/Sources/KallilexUI/ShareRootView.swift`

A SwiftUI view hosting the extension's UI:

```swift
struct ShareRootView: View {
    let session: EditorSession
    let extensionContext: NSExtensionContext
    let settings: AppSettings
    let settingsStore: SettingsStore
    let onDismiss: () -> Void
    
    @State private var showCopiedFeedback = false
    
    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                // Header
                HStack {
                    Text("Kallilex")
                        .font(.headline)
                    Spacer()
                    
                    if let profile = activeProfile() {
                        PrivacyBadge(
                            privacyClass: classifyPrivacy(
                                baseUrl: profile.baseUrl
                            ) ?? .cloud,
                            host: consentHost(for: profile) ?? ""
                        )
                    }
                    
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                    }
                }
                .padding()
                
                // Content
                VStack(spacing: 12) {
                    EditorView(text: Binding(
                        get: { session.text },
                        set: { session.text = $0 }
                    ))
                    
                    if session.text.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.quote")
                                .font(.title)
                            Text(String(localized: "extension.empty.title"))
                            Text(String(localized: "extension.empty.message"))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundColor(.gray)
                    } else {
                        PromptChipsBar(
                            prompts: settings.prompts,
                            onSelectPrompt: { prompt in
                                Task {
                                    await session.run(.prompt(
                                        instruction: prompt.instruction
                                    ))
                                }
                            },
                            onCustomTapped: { }
                        )
                        
                        CustomInstructionField(
                            text: .constant(""),
                            onReturn: { }
                        )
                        
                        StatusBanner(
                            state: session.state,
                            inlineNote: session.inlineNote,
                            onRetry: { await session.retry() },
                            onCancel: { session.cancel() },
                            onConsentAllow: { await session.grantConsentAndRetry() },
                            onConsentDecline: { session.declineConsent() }
                        )
                        
                        EditorToolbar(
                            canUndo: session.lastInput != session.text,
                            canRetry: session.lastAction != nil
                                && !session.isRunning,
                            canCopy: !session.text.isEmpty,
                            onUndo: { session.undo() },
                            onRetry: { await session.retry() },
                            onCopy: {
                                handleCopy()
                            }
                        )
                        
                        // Paste-back hint: visible whenever a result is
                        // shown, stores no state of its own. The selection
                        // in the host app is gone after the share sheet
                        // closes (spike ios-01 unknown 6), so the user must
                        // select the original text again before pasting.
                        if case .result = session.state {
                            Text(String(localized: "extension.pasteHint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            
            // Copied feedback
            if showCopiedFeedback {
                Text(String(localized: "editor.copied"))
                    .font(.body)
                    .padding(12)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.opacity)
            }
        }
        .onChange(of: session.state) { oldState, newState in
            handleStateChange(from: oldState, to: newState)
        }
    }
    
    private func activeProfile() -> ProviderProfile? {
        guard let activeID = settings.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == activeID && $0.enabled }
    }
    
    private func handleCopy() {
        session.copy()
        showCopiedFeedback = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            showCopiedFeedback = false
            
            // Auto-close after copy
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
                extensionContext.completeRequest(returningItems: [])
            }
        }
    }
    
    private func handleStateChange(
        from oldState: EditorSession.State,
        to newState: EditorSession.State
    ) {
        if case .result = newState, settings.autoCopyResult {
            handleCopy()
        }
    }
}
```

**Layout (top to bottom):**
1. **Header:** "Kallilex" title, privacy badge, Close button.
2. **Content:**
   - If text is empty: "Kallilex needs selected text. Select the text first,
     then tap Share." (`String(localized: "extension.empty.title")` and
     `"extension.empty.message"`)
   - If text present: editor, chips, custom field, status banner, toolbar,
     and (in the `result` state) the paste-back hint footnote.
3. **Footer:** (none; toolbar is inline above the status banner)

**States handled:**
- `loadingInput` (internal; show a brief spinner while extracting)
- `ready` (no indicator; user can select a prompt)
- `running` (spinner + Cancel)
- `result` (checkmark, "Show original" toggle visible, paste-back hint)
- `error` (error message + Retry)
- `notConfigured` (card: "Set up a provider in the Kallilex app")
- `consentRequired` (inline `ConsentView`)

The extension never shows the Local Network permission prompt itself (spike
ios-01 unknown 2: the prompt appeared only from the container app, and the
extension reached LAN targets before any permission had been granted). A
`localNetworkDenied` error (ios-05) displays like any other error, through
its localized message, which points the user to Settings → Privacy &
Security → Local Network → Kallilex.

**Paste-back hint:**

After the share sheet closes, the selection in the host app is gone, so a
single Paste does not replace it (spike ios-01 unknown 6, confirmed in
Notes on iOS 27; not tested in other apps). The result state shows a small
secondary footnote under the toolbar — `Text(String(localized:
"extension.pasteHint"))` with `.font(.footnote)` and
`.foregroundStyle(.secondary)` — reading "After copying, select the
original text again and paste." It is always visible whenever a result is
shown and stores no state of its own.

When `settings.autoCopyResult` is enabled, `handleCopy()` copies and closes
the sheet immediately, so the hint is never shown in that flow. ios-06 and
ios-07's settings text for auto-copy should mention re-selecting the
original text (noted here; those specs are not changed by this task).

**Not-configured card:**

When the active profile is not found or disabled:

```swift
VStack(alignment: .leading, spacing: 12) {
    Image(systemName: "gear.circle")
        .font(.title)
    Text(String(localized: "extension.notConfigured.title"))
    Text(String(localized: "extension.notConfigured.message"))
    // "Open the Kallilex app to set up a provider."
}
.padding()
.background(Color(.systemGray6))
```

There is no button and no "Open Kallilex" affordance. Spike ios-01
(unknown 4) confirmed that `extensionContext.open(_:)` returns `false` when
called from a Share Extension; the completion ran seven times and the app
never opened. Do not call `extensionContext.open`, and do not reach for a
responder-chain or `UIApplication` workaround to open the app instead,
because that is an App Review risk. The message is the only guidance shown.

### Auto-run and auto-copy logic

- **Auto-run:** in `viewDidLoad`, after `editorSession` is initialized and text
  is extracted, check `settings.autoRunFirstPrompt`. If true and the prompts
  list is not empty, call `editorSession.run(.prompt(instruction: prompts[0].instruction))`.
- **Auto-copy:** on state change to `.result`, check `settings.autoCopyResult`.
  If true, immediately call `handleCopy()` which copies, shows "Copied" briefly,
  and calls `extensionContext.completeRequest(returningItems: [])`.

Both settings apply only to the extension, not to the Scratchpad (decided in
PLAN.md).

### Memory budget and optimization

- Keep peak memory < 50 MB during a request (Instruments).
- No images beyond SF Symbols.
- No extra dependencies (only Foundation, SwiftUI, Security).
- Keep UIHostingController view minimal.
- Dispose of the editor session and task when the view is deallocated.
- Spike ios-01 measured a peak of about 36 MB with the SwiftUI UI, network
  requests and an on-device rewrite, so the 50 MB budget holds with no
  special memory work beyond what is listed above.

## Testing Decisions

### InputExtractor unit tests

- **Plain text:** a plain-text `NSItemProvider`, `extract()` returns it.
- **UTF-8 text:** a utf8-text provider, extract returns it.
- **RTF:** an RTF provider, `extract()` parses and returns plain string.
- **CRLF normalization:** text with `\r\n` and `\r`, extract returns `\n` only.
- **URL only:** a URL provider with no text, extract returns empty string.
- **Empty input:** empty `inputItems`, extract returns empty.
- **Multiple items, first text wins:** two providers, first is URL (no text),
  second is plain text, extract returns the plain text.
- **Safari JS preprocessing:** test with a synthetic preprocessing result
  (a property-list attachment containing
  `NSExtensionJavaScriptPreprocessingResultsKey`), since spike ios-01 did
  not test Safari and this path ships unconditionally.

Use synthetic `NSItemProvider`s created with `NSItemProvider.registerDataRepresentation`.

### EditorSession tests (already in ios-08, reused here)

All tests from ios-08 apply. The extension uses the same `EditorSession` class.

### Extension integration tests

- **Auto-run first prompt:** set `autoRunFirstPrompt = true` in settings, launch
  with text via an input item, verify the first prompt runs automatically.
- **Auto-copy and close:** set `autoCopyResult = true`, run a prompt (mock via
  fake runner returning uppercase), verify Copy is called and the extension
  closes.
- **Consent inline:** set up a cloud provider without consent, run a prompt,
  verify the `ConsentView` appears inline, tap Allow, verify the prompt runs.
- **Not configured card:** with no active provider, run the extension, verify
  the "Set up a provider" card appears.

Use a `-uiTestStubProvider` launch argument to inject a stub provider that
returns input uppercased.

### Manual host-app matrix (Phase 3 exit criterion)

Before release, test Kallilex in a real device on these apps (record results
in Further Notes or a linked checklist):

1. **Safari**: select text from a webpage, tap Share, verify Kallilex appears,
   text arrives intact, result pastes back.
2. **Mail**: open a message, select quoted text, tap Share, verify Kallilex
   appears, text is correct, result pastes.
3. **Notes**: create a note with text, select it, tap Share, verify Kallilex
   appears, text intact, result pastes.
4. **Messages**: in a conversation, long-press a message, select text, tap Share,
   verify Kallilex appears.
5. **WhatsApp**: (bonus) select a message, tap Share, verify Kallilex appears.

For each: does Kallilex appear in the share sheet? Does the text arrive intact?
Does pasting back replace the selection in the source app? Record pass/fail.

## Out of Scope

- Streaming responses.
- Image or file input.
- Secondary windows or app switching. The extension cannot open the
  container app (spike ios-01 unknown 4).
- Background processing or scheduled runs.
- Persistence of the editor state (each launch is fresh).
- Localization of app names or system UI (apple's responsibility).

## Further Notes

- PLAN.md §8 covers the Share Extension architecture and activation rules.
- PLAN.md §4.2, §4.3 cover the main loop and error flows.
- PLAN.md §12.3 covers the manual host-app matrix exit criterion for Phase 3.
- The spike ios-01 report answers unknown 4: `extensionContext.open(_:)`
  does not work from a Share Extension (confirmed no), which is why the
  not-configured card has no button. Unknown 1 confirmed `public.plain-text`
  delivery from Notes; Safari (both with and without a selection) is still
  open and is verified during this spec's acceptance testing.
- The extension's principal class `ShareViewController` is registered in ios-02's
  Info.plist.
- The extension reads App Group and Keychain access group identifiers from the
  Info.plist at runtime (set in ios-02), so team-specific values are not
  hardcoded.
- Memory budget (< 50 MB) is validated with Instruments before release (Phase 5).
- The manual host-app matrix is a release-gating criterion; results are recorded
  in the release spec (ios-13) or a separate checklist linked in Further Notes.
