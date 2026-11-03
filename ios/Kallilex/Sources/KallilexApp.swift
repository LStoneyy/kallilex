import SwiftUI

@main
struct KallilexApp: App {
    @State private var environment: AppEnvironment?
    @State private var startupError: AppStartupError?
    @State private var showCorruptionAlert = false

    init() {
        switch AppEnvironment.start() {
        case .success(let result):
            _environment = State(initialValue: result.environment)
            _showCorruptionAlert = State(initialValue: result.recoveredFromCorruption)
        case .failure(let error):
            _startupError = State(initialValue: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment {
                    RootTabView(suppressOnboardingCover: showCorruptionAlert)
                        .environment(environment)
                } else {
                    StartupErrorView(error: startupError ?? .other("unknown"))
                }
            }
            .alert(
                String(localized: "corruption.alert.title", defaultValue: "Settings recovered"),
                isPresented: $showCorruptionAlert
            ) {
                Button(String(localized: "corruption.alert.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(String(
                    localized: "corruption.alert.message",
                    defaultValue: "Kallilex couldn't read its settings and started fresh. Your old settings file was kept for troubleshooting."
                ))
            }
        }
    }
}
