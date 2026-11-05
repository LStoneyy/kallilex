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
            .buttonStyle(.plain)
            // Fills the full 36 pt toolbar row's height exactly (rather
            // than a smaller `minHeight` that SwiftUI would otherwise
            // compress/clip down when it conflicts with the fixed-height
            // UIKit container the toolbar is hosted in — found by this
            // file's own accessibility audit test): at least 44 pt wide,
            // the full row tall, with the whole frame tappable.
            .frame(minWidth: 44, minHeight: 36)
            .contentShape(Rectangle())
            .accessibilityLabel(String(
                localized: "keyboard.showPrompts",
                defaultValue: "Show prompts",
                bundle: .module
            ))
            .accessibilityIdentifier("keyboard.mode.prompts")
        }
        .padding(.horizontal, 10)
        // Matches the 36 pt UIKit height this is always hosted at
        // (`KallilexKeyboardController.keysModeConstraints`) exactly, so
        // SwiftUI never has to guess a height and then clip/compress a
        // child's own `.frame(minHeight:)` down below what it asked for.
        .frame(height: 36)
    }
}

#Preview {
    KeyboardKeysToolbar(target: .constant(.scratchpad), onShowPrompts: {})
}
