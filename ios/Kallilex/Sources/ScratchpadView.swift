import SwiftUI
import UIKit
import KallilexKit
import KallilexUI

/// The Scratchpad tab (ios-08): the shared `EditorScreen` wired to one
/// `EditorSession` owned by this view (created once, in `onAppear`), so
/// running a prompt, retrying, undoing, and copying all survive navigating
/// away to another tab and back. Pasting (via `PasteButton`, which needs
/// no paste-permission prompt) replaces the whole text; Clear erases it.
/// Neither auto-runs nor auto-copies — `autoRunFirstPrompt`/
/// `autoCopyResult` are share-sheet-only (ios-09).
struct ScratchpadView: View {
    @Environment(AppEnvironment.self) private var appEnv

    /// `RootTabView`'s selected tab, so `onOpenProviders` below can switch
    /// to the Providers tab from the editor's not-configured or
    /// consent-required status.
    @Binding var selectedTab: AppTab

    @State private var session: EditorSession?

    /// How long "Copied" stays visible. UI tests pass
    /// `-uiTestLongCopiedConfirmation` (debug builds only) because XCUITest
    /// waits for the app to go idle after a tap, which can take longer than
    /// the default 0.8 s, so the confirmation would be gone before the
    /// test could see it.
    private static var copiedDuration: Duration {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestLongCopiedConfirmation") {
            return .seconds(3)
        }
        #endif
        return editorScreenDefaultCopiedDuration
    }

    private var activeProfile: ProviderProfile? {
        guard let activeID = appEnv.settings.activeProfileID else { return nil }
        return appEnv.settings.profiles.first { $0.id == activeID && $0.enabled }
    }

    var body: some View {
        Group {
            if let session {
                EditorScreen(
                    session: session,
                    prompts: appEnv.settings.prompts,
                    activeProfile: activeProfile,
                    onOpenProviders: { selectedTab = .providers },
                    copiedDuration: Self.copiedDuration
                ) {
                    Button {
                        session.text = ""
                    } label: {
                        Label(
                            String(localized: "scratchpad.clear", defaultValue: "Clear"),
                            systemImage: "xmark.circle"
                        )
                    }
                    .disabled(session.isRunning || session.text.isEmpty)
                    .accessibilityIdentifier("scratchpad.clear")
                }
            } else {
                // Only ever visible for the one render before `onAppear`
                // creates `session` below — construction is synchronous
                // and depends on `appEnv`, which isn't available in `init`.
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "tab.scratchpad", defaultValue: "Scratchpad"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    session?.text = pasted
                }
                .disabled(session == nil)
                .accessibilityIdentifier("scratchpad.paste")
            }
            // `PasteButton` draws its own filled capsule; without this the
            // toolbar's glass background puts a second ring around it.
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear {
            guard session == nil else { return }
            session = EditorSession(
                actionRunner: appEnv.actionRunner,
                pasteboard: DevicePasteboard(),
                consentGranting: ReloadingConsentGranter(
                    settingsService: appEnv.service,
                    reload: { [appEnv] in
                        Task { @MainActor in appEnv.reload() }
                    }
                )
            )
        }
    }
}

#Preview {
    NavigationStack {
        ScratchpadView(selectedTab: .constant(.scratchpad))
    }
}

