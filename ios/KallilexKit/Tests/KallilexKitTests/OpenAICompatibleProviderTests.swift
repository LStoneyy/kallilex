import Foundation
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

    func makeProvider(profile: ProviderProfile, apiKey: String? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(profile: profile, apiKey: apiKey, session: StubURLProtocol.makeSession())
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

    @Test func aHungRequestTimesOutAfterTheProfilesTimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, hang: true)

        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 1))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await provider.complete(systemPrompt: "s", userText: "u")
            Issue.record("expected a timeout error")
        } catch let error as ProviderError {
            #expect(error == .timeout(1))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(5), "expected the deadline to fire within a few seconds, took \(elapsed)")
    }

    @Test func aResponseArrivingJustBeforeTheDeadlineIsNotATimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        // A generous margin between the response's delay and the profile's
        // deadline (300 ms vs. 3 s) so this isn't flaky under a loaded test
        // runner — the point is "arrives before the deadline", not "arrives
        // at the last possible instant".
        StubURLProtocol.stub(endpoint, body: successBody("just in time"), delay: .milliseconds(300))

        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 3))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await provider.complete(systemPrompt: "s", userText: "u")
        let elapsed = clock.now - start

        #expect(result == "just in time")
        #expect(elapsed < .seconds(3), "expected the real response to win the race, took \(elapsed)")
    }

    @Test func cancellingTheCallerDuringAHangIsCancellationNotTimeout() async throws {
        let base = StubURLProtocol.uniqueBaseURL()
        let endpoint = expectedEndpoint(from: base.absoluteString)
        StubURLProtocol.stub(endpoint, hang: true)

        // A long profile timeout, so only the caller's own cancellation —
        // never the deadline race — can resolve this.
        let provider = makeProvider(profile: makeProfile(baseUrl: base.absoluteString, timeoutSecs: 30))
        let task = Task {
            try await provider.complete(systemPrompt: "s", userText: "u")
        }
        await Task.yield()
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
