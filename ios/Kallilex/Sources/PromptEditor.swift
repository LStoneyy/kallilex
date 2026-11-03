import SwiftUI
import KallilexKit

/// The Add/Edit sheet for a single prompt (ios-06).
struct PromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PromptDraft
    let onSave: (CustomPrompt) -> Void

    init(draft: PromptDraft, onSave: @escaping (CustomPrompt) -> Void) {
        self._draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: "prompt.label.placeholder", defaultValue: "Prompt name"),
                        text: $draft.label
                    )
                    .accessibilityIdentifier("prompt.editor.label")

                    TextEditor(text: $draft.instruction)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("prompt.editor.instruction")
                        .overlay(alignment: .topLeading) {
                            if draft.instruction.isEmpty {
                                Text(String(
                                    localized: "prompt.instruction.placeholder",
                                    defaultValue: "What should Kallilex do?"
                                ))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                            }
                        }
                }

                if let error = draft.validationError {
                    Section {
                        Text(error.errorDescription ?? "")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(
                draft.id.isEmpty
                    ? String(localized: "prompt.add.title", defaultValue: "Add Prompt")
                    : String(localized: "prompt.edit.title", defaultValue: "Edit Prompt")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save", defaultValue: "Save")) {
                        onSave(draft.makePrompt())
                        dismiss()
                    }
                    .disabled(!draft.canSave)
                    .accessibilityIdentifier("prompt.editor.save")
                }
            }
        }
    }
}

#Preview {
    PromptEditor(draft: PromptDraft()) { _ in }
}
