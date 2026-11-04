import Foundation
import Synchronization

/// Talks to any server implementing the OpenAI Chat Completions API shape
/// (`POST {baseUrl}/chat/completions`) — the one adapter for every
/// `openAICompatible` provider profile, local or cloud. A byte-for-byte
/// port of `src-tauri/src/core/providers/openai.rs`, using `URLSession`
/// instead of `reqwest`.
public struct OpenAICompatibleProvider: TextProvider {
    public let profile: ProviderProfile
    public let apiKey: String?
    public let session: URLSession

    /// The sleep used to drive the total-deadline timer in
    /// `sendWithDeadline`, and *only* that timer — never the real request.
    /// Overridable so tests can race a hung request (or a caller
    /// cancellation) against the deadline deterministically, without
    /// depending on wall-clock time or a real `Task.sleep`. Production code
    /// always uses the default.
    public let deadlineSleep: @Sendable (Duration) async throws -> Void

    /// Used by production code when no session is injected: an ephemeral
    /// configuration (no cache, no cookies), matching PLAN.md §7.3.
    public static let defaultSession = URLSession(configuration: .ephemeral)

    public init(
        profile: ProviderProfile,
        apiKey: String?,
        session: URLSession = OpenAICompatibleProvider.defaultSession,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
        self.deadlineSleep = deadlineSleep
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
                timeoutSecs: profile.timeoutSecs,
                deadlineSleep: deadlineSleep
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

    /// Coordinates the race between the real request and the deadline timer
    /// so exactly one of them ever resumes the continuation, and so a
    /// cancellation arriving before either child exists is remembered and
    /// honored once they do. All mutable state lives behind a `Mutex`;
    /// `URLSessionDataTask` and `Task.cancel()` are safe to call from any
    /// thread, which is the only thing done to them outside the lock.
    ///
    /// `@unchecked Sendable`: `CheckedContinuation` and `Task` are already
    /// `Sendable`; `URLSessionDataTask` is a thread-safe Foundation
    /// reference type but predates Swift 6 Sendable annotations on this
    /// platform, so the compiler can't verify it — only `.cancel()` is ever
    /// called on it, which is documented safe from any thread.
    private final class DeadlineRace: @unchecked Sendable {
        private struct State {
            var finished = false
            var cancelled = false
            var dataTask: URLSessionDataTask?
            var timeoutTask: Task<Void, Never>?
            var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        }

        private let state = Mutex(State())

        /// Called once, synchronously, from inside the
        /// `withCheckedThrowingContinuation` closure. If the caller's task
        /// was already cancelled by the time this runs, resumes immediately
        /// with `CancellationError`; otherwise stores the continuation for
        /// `resume(with:)` or `cancelForTaskCancellation()` to find later.
        func start(continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            let resumeNow = state.withLock { s -> Bool in
                guard !s.finished else { return false }
                if s.cancelled {
                    s.finished = true
                    return true
                }
                s.continuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume(throwing: CancellationError())
            }
        }

        /// Records the data task and the deadline timer once both exist, so
        /// a cancellation observed earlier — while neither existed yet —
        /// still reaches them here. Cancels both immediately if the race
        /// was already decided by the time this runs.
        func register(dataTask: URLSessionDataTask, timeoutTask: Task<Void, Never>) {
            let shouldCancel = state.withLock { s -> Bool in
                s.dataTask = dataTask
                s.timeoutTask = timeoutTask
                return s.finished || s.cancelled
            }
            if shouldCancel {
                dataTask.cancel()
                timeoutTask.cancel()
            }
        }

        /// The data task's completion handler or the deadline timer
        /// reporting its result. Only the first call does anything; it
        /// tears down whichever of the two didn't win, so nothing is left
        /// running past this call.
        func resume(with result: Result<(Data, URLResponse), Error>) {
            let (continuation, dataTask, timeoutTask) = state.withLock { s in
                (consumeIfUnfinished(&s), s.dataTask, s.timeoutTask)
            }
            dataTask?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }

        /// `withTaskCancellationHandler`'s `onCancel`: the caller's own
        /// `Task` was cancelled, not the deadline. Tears down both children
        /// and resumes with `CancellationError` — unless the race was
        /// already decided, in which case this only runs the (harmless,
        /// idempotent) cleanup.
        func cancelForTaskCancellation() {
            let (continuation, dataTask, timeoutTask) = state.withLock { s -> (
                CheckedContinuation<(Data, URLResponse), Error>?, URLSessionDataTask?, Task<Void, Never>?
            ) in
                s.cancelled = true
                // `withTaskCancellationHandler` runs `onCancel` *before*
                // the operation when the task is already cancelled. Then
                // `start` hasn't stored the continuation yet: leave the
                // race unfinished so `start` sees `cancelled` and resumes.
                guard s.continuation != nil else {
                    return (nil, s.dataTask, s.timeoutTask)
                }
                return (consumeIfUnfinished(&s), s.dataTask, s.timeoutTask)
            }
            dataTask?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        /// Marks the race finished and hands back the stored continuation,
        /// unless it was already finished — must only be called with the
        /// lock held.
        private func consumeIfUnfinished(
            _ s: inout State
        ) -> CheckedContinuation<(Data, URLResponse), Error>? {
            guard !s.finished else { return nil }
            s.finished = true
            let continuation = s.continuation
            s.continuation = nil
            return continuation
        }
    }

    /// `URLRequest.timeoutInterval` (set above) is only an *idle* timeout —
    /// it resets on every byte received, so a server that trickles data
    /// slowly enough never trips it, and it offers no guarantee about how
    /// quickly a cancelled request actually stops running. Desktop's
    /// `reqwest` timeout (`RequestBuilder::timeout`) is a hard cap on the
    /// whole request instead. This reproduces that hard cap with a
    /// `URLSessionDataTask` (completion-handler based, so it can be
    /// cancelled and simply abandoned — never awaited) raced against a
    /// timer driven by `deadlineSleep` (`Task.sleep` in production; a test
    /// double in tests), bridged into `async` with
    /// `withCheckedThrowingContinuation`. Whichever finishes first resumes
    /// the continuation and cancels the other; crucially, nothing here
    /// *awaits* the loser, so this function returns at the deadline
    /// regardless of how long the cancelled request takes to actually wind
    /// down.
    ///
    /// Caller cancellation (the enclosing `Task`) is handled by
    /// `withTaskCancellationHandler`, which fires as soon as cancellation
    /// happens — not when the next suspension point is reached — so it
    /// surfaces as `CancellationError` immediately rather than racing the
    /// deadline or the request.
    private static func sendWithDeadline(
        request: URLRequest,
        session: URLSession,
        timeoutSecs: Int,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> (Data, URLResponse) {
        let race = DeadlineRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                race.start(continuation: continuation)

                let dataTask = session.dataTask(with: request) { data, response, error in
                    if let error {
                        race.resume(with: .failure(error))
                    } else if let data, let response {
                        race.resume(with: .success((data, response)))
                    } else {
                        race.resume(with: .failure(ProviderError.invalidResponse("no data or response")))
                    }
                }

                let timeoutTask = Task {
                    try? await deadlineSleep(.seconds(timeoutSecs))
                    guard !Task.isCancelled else { return }
                    race.resume(with: .failure(ProviderError.timeout(timeoutSecs)))
                }

                race.register(dataTask: dataTask, timeoutTask: timeoutTask)
                dataTask.resume()
            }
        } onCancel: {
            race.cancelForTaskCancellation()
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
