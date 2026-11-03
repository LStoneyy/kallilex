import SwiftUI

/// Shows the repository's Apache-2.0 license text, bundled at
/// `Resources/LICENSE.txt` (ios-06). Static for now; a later spec adds any
/// Swift package licenses.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(Self.licenseText)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .accessibilityIdentifier("settings.licenses.text")
        .navigationTitle(String(localized: "settings.licenses.title", defaultValue: "Licenses"))
    }

    private static let licenseText: String = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Apache License, Version 2.0 — see https://github.com/LStoneyy/kallilex/blob/main/LICENSE"
        }
        return text
    }()
}

#Preview {
    NavigationStack {
        LicensesView()
    }
}
