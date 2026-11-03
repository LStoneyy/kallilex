import SwiftUI

/// The four-tab shell (ios-06): Scratchpad, Prompts, Providers, Settings.
/// Reloads settings whenever the scene becomes active, so it picks up
/// consents or settings the Share Extension wrote while backgrounded, and
/// shows `appEnv.lastError` in an alert.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.scenePhase) private var scenePhase

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
