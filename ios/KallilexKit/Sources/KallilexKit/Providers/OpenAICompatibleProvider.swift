import Foundation

/// Talks to any server implementing the OpenAI Chat Completions API shape
/// (`POST {baseUrl}/chat/completions`) — the one adapter for every
/// `openAICompatible` provider profile, local or cloud. A byte-for-byte
/// port of `src-tauri/src/core/providers/openai.rs`, using `URLSession`
/// instead of `reqwest`.
public struct OpenAICompatibleProvider: TextProvider {
    public let profile: ProviderProfile
    public let apiKey: String?
    public let session: URLSession

    /// Used by production code when no session is injected: an ephemeral
    /// configuration (no cache, no cookies), matching PLAN.md §7.3.
    public static let defaultSession = URLSession(configuration: .ephemeral)

    public init(
        profile: ProviderProfile,
        apiKey: String?,
        session: URLSession = OpenAICompatibleProvider.defaultSession
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public func complete(
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        try Task.checkCancellation()

        let endpoint = try Self.endpointURL(for: profile.baseUrl)
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingModel
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(profile.timeoutSecs)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": profile.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "stream": false,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ProviderError.invalidResponse(String(describing: error))
        }

        // `Authorization: Bearer <key>` whenever a key is given, mirroring
        // `build_request` exactly: the check is on "is a key present at
        // all" (desktop's `Option::is_some()`), not on whether it happens
        // to be an empty string.
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for header in profile.customHeaders {
            Self.apply(header, to: &request)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.sendWithDeadline(
                request: request,
                session: session,
                timeoutSecs: profile.timeoutSecs
            )
        } catch let providerError as ProviderError {
            throw providerError
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            throw Self.mapURLError(urlError, profile: profile)
        } catch {
            throw ProviderError.invalidResponse(String(describing: error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(String(describing: response))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Lossy, like Rust's `Response::text()`: invalid UTF-8 bytes
            // become U+FFFD rather than losing the whole snippet.
            let bodyString = String(decoding: data, as: UTF8.self)
            let snippet = String(bodyString.unicodeScalars.prefix(300))
            throw ProviderError.http(status: httpResponse.statusCode, snippet: snippet)
        }

        return try Self.extractContent(from: data)
    }

    // MARK: - Total deadline

    private enum RaceResult: Sendable {
        case response(Data, URLResponse)
        case timedOut
    }

    /// `URLRequest.timeoutInterval` (set above) is only an *idle* timeout —
    /// it resets on every byte received, so a server that trickles data
    /// slowly enough never trips it. Desktop's `reqwest` timeout
    /// (`RequestBuilder::timeout`) is a hard cap on the whole request
    /// instead. This reproduces that hard cap by racing the real request
    /// against a `Task.sleep` in a throwing task group and cancelling
    /// whichever loses — the loser is always cancelled via `defer`, so
    /// nothing is left running past this call.
    ///
    /// Caller cancellation (the enclosing `Task`) must still surface as
    /// `CancellationError`, never `.timeout`: structured concurrency
    /// propagates that cancellation into both child tasks, so either one
    /// might be the one `group.next()` observes first — the sleep task as
    /// a thrown `CancellationError`, the network task as a thrown
    /// `URLError(.cancelled)`. Both are normalized to `CancellationError`
    /// here; only a *naturally completed* sleep (the deadline actually
    /// elapsing, uncancelled) is treated as a real timeout.
    private static func sendWithDeadline(
        request: URLRequest,
        session: URLSession,
        timeoutSecs: Int
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                return .response(data, response)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSecs))
                return .timedOut
            }
            defer { group.cancelAll() }

            do {
                guard let first = try await group.next() else {
                    throw ProviderError.invalidResponse("no result from the request or its deadline")
                }
                switch first {
                case .response(let data, let response):
                    return (data, response)
                case .timedOut:
                    throw ProviderError.timeout(timeoutSecs)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
        }
    }

    // MARK: - Endpoint building

    /// Builds `{baseUrl}/chat/completions`, trimming trailing slashes from
    /// `baseUrl` first. Validates that `baseUrl` parses as a URL with an
    /// `http`/`https` scheme; anything else is `invalidBaseUrl`. Checked
    /// before the missing-model check.
    static func endpointURL(for baseUrl: String) throws -> URL {
        guard let parsed = URL(string: baseUrl),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ProviderError.invalidBaseUrl(baseUrl)
        }
        var trimmed = baseUrl
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let endpoint = URL(string: "\(trimmed)/chat/completions") else {
            throw ProviderError.invalidBaseUrl(baseUrl)
        }
        return endpoint
    }

    // MARK: - Headers

    /// RFC 7230 token characters, used to validate a custom header's name —
    /// mirrors `HeaderName::from_bytes` (reqwest). ASCII letters, digits,
    /// and the token's punctuation set.
    private static let headerNameAllowedBytes: Set<UInt8> = {
        var set = Set<UInt8>()
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(byte) }
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(byte) }
        for byte in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(byte) }
        for byte in "!#$%&'*+-.^_`|~".utf8 { set.insert(byte) }
        return set
    }()

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { headerNameAllowedBytes.contains($0) }
    }

    /// A valid header value contains only tab (0x09) or any byte that
    /// isn't a control character other than tab: `b == 0x09 || (b >= 0x20
    /// && b != 0x7F)`. That includes 0x80–0xFF (`obs-text`, RFC 7230
    /// §3.2.6) — mirrors `HeaderValue::from_str` (reqwest/the `http`
    /// crate), which treats header values as opaque bytes and doesn't
    /// require valid UTF-8; only 0x00–0x08, 0x0A–0x1F and 0x7F (DEL) are
    /// rejected.
    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }
    }

    /// Applies one custom header to `request`. Entries whose name or value
    /// don't form a valid HTTP header are silently skipped — they are
    /// user-supplied data, not a protocol error worth failing the whole
    /// request over.
    private static func apply(_ header: HeaderEntry, to request: inout URLRequest) {
        guard !header.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard isValidHeaderName(header.name), isValidHeaderValue(header.value) else {
            return
        }
        request.setValue(header.value, forHTTPHeaderField: header.name)
    }

    // MARK: - URLError mapping

    private static func mapURLError(_ error: URLError, profile: ProviderProfile) -> ProviderError {
        switch error.code {
        case .timedOut:
            return .timeout(profile.timeoutSecs)
        case .notConnectedToInternet:
            // Spike ios-01 unknown 2: with the Local Network permission
            // denied, a request to a private IP fails within milliseconds
            // with -1009, while internet access still works. A timeout to
            // a `.local` host stays `.timeout` — it can't be told apart
            // from a host that's simply down.
            if classifyPrivacy(baseUrl: profile.baseUrl) == .lan {
                return .localNetworkDenied
            }
            return .unreachable(error.localizedDescription)
        default:
            return .unreachable(error.localizedDescription)
        }
    }

    // MARK: - Response parsing

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }

        let choices: [Choice]

        private enum CodingKeys: String, CodingKey {
            case choices
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        }
    }

    private static func extractContent(from data: Data) throws -> String {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse("invalid JSON: \(error)")
        }
        guard let first = decoded.choices.first else {
            throw ProviderError.invalidResponse("response contained no choices")
        }
        guard let content = first.message.content else {
            throw ProviderError.invalidResponse("message content was missing or null")
        }
        return stripPadding(content)
    }

    // MARK: - Padding

    /// Strips model padding without destroying user-visible formatting:
    /// removes leading blank lines and all trailing whitespace, but keeps
    /// the first content line's indentation and all interior whitespace.
    /// Operates on Unicode scalars so `\r\n` behaves like Rust, and
    /// `Unicode.Scalar.Properties.isWhitespace` is the same White_Space
    /// property as Rust's `char::is_whitespace`.
    static func stripPadding(_ content: String) -> String {
        let u = content.unicodeScalars
        guard let first = u.firstIndex(where: { !$0.properties.isWhitespace }) else {
            return ""
        }
        let lineStart = u[..<first].lastIndex(of: "\n").map { u.index(after: $0) } ?? u.startIndex
        var end = u.endIndex
        while end > lineStart, u[u.index(before: end)].properties.isWhitespace {
            end = u.index(before: end)
        }
        return String(u[lineStart..<end])
    }
}
