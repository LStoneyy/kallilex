import SwiftUI
import KallilexKit

/// Prompt mode's action row badge (ios-18 spec, "A compact `PrivacyBadge`
/// in the action row"): the privacy icon plus a short kind label only — no
/// host, unlike the app's own `PrivacyBadge` ("Cloud: 100.127.106.115"),
/// which doesn't fit the 44 pt action row and was getting clipped. The
/// full text (the same one `PrivacyBadge`/`PrivacyBadgeInfo` shows) is
/// still exposed to VoiceOver via `accessibilityLabel`.
///
/// A separate view rather than a new mode on `PrivacyBadge` itself: this
/// never needs the popover/tap-for-detail behavior `PrivacyBadge`
/// (`interactive`) has, and the app's own badge is explicitly left alone.
/// "On device" (`PrivacyBadgeInfo.title` for `.onDevice`) is already
/// short enough to reuse as-is; `.local`/`.lan` are both shown as the new
/// "Local network" here — the action row has no room to distinguish "This
/// device" from "Your network", and prompt mode never needs to.
public struct KeyboardCompactPrivacyBadge: View {
    private let info: PrivacyBadgeInfo

    public init(profile: ProviderProfile) {
        self.info = PrivacyBadgeInfo(profile: profile)
    }

    public var body: some View {
        Label {
            Text(shortTitle)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: info.symbolName)
                .foregroundStyle(tintColor)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tintColor.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityIdentifier("provider.privacyBadge")
    }

    private var shortTitle: String {
        switch info.classification {
        case .onDevice:
            info.title
        case .local, .lan:
            String(
                localized: "keyboard.privacyBadge.localNetwork",
                defaultValue: "Local network",
                bundle: .module
            )
        case .cloud:
            String(localized: "keyboard.privacyBadge.cloud", defaultValue: "Cloud", bundle: .module)
        case nil:
            info.title
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
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        KeyboardCompactPrivacyBadge(profile: ProviderProfile(
            id: "1", name: "Local", kind: .appleOnDevice, baseUrl: "", model: ""
        ))
        KeyboardCompactPrivacyBadge(profile: ProviderProfile(
            id: "4", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4-turbo"
        ))
    }
    .padding()
}
