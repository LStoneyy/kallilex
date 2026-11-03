import Foundation
import Testing

/// Verifies `StubURLProtocol` itself fails closed: an unregistered URL
/// must never fall through to `URLSession`'s normal (real network)
/// handling — see `StubURLProtocol.canInit`'s doc comment.
struct StubURLProtocolTests {
    @Test func anUnregisteredURLFailsImmediatelyWithoutARealNetworkCall() async {
        let url = StubURLProtocol.uniqueBaseURL(path: "/never-stubbed")
        let session = StubURLProtocol.makeSession()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            _ = try await session.data(for: request)
            Issue.record("expected an error for an unregistered URL")
        } catch let error as URLError {
            #expect(error.code == .unsupportedURL)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        #expect(
            StubURLProtocol.recordedRequest(for: url) != nil,
            "the unregistered request should still be recorded by the stub, proving it never reached the network"
        )
    }
}
