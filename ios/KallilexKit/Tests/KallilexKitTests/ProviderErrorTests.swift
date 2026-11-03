import Testing
import KallilexKit

/// Tests for `ProviderError`'s `kind` discriminant and its `LocalizedError`
/// conformance. See
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`.
struct ProviderErrorTests {
    @Test func kindMatchesTheDesktopStringsForTheSharedCases() {
        #expect(ProviderError.unreachable("x").kind == "unreachable")
        #expect(ProviderError.timeout(30).kind == "timeout")
        #expect(ProviderError.http(status: 500, snippet: "boom").kind == "http")
        #expect(ProviderError.missingModel.kind == "missingModel")
        #expect(ProviderError.invalidBaseUrl("bad").kind == "invalidBaseUrl")
        #expect(ProviderError.invalidResponse("weird").kind == "invalidResponse")
    }

    @Test func kindCoversTheIOSOnlyCases() {
        #expect(ProviderError.unavailable(reason: "r").kind == "unavailable")
        #expect(ProviderError.contextTooLong.kind == "contextTooLong")
        #expect(ProviderError.declined.kind == "declined")
        #expect(ProviderError.localNetworkDenied.kind == "localNetworkDenied")
    }

    @Test func everyCaseHasAnActionableNonEmptyDescription() {
        let cases: [ProviderError] = [
            .unreachable("the server refused the connection"),
            .timeout(30),
            .http(status: 500, snippet: "boom"),
            .missingModel,
            .invalidBaseUrl("not a url"),
            .invalidResponse("invalid JSON"),
            .unavailable(reason: "Apple on-device AI isn't available yet."),
            .contextTooLong,
            .declined,
            .localNetworkDenied,
        ]
        for error in cases {
            let description = error.errorDescription
            #expect(description != nil, "\(error.kind) has no errorDescription")
            #expect(description != "failed", "\(error.kind)'s description must be actionable, not \"failed\"")
            #expect(!(description ?? "").isEmpty, "\(error.kind) has an empty description")
        }
    }

    @Test func dynamicDetailsAppearInTheDescription() {
        #expect(ProviderError.unreachable("boom").errorDescription?.contains("boom") == true)
        #expect(ProviderError.timeout(42).errorDescription?.contains("42") == true)
        let http = ProviderError.http(status: 503, snippet: "service unavailable")
        #expect(http.errorDescription?.contains("503") == true)
        #expect(http.errorDescription?.contains("service unavailable") == true)
        #expect(ProviderError.invalidBaseUrl("ftp://x").errorDescription?.contains("ftp://x") == true)
        #expect(ProviderError.invalidResponse("invalid JSON: x").errorDescription?.contains("invalid JSON: x") == true)
        #expect(ProviderError.unavailable(reason: "custom reason").errorDescription == "custom reason")
    }
}
