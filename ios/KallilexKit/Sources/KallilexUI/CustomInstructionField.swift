import SwiftUI

/// A one-line field for a free-form instruction, shown when the "Custom…"
/// chip in `PromptChipsBar` is tapped (ios-08). Submitting (Return) runs the
/// instruction and clears the field; it stays visible but empty otherwise,
/// so the user can immediately type another custom instruction.
public struct CustomInstructionField: View {
    @Binding private var text: String
    private let isDisabled: Bool
    private let onSubmit: (String) -> Void

    public init(
        text: Binding<String>,
        isDisabled: Bool = false,
        onSubmit: @escaping (String) -> Void
    ) {
        self._text = text
        self.isDisabled = isDisabled
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(
            String(localized: "prompt.custom.placeholder", defaultValue: "Custom instruction…", bundle: .module),
            text: $text
        )
        .textFieldStyle(.roundedBorder)
        .submitLabel(.return)
        .disabled(isDisabled)
        .accessibilityIdentifier("editor.customField")
        .onSubmit {
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            onSubmit(instruction)
            text = ""
        }
    }
}

#Preview {
    CustomInstructionField(text: .constant(""), onSubmit: { _ in })
        .padding()
}
