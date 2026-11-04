import Foundation
import Synchronization
import Testing
import KallilexKit

/// Verifies `OpenAICompatibleProvider` against `contracts/openai-endpoint.json`,
/// `contracts/openai-request.json`, `contracts/openai-response.json`, and
/// the `URLError` mapping rules from
/// `issues-ios/spec-ios-05-core-logic-and-openai-provider.md`. Every test
/// talks to `StubURLProtocol`, never the real network.
struct OpenAICompatibleProviderTests {
    // MARK: - Helpers

    /// Replaces `original`'s host with a fresh, unique one and drops its
    /// port, keeping the scheme and path (trailing slash included) intact
    /// — so a test can stub a real-looking fixture URL without ever
    /// touching the network or colliding with another test's stub.
    func substitutedBaseURL(from original: String) -> String? {
        guard var components = URLComponents(string: original) else { return nil }
        components.host = "stub-\(UUID().uuidString).example"
        components.port = nil
        return components.string
    }

    /// Mirrors `OpenAICompatibleProvider.endpointURL(for:)`'s trimming
    /// rule, applied independently here so the test isn't just checking
    /// production code against itself.
    func expectedEndpoint(from baseUrl: String) -> URL {
        var trimmed = baseUrl
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: "\(trimmed)/chat/completions")!
    }

    func successBody(_ content: String) -> Data {
        let json: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func makeProfile(
        baseUrl: String,
        model: String = "test-model",
        customHeaders: [HeaderEntry] = [],
        timeoutSecs: Int = 30
    ) -> ProviderProfile {
        ProviderProfile(
            id: "p1",
            name: "Test",
            baseUrl: baseUrl,
            model: model,
            timeoutSecs: timeoutSecs,
            customHeaders: customHeaders
        )
    }

    func makeProvider(
        profile: ProviderProfile,
        apiKey: String? = nil,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            profile: profile,
            apiKey: apiKey,
            session: StubURLProtocol.makeSession(),
            deadlineSleep: deadlineSleep
        )
    }

    /// Polls (via `Task.yield()`, not a real sleep) until `StubURLProtocol`
    /// has recorded a request at `endpoint`, so a test can be sure the
    /// request actually reached the stub — and so production code actually
    /// started a data task — before doing something time-sensitive like
    /// cancelling the caller. `timeout` is only a hang guard, generous
    /// enough to never fire in a passing run; it is not a correctness bound.
    func waitUntilRequestIsRecorded(
        at endpoint: URL,
        timeout: Duration = .seconds(20)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while StubURLProtocol.recordedRequest(for: endpoint) == nil {
            if clock.now >= deadline {
                Issue.record("timed out waiting for the stubbed request at \(endpoint) to be recorded")
                return
            }
            await Task.yield()
        }
    }

    /// A deadline sleeper that never completes on its own — it only
    /// resumes if its `Task` is cancelled, in which case it throws
    /// `CancellationError` like a real `Task.sleep` would. Used to prove
    /// "the real response won, not the deadline" and "caller cancellation
    /// wins, not the deadline" without ever depending on how long a real
    /// timer would take to fire. Swift 6-clean: all mutable state lives
    /// behind a `Mutex`, mirroring `OpenAICompatibleProvider.DeadlineRace`'s
    /// own pattern for the same "exactly one resume, from any thread"
    /// problem.
    final class NeverFiringSleeper: @unchecked Sendable {
        private struct State {
            var cancelled = false
            var continuation: CheckedContinuation<Void, Error>?
        }

        private let state = Mutex(State())

        var sleep: @Sendable (Duration) async throws -> Void {
            { _ in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let resumeNow = self.state.withLock { s -> Bool in
                            if s.cancelled { return true }
                            s.continuation = continuation
                            return false
                        }
                        if resumeNow {
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                } onCancel: {
                    let continuation = self.state.withLock { s -> CheckedContinuation<Void, Error>? in
                        s.cancelled = true
                        let c = s.continuation
                        s.continuation = nil
                        return c
                    }
                    continuation?.resume(throwing: CancellationError())
                }
            }
        }
    }

    // MARK: - openai-endpoint.json

    struct EndpointCase: Decodable {
        let baseUrl: String
        let expected: String?
        let shouldError: Bool?
        let errorKind: String?
    }

    @Test func endpointBuildingMatchesTheContractFixture() async throws {
        let cases = try ContractFixtures.decode("openai-endpoint.json", as: [EndpointCase].self)
        #expect(!cases.isEmpty, "openai-endpoint.json must not be empty")

        for testCase in cases {
            let provider = makeProvider(profile: makeProfile(baseUrl: testCase.baseUrl))

            if testCase.shouldError == true {
                do {
                    _ = try await provider.complete(systemPrompt: "s", userText: "u")
                    Issue.record("\(testCase.baseUrl): expected an error")
                } catch let error as ProviderError {
                    #expect(error.kind == testCase.errorKind, "\(testCase.baseUrl)")
                } catch {
                    Issue.record("\(testCase.baseUrl): unexpected error \(error)")
                }
                continue
            }

            guard let substituted = substitutedBaseURL(from: testCase.baseUrl) else {
                Issue.record("\(testCase.baseUrl): could not substitute a test host")
                continue
            }
            let endpoint = expectedEndpoint(from: substituted)
            StubURLProtocol.stub(endpoint, body: successBody("ok"))

            let liveProvider = makeProvider(profile: makeProfile(baseUrl: substituted))
            let result = try await liveProvider.complete(systemPrompt: "s", userText: "u")
            #expect(result == "ok", "\(testCase.baseUrl)")
            #expect(
                StubURLProtocol.recordedRequest(for: endpoint) != nil,
                "\(testCase.baseUrl): expected a request at \(endpoint)"
            )
        }
    }

    // MARK: - openai-request.json

    struct RequestFixtureCase {
        let name: String
        let baseUrl: String
        let model: String
        let apiKey: String?
        let customHeaders: [HeaderEntry]
        let systemPrompt: String
        let userText: String
        let expectedBody: [String: Any]?
        let expectedHeaders: [String: String]
        let expectedAbsentHeaders: [String]
        let expectedErrorKind: String?
        let expectNoRequest: Bool
    }

    func loadRequestCases() throws -> [RequestFixtureCase] {
        let data = try ContractFixtures.data("openai-request.json")
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ContractFixtures.LookupError(description: "openai-request.json is not an array of objects")
        }
        return raw.map { dict in
            let headersRaw = dict["customHeaders"] as? [[String: Any]] ?? []
            let headers = headersRaw.map {
                HeaderEntry(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "")
            }
            return RequestFixtureCase(
                name: dict["name"] as? String ?? "",
                baseUrl: dict["baseUrl"] as? String ?? "",
                model: dict["model"] as? String ?? "",
                apiKey: dict["apiKey"] as? String,
                customHeaders: headers,
                systemPrompt: dict["systemPrompt"] as? String ?? "",
                userText: dict["userText"] as? String ?? "",
                expectedBody: dict["expectedBody"] as? [String: Any],
                expectedHeaders: dict["expectedHeaders"] as? [String: String] ?? [:],
                expectedAbsentHeaders: dict["expectedAbsentHeaders"] as? [String] ?? [],
                expectedErrorKind: dict["expectedErrorKind"] as? String,
                expectNoRequest: dict["expectNoRequest"] as? Bool ?? false
            )
        }
    }

    @Test func requestsMatchTheContractFixture() async throws {
        let cases = try loadRequestCases()
        #expect(!cases.isEmpty, "openai-request.json must not be empty")

        for testCase in cases {
            if testCase.expectNoRequest {
                let profile = makeProfile(
                    baseUrl: testCase.baseUrl,
                    model: testCase.model,
                    customHeaders: testCase.customHeaders
                )
                let provider = makeProvider(profile: profile, apiKey: testCase.apiKey)
                do {
                    _ = try await provider.complete(systemPrompt: testCase.systemPrompt, userText: testCase.userText)
                    Issue.record("\(testCase.name): expected an error")
                } catch let error as ProviderError {
                    #expect(error.kind == testCase.expectedErrorKind, "\(testCase.name)")
                } catch {
                    Issue.record("\(testCase.name): unexpected error \(error)")
                }
                continue
            }

            guard let substituted = substitutedBaseURL(from: testCase.baseUrl) else {
                Issue.record("\(testCase.name): could not substitute a test host")
                continue
            }
            let endpoint = expectedEndpoint(from: substituted)
            StubURLProtocol.stub(endpoint, body: successBody("ok"))

            let profile = makeProfile(
                baseUrl: substituted,
                model: testCase.model,
                customHeaders: testCase.customHeaders
            )
            let provider = makeProvider(profile: profile, apiKey: testCase.apiKey)
            let result = try await provider.complete(systemPrompt: testCase.systemPrompt, userText: testCase.userText)
            #expect(result == "ok", "\(testCase.name)")

            let recorded = try #require(
                StubURLProtocol.recordedRequest(for: endpoint),
                "\(testCase.name): expected a request at \(endpoint)"
            )

            if let expectedBody = testCase.expectedBody {
                let bodyData = try #require(recorded.body, "\(testCase.name): missing request body")
                let actualBody = try JSONSerialization.jsonObject(with: bodyData) as? NSDictionary
                #expect(actualBody == (expectedBody as NSDictionary), "\(testCase.name)")
            }

            for (name, value) in testCase.expectedHeaders {
                #expect(recorded.headers[name] == value, "\(testCase.name): header \(name)")
            }
            for name in testCase.expectedAbsentHeaders {
                #expect(recorded.headers[name] == nil, "\(testCase.name): header \(name) should be absent")
            }
        }
    }

    // MARK: - openai-response.json

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

    @Test func responsesMatchTheContractFixture() async throws {
        let cases = try ContractFixtures.decode("openai-response.json", as: [ResponseCase].self)
        #expect(!cases.isEmpty, "openai-response.json must not be empty")

        for testCase in cases {
            let base = StubURLProtocol.uniqueBaseURL()
            let endpoint = expectedEndpoint(from: base.absoluteString)
            StubURLProtocol.stub(endpoint, statusCode: testCase.status, body: Data(testCase.body.utf8))

            let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString))

            if testCase.shouldError == true {
                do {
                    _ = try await provider.complete(systemPrompt: "system", userText: "user")
                    Issue.record("\(testCase.name): expected an error")
                } catch let error as ProviderError {
                    #expect(error.kind == testCase.errorKind, "\(testCase.name)")

                    if let contains = testCase.errorMessageContains {
                        let detail: String
                        switch error {
                        case .invalidResponse(let d): detail = d
                        default: detail = ""
                        }
                        #expect(
                            detail.contains(contains),
                            "\(testCase.name): \(detail.debugDescription) does not contain \(contains.debugDescription)"
                        )
                    }

                    if case .http(let status, let snippet) = error {
                        if let expectedStatus = testCase.expectedStatus {
                            #expect(status == expectedStatus, "\(testCase.name)")
                        }
                        if let n = testCase.expectedSnippetChars {
                            let expectedSnippet = String(testCase.body.unicodeScalars.prefix(n))
                            #expect(
                                snippet == expectedSnippet,
                                "\(testCase.name): snippet is not exactly the first \(n) Unicode scalars"
                            )
                        }
                    }
                } catch {
                    Issue.record("\(testCase.name): unexpected error \(error)")
                }
            } else {
                let result = try await provider.complete(systemPrompt: "system", userText: "user")
                #expect(result == testCase.expectedText, "\(testCase.name)")
            }
        }
    }

    // MARK: - URLError mapping

    @Test func timedOutMapsToTimeoutWithTheProfilesTimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, errorCode: .timedOut)

        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 7))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected a timeout error")
        } catch let error as ProviderError {
            #expect(error == .timeout(7))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func cancelledPropagatesAsCancellationError() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, errorCode: .cancelled)

        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func notConnectedToInternetWithALANHostIsLocalNetworkDenied() async throws {
        let endpoint = URL(string: "http://192.168.1.10:11434/v1/chat/completions")!
        StubURLProtocol.stub(endpoint, errorCode: .notConnectedToInternet)

        let provider = makeProvider(profile: makeProfile(baseUrl: "http://192.168.1.10:11434/v1"))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected localNetworkDenied")
        } catch let error as ProviderError {
            #expect(error == .localNetworkDenied)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func notConnectedToInternetWithACloudHostIsUnreachable() async throws {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        StubURLProtocol.stub(endpoint, errorCode: .notConnectedToInternet)

        let provider = makeProvider(profile: makeProfile(baseUrl: "https://api.openai.com/v1"))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected unreachable")
        } catch let error as ProviderError {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Header value bytes (reqwest's real rule)

    @Test func headerValueAllowsUTF8ObsTextBytes() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, body: successBody("ok"))

        let profile = makeProfile(
            baseUrl: base.absoluteString,
            customHeaders: [HeaderEntry(name: "X-Greeting", value: "café")]
        )
        _ = try await makeProvider(profile: profile).complete(systemPrompt: "s", userText: "u")

        let recorded = try #require(StubURLProtocol.recordedRequest(for: endpoint))
        #expect(recorded.headers["X-Greeting"] == "café")
    }

    @Test func headerValueWithANewlineOrDELIsSkippedButOtherHeadersStillSend() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, body: successBody("ok"))

        let profile = makeProfile(
            baseUrl: base.absoluteString,
            customHeaders: [
                HeaderEntry(name: "X-Newline", value: "line\nbreak"),
                HeaderEntry(name: "X-Del", value: "a\u{7F}b"),
                HeaderEntry(name: "X-Valid", value: "ok"),
            ]
        )
        _ = try await makeProvider(profile: profile).complete(systemPrompt: "s", userText: "u")

        let recorded = try #require(StubURLProtocol.recordedRequest(for: endpoint))
        #expect(recorded.headers["X-Newline"] == nil)
        #expect(recorded.headers["X-Del"] == nil)
        #expect(recorded.headers["X-Valid"] == "ok")
    }

    // MARK: - Non-2xx body decoding is lossy

    @Test func nonTwoXXSnippetDecodingIsLossyForInvalidUTF8() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        let invalidUTF8 = Data([0xFF, 0xFE, 0x41, 0x42])
        StubURLProtocol.stub(endpoint, statusCode: 500, body: invalidUTF8)

        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString))
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected an http error")
        } catch let error as ProviderError {
            guard case .http(let status, let snippet) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 500)
            #expect(!snippet.isEmpty)
            #expect(snippet.contains("\u{FFFD}"), "expected a replacement character, got \(snippet.debugDescription)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Total deadline (idle timeout vs. hard cap)

    /// A hung request raced against a deadline sleeper that returns
    /// immediately: proves `sendWithDeadline` resolves from the timer
    /// winning the race, without ever waiting on the hung request — no
    /// wall-clock assertion needed, since the sleeper itself never
    /// actually sleeps.
    @Test func aHungRequestTimesOutAfterTheProfilesTimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, hang: true)

        let provider = makeProvider(
            profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 1),
            deadlineSleep: { _ in }
        )
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected a timeout error")
        } catch let error as ProviderError {
            #expect(error == .timeout(1))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// The real response arrives (after a short, incidental delay) while
    /// the deadline sleeper is one that never fires on its own — only
    /// cancellation can resume it, and the data task winning the race is
    /// exactly what cancels it. So success here can only mean the response
    /// won; it cannot mean "the deadline happened not to have elapsed yet".
    @Test func aResponseArrivingJustBeforeTheDeadlineIsNotATimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, body: successBody("just in time"), delay: .milliseconds(50))

        let sleeper = NeverFiringSleeper()
        let provider = makeProvider(
            profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 3),
            deadlineSleep: sleeper.sleep
        )
        let result = try await provider.complete(systemPrompt: "s", userText: "u")

        #expect(result == "just in time")
    }

    /// The caller cancels its own `Task` mid-hang, with a deadline sleeper
    /// that never fires on its own — so only the caller's cancellation,
    /// never the deadline race, can be responsible for the result. Waits
    /// for the stub to actually record the request (proof the data task
    /// has started) before cancelling, rather than a single `Task.yield()`.
    @Test func cancellingTheCallerDuringAHangIsCancellationNotTimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, hang: true)

        let sleeper = NeverFiringSleeper()
        let provider = makeProvider(
            profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 30),
            deadlineSleep: sleeper.sleep
        )
        let task = Task {
            try await provider.complete(systemPrompt: "s", userText: "u")
        }
        await waitUntilRequestIsRecorded(at: endpoint)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
