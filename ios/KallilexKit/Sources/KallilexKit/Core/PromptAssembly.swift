import Foundation

/// A saved prompt's instruction, or a free-form custom instruction. Mirrors
/// the desktop's `Action` (`src-tauri/src/core/providers/mod.rs`).
public enum Action: Equatable, Sendable {
    case prompt(instruction: String)
    case custom(instruction: String)
}

/// Prompt assembly, a byte-for-byte port of `assemble_prompt`
/// (`src-tauri/src/core/providers/mod.rs`). The user's text always travels
/// as a separate user message — never folded into the system prompt built
/// here — so it can't be reinterpreted as instructions.
public enum PromptAssembly {
    /// The strict instruction every prompt ends with: models love to add
    /// preamble ("Here's the rewritten text:") or wrap the result in
    /// quotes, both of which would land verbatim in the source app on
    /// replace-back. This package can't read `contracts/` at runtime, so
    /// this is a string literal; `ReturnOnlyTextInstructionTests` asserts it
    /// matches `contracts/return-only-text-instruction.txt` byte-for-byte.
    public static let returnOnlyTextInstruction =
        "Return only the transformed text, with no preamble, commentary, "
        + "or surrounding quotes. Preserve the text's original language. "
        + "Preserve the text's structure and formatting exactly: keep "
        + "paragraph breaks, line breaks, list markers, indentation, and "
        + "any markup characters (e.g. Markdown) that appear in the input."

    /// Builds the system prompt for `action`.
    public static func systemPrompt(for action: Action) -> String {
        switch action {
        case .prompt(let instruction):
            return "\(instruction) \(returnOnlyTextInstruction)"
        case .custom(let instruction):
            return "Apply the following instruction to the user's text: "
                + "\(instruction) \(returnOnlyTextInstruction)"
        }
    }
}
