import SwiftUI
import KallilexKeyboardCore

/// Keys mode's typing-target switch, "Scratchpad | App"
/// (PLAN-keyboard.md §6.2): a two-segment control, built from plain
/// `Button`s rather than a SwiftUI `Picker(.segmented)`, so each segment
/// reliably carries its own `accessibilityIdentifier`
/// (`keyboard.target.scratchpad` / `keyboard.target.app`) — a `Picker`'s
/// per-tag accessibility identifiers don't consistently attach to the
/// underlying `UISegmentedControl` segments it renders.
public struct KeyboardTargetSwitch: View {
    @Binding private var target: TypingTargetKind

    public init(target: Binding<TypingTargetKind>) {
        self._target = target
    }

    public var body: some View {
        HStack(spacing: 2) {
            segment(
                .scratchpad,
                title: String(localized: "keyboard.target.scratchpad", defaultValue: "Scratchpad", bundle: .module),
                identifier: "keyboard.target.scratchpad"
            )
            segment(
                .host,
                title: String(localized: "keyboard.target.app", defaultValue: "App", bundle: .module),
                identifier: "keyboard.target.app"
            )
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func segment(_ kind: TypingTargetKind, title: String, identifier: String) -> some View {
        let isSelected = target == kind
        return Button {
            target = kind
        } label: {
            Text(title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color(.systemBackground) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        // At least 44 pt wide (the accessibility audit's minimum hit-region
        // size), applied to the button itself (not just its label) so the
        // extra, otherwise-invisible space actually grows the tappable/
        // accessibility frame: the 36 pt toolbar row can't also grow this
        // tall, but a title as short as "App" would otherwise leave a hit
        // area far too narrow to tap reliably.
        .frame(minWidth: 44, minHeight: 28)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    KeyboardTargetSwitch(target: .constant(.scratchpad))
        .padding()
}
