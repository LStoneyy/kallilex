import SwiftUI
import KallilexKit

/// How long `ShareRootView`'s "Copy & Close" button shows its "Copied"
/// confirmation before calling `onFinish()`.
public let shareRootViewDefaultCopiedDuration: Duration = .milliseconds(600)

/// The Share Extension's root view (ios-09, PLAN.md §8.3): a header
/// ("Kallilex", the active profile's privacy badge, Close), then — driven
/// by `contentState`, computed by `ShareFlow.contentState(text:
/// settingsLoadFailed:)` — a brief loading spinner, the empty-input
/// message, the settings-load-error card, or the shared `EditorScreen` with
/// its own "Copy & Close" toolbar button. `EditorScreen`'s
/// `onOpenProviders: nil` already makes its not-configured card
/// button-less (there is nowhere to navigate to from the extension), and
/// its `StatusBanner` already renders `.consentRequired` inline — neither
/// needs any extra handling here.
///
/// Takes `onClose`/`onFinish` closures rather than an `NSExtensionContext`
/// directly, so it has no dependency on the extension host at all: the
/// Share Extension's `ShareViewController` wires them to
/// `cancelRequest`/`completeRequest`, and the container app (part 2 of this
/// spec) can host this same view with its own closures for an in-app debug
/// harness and XCUITests.
public struct ShareRootView: View {
    private let session: EditorSession
    private let shareFlow: ShareFlow
    private let contentState: ShareContentState
    private let settings: AppSettings?
    private let activeProfile: ProviderProfile?
    private let copiedDuration: Duration
    private let onClose: () -> Void
    private let onFinish: () -> Void

    @State private var showCopiedFeedback = false
    @State private var copiedTask: Task<Void, Never>?

    public init(
        session: EditorSession,
        shareFlow: ShareFlow,
        contentState: ShareContentState,
        settings: AppSettings?,
        activeProfile: ProviderProfile?,
        copiedDuration: Duration = shareRootViewDefaultCopiedDuration,
        onClose: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.session = session
        self.shareFlow = shareFlow
        self.contentState = contentState
        self.settings = settings
        self.activeProfile = activeProfile
        self.copiedDuration = copiedDuration
        self.onClose = onClose
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 12) {
            header

            switch contentState {
            case .loadingInput:
                Spacer()
                ProgressView()
                Spacer()

            case .emptyInput:
                emptyInputView

            case .settingsError:
                settingsErrorView

            case .editor:
                if let settings {
                    EditorScreen(
                        session: session,
                        prompts: settings.prompts,
                        activeProfile: activeProfile,
                        onOpenProviders: nil
                    ) {
                        copyAndCloseButton
                    }

                    if case .result = session.state {
                        Text(String(
                            localized: "extension.pasteHint",
                            defaultValue: "After copying, select the original text again and paste.",
                            bundle: .module
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .accessibilityIdentifier("share.pasteHint")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .task(id: contentState) {
            performAutoRunIfNeeded()
        }
        .onChange(of: session.state) { _, newState in
            handleStateChange(newState)
        }
    }

    private var header: some View {
        HStack {
            Text("Kallilex")
                .font(.headline)
            Spacer()
            if let activeProfile {
                PrivacyBadge(profile: activeProfile, interactive: false)
            }
            Button {
                // A pending Copy & Close timer must not call `onFinish()`
                // after the sheet was already closed.
                copiedTask?.cancel()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel(Text(String(localized: "extension.close", defaultValue: "Close", bundle: .module)))
            .accessibilityIdentifier("share.close")
        }
        .padding(.horizontal)
    }

    private var emptyInputView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.title)
            Text(String(
                localized: "extension.empty.title",
                defaultValue: "Kallilex needs selected text",
                bundle: .module
            ))
            .font(.headline)
            Text(String(
                localized: "extension.empty.message",
                defaultValue: "Select the text first, then tap Share.",
                bundle: .module
            ))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.emptyInput")
    }

    private var settingsErrorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(String(
                localized: "extension.settingsError.message",
                defaultValue: "Kallilex couldn't read its settings. Open the Kallilex app to fix this.",
                bundle: .module
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.settingsError")
    }

    private var copyAndCloseButton: some View {
        Button {
            copyAndClose()
        } label: {
            if showCopiedFeedback {
                Text(String(localized: "editor.copied", defaultValue: "Copied", bundle: .module))
            } else {
                Text(String(localized: "extension.copyAndClose", defaultValue: "Copy & Close", bundle: .module))
            }
        }
        .buttonStyle(.borderedProminent)
        // Not while running: copying would take the pre-run text and
        // closing would cancel the run.
        .disabled(!session.canCopy || session.isRunning || showCopiedFeedback)
        .accessibilityIdentifier("share.copyAndClose")
    }

    /// Writes `session.text` to the pasteboard, shows "Copied" for
    /// `copiedDuration`, then calls `onFinish()` — used both by the "Copy &
    /// Close" button and by `autoCopyResult` (PLAN.md §4.2's speed-up).
    private func copyAndClose() {
        session.copy()
        copiedTask?.cancel()
        copiedTask = Task {
            showCopiedFeedback = true
            try? await Task.sleep(for: copiedDuration)
            guard !Task.isCancelled else { return }
            showCopiedFeedback = false
            onFinish()
        }
    }

    private func performAutoRunIfNeeded() {
        guard contentState == .editor, let settings else { return }
        guard shareFlow.shouldAutoRunFirstPrompt(settings: settings, text: session.text) else { return }
        guard let firstPrompt = settings.prompts.first else { return }
        shareFlow.consumeAutoRun()
        session.run(.prompt(instruction: firstPrompt.instruction), label: firstPrompt.label)
    }

    private func handleStateChange(_ newState: EditorSession.State) {
        guard case .result = newState, let settings else { return }
        if shareFlow.shouldAutoCopyResult(settings: settings) {
            copyAndClose()
        }
    }
}
