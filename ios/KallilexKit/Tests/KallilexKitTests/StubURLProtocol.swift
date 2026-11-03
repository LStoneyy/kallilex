import Foundation
import Synchronization

/// A `URLProtocol` stub that serves canned responses (or simulated
/// `URLError`s) for exact-URL matches, so `OpenAICompatibleProvider` tests
/// never make a real network request.
///
/// Swift 6 safe: no unsynchronized static mutable state — the registry
/// lives behind a `Mutex` (`Synchronization`), same as the package's own
/// in-memory store fakes.
///
/// Safe under Swift Testing's parallel execution: every test that needs a
/// stub calls `uniqueBaseURL(path:)` to get its own, randomly-hosted base
/// URL, so two tests' registry entries can never collide, key on the same
/// `URL`, or race each other's `reset()` — there's no need to serialize
/// these tests into one suite.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct CannedResponse: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var errorCode: URLError.Code?
        /// When `true`, `startLoading()` never signals completion at all —
        /// it just sits there until the request is cancelled (e.g. by
        /// `sendWithDeadline`'s total-deadline race, or by the caller's own
        /// `Task` cancellation), for deterministically testing both of
        /// those without a real server that's merely slow.
        var hang: Bool = false
    }

    struct RecordedRequest: Sendable {
        var headers: [String: String]
        var body: Data?
    }

    private static let registry = Mutex<[URL: CannedResponse]>([:])
    private static let recorded = Mutex<[URL: RecordedRequest]>([:])

    static func stub(
        _ url: URL,
        statusCode: Int = 200,
        body: Data = Data(),
        errorCode: URLError.Code? = nil,
        hang: Bool = false
    ) {
        registry.withLock {
            $0[url] = CannedResponse(statusCode: statusCode, body: body, errorCode: errorCode, hang: hang)
        }
    }

    static func recordedRequest(for url: URL) -> RecordedRequest? {
        recorded.withLock { $0[url] }
    }

    /// A URLSession wired to this protocol only, via an ephemeral
    /// configuration — no cache, no cookies, no real network access.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A base URL with a unique, never-reused host, so a test's stub
    /// registration can never collide with another test's. `path` mirrors
    /// a contract fixture's `baseUrl` path (e.g. `/v1`), trailing slash and
    /// all, so endpoint-trimming behavior is exercised exactly as the
    /// fixture intends.
    static func uniqueBaseURL(path: String = "/v1") -> URL {
        URL(string: "https://stub-\(UUID().uuidString).example\(path)")!
    }

    /// Always `true`: this protocol must fail *closed*. If `canInit`
    /// returned `false` for an unregistered URL, `URLSession` would fall
    /// through to its normal handling for that request — i.e. a real
    /// network call — defeating the entire point of stubbing. Returning
    /// `true` unconditionally means every request this session makes is
    /// guaranteed to end up in `startLoading()` below, where an
    /// unregistered URL fails immediately instead of ever reaching the
    /// network.
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        // Recorded unconditionally — including for an unregistered URL —
        // so a test can assert "this exact request was captured by the
        // stub" as proof that no real network call happened.
        Self.recorded.withLock {
            $0[url] = RecordedRequest(
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.body(of: request)
            )
        }

        guard let canned = Self.registry.withLock({ $0[url] }) else {
            // Fail closed with a distinctive, recognizable error rather
            // than silently succeeding or falling through to the network.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        if canned.hang {
            // Deliberately never call back into `client` — this request
            // just sits here until `stopLoading()` is called (i.e. until
            // whoever is awaiting it is cancelled).
            return
        }

        if let errorCode = canned.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: canned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLRequest.httpBody` is `nil` for a request that arrives via
    /// `httpBodyStream` instead (which `URLSession.data(for:)` sometimes
    /// uses internally) — read that stream to capture the body either way.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
