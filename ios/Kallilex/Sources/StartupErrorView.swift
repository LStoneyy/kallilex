import SwiftUI

/// Shown instead of the tabs when `AppEnvironment.start()` fails — the app
/// never crashes on a storage failure (ios-06).
struct StartupErrorView: View {
    let error: AppStartupError

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "startup.error.title", defaultValue: "Couldn't start Kallilex"))
                .font(.title2)
                .bold()
            Text(error.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .accessibilityIdentifier("startup.errorView")
        .padding()
    }
}

#Preview {
    StartupErrorView(error: .appGroupUnavailable("group.com.webcommits.kallilex"))
}
