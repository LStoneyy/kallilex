import SwiftUI
import KallilexKit

/// The Full Access card (ios-19 part B, "Full Access card"): shown inside
/// prompt mode's expanded panel (`KeyboardModel.isPanelExpanded`) instead
/// of the chips, either pre-emptively (a network profile's chip was
/// tapped without Full Access) or as the post-run fallback (a run failed
/// the way it always does without Full Access: no network, or no
/// Keychain access). Explains what still works without Full Access and
/// offers a path to Settings — never an "Open Kallilex" button, since this
/// isn't about the app itself (4.4.1).
public struct KeyboardFullAccessCard: View {
    private let onOpenSettings: () -> Void
    private let onDismiss: () -> Void

    public init(onOpenSettings: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(String(
                    localized: "keyboard.fullAccessCard.body",
                    defaultValue: "Prompts need Full Access to reach your AI provider. Typing, Insert and dictation work without it.",
                    bundle: .module
                ))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(String(
                    localized: "keyboard.fullAccessCard.dismiss.label",
                    defaultValue: "Dismiss",
                    bundle: .module
                ))
                .accessibilityIdentifier("keyboard.fullAccessCard.dismiss")
            }

            Text(String(
                localized: "keyboard.fullAccessCard.footnote",
                defaultValue: "Settings → General → Keyboard → Keyboards → Kallilex → Allow Full Access",
                bundle: .module
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(String(localized: "keyboard.fullAccessCard.settings", defaultValue: "Settings", bundle: .module)) {
                onOpenSettings()
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("keyboard.fullAccessCard.settings")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard.fullAccessCard")
    }
}

#Preview {
    KeyboardFullAccessCard(onOpenSettings: {}, onDismiss: {})
        .frame(height: 200)
}
