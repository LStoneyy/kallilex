import Testing
import KallilexKit

/// Unit tests for `consentHost(for:)`. See
/// `issues-ios/spec-ios-04-models-and-stores.md`.
struct ConsentHostTests {
    func profile(baseUrl: String) -> ProviderProfile {
        ProviderProfile(id: "p1", name: "P", baseUrl: baseUrl, model: "m")
    }

    @Test func returnsTheLowercasedHost() {
        #expect(consentHost(for: profile(baseUrl: "http://Example.COM/v1")) == "example.com")
    }

    @Test func dropsATrailingDot() {
        #expect(consentHost(for: profile(baseUrl: "http://example.com./v1")) == "example.com")
    }

    @Test func isNilForAnUnparseableBaseUrl() {
        #expect(consentHost(for: profile(baseUrl: "not a url")) == nil)
    }

    @Test func isNilForAUrlWithNoHost() {
        #expect(consentHost(for: profile(baseUrl: "file:///tmp/x")) == nil)
    }

    @Test func ignoresThePort() {
        // Only the host participates in a consent host — a port-only
        // change (e.g. Ollama moving from :11434 to :11435) must not
        // invalidate consent.
        let a = consentHost(for: profile(baseUrl: "http://localhost:11434/v1"))
        let b = consentHost(for: profile(baseUrl: "http://localhost:11435/v1"))
        #expect(a == b)
        #expect(a == "localhost")
    }

    @Test func ignoresThePath() {
        let a = consentHost(for: profile(baseUrl: "http://api.example.com/v1"))
        let b = consentHost(for: profile(baseUrl: "http://api.example.com/v2/chat"))
        #expect(a == b)
    }

    @Test func differsForDifferentHosts() {
        let a = consentHost(for: profile(baseUrl: "http://localhost:11434/v1"))
        let b = consentHost(for: profile(baseUrl: "http://api.openai.com/v1"))
        #expect(a != b)
    }
}
