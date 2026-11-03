# Spec ios-08 — Shared editor UI and Scratchpad

Status: ready-for-agent
Phase: Phase 2 (Container app)
Depends on: ios-07

## Problem Statement

The Scratchpad and the Share Extension both need text editing, prompt selection,
running prompts, displaying results, and managing editor state (running,
success, error, not configured, consent required). The UI and state logic
must be shared between them to avoid duplication and ensure consistent behavior.
The editor must support cancellation, retry on the original input, undo to
revert an edit after a result, and copy to the pasteboard. It must display
appropriate status messages, respect accessibility settings, and provide
haptic feedback.

## Solution

Implement `EditorSession` in KallilexUI as a state container (`@Observable`,
`@MainActor`) managing editor state and the async run task. Build reusable
view components: `EditorView`, `PromptChipsBar`, `CustomInstructionField`,
`EditorToolbar`, `StatusBanner`, and `PrivacyBadge`. The Scratchpad tab in
the app uses these components, and the Share Extension reuses them via
`UIHostingController`. All state transitions and side effects are testable
through a fake `ActionRunner` and `Pasteboard` protocol.

## User Stories

1. As a user, I want to edit text in a large text view with spell check so
   that I can refine what I'm sending to the AI.
2. As a user, I want to see all my saved prompts as tappable chips so that I
   can quickly choose which instruction to run.
3. As a user, I want a "Custom…" chip that opens a one-line field for a
   free-form instruction so that I can apply unique rewrites without saving.
4. As a user, I want to see a spinner and Cancel button while a request is
   running so that I know something is happening and I can stop it.
5. As a user, I want the result to replace the original text, with a "Show
   original" toggle so that I can compare before moving on.
6. As a user, I want Undo, Retry, and Copy buttons so that I can revert,
   re-run on the original, or copy the result to my clipboard.
7. As a user, I want "Copied" to briefly flash so that I know Copy worked.
8. As a user, I want clear error messages when something fails so that I know
   what went wrong.
9. As a user, I want a clear message when no provider is configured so that I
   know to go to the app to set one up.
10. As a user, I want a clear consent card when I haven't granted consent for
    a cloud provider so that I can make the choice right then.
11. As a user, I want a soft warning if my text is very long so that I can
    shorten it if the AI might reject it.
12. As a user with VoiceOver, I want state announcements like "Rewriting…" and
    "Done" so that I know progress without watching the screen.
13. As a user with motion sensitivity, I want animations to respect Reduce
    Motion so that I don't get motion sickness.

## Implementation Decisions

### EditorSession state model

**File:** `ios/KallilexKit/Sources/KallilexUI/EditorSession.swift`

```swift
@Observable @MainActor
class EditorSession {
    enum State: Equatable {
        case idle
        case running(Action)
        case result
        case failed(ProviderError)
        case notConfigured
        case consentRequired(ProviderProfile)
    }
    
    var text: String = ""
    var lastInput: String = ""
    var lastAction: Action?
    var showingOriginal: Bool = false
    var state: State = .idle
    var inlineNote: String?
    
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
    
    let actionRunner: ActionRunner
    let pasteboard: Pasteboard
    let consentGranting: ConsentGranting
    
    private var runTask: Task<Void, Never>?
    
    init(
        actionRunner: ActionRunner,
        pasteboard: Pasteboard,
        consentGranting: ConsentGranting
    ) {
        self.actionRunner = actionRunner
        self.pasteboard = pasteboard
        self.consentGranting = consentGranting
    }
    
    func run(_ action: Action) async {
        cancel()  // Cancel any in-flight task
        lastInput = text
        lastAction = action
        inlineNote = nil
        
        state = .running(action)
        
        runTask = Task {
            let outcome = await actionRunner.run(text: text, action: action)
            
            switch outcome {
            case .ok(let result):
                text = result
                state = .result
            case .notConfigured:
                state = .notConfigured
            case .consentRequired(let profile):
                state = .consentRequired(profile)
            case .cancelled:
                state = .idle
            case .failed(let error):
                state = .failed(error)
            }
        }
    }
    
    func cancel() {
        runTask?.cancel()
        runTask = nil
        state = .idle
    }
    
    func retry() async {
        guard let lastAction = lastAction else { return }
        text = lastInput
        await run(lastAction)
    }
    
    func undo() {
        text = lastInput
        showingOriginal = false
    }
    
    func copy(to board: Pasteboard? = nil) {
        let board = board ?? pasteboard
        board.setString(text)
    }
    
    func grantConsentAndRetry() async {
        guard case .consentRequired(let profile) = state,
              let lastAction = lastAction,
              let host = consentHost(for: profile) else { return }
        do {
            try consentGranting.grantConsent(profileID: profile.id, host: host)
        } catch {
            // Stay on the consent card so the user can tap Allow again.
            inlineNote = String(localized: "editor.consent.saveFailed")  // "Couldn't save your choice. Try again."
            return
        }
        await run(lastAction)
    }
    
    func declineConsent() {
        state = .idle
        inlineNote = String(localized: "editor.consent.declined")  // "Nothing was sent."
    }
}

protocol Pasteboard: Sendable {
    func setString(_ string: String)
}

/// Injected so `EditorSession` can grant consent without depending on a
/// concrete `SettingsStore` shape. The production implementation calls
/// ios-04's `grantConsent(profileID:host:)` over `SettingsStore.update`.
protocol ConsentGranting: Sendable {
    func grantConsent(profileID: String, host: String) throws
}

struct SettingsStoreConsentGranter: ConsentGranting {
    let settingsStore: SettingsStore
    
    func grantConsent(profileID: String, host: String) throws {
        _ = try settingsStore.update { settings in
            KallilexKit.grantConsent(profileID: profileID, host: host, settings: &settings)
        }
    }
}
```

`consentHost(for:)` (ios-04) computes the canonical host from the profile's
`baseUrl` for every consent-host computation, including this one.

**Behavior:**
- `text` is the editor's current content, always editable.
- `lastInput` stores the text that the last run used.
- `run(_ action:)` cancels any in-flight task, sets `lastInput = text`, calls
  the runner, and updates state. On `.ok`, replaces `text` with the result and
  sets state to `.result`. On error/consent/not-configured, sets the
  corresponding state.
- `cancel()` cancels the task and sets state back to `.idle`.
- `retry()` sets `text = lastInput` and calls `run(lastAction)` on the original
  input.
- `undo()` sets `text = lastInput` and hides the original toggle.
- `copy()` writes `text` to the pasteboard.
- `grantConsentAndRetry()` grants consent for the pending profile's host (via
  `consentHost(for:)`, ios-04) and re-runs `lastAction`. If granting throws,
  the state stays `.consentRequired`, `inlineNote` shows "Couldn't save your
  choice. Try again.", and nothing is sent.
- `declineConsent()` sets `state = .idle` and `inlineNote` to "Nothing was
  sent."
- Editing the text after a result is allowed. The next `run()` uses the edited
  text as input, not the original.

### Reusable view components

#### EditorView

**File:** `ios/KallilexKit/Sources/KallilexUI/EditorView.swift`

A full-height `TextEditor` with system spell check and an accessibility label
`String(localized: "editor.label")` — "Text".

```swift
struct EditorView: View {
    @Binding var text: String
    
    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .lineSpacing(2)
            .accessibilityLabel(String(localized: "editor.label"))
    }
}
```

#### PromptChipsBar

**File:** `ios/KallilexKit/Sources/KallilexUI/PromptChipsBar.swift`

A horizontal scrollable row of prompt chips plus a "Custom…" chip:

```swift
struct PromptChipsBar: View {
    let prompts: [CustomPrompt]
    let onSelectPrompt: (CustomPrompt) -> Void
    let onCustomTapped: () -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts) { prompt in
                    PromptChip(
                        label: prompt.label,
                        instruction: prompt.instruction,
                        onTap: { onSelectPrompt(prompt) }
                    )
                }
                
                Button(action: onCustomTapped) {
                    Text(String(localized: "prompt.custom"))
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
    }
}

struct PromptChip: View {
    let label: String
    let instruction: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Text(label)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .contextMenu {
            // Long press shows the prompt's instruction (read-only).
            Text(instruction)
        }
    }
}
```

At accessibility Dynamic Type sizes (Large or larger), the chips wrap into a
vertical list. Use `ViewThatFits` or conditional layout:

```swift
if horizontalSizeClass == .regular {
    // Horizontal scroll
} else {
    // Vertical list
}
```

Long-pressing a chip shows its full instruction in a popover or tooltip.

#### CustomInstructionField

**File:** `ios/KallilexKit/Sources/KallilexUI/CustomInstructionField.swift`

A one-line `TextField` with Return key binding:

```swift
struct CustomInstructionField: View {
    @Binding var text: String
    let onReturn: () -> Void
    var isVisible: Bool = true
    
    var body: some View {
        if isVisible {
            TextField(
                String(localized: "prompt.custom.placeholder"),
                text: $text
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                if !text.isEmpty {
                    onReturn()
                    text = ""
                }
            }
            .submitLabel(.return)
        }
    }
}
```

Placeholder: `String(localized: "prompt.custom.placeholder")` — "Custom instruction…"

#### EditorToolbar

**File:** `ios/KallilexKit/Sources/KallilexUI/EditorToolbar.swift`

Three buttons in a horizontal row:

```swift
struct EditorToolbar: View {
    let canUndo: Bool
    let canRetry: Bool
    let canCopy: Bool
    let onUndo: () -> Void
    let onRetry: () async -> Void
    let onCopy: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(
                action: onUndo,
                label: {
                    Label(
                        String(localized: "editor.undo"),
                        systemImage: "arrow.uturn.backward"
                    )
                }
            )
            .disabled(!canUndo)
            
            Button(
                action: {
                    Task {
                        await onRetry()
                    }
                },
                label: {
                    Label(
                        String(localized: "editor.retry"),
                        systemImage: "arrow.clockwise"
                    )
                }
            )
            .disabled(!canRetry)
            
            Button(
                action: onCopy,
                label: {
                    Label(
                        String(localized: "editor.copy"),
                        systemImage: "doc.on.doc"
                    )
                }
            )
            .disabled(!canCopy)
        }
    }
}
```

Button labels use `String(localized:)` keys: `"editor.undo"`, `"editor.retry"`,
`"editor.copy"`.

#### StatusBanner

**File:** `ios/KallilexKit/Sources/KallilexUI/StatusBanner.swift`

Displays the current state of the editor:

```swift
struct StatusBanner: View {
    let state: EditorSession.State
    let inlineNote: String?
    let onRetry: () async -> Void
    let onCancel: () -> Void
    let onConsentAllow: () async -> Void
    let onConsentDecline: () -> Void
    
    var body: some View {
        Group {
            switch state {
            case .idle:
                if let inlineNote {
                    Text(inlineNote)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    EmptyView()
                }
            
            case .running(_):
                HStack(spacing: 12) {
                    ProgressView()
                    Text(String(localized: "editor.running"))
                        .accessibilityLabel(String(localized: "editor.running"))
                    Spacer()
                    Button(action: onCancel) {
                        Text(String(localized: "editor.cancel"))
                    }
                }
                .padding()
                .background(Color(.systemGray6))
            
            case .result:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(String(localized: "editor.done"))
                        .accessibilityLabel(String(localized: "editor.done"))
                }
                .padding()
                .background(Color(.systemGray6))
            
            case .failed(let error):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error.localizedDescription)
                    }
                    Button(action: {
                        Task { await onRetry() }
                    }) {
                        Text(String(localized: "editor.retry"))
                    }
                }
                .padding()
                .background(Color(.systemGray6))
            
            case .notConfigured:
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "editor.notConfigured.title"))
                        .font(.headline)
                    Text(String(localized: "editor.notConfigured.message"))
                    Button(action: {
                        // Navigate to Providers tab
                    }) {
                        Text(String(localized: "editor.notConfigured.action"))
                    }
                }
                .padding()
                .background(Color(.systemGray6))
            
            case .consentRequired(let profile):
                ConsentView(
                    profile: profile,
                    host: consentHost(for: profile) ?? "",
                    onAllow: onConsentAllow,
                    onNotNow: onConsentDecline
                )
            }
        }
    }
}
```

`ProviderError` conforms to `LocalizedError` in `KallilexKit` (ios-05), with
`errorDescription` sourced from KallilexKit's string catalog; this view
displays `error.localizedDescription` rather than defining its own mapping.

The `.running` case shows the action's label (via `action.label` or
`actionLabel(for:)` helper). The `.result` case shows a brief success message.
The `.failed` case shows the error message with a Retry button. The
`.notConfigured` case shows a card explaining setup is needed. The
`.consentRequired` case embeds `ConsentView`, wiring `onAllow` to
`session.grantConsentAndRetry()` and `onNotNow` to `session.declineConsent()`
at the call site (see Scratchpad tab below).

#### PrivacyBadge (if not already in ios-06)

**File:** `ios/KallilexKit/Sources/KallilexUI/PrivacyBadge.swift`

A small badge showing the privacy class:

```swift
struct PrivacyBadge: View {
    let privacyClass: PrivacyClass
    let host: String = ""
    
    var body: some View {
        switch privacyClass {
        case .onDevice:
            Label(String(localized: "privacy.onDevice"), systemImage: "iphone")
        case .local:
            Label(String(localized: "privacy.local"), systemImage: "desktopcomputer")
        case .lan:
            Label(String(localized: "privacy.lan"), systemImage: "network")
        case .cloud:
            Label(
                "Cloud: \(host)",
                systemImage: "cloud"
            )
        }
    }
}
```

### Scratchpad tab in the app

**File:** `Kallilex/Sources/ScratchpadView.swift`

Integrates all the shared components:

```swift
struct ScratchpadView: View {
    @Environment(AppEnvironment.self) var appEnv
    @State private var editorSession: EditorSession?
    @State private var customInstruction = ""
    @State private var showCopiedFeedback = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                EditorView(text: Binding(
                    get: { editorSession?.text ?? "" },
                    set: { editorSession?.text = $0 }
                ))
                
                if let session = editorSession {
                    PromptChipsBar(
                        prompts: appEnv.settings.prompts,
                        onSelectPrompt: { prompt in
                            Task {
                                await session.run(.prompt(
                                    instruction: prompt.instruction
                                ))
                            }
                        },
                        onCustomTapped: {
                            // Focus custom field
                        }
                    )
                    
                    CustomInstructionField(
                        text: $customInstruction,
                        onReturn: {
                            Task {
                                await session.run(.custom(
                                    instruction: customInstruction
                                ))
                            }
                        }
                    )
                    
                    StatusBanner(
                        state: session.state,
                        inlineNote: session.inlineNote,
                        onRetry: { await session.retry() },
                        onCancel: { session.cancel() },
                        onConsentAllow: { await session.grantConsentAndRetry() },
                        onConsentDecline: { session.declineConsent() }
                    )
                    
                    HStack(spacing: 12) {
                        EditorToolbar(
                            canUndo: session.lastInput != session.text,
                            canRetry: session.lastAction != nil
                                && !session.isRunning,
                            canCopy: !session.text.isEmpty,
                            onUndo: { session.undo() },
                            onRetry: { await session.retry() },
                            onCopy: {
                                session.copy()
                                showCopiedFeedback = true
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.8
                                ) {
                                    showCopiedFeedback = false
                                }
                            }
                        )
                        
                        Button(action: {
                            editorSession?.text = ""
                        }) {
                            Label(
                                String(localized: "editor.clear"),
                                systemImage: "xmark"
                            )
                        }
                        
                        Spacer()
                        
                        if let session = editorSession,
                           case .result = session.state {
                            Toggle(
                                String(localized: "editor.showOriginal"),
                                isOn: $editorSession!.showingOriginal
                            )
                        }
                    }
                    
                    if showCopiedFeedback {
                        Text(String(localized: "editor.copied"))
                            .transition(.opacity)
                    }
                }
            }
            .navigationTitle(String(localized: "tab.scratchpad"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PasteButton(payloadType: String.self) { strings in
                        editorSession?.text = strings.first ?? editorSession?.text ?? ""
                    }
                }
            }
        }
        .onAppear {
            guard editorSession == nil else { return }
            let pasteboard = UIPasteboard()
            editorSession = EditorSession(
                actionRunner: appEnv.actionRunner,
                pasteboard: DevicePasteboard(),
                consentGranting: SettingsStoreConsentGranter(
                    settingsStore: appEnv.settingsStore
                )
            )
        }
    }
}

struct DevicePasteboard: Pasteboard {
    func setString(_ string: String) {
        UIPasteboard.general.string = string
    }
}
```

The Scratchpad uses a `PasteButton` which iOS provides without a paste
permission prompt. The Clear button erases all text. The "Show original"
toggle appears only in the `.result` state. Copy shows "Copied" for ~0.8 s
with `withAnimation()` respecting Reduce Motion.

### Accessibility and haptics

- VoiceOver announcements:
  - When state becomes `.running(action)`: announce
    `"Rewriting with \(prompt.label)…"`
  - When state becomes `.result`: announce `"Done"`
  - When state becomes `.failed(error)`: announce `error.localizedDescription`
- Haptics:
  - On `.result`: `UINotificationFeedbackGenerator().notificationOccurred(.success)`
  - On `.failed`: `UINotificationFeedbackGenerator().notificationOccurred(.error)`
- Reduce Motion:
  - The "Copied" animation uses `withAnimation(.easeInOut(duration: 0.3))`
    wrapped in a check for `@Environment(\.accessibilityReduceMotion)`.

### Soft character limit warning

Display a non-blocking warning when text exceeds 20,000 characters:

```swift
if session.text.count > 20000 {
    HStack {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
        Text(String(localized: "editor.textTooLong"))
    }
    .font(.caption)
    .padding(8)
    .background(Color(.systemOrange).opacity(0.1))
}
```

Message key: `"editor.textTooLong"` — "Long texts can be slow or exceed the model's
limit."

For the on-device model (ios-10), add a hard block above its context size:
`"editor.textTooLongForModel"` — "Too long for the on-device model."

## Testing Decisions

### EditorSession unit tests

- **Idle state:** session starts with `text = ""`, `state = .idle`.
- **Run a prompt:** call `run(.prompt(...))`, state becomes `.running`, then on
  success becomes `.result` and text is replaced.
- **Run failed:** call `run(...)`, on error state becomes `.failed(error)`.
- **Cancel:** while running, call `cancel()`, state becomes `.idle`.
- **Run while running:** call `run(...)` while a task is in flight, the first
  task is cancelled and a new one starts.
- **Retry:** after a result, call `retry()`, text is reset to `lastInput` and
  the last action runs on it.
- **Undo:** after a result, call `undo()`, text is reset to `lastInput`.
- **Edit after result then run:** after a result, edit the text, call `run(...)`,
  the new text (not the original) is used as input.
- **Consent required then allow:** on consent required state, call
  `grantConsentAndRetry()`, the last action is re-run.
- **Consent required then decline:** on consent required state, call
  `declineConsent()`, state becomes `.idle` and `inlineNote` is "Nothing was
  sent."
- **Consent grant throws:** stub `ConsentGranting` to throw, call
  `grantConsentAndRetry()`, state stays `.consentRequired`, `inlineNote` is
  "Couldn't save your choice. Try again." and the action is not re-run.
- **Not configured:** call `run(...)` with no provider configured, state becomes
  `.notConfigured`.
- **Copy writes to pasteboard:** use a fake `Pasteboard`, call `copy()`,
  verify `setString` was called with the current text.

Use a fake `ActionRunner` that returns stubs based on input.

### XCUITest

- **Paste and run:** use the Scratchpad, tap the Paste button, paste "hello",
  select the stub prompt, verify "HELLO" appears (uppercased by the stub).
- **Copy:** with text "hello", tap Copy, verify "Copied" appears and disappears
  after 0.8 s.
- **Reorder prompts and see in Scratchpad:** add two prompts in the Prompts tab,
  reorder them, return to Scratchpad, tap the chips in order, verify they run
  in the new order.

## Out of Scope

- Streaming responses.
- Scheduled/deferred runs (e.g., retry later).
- Text formatting, rich text, or Markdown previews.
- Voice input or TTS output.
- Syncing the Scratchpad text across devices.

## Further Notes

- PLAN.md §4.2, §4.3, §8.3 and §9 item 1 describe the editor and Scratchpad.
- PLAN.md §11 covers localization and accessibility.
- The `EditorSession` is designed to be agnostic of the view layer, so it can
  be tested with a fake `ActionRunner` and `Pasteboard`.
- The shared components (`EditorView`, `PromptChipsBar`, etc.) live in
  `KallilexUI` and are imported by both Scratchpad and the Share Extension.
- Haptic feedback is triggered on success and error completion.
- VoiceOver announcements use the action label or error message.
