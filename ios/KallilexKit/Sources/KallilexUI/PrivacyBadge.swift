import SwiftUI
import KallilexKit

/// A small, tappable badge showing a provider's privacy class (ios-06):
/// "On device", "This device", "Your network", or "Cloud: <host>". Tapping
/// it shows a longer explanation in a popover. Shared between the
/// container app's Providers tab (this spec) and, later, the Share
/// Extension (ios-09).
public struct PrivacyBadge: View {
    private let info: PrivacyBadgeInfo
    @State private var showDetail = false

    public init(info: PrivacyBadgeInfo) {
        self.info = info
    }

    public init(profile: ProviderProfile) {
        self.info = PrivacyBadgeInfo(profile: profile)
    }

    public var body: some View {
        Button {
            showDetail = true
        } label: {
            Label(info.title, systemImage: info.symbolName)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(tintColor)
                .background(tintColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityIdentifier("provider.privacyBadge")
        .popover(isPresented: $showDetail) {
            Text(detailText)
                .font(.callout)
                .padding()
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var tintColor: Color {
        switch info.classification {
        case .onDevice: .green
        case .local: .blue
        case .lan: .orange
        case .cloud: .purple
        case nil: .gray
        }
    }

    private var detailText: String {
        switch info.classification {
        case .onDevice:
            String(
                localized: "privacyBadge.detail.onDevice",
                defaultValue: "Processed entirely on this device using Apple's on-device model. Nothing leaves your phone.",
                bundle: .module
            )
        case .local:
            String(
                localized: "privacyBadge.detail.local",
                defaultValue: "Processed on this device. Nothing leaves your phone.",
                bundle: .module
            )
        case .lan:
            String(
                localized: "privacyBadge.detail.lan",
                defaultValue: "Sent to a server on your local network. Nothing leaves your network.",
                bundle: .module
            )
        case .cloud:
            String(
                localized: "privacyBadge.detail.cloud",
                defaultValue: "Sent to a cloud server over the internet.",
                bundle: .module
            )
        case nil:
            String(
                localized: "privacyBadge.detail.unsupported",
                defaultValue: "This provider type isn't supported by this version of Kallilex.",
                bundle: .module
            )
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        PrivacyBadge(info: PrivacyBadgeInfo(profile: ProviderProfile(
            id: "1", name: "Local", kind: .appleOnDevice, baseUrl: "", model: ""
        )))
        PrivacyBadge(info: PrivacyBadgeInfo(profile: ProviderProfile(
            id: "2", name: "Mac", baseUrl: "http://localhost:11434/v1", model: "llama3"
        )))
        PrivacyBadge(info: PrivacyBadgeInfo(profile: ProviderProfile(
            id: "3", name: "Ollama", baseUrl: "http://your-mac.local:11434/v1", model: "llama3"
        )))
        PrivacyBadge(info: PrivacyBadgeInfo(profile: ProviderProfile(
            id: "4", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4-turbo"
        )))
    }
    .padding()
}
