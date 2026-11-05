import SwiftUI
import KallilexKeyboardCore

/// Keys mode's 36 pt toolbar (PLAN-keyboard.md §5): the typing target
/// switch and ⌨ ✓ (back to prompt mode, `keyboard.mode.prompts`).
public struct KeyboardKeysToolbar: View {
    @Binding private var target: TypingTargetKind
    private let onShowPrompts: () -> Void

    public init(target: Binding<TypingTargetKind>, onShowPrompts: @escaping () -> Void) {
        self._target = target
        self.onShowPrompts = onShowPrompts
    }

    public var body: some View {
        HStack {
            KeyboardTargetSwitch(target: $target)
            Spacer()
            Button(action: onShowPrompts) {
                Text("⌨ ✓").font(.subheadline)
            }
            .frame(minWidth: 44, minHeight: 32)
            .accessibilityLabel(String(
                localized: "keyboard.showPrompts",
                defaultValue: "Show prompts",
                bundle: .module
            ))
            .accessibilityIdentifier("keyboard.mode.prompts")
        }
        .padding(.horizontal, 10)
    }
}

#Preview {
    KeyboardKeysToolbar(target: .constant(.scratchpad), onShowPrompts: {})
}
