import Foundation

/// The single validation failure a `PromptDraft` can have. Mirrors the
/// prompt editor's "prompt.validation.blank" copy (ios-06 spec).
public enum PromptDraftValidationError: Equatable, Sendable {
    /// The label and/or the instruction is blank after trimming.
    case blank
}

extension PromptDraftValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blank:
            return String(
                localized: "prompt.validation.blank",
                defaultValue: "Both label and instruction are required.",
                bundle: .module
            )
        }
    }
}

/// UI-free editing state for the prompt editor sheet (ios-06): backs the
/// label and instruction text fields, validates them, and builds a
/// `CustomPrompt` to pass to `SettingsService.savePrompt`.
public struct PromptDraft: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var instruction: String

    public init(id: String = "", label: String = "", instruction: String = "") {
        self.id = id
        self.label = label
        self.instruction = instruction
    }

    /// Starts a draft from an existing prompt, for editing.
    public init(editing prompt: CustomPrompt) {
        self.id = prompt.id
        self.label = prompt.label
        self.instruction = prompt.instruction
    }

    /// `.blank` when either field is blank after trimming whitespace and
    /// newlines; `nil` when both are non-blank.
    public var validationError: PromptDraftValidationError? {
        let labelBlank = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let instructionBlank = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (labelBlank || instructionBlank) ? .blank : nil
    }

    /// Whether the Save button should be enabled.
    public var canSave: Bool { validationError == nil }

    /// Builds the `CustomPrompt` to pass to `SettingsService.savePrompt`.
    /// An empty `id` lets the service generate one.
    public func makePrompt() -> CustomPrompt {
        CustomPrompt(id: id, label: label, instruction: instruction)
    }
}
