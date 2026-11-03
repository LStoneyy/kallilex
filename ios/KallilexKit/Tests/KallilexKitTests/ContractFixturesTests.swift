import Foundation
import Testing

/// Proves the `ContractFixtures` loader works: every fixture file exists,
/// is non-empty, and (for the JSON ones) decodes into a schema mirroring
/// its shape. Does **not** assert anything about `KallilexKit` logic —
/// those assertions land in ios-05, once the Swift ports of prompt
/// assembly, privacy classification and the OpenAI provider exist. See
/// `issues-ios/spec-ios-03-contract-fixtures.md`.
struct ContractFixturesTests {
    // ---- fixture-schema structs (test-only, mirror the JSON shapes) -----

    /// Mirrors `contracts/default-prompts.json`.
    struct FixturePrompt: Decodable {
        let id: String
        let label: String
        let instruction: String
    }

    /// Mirrors `contracts/prompt-assembly.json`.
    struct AssemblyCase: Decodable {
        let kind: String
        let instruction: String
        let expected: String
    }

    /// Mirrors `contracts/privacy-classification.json`. `expected` is
    /// `nil` for unparseable URLs.
    struct PrivacyCase: Decodable {
        let baseUrl: String
        let expected: String?
    }

    /// Mirrors `contracts/openai-endpoint.json`.
    struct EndpointCase: Decodable {
        let baseUrl: String
        let expected: String?
        let shouldError: Bool?
        let errorKind: String?
    }

    /// Mirrors a `customHeaders` entry in `contracts/openai-request.json`.
    struct HeaderFixture: Decodable {
        let name: String
        let value: String
    }

    /// Mirrors a chat-completion request body's shape, as used by
    /// `expectedBody` in `contracts/openai-request.json`.
    struct ExpectedBody: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    /// Mirrors `contracts/openai-request.json`.
    struct RequestCase: Decodable {
        let name: String
        let baseUrl: String
        let model: String
        let apiKey: String?
        let customHeaders: [HeaderFixture]?
        let systemPrompt: String
        let userText: String
        let expectedBody: ExpectedBody?
        let expectedHeaders: [String: String]?
        let expectedAbsentHeaders: [String]?
        let expectedErrorKind: String?
        let expectNoRequest: Bool?
    }

    /// Mirrors `contracts/openai-response.json`.
    struct ResponseCase: Decodable {
        let name: String
        let status: Int
        let body: String
        let expectedText: String?
        let shouldError: Bool?
        let errorKind: String?
        let errorMessageContains: String?
        let expectedStatus: Int?
        let expectedSnippetChars: Int?
        let description: String?
    }

    // ---- existence / non-emptiness ---------------------------------------

    @Test(
        "Every contract fixture file exists and is non-empty",
        arguments: [
            "default-prompts.json",
            "return-only-text-instruction.txt",
            "prompt-assembly.json",
            "privacy-classification.json",
            "openai-endpoint.json",
            "openai-request.json",
            "openai-response.json",
        ]
    )
    func fixtureFileExistsAndIsNonEmpty(name: String) throws {
        let data = try ContractFixtures.data(name)
        #expect(!data.isEmpty, "\(name) should not be empty")
    }

    // ---- JSON fixtures decode into their schema structs ------------------

    @Test("default-prompts.json decodes into the expected schema")
    func defaultPromptsDecodes() throws {
        let prompts = try ContractFixtures.decode(
            "default-prompts.json",
            as: [FixturePrompt].self
        )
        #expect(!prompts.isEmpty)
        #expect(prompts.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty && !$0.instruction.isEmpty })
    }

    @Test("prompt-assembly.json decodes into the expected schema")
    func promptAssemblyDecodes() throws {
        let cases = try ContractFixtures.decode("prompt-assembly.json", as: [AssemblyCase].self)
        #expect(!cases.isEmpty)
        #expect(cases.allSatisfy { ["prompt", "custom"].contains($0.kind) })
    }

    @Test("privacy-classification.json decodes into the expected schema")
    func privacyClassificationDecodes() throws {
        let cases = try ContractFixtures.decode(
            "privacy-classification.json",
            as: [PrivacyCase].self
        )
        #expect(!cases.isEmpty)
        // At least one case must exercise the "unparseable URL" (`null`)
        // path, and at least one must be a real classification.
        #expect(cases.contains { $0.expected == nil })
        #expect(cases.contains { $0.expected != nil })
    }

    @Test("openai-endpoint.json decodes into the expected schema")
    func openAiEndpointDecodes() throws {
        let cases = try ContractFixtures.decode("openai-endpoint.json", as: [EndpointCase].self)
        #expect(!cases.isEmpty)
        #expect(cases.contains { $0.shouldError == true })
        #expect(cases.contains { $0.shouldError != true })
    }

    @Test("openai-request.json decodes into the expected schema")
    func openAiRequestDecodes() throws {
        let cases = try ContractFixtures.decode("openai-request.json", as: [RequestCase].self)
        #expect(!cases.isEmpty)
        #expect(cases.contains { $0.expectNoRequest == true })
        #expect(cases.contains { $0.expectedBody != nil })
    }

    @Test("openai-response.json decodes into the expected schema")
    func openAiResponseDecodes() throws {
        let cases = try ContractFixtures.decode("openai-response.json", as: [ResponseCase].self)
        #expect(!cases.isEmpty)
        #expect(cases.contains { $0.shouldError == true })
        #expect(cases.contains { $0.expectedText != nil })
    }

    // ---- fixture-internal consistency checks ------------------------------

    @Test("the HTTP 500 fixture body is exactly 400 characters")
    func http500BodyIsExactly400Characters() throws {
        let cases = try ContractFixtures.decode("openai-response.json", as: [ResponseCase].self)
        let case500 = try #require(cases.first { $0.name == "HTTP 500 error" })
        #expect(case500.body.count == 400)
    }

    @Test(
        "the instruction .txt fixture matches the suffix of the first prompt-assembly expectation"
    )
    func instructionTextFixtureMatchesPromptAssemblySuffix() throws {
        let instruction = try ContractFixtures.text("return-only-text-instruction.txt")
        let cases = try ContractFixtures.decode("prompt-assembly.json", as: [AssemblyCase].self)
        let first = try #require(cases.first)

        #expect(first.expected.hasSuffix(instruction))
        #expect(first.expected == "\(first.instruction) \(instruction)")
    }
}
