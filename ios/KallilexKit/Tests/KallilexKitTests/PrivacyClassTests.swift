import Foundation
import Testing
import KallilexKit

/// Verifies `classifyPrivacy(baseUrl:)` against
/// `contracts/privacy-classification.json`, and `privacyClass(for:)`'s
/// handling of the non-`openAICompatible` kinds. See
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`.
struct PrivacyClassTests {
    struct PrivacyCase: Decodable {
        let baseUrl: String
        let expected: String?
    }

    @Test func classifyPrivacyMatchesTheContractFixture() throws {
        let cases = try ContractFixtures.decode("privacy-classification.json", as: [PrivacyCase].self)
        #expect(!cases.isEmpty, "privacy-classification.json must not be empty")

        for testCase in cases {
            let actual = classifyPrivacy(baseUrl: testCase.baseUrl).map { (klass: PrivacyClass) -> String in
                klass.rawValue
            }
            #expect(
                actual == testCase.expected,
                "classification mismatch for \(testCase.baseUrl.debugDescription)"
            )
        }
    }

    @Test func profileOfKindAppleOnDeviceIsAlwaysOnDevice() {
        let profile = ProviderProfile(
            id: "a",
            name: "Apple",
            kind: .appleOnDevice,
            baseUrl: "",
            model: ""
        )
        #expect(privacyClass(for: profile) == .onDevice)
    }

    @Test func profileOfUnknownKindHasNoPrivacyClass() {
        let profile = ProviderProfile(
            id: "a",
            name: "Mystery",
            kind: .unknown("applePrivateCloud"),
            baseUrl: "https://example.com/v1",
            model: "m"
        )
        #expect(privacyClass(for: profile) == nil)
    }

    @Test func profileOfKindOpenAICompatibleDelegatesToClassifyPrivacy() {
        let profile = ProviderProfile(
            id: "a",
            name: "Local",
            kind: .openAICompatible,
            baseUrl: "http://localhost:11434/v1",
            model: "m"
        )
        #expect(privacyClass(for: profile) == .local)
    }

    // MARK: - Foundation-vs-`url`-crate quirks (regression lock, not contract behavior)
    //
    // These four cases aren't in `privacy-classification.json`: they pin
    // down how Foundation's `URL`/`IPv4Address`/`IPv6Address` parse a few
    // edge-case hosts, which may or may not match what Rust's `url` crate
    // and `std::net` do for the same string — that hasn't been verified
    // against the desktop core, and isn't the contract's job to arbitrate.
    // What *is* verified here is the safety direction: every known
    // divergence below errs toward `.cloud` (consent required), never
    // toward `.local`/`.lan` (which would silently skip a consent check
    // that should have been required).

    @Test func aTrailingDotAfterAnIPv4LiteralIsNotRecognizedAsLoopback() {
        // Foundation keeps the trailing dot in the parsed host
        // ("127.0.0.1."), which `IPv4Address` then refuses to parse as an
        // address at all, so this falls through to the domain-suffix path
        // and comes out `.cloud` instead of `.local`. Safe direction: it
        // demands consent for a URL that arguably shouldn't have needed
        // any, never the reverse.
        #expect(classifyPrivacy(baseUrl: "http://127.0.0.1./v1") == .cloud)
    }

    @Test func aLeadingZeroInAnIPv4OctetIsReadAsDecimalNotOctal() {
        // `IPv4Address("09.0.0.1")` reads "09" as decimal 9, not octal
        // (9 isn't even a valid octal digit). That lands in 9.0.0.0/8, a
        // real public block, so this is `.cloud` either way — whether
        // Swift parses it as the IP 9.0.0.1 or (if it had failed to
        // parse) fell through to the domain path, which would also reject
        // it as a `.local`/`.lan` suffix and land on `.cloud`. Locked in
        // for the parse path, not because there's a riskier alternative
        // outcome here.
        #expect(classifyPrivacy(baseUrl: "http://09.0.0.1/v1") == .cloud)
    }

    @Test func aZoneIdOnALinkLocalIPv6HostDoesNotChangeItsClassification() {
        // The zone id (`%en0`, percent-escaped as `%25en0` in the URL) is
        // parsed and dropped by `IPv6Address`, leaving the real `fe80::1`
        // bytes behind — correctly still `.lan`.
        #expect(classifyPrivacy(baseUrl: "http://[fe80::1%25en0]/v1") == .lan)
    }

    @Test func aZoneIdOnAPublicIPv6HostDoesNotChangeItsClassification() {
        // Same zone-id handling, on a real public address (Google DNS) —
        // correctly still `.cloud`.
        #expect(classifyPrivacy(baseUrl: "http://[2001:4860:4860::8888%25en0]/v1") == .cloud)
    }
}
