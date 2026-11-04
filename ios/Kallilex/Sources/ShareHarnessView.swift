#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import KallilexKit
import KallilexUI

/// DEBUG-only in-app harness that hosts `ShareHostView`/`ShareHost` the
/// same way the Share Extension's `ShareViewController` does, so XCUITests
/// can exercise the extension's UI from inside the app itself — there's no
/// way to drive a real Share Extension from XCUITest (ios-09 spec part B).
///
/// Shown by `KallilexApp` instead of `RootTabView` when launched with
/// `-uiTestShareHarness`. The shared text comes from `-uiTestShareText
/// <text>`; an empty input is used when that argument is absent.
///
/// On `onClose`/`onFinish` (exactly what the Share Extension's own
/// `finishRequest(cancelled:)` would have led to), replaces the hosted UI
/// with a static text identified by `shareHarness.outcome`, labeled
/// "cancelled" or "completed" — that's how a test observes the extension
/// would have closed its sheet, since there's no real
/// `NSExtensionContext` here to complete/cancel.
struct ShareHarnessView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var host: ShareHost?
    @State private var outcome: Outcome?

    private enum Outcome: String {
        case cancelled, completed
    }

    var body: some View {
        Group {
            if let outcome {
                Text(outcome.rawValue)
                    .accessibilityIdentifier("shareHarness.outcome")
            } else if let host {
                ShareHostView(
                    host: host,
                    copiedDuration: Self.copiedDuration,
                    onClose: { outcome = .cancelled },
                    onFinish: { outcome = .completed }
                )
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard host == nil else { return }
            let newHost = Self.makeHost(appEnv: appEnv)
            host = newHost
            newHost.start(items: [Self.harnessExtensionItem()])
        }
    }

    /// Mirrors `ScratchpadView.copiedDuration`: XCUITest waits for the app
    /// to go idle after a tap, which can outlast the default "Copied"
    /// confirmation.
    private static var copiedDuration: Duration {
        if ProcessInfo.processInfo.arguments.contains("-uiTestLongCopiedConfirmation") {
            return .seconds(3)
        }
        return shareRootViewDefaultCopiedDuration
    }

    /// Uses the app's own `AppEnvironment.actionRunner` (so
    /// `-uiTestStubProvider` applies here too) and `settingsStore`, exactly
    /// like `ScratchpadView`'s own `EditorSession`/`ShareHost` would — the
    /// only thing distinguishing this from the real Share Extension is
    /// which `NSExtensionItem`s it's handed and how `onClose`/`onFinish`
    /// are observed.
    private static func makeHost(appEnv: AppEnvironment) -> ShareHost {
        let session = EditorSession(
            actionRunner: appEnv.actionRunner,
            pasteboard: DevicePasteboard(),
            consentGranting: ReloadingConsentGranter(
                settingsService: appEnv.service,
                reload: { [appEnv] in
                    Task { @MainActor in appEnv.reload() }
                }
            )
        )
        return ShareHost(session: session, load: { try appEnv.settingsStore.load() })
    }

    /// One `NSExtensionItem` mirroring how a real Share Extension receives
    /// selected text: one `NSItemProvider` registering `-uiTestShareText`'s
    /// value as `public.plain-text` data, matching
    /// `InputExtractorTests.dataProvider`. An item with no attachments at
    /// all when that argument is absent/empty, exercising `InputExtractor`
    /// 's "no text found" path the same way an item with only a URL
    /// attachment would.
    private static func harnessExtensionItem() -> NSExtensionItem {
        let item = NSExtensionItem()
        let text = harnessText()
        guard !text.isEmpty else { return item }

        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(text.utf8), nil)
            return nil
        }
        item.attachments = [provider]
        return item
    }

    private static func harnessText() -> String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestShareText") else { return "" }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.count else { return "" }
        return arguments[valueIndex]
    }
}
#endif
