import SwiftUI

/// A minimal static guide explaining how to pin Kallilex in the iOS share
/// sheet (ios-06). ios-07 replaces this with the full onboarding flow, and
/// this same view is reused there.
struct ShareSheetGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(
                        localized: "settings.shareSheetGuide.body",
                        defaultValue: "Open the share sheet from any app (the square with an arrow pointing up), scroll the top row of apps all the way to the end, tap \"More\", then turn on Kallilex and drag it near the top of your favorites."
                    ))
                    .accessibilityIdentifier("settings.shareSheetGuide.body")
                }
                .padding()
            }
            .navigationTitle(String(
                localized: "settings.shareSheetGuide.title",
                defaultValue: "Add Kallilex to your share sheet"
            ))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.close", defaultValue: "Close")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ShareSheetGuideView()
}
