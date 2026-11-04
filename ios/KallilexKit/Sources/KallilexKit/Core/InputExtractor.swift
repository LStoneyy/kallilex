import Foundation
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// Extracts the shared text from a Share Extension's `extensionContext
/// .inputItems` (ios-09, PLAN.md §8.2). Tries, per attachment, in order:
/// `public.plain-text`, `public.utf8-plain-text`, `public.rtf` (parsed via
/// `NSAttributedString`), the generic `public.text` (for a tagged subtype
/// none of the above matched), Safari's JS-preprocessing result (a
/// `public.property-list` payload keyed by
/// `NSExtensionJavaScriptPreprocessingResultsKey`), then the
/// `NSExtensionItem`'s own `attributedContentText`. The first attachment
/// that yields non-empty text wins; `extract` never throws and never
/// crashes on an unexpected payload type — every cast is a safe `as?`,
/// falling through to the next source instead.
///
/// Every `loadItem` call races against `loadTimeout` (production default:
/// 5 s), so a misbehaving provider that never completes its load handler
/// can't hang the sheet open forever — it's treated the same as "this
/// source has no text" and the extractor moves on.
public struct InputExtractor: Sendable {
    public static let defaultLoadTimeout: Duration = .seconds(5)

    private let loadTimeout: Duration

    public init(loadTimeout: Duration = InputExtractor.defaultLoadTimeout) {
        self.loadTimeout = loadTimeout
    }

    /// `nonisolated(nonsending)`: under Swift 6 (pre-Swift-7) language
    /// mode, a plain `nonisolated async` function defaults to running on
    /// the global concurrent executor, which would force
    /// `ShareViewController`'s `extensionContext.inputItems` (main-actor
    /// isolated, and not `Sendable` — `NSExtensionItem` predates Swift
    /// concurrency) across an isolation boundary just to call this. This
    /// keeps `extract` on its caller's actor instead, so the Share
    /// Extension can call it directly from the main actor with the
    /// `NSExtensionItem`s it already has.
    public nonisolated(nonsending) func extract(from items: [NSExtensionItem]) async -> String {
        for item in items {
            if let attachments = item.attachments {
                for attachment in attachments {
                    if let text = await tryLoad(attachment: attachment, typeIdentifier: UTType.plainText.identifier) {
                        return text
                    }
                    if let text = await tryLoad(attachment: attachment, typeIdentifier: UTType.utf8PlainText.identifier) {
                        return text
                    }
                    if let text = await tryRTF(attachment: attachment) {
                        return text
                    }
                    if let text = await tryLoad(attachment: attachment, typeIdentifier: UTType.text.identifier) {
                        return text
                    }
                    if let text = await trySafariPreprocessing(attachment: attachment) {
                        return text
                    }
                }
            }
            // `attributedContentText` lives on the item itself, not on any
            // one attachment, so it's tried once per item — including items
            // with no attachments at all — after every attachment-specific
            // source above has had its chance.
            if let text = tryAttributedContent(from: item) {
                return text
            }
        }
        return ""
    }

    // MARK: - Per-type attempts

    private nonisolated(nonsending) func tryLoad(attachment: NSItemProvider, typeIdentifier: String) async -> String? {
        guard attachment.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }
        let value = await loadItemWithTimeout(attachment, typeIdentifier: typeIdentifier)
        guard let text = string(from: value), !text.isEmpty else { return nil }
        return text.normalizedLineEndings()
    }

    private nonisolated(nonsending) func tryRTF(attachment: NSItemProvider) async -> String? {
        let identifier = UTType.rtf.identifier
        guard attachment.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        guard let value = await loadItemWithTimeout(attachment, typeIdentifier: identifier) else { return nil }

        let data: Data?
        switch value {
        case let value as Data:
            data = value
        case let value as String:
            data = Data(value.utf8)
        default:
            data = nil
        }
        guard let data,
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else {
            return nil
        }
        let text = attributed.string
        return text.isEmpty ? nil : text.normalizedLineEndings()
    }

    /// Safari's JS preprocessing result (the companion `Preprocess.js`,
    /// registered via `NSExtensionJavaScriptPreprocessingFile`): a
    /// `public.property-list` payload whose
    /// `NSExtensionJavaScriptPreprocessingResultsKey` entry carries the
    /// dictionary `Preprocess.js` returned (`selection`, `title`, `url`).
    /// `loadItem` may hand back either the already-decoded dictionary or
    /// the raw plist `Data`, depending on how the attachment was
    /// registered, so both are accepted.
    private nonisolated(nonsending) func trySafariPreprocessing(attachment: NSItemProvider) async -> String? {
        let identifier = UTType.propertyList.identifier
        guard attachment.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        guard let value = await loadItemWithTimeout(attachment, typeIdentifier: identifier) else { return nil }

        let dictionary: [String: Any]?
        switch value {
        case let value as [String: Any]:
            dictionary = value
        case let value as Data:
            dictionary = (try? PropertyListSerialization.propertyList(
                from: value,
                options: [],
                format: nil
            )) as? [String: Any]
        default:
            dictionary = nil
        }

        guard let dictionary,
              let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
              let selection = results["selection"] as? String,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selection.normalizedLineEndings()
    }

    private func tryAttributedContent(from item: NSExtensionItem) -> String? {
        guard let attributed = item.attributedContentText else { return nil }
        let text = attributed.string
        return text.isEmpty ? nil : text.normalizedLineEndings()
    }

    // MARK: - Value coercion

    /// Coerces whatever `NSSecureCoding` value `loadItem` handed back into
    /// a `String`, without ever crashing on a type it doesn't recognize
    /// (e.g. a `URL`, which deliberately isn't text).
    private func string(from value: NSSecureCoding?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as Data:
            return String(data: value, encoding: .utf8)
        case let value as NSAttributedString:
            return value.string
        default:
            return nil
        }
    }

    /// Races `attachment.loadItem(forTypeIdentifier:)` against
    /// `loadTimeout`: whichever finishes first wins, and the loser is
    /// cancelled. A timeout, a thrown error, and a legitimate "no value"
    /// all collapse to `nil` here — the caller treats every one of them as
    /// "this source has no text" and moves on to the next.
    ///
    /// `loadItem` is completion-handler based and, in practice, doesn't
    /// react to `Task` cancellation: a provider that never calls its
    /// completion handler never finishes, cancelled or not. So this can't
    /// use `withTaskGroup` (whose `next()`/implicit-await-on-return would
    /// still hang waiting for that child to finish). Instead it's a
    /// one-shot continuation race, mirroring
    /// `OpenAICompatibleProvider.DeadlineRace`: `loadItem`'s completion
    /// handler and a separate timer `Task` both race to call
    /// `LoadRace.resume(with:)`, guarded by a `Mutex` so only the first
    /// call does anything: nothing here ever awaits the loser.
    private nonisolated(nonsending) func loadItemWithTimeout(
        _ attachment: NSItemProvider,
        typeIdentifier: String
    ) async -> NSSecureCoding? {
        let attachmentBox = UncheckedSendableBox(value: attachment)
        let race = LoadRace()
        let result: UncheckedSendableBox<NSSecureCoding?> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation: continuation)

                attachmentBox.value.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { value, _ in
                    race.resume(with: UncheckedSendableBox(value: value))
                }

                let timeoutTask = Task { [loadTimeout] in
                    try? await Task.sleep(for: loadTimeout)
                    guard !Task.isCancelled else { return }
                    race.resume(with: UncheckedSendableBox(value: nil))
                }

                race.register(timeoutTask: timeoutTask)
            }
        } onCancel: {
            race.cancelForTaskCancellation()
        }
        return result.value
    }
}

/// Coordinates the race in `loadItemWithTimeout` between `loadItem`'s
/// completion handler and the timeout timer so exactly one of them ever
/// resumes the continuation, and so a cancellation arriving before the
/// continuation exists is remembered and honored once it does. All mutable
/// state lives behind a `Mutex`; `Task.cancel()` is safe to call from any
/// thread, which is the only thing done to it outside the lock.
///
/// `@unchecked Sendable`: `CheckedContinuation` and `Task` are already
/// `Sendable`; the stored value is an `UncheckedSendableBox`, for the same
/// reason that type exists below.
private final class LoadRace: @unchecked Sendable {
    private struct State {
        var finished = false
        var cancelled = false
        var timeoutTask: Task<Void, Never>?
        var continuation: CheckedContinuation<UncheckedSendableBox<NSSecureCoding?>, Never>?
    }

    private let state = Mutex(State())

    /// Called once, synchronously, from inside the `withCheckedContinuation`
    /// closure. If the caller's task was already cancelled by the time
    /// this runs, resumes immediately with `nil`; otherwise stores the
    /// continuation for `resume(with:)` or `cancelForTaskCancellation()` to
    /// find later.
    func start(continuation: CheckedContinuation<UncheckedSendableBox<NSSecureCoding?>, Never>) {
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
            continuation.resume(returning: UncheckedSendableBox(value: nil))
        }
    }

    /// Records the timeout timer once it exists, so a cancellation
    /// observed earlier — while it didn't exist yet — still reaches it
    /// here. Cancels it immediately if the race was already decided by the
    /// time this runs.
    func register(timeoutTask: Task<Void, Never>) {
        let shouldCancel = state.withLock { s -> Bool in
            s.timeoutTask = timeoutTask
            return s.finished || s.cancelled
        }
        if shouldCancel {
            timeoutTask.cancel()
        }
    }

    /// `loadItem`'s completion handler or the timeout timer reporting its
    /// result. Only the first call does anything; it cancels the timer if
    /// it hasn't already fired, so nothing is left running past this call.
    /// Never cancels or awaits `loadItem` itself — it doesn't react to
    /// cancellation anyway.
    func resume(with value: UncheckedSendableBox<NSSecureCoding?>) {
        let (continuation, timeoutTask) = state.withLock { s in
            (consumeIfUnfinished(&s), s.timeoutTask)
        }
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
    }

    /// `withTaskCancellationHandler`'s `onCancel`: the caller's own `Task`
    /// was cancelled, not the timer. Cancels the timer and resumes with
    /// `nil` — unless the race was already decided, in which case this
    /// only runs the (harmless, idempotent) cleanup.
    func cancelForTaskCancellation() {
        let (continuation, timeoutTask) = state.withLock { s -> (
            CheckedContinuation<UncheckedSendableBox<NSSecureCoding?>, Never>?, Task<Void, Never>?
        ) in
            s.cancelled = true
            // `withTaskCancellationHandler` runs `onCancel` *before* the
            // operation when the task is already cancelled. Then `start`
            // hasn't stored the continuation yet: leave the race
            // unfinished so `start` sees `cancelled` and resumes.
            guard s.continuation != nil else {
                return (nil, s.timeoutTask)
            }
            return (consumeIfUnfinished(&s), s.timeoutTask)
        }
        timeoutTask?.cancel()
        continuation?.resume(returning: UncheckedSendableBox(value: nil))
    }

    /// Marks the race finished and hands back the stored continuation,
    /// unless it was already finished — must only be called with the lock
    /// held.
    private func consumeIfUnfinished(
        _ s: inout State
    ) -> CheckedContinuation<UncheckedSendableBox<NSSecureCoding?>, Never>? {
        guard !s.finished else { return nil }
        s.finished = true
        let continuation = s.continuation
        s.continuation = nil
        return continuation
    }
}

/// `NSSecureCoding` (and `NSItemProvider` itself) predate Swift concurrency
/// and aren't `Sendable`, but `loadItem(forTypeIdentifier:)` only ever hands
/// its result to a single awaiting caller — never shared across
/// `Task`s — so crossing an isolation boundary with it here is safe in
/// practice even though the compiler can't verify it.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

extension String {
    /// Normalizes `\r\n` and `\r` line endings to `\n`, leaving every other
    /// whitespace character untouched (PLAN.md §8.2).
    fileprivate func normalizedLineEndings() -> String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
