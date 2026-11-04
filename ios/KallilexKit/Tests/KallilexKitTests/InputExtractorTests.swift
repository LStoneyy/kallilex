import Foundation
import Testing
import UniformTypeIdentifiers
import KallilexKit

/// Tests for `InputExtractor`. See
/// `issues-ios/spec-ios-09-share-extension.md`'s "InputExtractor unit
/// tests". Every provider is built with
/// `NSItemProvider.registerDataRepresentation`, matching how a real Share
/// Extension's attachments arrive — `loadItem` hands the registered `Data`
/// straight back for these (not a coerced `String`/dictionary), which is
/// exactly why `InputExtractor` accepts `Data` as well as `String` for
/// every text-bearing type, and raw plist `Data` for the Safari path.
struct InputExtractorTests {
    private func dataProvider(typeIdentifier: String, data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func item(attachments: [NSItemProvider]) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = attachments
        return item
    }

    @Test func plainTextProviderReturnsItsText() async {
        let provider = dataProvider(typeIdentifier: UTType.plainText.identifier, data: Data("Hello world".utf8))
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text == "Hello world")
    }

    @Test func utf8PlainTextProviderReturnsItsText() async {
        let provider = dataProvider(typeIdentifier: UTType.utf8PlainText.identifier, data: Data("Café ☕️".utf8))
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text == "Café ☕️")
    }

    @Test func rtfProviderIsParsedToPlainText() async throws {
        let attributed = NSAttributedString(string: "Hello RTF")
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let provider = dataProvider(typeIdentifier: UTType.rtf.identifier, data: rtfData)
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text == "Hello RTF")
    }

    @Test func crlfAndCrAreNormalizedToLF() async {
        let provider = dataProvider(
            typeIdentifier: UTType.plainText.identifier,
            data: Data("Line1\r\nLine2\rLine3".utf8)
        )
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text == "Line1\nLine2\nLine3")
    }

    @Test func urlOnlyProviderReturnsEmptyString() async {
        let provider = dataProvider(
            typeIdentifier: UTType.url.identifier,
            data: Data("https://example.com".utf8)
        )
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text.isEmpty)
    }

    @Test func emptyInputItemsReturnsEmptyString() async {
        let text = await InputExtractor().extract(from: [])
        #expect(text.isEmpty)
    }

    @Test func multipleItemsFirstTextWins() async {
        let urlProvider = dataProvider(typeIdentifier: UTType.url.identifier, data: Data("https://example.com".utf8))
        let textProvider = dataProvider(typeIdentifier: UTType.plainText.identifier, data: Data("Second item text".utf8))
        let items = [item(attachments: [urlProvider]), item(attachments: [textProvider])]
        let text = await InputExtractor().extract(from: items)
        #expect(text == "Second item text")
    }

    @Test func safariJSPreprocessingResultReturnsTheSelection() async throws {
        let payload: [String: Any] = [
            NSExtensionJavaScriptPreprocessingResultsKey: [
                "selection": "Selected text from the page",
                "title": "Example page",
                "url": "https://example.com",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let provider = dataProvider(typeIdentifier: UTType.propertyList.identifier, data: data)
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text == "Selected text from the page")
    }

    @Test func safariJSPreprocessingResultWithBlankSelectionFallsThrough() async throws {
        let payload: [String: Any] = [
            NSExtensionJavaScriptPreprocessingResultsKey: [
                "selection": "   ",
                "title": "Example page",
                "url": "https://example.com",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let provider = dataProvider(typeIdentifier: UTType.propertyList.identifier, data: data)
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text.isEmpty)
    }

    @Test func attributedContentTextIsUsedWhenNoAttachmentYieldsText() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "From attributedContentText")
        let text = await InputExtractor().extract(from: [item])
        #expect(text == "From attributedContentText")
    }

    // ---- timeout and odd-type safety -----------------------------------

    @Test(.timeLimit(.minutes(1)))
    func aProviderThatNeverCompletesTimesOutRatherThanHanging() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { _ in
            // Never calls `completion` — simulates a misbehaving provider.
            nil
        }
        let extractor = InputExtractor(loadTimeout: .milliseconds(50))
        let text = await extractor.extract(from: [item(attachments: [provider])])
        // The time limit above is the real guard against a regression
        // that hangs again; wall-clock assertions are flaky on slow CI
        // runners.
        #expect(text.isEmpty)
    }

    /// A never-completing provider with a timeout far beyond the test's
    /// time limit, so only cancellation can end the load. Built inside
    /// each task because `NSItemProvider` isn't `Sendable`.
    private func neverCompletingItem() -> NSExtensionItem {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { _ in
            nil
        }
        return item(attachments: [provider])
    }

    /// The caller's task is already cancelled before `extract` starts:
    /// `withTaskCancellationHandler` runs `onCancel` before the
    /// continuation exists, and the load must still finish promptly
    /// instead of waiting for the timeout or hanging.
    @Test(.timeLimit(.minutes(1)))
    func anAlreadyCancelledTaskReturnsWithoutWaitingForTheTimeout() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await InputExtractor(loadTimeout: .seconds(3600)).extract(from: [neverCompletingItem()])
        }
        let text = await task.value
        #expect(text.isEmpty)
    }

    /// Cancelling the caller's task while a load is pending resumes it
    /// with no text instead of waiting for the timeout.
    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringAPendingLoadReturnsWithoutWaitingForTheTimeout() async {
        let task = Task {
            await InputExtractor(loadTimeout: .seconds(3600)).extract(from: [neverCompletingItem()])
        }
        task.cancel()
        let text = await task.value
        #expect(text.isEmpty)
    }

    @Test func invalidUTF8DataForPlainTextFallsThroughWithoutCrashing() async {
        let provider = dataProvider(typeIdentifier: UTType.plainText.identifier, data: Data([0xFF, 0xFE, 0xFD]))
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text.isEmpty)
    }

    @Test func malformedRTFDataFallsThroughWithoutCrashing() async {
        // Bytes that are neither valid RTF nor valid UTF-8 text, so the
        // "public.text" fallback (which `public.rtf` also conforms to)
        // can't accidentally succeed by decoding them as plain text either.
        let provider = dataProvider(typeIdentifier: UTType.rtf.identifier, data: Data([0xFF, 0xFE, 0xFD, 0x00, 0x01]))
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text.isEmpty)
    }

    @Test func malformedPropertyListDataFallsThroughWithoutCrashing() async {
        let provider = dataProvider(typeIdentifier: UTType.propertyList.identifier, data: Data("not a plist".utf8))
        let text = await InputExtractor().extract(from: [item(attachments: [provider])])
        #expect(text.isEmpty)
    }
}
