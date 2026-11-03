import SwiftUI
import KallilexKit

struct ContentView: View {
    var body: some View {
        Text("Kallilex")
            .accessibilityIdentifier("kallilex.kit.\(KallilexKit.name)")
    }
}

#Preview {
    ContentView()
}
