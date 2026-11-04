import SwiftUI
import UIKit
import KallilexKit
import KallilexUI

/// Principal class for the Share Extension (ios-09, PLAN.md §8). No
/// storyboard; hosts `ShareRootView` through a `UIHostingController`
/// immediately, in its `.loadingInput` state, then extracts the shared
/// text and loads settings asynchronously and re-renders once both are
/// known. `APPLICATION_EXTENSION_API_ONLY` (set on the target) means no
/// `UIApplication.shared` anywhere in this file or in anything it calls.
final class ShareViewController: UIViewController {
    private var editorSession: EditorSession?
    private var shareFlow: ShareFlow?
    private var hostingController: UIHostingController<ShareRootView>?
    private var extractionTask: Task<Void, Never>?

    /// `NSExtensionContext` must see exactly one `completeRequest` or
    /// `cancelRequest`. Close, Copy & Close (including its auto-copy
    /// timer) and the `viewDidDisappear` fallback can all ask, so every
    /// path goes through `finishRequest(cancelled:)`, which honors only
    /// the first.
    private var hasFinishedRequest = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let extensionContext else { return }

        // Reads the App Group and Keychain access group identifiers from
        // Info.plist (ios-02) via `InfoPlist`, which `preconditionFailure`s
        // if either is missing or unresolved — there is no hardcoded
        // fallback, so a build misconfiguration fails loudly instead of
        // silently pointing at the wrong shared storage.
        let settingsStore: AppGroupSettingsStore
        do {
            settingsStore = try AppGroupSettingsStore(appGroupId: InfoPlist.kallilexAppGroup)
        } catch {
            // The App Group container itself is unavailable: there is no
            // settings to load and no profile to run against, so this is
            // the same user-facing failure as a settings-load error.
            hostSettingsLoadError(extensionContext: extensionContext)
            return
        }

        let secretStore = KeychainSecretStore(accessGroup: InfoPlist.kallilexKeychainAccessGroup)
        let runner = ActionRunner(
            settings: settingsStore,
            secrets: secretStore,
            makeProvider: ActionRunner.defaultProviderFactory
        )
        let session = EditorSession(
            actionRunner: runner,
            pasteboard: ExtensionPasteboard(),
            consentGranting: SettingsServiceConsentGranter(
                settingsService: SettingsService(settings: settingsStore, secrets: secretStore)
            )
        )
        let flow = ShareFlow()
        editorSession = session
        shareFlow = flow

        render(contentState: .loadingInput, settings: nil, session: session, shareFlow: flow)

        extractionTask = Task { [weak self] in
            let extractor = InputExtractor()
            let extensionItems = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
            let text = await extractor.extract(from: extensionItems)

            guard !Task.isCancelled else { return }
            session.text = text

            var loadedSettings: AppSettings?
            var settingsLoadFailed = false
            do {
                loadedSettings = try settingsStore.load()
            } catch {
                settingsLoadFailed = true
            }

            guard !Task.isCancelled, let self else { return }
            let contentState = flow.contentState(text: text, settingsLoadFailed: settingsLoadFailed)
            self.render(contentState: contentState, settings: loadedSettings, session: session, shareFlow: flow)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Belt-and-suspenders: `EditorSession`'s own `isolated deinit`
        // already cancels its in-flight run once nothing retains it, but
        // the extraction `Task` and the session itself can otherwise both
        // outlive the dismissed sheet for a moment — cancel explicitly
        // rather than rely on deallocation timing.
        extractionTask?.cancel()
        editorSession?.cancel()
        // A dismissal that didn't come from Close or Copy & Close (e.g. an
        // interactive swipe) still has to end the request; a no-op once
        // either of those already did.
        finishRequest(cancelled: true)
    }

    /// Ends the extension request exactly once: `cancelled` maps to
    /// `cancelRequest(withError: NSUserCancelledError)`, otherwise
    /// `completeRequest(returningItems: nil)`. Later calls do nothing.
    private func finishRequest(cancelled: Bool) {
        guard !hasFinishedRequest else { return }
        hasFinishedRequest = true
        extractionTask?.cancel()
        editorSession?.cancel()
        if cancelled {
            extensionContext?.cancelRequest(
                withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            )
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func hostSettingsLoadError(extensionContext: NSExtensionContext) {
        let session = EditorSession(
            actionRunner: UnreachableActionRunner(),
            pasteboard: ExtensionPasteboard(),
            consentGranting: UnreachableConsentGranter()
        )
        let flow = ShareFlow()
        editorSession = session
        shareFlow = flow
        render(contentState: .settingsError, settings: nil, session: session, shareFlow: flow)
    }

    private func render(
        contentState: ShareContentState,
        settings: AppSettings?,
        session: EditorSession,
        shareFlow: ShareFlow
    ) {
        let activeProfile: ProviderProfile?
        if let settings, let activeID = settings.activeProfileID {
            activeProfile = settings.profiles.first { $0.id == activeID && $0.enabled }
        } else {
            activeProfile = nil
        }
        let rootView = ShareRootView(
            session: session,
            shareFlow: shareFlow,
            contentState: contentState,
            settings: settings,
            activeProfile: activeProfile,
            onClose: { [weak self] in
                self?.finishRequest(cancelled: true)
            },
            onFinish: { [weak self] in
                self?.finishRequest(cancelled: false)
            }
        )

        if let hostingController {
            hostingController.rootView = rootView
            return
        }

        let hosting = UIHostingController(rootView: rootView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
    }
}

/// Writes to `UIPasteboard.general` — the extension's production
/// `Pasteboard` (ios-09). `UIPasteboard` is allowed under
/// `APPLICATION_EXTENSION_API_ONLY`; only `UIApplication` is not.
private struct ExtensionPasteboard: Pasteboard {
    func setString(_ string: String) {
        UIPasteboard.general.string = string
    }
}

/// Used only on the `AppGroupSettingsStore(appGroupId:)` failure path,
/// where there is no working `ActionRunner` to speak of: `EditorSession`
/// still needs *some* `any ActionRunning`/`any ConsentGranting` to
/// construct, but the settings-error card never lets the user reach a
/// state that would call either.
private struct UnreachableActionRunner: ActionRunning {
    func run(text: String, action: Action) async -> RunOutcome { .notConfigured }
}

private struct UnreachableConsentGranter: ConsentGranting {
    func grantConsent(profileID: String, host: String) throws {}
}
