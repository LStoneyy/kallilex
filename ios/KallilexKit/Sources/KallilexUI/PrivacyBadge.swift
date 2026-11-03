import SwiftUI
import KallilexKit

/// A small badge showing a provider's privacy class (ios-06): "On device",
/// "This device", "Your network", or "Cloud: <host>". Shared between the
/// container app's Providers tab (this spec) and, later, the Share
/// Extension (ios-09).
///
/// `interactive` (default `true`) controls whether tapping it shows a
/// longer explanation in a popover. Pass `false` inside another tappable
/// row (e.g. `ProviderListView`'s row `Button`) — a `Button` nested inside
/// another `Button`'s label is an anti-pattern: taps anywhere in the outer
/// row, even well outside the badge's own frame, get misrouted to the
/// inner badge instead of the row's own action (verified empirically while
/// building ios-06's XCUITests). The provider editor, which doesn't nest
/// this inside another button, keeps the interactive form.
public struct PrivacyBadge: View {
    private let info: PrivacyBadgeInfo
    private let interactive: Bool
    @State private var showDetail = false

    public init(info: PrivacyBadgeInfo, interactive: Bool = true) {
        self.info = info
        self.interactive = interactive
    }

    public init(profile: ProviderProfile, interactive: Bool = true) {
        self.info = PrivacyBadgeInfo(profile: profile)
        self.interactive = interactive
    }

    public var body: some View {
        if interactive {
            Button {
                showDetail = true
            } label: {
                badgeLabel
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
        } else {
            badgeLabel
                .accessibilityLabel(info.accessibilityLabel)
                .accessibilityIdentifier("provider.privacyBadge")
        }
    }

    private var badgeLabel: some View {
        Label(info.title, systemImage: info.symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tintColor)
            .background(tintColor.opacity(0.15), in: Capsule())
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
