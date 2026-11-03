import Foundation
import Testing
import KallilexKit

/// Tests for `PromptDraft`'s validation. See
/// `issues-ios/spec-ios-06-container-app-settings.md`.
struct PromptDraftTests {
    @Test func bothFieldsBlankDisablesSave() {
        let draft = PromptDraft(label: "   ", instruction: "  \n ")
        #expect(draft.validationError == .blank)
        #expect(!draft.canSave)
    }

    @Test func onlyTheLabelBlankDisablesSave() {
        let draft = PromptDraft(label: "  ", instruction: "Do the thing")
        #expect(draft.validationError == .blank)
        #expect(!draft.canSave)
    }

    @Test func onlyTheInstructionBlankDisablesSave() {
        let draft = PromptDraft(label: "Rewrite", instruction: "   ")
        #expect(draft.validationError == .blank)
        #expect(!draft.canSave)
    }

    @Test func bothFieldsFilledEnablesSave() {
        let draft = PromptDraft(label: "Rewrite", instruction: "Rewrite the text")
        #expect(draft.validationError == nil)
        #expect(draft.canSave)
    }

    @Test func makePromptKeepsTheIdLabelAndInstruction() {
        let draft = PromptDraft(id: "abc", label: "Rewrite", instruction: "Rewrite the text")
        let prompt = draft.makePrompt()
        #expect(prompt.id == "abc")
        #expect(prompt.label == "Rewrite")
        #expect(prompt.instruction == "Rewrite the text")
    }

    @Test func editingAnExistingPromptCopiesItsFields() {
        let prompt = CustomPrompt(id: "x", label: "Shorten", instruction: "Make it shorter")
        let draft = PromptDraft(editing: prompt)
        #expect(draft.id == "x")
        #expect(draft.label == "Shorten")
        #expect(draft.instruction == "Make it shorter")
    }

    @Test func validationErrorHasALocalizedDescription() {
        let draft = PromptDraft(label: "", instruction: "")
        #expect(draft.validationError?.errorDescription != nil)
    }
}
