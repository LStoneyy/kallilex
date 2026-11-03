import SwiftUI
import KallilexKit

/// The Prompts tab (ios-06): a reorderable, editable list of
/// `CustomPrompt`s, backed by `AppEnvironment.settings.prompts`.
struct PromptListView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var editingDraft: PromptDraft?
    @State private var promptPendingDelete: CustomPrompt?
    @State private var showRestoreDefaultsConfirmation = false

    private var prompts: [CustomPrompt] { appEnv.settings.prompts }

    var body: some View {
        Group {
            if prompts.isEmpty {
                ContentUnavailableView {
                    Label(
                        String(localized: "tab.prompts", defaultValue: "Prompts"),
                        systemImage: "text.quote"
                    )
                } description: {
                    Text(String(
                        localized: "prompt.empty.message",
                        defaultValue: "No prompts yet. Tap Add to create one."
                    ))
                }
                .accessibilityIdentifier("prompt.emptyState")
            } else {
                List {
                    ForEach(prompts) { prompt in
                        Button {
                            editingDraft = PromptDraft(editing: prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(prompt.label)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(prompt.instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("prompt.row.\(prompt.id)")
                        .swipeActions {
                            Button(role: .destructive) {
                                promptPendingDelete = prompt
                            } label: {
                                Label(String(localized: "action.delete", defaultValue: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        appEnv.perform { try $0.movePrompts(fromOffsets: offsets, toOffset: destination) }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "tab.prompts", defaultValue: "Prompts"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingDraft = PromptDraft()
                } label: {
                    Label(String(localized: "action.add", defaultValue: "Add"), systemImage: "plus")
                }
                .accessibilityIdentifier("prompt.add")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showRestoreDefaultsConfirmation = true
                } label: {
                    Label(
                        String(localized: "prompt.restoreDefaults", defaultValue: "Restore default prompts"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .accessibilityIdentifier("prompt.restoreDefaults")
            }
            if !prompts.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
        }
        .sheet(item: $editingDraft) { draft in
            PromptEditor(draft: draft) { saved in
                appEnv.perform { try $0.savePrompt(saved) }
            }
        }
        .alert(
            promptPendingDelete.map {
                String(localized: "prompt.delete.confirm.title", defaultValue: "Delete \($0.label)?")
            } ?? "",
            isPresented: Binding(
                get: { promptPendingDelete != nil },
                set: { isPresented in if !isPresented { promptPendingDelete = nil } }
            )
        ) {
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "action.delete", defaultValue: "Delete"), role: .destructive) {
                if let prompt = promptPendingDelete {
                    appEnv.perform { try $0.deletePrompt(id: prompt.id) }
                }
            }
        }
        .confirmationDialog(
            String(localized: "prompt.restoreDefaults.confirm.title", defaultValue: "Restore default prompts?"),
            isPresented: $showRestoreDefaultsConfirmation
        ) {
            Button(String(localized: "prompt.restoreDefaults.confirm.button", defaultValue: "Restore")) {
                appEnv.perform { try $0.restoreDefaultPrompts() }
            }
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }
}

#Preview {
    NavigationStack {
        PromptListView()
    }
}
