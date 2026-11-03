import SwiftUI

/// The four-tab shell (ios-06): Scratchpad, Prompts, Providers, Settings.
/// Reloads settings whenever the scene becomes active, so it picks up
/// consents or settings the Share Extension wrote while backgrounded, and
/// shows `appEnv.lastError` in an alert.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.scenePhase) private var scenePhase

    /// `true` while `KallilexApp`'s one-time corruption-recovery alert is
    /// up. SwiftUI can't cleanly present an `.alert` (from `KallilexApp`,
    /// above this view) and a `.fullScreenCover` (below, from this view) at
    /// the same instant — verified empirically: without this, a corrupt
    /// first launch (which also always seeds `onboardingCompleted = false`)
    /// raced the two, and the alert never actually appeared. Suppressing
    /// the cover's binding while the alert is still showing sequences them:
    /// the cover presents right after the alert is dismissed, instead of
    /// fighting it for the same instant.
    var suppressOnboardingCover: Bool = false

    var body: some View {
        TabView {
            NavigationStack {
                ScratchpadView()
            }
            .tabItem {
                Label(String(localized: "tab.scratchpad", defaultValue: "Scratchpad"), systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("tab.scratchpad")

            NavigationStack {
                PromptListView()
            }
            .tabItem {
                Label(String(localized: "tab.prompts", defaultValue: "Prompts"), systemImage: "text.quote")
            }
            .accessibilityIdentifier("tab.prompts")

            NavigationStack {
                ProviderListView()
            }
            .tabItem {
                Label(String(localized: "tab.providers", defaultValue: "Providers"), systemImage: "server.rack")
            }
            .accessibilityIdentifier("tab.providers")

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(String(localized: "tab.settings", defaultValue: "Settings"), systemImage: "gearshape")
            }
            .accessibilityIdentifier("tab.settings")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appEnv.reload()
            }
        }
        // A real `Binding`, not `.constant`: SwiftUI needs a settable
        // binding to animate the cover away the moment `onboardingCompleted`
        // flips to `true` (ios-07). The flow itself is the only thing that
        // ever flips it — there's no swipe-to-dismiss or Cancel on the
        // cover — but the `set` side still has to exist for SwiftUI's own
        // dismissal bookkeeping, and mirrors the flow's own effect if it
        // ever fires.
        .fullScreenCover(
            isPresented: Binding(
                get: { !appEnv.settings.onboardingCompleted && !suppressOnboardingCover },
                set: { isPresented in
                    if !isPresented {
                        appEnv.updateSettings { $0.onboardingCompleted = true }
                    }
                }
            )
        ) {
            OnboardingView()
        }
        .alert(
            String(localized: "error.alert.title", defaultValue: "Something went wrong"),
            isPresented: Binding(
                get: { appEnv.lastError != nil },
                set: { isPresented in if !isPresented { appEnv.lastError = nil } }
            )
        ) {
            Button(String(localized: "action.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(appEnv.lastError ?? "")
        }
    }
}
