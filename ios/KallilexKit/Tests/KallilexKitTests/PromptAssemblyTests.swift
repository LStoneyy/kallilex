import Foundation
import Testing
import KallilexKit

/// Verifies `PromptAssembly` against `contracts/prompt-assembly.json` and
/// `contracts/return-only-text-instruction.txt`. See
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`.
struct PromptAssemblyTests {
    struct AssemblyCase: Decodable {
        let kind: String
        let instruction: String
        let expected: String
    }

    @Test func returnOnlyTextInstructionMatchesTheContractFixtureByteForByte() throws {
        let fixture = try ContractFixtures.text("return-only-text-instruction.txt")
        #expect(PromptAssembly.returnOnlyTextInstruction == fixture)
    }

    @Test func systemPromptMatchesTheContractFixture() throws {
        let cases = try ContractFixtures.decode("prompt-assembly.json", as: [AssemblyCase].self)
        #expect(!cases.isEmpty, "prompt-assembly.json must not be empty")

        for testCase in cases {
            let action: Action
            switch testCase.kind {
            case "prompt":
                action = .prompt(instruction: testCase.instruction)
            case "custom":
                action = .custom(instruction: testCase.instruction)
            default:
                Issue.record("prompt-assembly.json: unknown action kind \"\(testCase.kind)\"")
                continue
            }
            let assembled = PromptAssembly.systemPrompt(for: action)
            #expect(
                assembled == testCase.expected,
                "assembly mismatch for kind=\(testCase.kind) instruction=\(testCase.instruction)"
            )
        }
    }

    @Test func userTextIsNeverFoldedIntoTheSystemPrompt() {
        let prompt = PromptAssembly.systemPrompt(for: .custom(instruction: "Translate to French"))
        #expect(prompt.contains("Translate to French"))
        #expect(prompt.contains("Return only the transformed text"))
        #expect(!prompt.contains("Hello world"))
    }
}
