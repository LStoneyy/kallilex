import SwiftUI

/// Placeholder for the Scratchpad tab (ios-06). ios-08 replaces this with
/// the real editor, built from `KallilexUI`'s shared components.
struct ScratchpadView: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                String(localized: "scratchpad.placeholder.title", defaultValue: "Scratchpad"),
                systemImage: "square.and.pencil"
            )
        } description: {
            Text(String(
                localized: "scratchpad.placeholder.message",
                defaultValue: "Scratchpad editing is coming in a future update."
            ))
        }
        .accessibilityIdentifier("scratchpad.placeholder")
        .navigationTitle(String(localized: "tab.scratchpad", defaultValue: "Scratchpad"))
    }
}

#Preview {
    NavigationStack {
        ScratchpadView()
    }
}
