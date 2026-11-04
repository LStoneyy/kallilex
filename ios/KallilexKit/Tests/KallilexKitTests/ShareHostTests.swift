import Foundation
import Testing
import UniformTypeIdentifiers
import KallilexKit
import KallilexUI

/// Tests for `ShareHost`. See
/// `issues-ios/spec-ios-09-share-extension.md`'s "Extension integration
/// tests" and `PLAN.md` §8.3. Uses the same `FakeActionRunning`/
/// `FakePasteboard`/`FakeConsentGranting`/`FakeEditorFeedback` fakes as
/// `EditorSessionTests`.
@MainActor
struct ShareHostTests {
    enum LoadFailure: Error {
        case boom
    }

    private func makeSession() -> EditorSession {
        EditorSession(
            actionRunner: FakeActionRunning(),
            pasteboard: FakePasteboard(),
            consentGranting: FakeConsentGranting(),
            feedback: FakeEditorFeedback()
        )
    }

    private func textItem(_ text: String) -> NSExtensionItem {
        let item = NSExtensionItem()
        guard !text.isEmpty else { return item }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        item.attachments = [provider]
        return item
    }

    private func settings(
        activeProfileID: String? = nil,
        profiles: [ProviderProfile] = []
    ) -> AppSettings {
        AppSettings(
            activeProfileID: activeProfileID,
            profiles: profiles,
            prompts: [CustomPrompt(id: "p1", label: "Fix grammar", instruction: "Fix grammar.")]
        )
    }

    // ---- loadingInput -> editor ------------------------------------------

    @Test func startsLoadingThenMovesToEditorWithExtractedText() async {
        let host = ShareHost(session: makeSession(), load: { self.settings() })
        #expect(host.contentState == .loadingInput)

        await host.start(items: [textItem("hello")]).value

        #expect(host.contentState == .editor)
        #expect(host.session.text == "hello")
        #expect(host.settings != nil)
    }

    @Test func activeProfileIsTheEnabledProfileMatchingActiveProfileID() async {
        let profile = ProviderProfile(id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4")
        let host = ShareHost(session: makeSession(), load: {
            self.settings(activeProfileID: "p1", profiles: [profile])
        })

        await host.start(items: [textItem("hello")]).value

        #expect(host.activeProfile == profile)
    }

    @Test func activeProfileIsNilWhenTheActiveProfileIsDisabled() async {
        let profile = ProviderProfile(
            id: "p1", name: "OpenAI", baseUrl: "https://api.openai.com/v1", model: "gpt-4", enabled: false
        )
        let host = ShareHost(session: makeSession(), load: {
            self.settings(activeProfileID: "p1", profiles: [profile])
        })

        await host.start(items: [textItem("hello")]).value

        #expect(host.activeProfile == nil)
    }

    // ---- emptyInput --------------------------------------------------------

    @Test func emptyExtractedTextLeadsToEmptyInput() async {
        let host = ShareHost(session: makeSession(), load: { self.settings() })

        await host.start(items: [textItem("")]).value

        #expect(host.contentState == .emptyInput)
        #expect(host.session.text == "")
    }

    // ---- settingsError -------------------------------------------------------

    @Test func aSettingsLoadFailureLeadsToSettingsErrorRegardlessOfText() async {
        let host = ShareHost(session: makeSession(), load: { throw LoadFailure.boom })

        await host.start(items: [textItem("hello")]).value

        #expect(host.contentState == .settingsError)
        #expect(host.settings == nil)
        #expect(host.activeProfile == nil)
        // The text itself is still extracted and applied to the session —
        // only the derived content state is affected.
        #expect(host.session.text == "hello")
    }

    @Test func settingsErrorFactoryStartsDirectlyInSettingsErrorWithoutStarting() {
        let host = ShareHost.settingsError(session: makeSession())
        #expect(host.contentState == .settingsError)
        #expect(host.settings == nil)
    }

    // ---- cancel --------------------------------------------------------------

    /// Mirrors `InputExtractorTests.cancellingDuringAPendingLoadReturnsWithoutWaitingForTheTimeout`:
    /// `cancel()` stops the task before it ever reaches `load`/sets
    /// `contentState`, rather than merely racing a slow extraction.
    @Test(.timeLimit(.minutes(1)))
    func cancelBeforeTheTaskFinishesLeavesStateAtLoadingInput() async {
        var loadWasCalled = false
        let host = ShareHost(session: makeSession(), load: {
            loadWasCalled = true
            return self.settings()
        })

        let task = host.start(items: [NeverCompletingItemFactory.make()])
        host.cancel()

        await task.value
        #expect(host.contentState == .loadingInput)
        #expect(host.settings == nil)
        #expect(!loadWasCalled)
    }
}

/// Builds an `NSExtensionItem` with a single attachment whose `loadItem`
/// never completes and whose timeout (`InputExtractor`'s default 5 s) is
/// far longer than this test's own time limit — only cancellation can end
/// the load, matching `InputExtractorTests.neverCompletingItem`.
private enum NeverCompletingItemFactory {
    static func make() -> NSExtensionItem {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { _ in
            nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        return item
    }
}
