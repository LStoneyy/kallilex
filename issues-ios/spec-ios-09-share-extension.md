# Spec ios-09 — Share Extension

Status: ready-for-agent
Phase: Phase 3 (Share Extension)
Depends on: ios-07, ios-08

## Problem Statement

The Share Extension is Kallilex's primary interface: a user selects text in any
app, taps Share, chooses Kallilex, and the extension immediately presents an
editor with the selected text, prompt chips, and tools to rewrite and copy the
result back. The extension runs under a 120 MB memory limit, is killed when the
sheet closes, and has undocumented access to some framework features (on-device
model, deep links). It must extract text from many source types (plain text,
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
5. As a user, I want Copy to write the text to the clipboard, show "Copied"
   briefly, and then close the sheet so that I can paste the result back.
6. As a user with auto-copy enabled, I want the result to copy and close
   automatically so that the flow is seamless.
7. As a user with auto-run enabled, I want the first prompt to run as soon as
   the sheet opens so that I don't have to tap anything.
8. As a user without a provider set up, I want a clear message and a button to
   open the app (if possible) so that I know what to do next.
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
        let appGroupId = Bundle.main.infoDictionary?["KallilexAppGroup"] as? String
            ?? "group.com.webcommits.kallilex"
        let keychainAccessGroup = Bundle.main.infoDictionary?["KallilexKeychainAccessGroup"]
            as? String ?? "com.webcommits.kallilex.shared"
        
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
                
                // Safari JS preprocessing (if spike ios-01 confirms it's needed)
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
        // **To confirm:** whether Safari JS preprocessing is needed
        // (spike ios-01 unknown 1 determines this)
        // If needed, extract the NSExtensionJavaScriptPreprocessingResultsKey
        return nil  // Stub for now
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
  `NSAttributedString`), Safari JS result (if spike ios-01 confirms it's
  needed), then `attributedContentText`.
- Normalize line endings (`\r\n` and `\r` → `\n`); preserve all other
  whitespace.
- If nothing yields text, return empty string (which triggers an empty-state
  message in the UI).

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
   - If text present: editor, chips, custom field, status banner, toolbar.
3. **Footer:** (none; toolbar is inline above the status banner)

**States handled:**
- `loadingInput` (internal; show a brief spinner while extracting)
- `ready` (no indicator; user can select a prompt)
- `running` (spinner + Cancel)
- `result` (checkmark, "Show original" toggle visible)
- `error` (error message + Retry)
- `notConfigured` (card: "Set up a provider in the Kallilex app")
- `consentRequired` (inline `ConsentView`)

**Not-configured card:**

When the active profile is not found or disabled:

```swift
VStack(alignment: .leading, spacing: 12) {
    Image(systemName: "gear.circle")
        .font(.title)
    Text(String(localized: "extension.notConfigured.title"))
    Text(String(localized: "extension.notConfigured.message"))
    
    // Try to open the app if extensionContext.open works (spike unknown 4)
    if let url = URL(string: "kallilex://settings/providers") {
        Button(action: {
            extensionContext.open(url) { success in
                if !success {
                    // Fallback: show instruction text
                }
            }
        }) {
            Text(String(localized: "extension.notConfigured.openApp"))
        }
        .buttonStyle(.borderedProminent)
    } else {
        Text(String(localized: "extension.notConfigured.instruction"))
            .font(.caption)
    }
}
.padding()
.background(Color(.systemGray6))
```

**To confirm:** whether `extensionContext.open(_:)` works from a Share Extension
on iOS 26/27 (spike ios-01 unknown 4). If it works, use it; if not, show
instruction text only.

### Auto-run and auto-copy logic

- **Auto-run:** in `viewDidLoad`, after `editorSession` is initialized and text
  is extracted, check `settings.autoRunFirstPrompt`. If true and the prompts
  list is not empty, call `editorSession.run(.prompt(instruction: prompts[0].instruction))`.
- **Auto-copy:** on state change to `.result`, check `settings.autoCopyResult`.
  If true, immediately call `handleCopy()` which copies, shows "Copied" briefly,
  and calls `extensionContext.completeRequest(returningItems: [])`.

Both settings apply only to the extension, not to the Scratchpad (decided in
PLAN.md).

### Deep link handling in the app

When the user taps "Open Kallilex" in the not-configured card, it opens
`kallilex://settings/providers`. Add to `KallilexApp`:

```swift
.onOpenURL { url in
    if url.scheme == "kallilex",
       url.host == "settings",
       url.pathComponents.contains("providers") {
        // Navigate to the Providers tab
        // (Implementation depends on the TabView structure)
    }
}
```

### Memory budget and optimization

- Keep peak memory < 50 MB during a request (Instruments).
- No images beyond SF Symbols.
- No extra dependencies (only Foundation, SwiftUI, Security).
- Keep UIHostingController view minimal.
- Dispose of the editor session and task when the view is deallocated.

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
- **Safari JS preprocessing:** if spike ios-01 confirms it's needed, test with
  a synthetic preprocessing result.

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
- Secondary windows or app switching (other than open to the app via deep link).
- Background processing or scheduled runs.
- Persistence of the editor state (each launch is fresh).
- Localization of app names or system UI (apple's responsibility).

## Further Notes

- PLAN.md §8 covers the Share Extension architecture and activation rules.
- PLAN.md §4.2, §4.3 cover the main loop and error flows.
- PLAN.md §12.3 covers the manual host-app matrix exit criterion for Phase 3.
- The spike ios-01 report (unknown 1, 4) answers whether Safari JS preprocessing
  is needed and whether `extensionContext.open` works from a Share Extension.
  Both have fallbacks if the answer is no.
- The extension's principal class `ShareViewController` is registered in ios-02's
  Info.plist.
- The extension reads App Group and Keychain access group identifiers from the
  Info.plist at runtime (set in ios-02), so team-specific values are not
  hardcoded.
- Memory budget (< 50 MB) is validated with Instruments before release (Phase 5).
- The manual host-app matrix is a release-gating criterion; results are recorded
  in the release spec (ios-13) or a separate checklist linked in Further Notes.
