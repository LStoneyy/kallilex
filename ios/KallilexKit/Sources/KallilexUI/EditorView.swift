import SwiftUI

/// The full-height text editor shared by the Scratchpad tab and the Share
/// Extension (ios-08). Bound to `EditorSession.displayedText`/`isEditable`
/// at the call site rather than to the session itself, so this view stays
/// free of any `KallilexKit` dependency.
public struct EditorView: View {
    @Binding private var text: String
    private let isEditable: Bool
    private let isFocused: FocusState<Bool>.Binding?

    /// - Parameter isFocused: optional focus binding applied directly to
    ///   the `TextEditor`, so the caller can dismiss the keyboard.
    public init(
        text: Binding<String>,
        isEditable: Bool = true,
        isFocused: FocusState<Bool>.Binding? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.isFocused = isFocused
    }

    public var body: some View {
        if let isFocused {
            editor.focused(isFocused)
        } else {
            editor
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.body)
            .lineSpacing(2)
            .disabled(!isEditable)
            .accessibilityLabel(String(localized: "editor.label", defaultValue: "Text", bundle: .module))
            .accessibilityIdentifier("editor.textEditor")
    }
}

#Preview {
    EditorView(text: .constant("Some text to edit."))
}
