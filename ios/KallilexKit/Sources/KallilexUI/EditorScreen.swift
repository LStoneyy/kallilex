import SwiftUI
import KallilexKit

/// How long `EditorScreen`'s "Copied" confirmation stays visible by
/// default. A free constant, not a `static let` on `EditorScreen` itself —
/// Swift doesn't support stored static properties on a generic type.
public let editorScreenDefaultCopiedDuration: Duration = .milliseconds(800)

/// Composes every shared editor component into one screen (ios-08): the
/// text editor, the long-text warning, the status banner, the prompt chips
/// bar, the custom-instruction field (shown once the "Custom…" chip is
/// tapped), the undo/retry/copy toolbar, a "Show original" toggle (only in
/// `.result`), a brief "Copied" confirmation, and a privacy badge for the
/// active provider if one is passed in.
///
/// Used unchanged by both the Scratchpad tab (this spec) and the Share
/// Extension (ios-09), which composes it inside its own
/// `UIHostingController` and passes its own `toolbarExtra` (e.g. "Copy &
/// close") — this view has no dependency on either host beyond `session`'s
/// own `any ActionRunning`/`any Pasteboard`/`any ConsentGranting`.
///
/// `EditorView` is given the remaining vertical space; every other control
/// sizes to fit, so they stay reachable above the keyboard rather than
/// being pushed off-screen by a growing text view.
public struct EditorScreen<ToolbarExtra: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let session: EditorSession
    private let prompts: [CustomPrompt]
    private let activeProfile: ProviderProfile?
    private let onOpenProviders: (() -> Void)?
    private let toolbarExtra: () -> ToolbarExtra
    private let copiedDuration: Duration

    @State private var showCustomField = false
    @State private var customInstruction = ""
    @FocusState private var customFieldFocused: Bool
    @FocusState private var editorFocused: Bool

    @State private var showCopied = false
    @State private var copiedTask: Task<Void, Never>?

    public init(
        session: EditorSession,
        prompts: [CustomPrompt],
        activeProfile: ProviderProfile? = nil,
        onOpenProviders: (() -> Void)? = nil,
        copiedDuration: Duration = editorScreenDefaultCopiedDuration,
        @ViewBuilder toolbarExtra: @escaping () -> ToolbarExtra
    ) {
        self.session = session
        self.prompts = prompts
        self.activeProfile = activeProfile
        self.onOpenProviders = onOpenProviders
        self.copiedDuration = copiedDuration
        self.toolbarExtra = toolbarExtra
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activeProfile {
                PrivacyBadge(profile: activeProfile)
                    .padding(.horizontal)
            }

            EditorView(
                text: Binding(
                    get: { session.displayedText },
                    set: { session.text = $0 }
                ),
                isEditable: session.isEditable,
                isFocused: $editorFocused
            )
            .frame(maxHeight: .infinity)
            .padding(.horizontal)

            if session.isTextLong {
                LongTextWarning()
                    .padding(.horizontal)
            }

            StatusBanner(
                state: session.state,
                runningLabel: session.lastLabel,
                inlineNote: session.inlineNote,
                onCancel: { session.cancel() },
                onRetry: { session.retry() },
                onConsentAllow: { session.grantConsentAndRetry() },
                onConsentDecline: { session.declineConsent() },
                onOpenProviders: onOpenProviders
            )
            .padding(.horizontal)

            PromptChipsBar(
                prompts: prompts,
                isRunning: session.isRunning || session.showingOriginal,
                onSelectPrompt: { prompt in
                    dismissKeyboard()
                    session.run(.prompt(instruction: prompt.instruction), label: prompt.label)
                },
                onCustomTapped: {
                    showCustomField = true
                    customFieldFocused = true
                }
            )

            if showCustomField {
                CustomInstructionField(
                    text: $customInstruction,
                    isDisabled: session.isRunning || session.showingOriginal,
                    onSubmit: { instruction in
                        dismissKeyboard()
                        session.run(.custom(instruction: instruction), label: Self.customLabel)
                    }
                )
                .focused($customFieldFocused)
                .padding(.horizontal)
            }

            // Two rows, rather than one crowded `HStack` with every
            // control plus a `Spacer()`: cramming undo/retry/copy, the
            // caller's own extra content, and "Show original" into a
            // single row left too little width per item on a standard
            // phone width, and SwiftUI wraps an unconstrained `Text`
            // instead of truncating it — producing an unreadable
            // one-letter-per-line result rather than an ellipsis. A plain
            // `HStack` (not a `ScrollView`) — undo/retry/copy plus the
            // caller's own content comfortably fit one row at ordinary
            // Dynamic Type sizes once the competing `Spacer()`/toggle are
            // out of the way, and a horizontally scrollable ancestor's own
            // pan gesture can otherwise contend with a `Button`'s tap.
            HStack(spacing: 12) {
                EditorToolbar(
                    canUndo: session.canUndo,
                    canRetry: session.canRetry,
                    canCopy: session.canCopy,
                    onUndo: { session.undo() },
                    onRetry: {
                        dismissKeyboard()
                        session.retry()
                    },
                    onCopy: { copyAndShowConfirmation() }
                )

                toolbarExtra()
            }
            .padding(.horizontal)

            if case .result = session.state {
                HStack {
                    Spacer()
                    Toggle(
                        String(localized: "editor.showOriginal", defaultValue: "Show original", bundle: .module),
                        isOn: Binding(
                            get: { session.showingOriginal },
                            set: { session.showingOriginal = $0 }
                        )
                    )
                    .toggleStyle(.button)
                    .accessibilityIdentifier("editor.showOriginal")
                }
                .padding(.horizontal)
            }

            if showCopied {
                Text(String(localized: "editor.copied", defaultValue: "Copied", bundle: .module))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("editor.copied")
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.vertical, 8)
    }

    /// Hides the keyboard when a run starts, so the status banner, the
    /// consent card and the result aren't squeezed behind it. Called at the
    /// start of each run rather than observed from `session.state`: a fast
    /// provider can finish before SwiftUI ever renders the running state.
    private func dismissKeyboard() {
        editorFocused = false
        customFieldFocused = false
    }

    /// The localized running label used for custom (unsaved) instructions —
    /// shared with the "Rewriting with …" status text and VoiceOver
    /// announcement.
    private static var customLabel: String {
        String(localized: "prompt.custom.label", defaultValue: "Custom instruction", bundle: .module)
    }

    /// Writes `session.text` to the pasteboard and shows "Copied" for
    /// `copiedDuration`, respecting Reduce Motion. Uses a cancellable
    /// `Task`/`Task.sleep` rather than `asyncAfter`, so a second tap of
    /// Copy restarts the timer instead of letting an earlier one hide the
    /// confirmation early.
    private func copyAndShowConfirmation() {
        session.copy()
        copiedTask?.cancel()
        copiedTask = Task {
            setCopiedVisible(true)
            try? await Task.sleep(for: copiedDuration)
            guard !Task.isCancelled else { return }
            setCopiedVisible(false)
        }
    }

    private func setCopiedVisible(_ visible: Bool) {
        if reduceMotion {
            showCopied = visible
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                showCopied = visible
            }
        }
    }
}

extension EditorScreen where ToolbarExtra == EmptyView {
    /// A convenience initializer for callers with no extra toolbar content
    /// (e.g. the Share Extension before it adds its own "Copy & close"),
    /// so they don't have to spell out `{ EmptyView() }` themselves.
    public init(
        session: EditorSession,
        prompts: [CustomPrompt],
        activeProfile: ProviderProfile? = nil,
        onOpenProviders: (() -> Void)? = nil,
        copiedDuration: Duration = editorScreenDefaultCopiedDuration
    ) {
        self.init(
            session: session,
            prompts: prompts,
            activeProfile: activeProfile,
            onOpenProviders: onOpenProviders,
            copiedDuration: copiedDuration,
            toolbarExtra: { EmptyView() }
        )
    }
}

/// Preview-only fakes: `EditorScreen` needs a real `EditorSession`, whose
/// dependencies otherwise live in `KallilexKitTests` (`FakeActionRunning`
/// et al.) — too heavy to pull into this target just for a preview.
private struct PreviewActionRunning: ActionRunning {
    func run(text: String, action: Action) async -> RunOutcome {
        try? await Task.sleep(for: .seconds(1))
        return .ok(text.uppercased())
    }
}

private struct PreviewPasteboard: Pasteboard {
    func setString(_ string: String) {}
}

private struct PreviewConsentGranting: ConsentGranting {
    func grantConsent(profileID: String, host: String) throws {}
}

#Preview {
    EditorScreen(
        session: EditorSession(
            actionRunner: PreviewActionRunning(),
            pasteboard: PreviewPasteboard(),
            consentGranting: PreviewConsentGranting()
        ),
        prompts: [
            CustomPrompt(id: "1", label: "Fix grammar", instruction: "Fix grammar and spelling."),
            CustomPrompt(id: "2", label: "Shorten", instruction: "Make this more concise."),
        ],
        activeProfile: ProviderProfile(id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4")
    ) {
        Button(role: .destructive) {} label: {
            Label("Clear", systemImage: "xmark.circle")
        }
    }
}
