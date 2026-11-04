import SwiftUI
import UIKit
import KallilexKit
import KallilexUI

/// Principal class for the Share Extension (ios-09, PLAN.md §8). No
/// storyboard; builds a `ShareHost` (which owns the `EditorSession`,
/// `ShareFlow`, and the extraction/settings-load task — `KallilexUI`,
/// shared with the app's own DEBUG-only harness) and hosts a single
/// `ShareHostView` through a `UIHostingController`, created once in
/// `viewDidLoad`. `APPLICATION_EXTENSION_API_ONLY` (set on the target)
/// means no `UIApplication.shared` anywhere in this file or in anything it
/// calls.
final class ShareViewController: UIViewController {
    private var host: ShareHost?
    private var hostingController: UIHostingController<ShareHostView>?

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
            let errorHost = ShareHost.settingsError(session: EditorSession(
                actionRunner: UnreachableActionRunner(),
                pasteboard: ExtensionPasteboard(),
                consentGranting: UnreachableConsentGranter()
            ))
            host = errorHost
            hostView(errorHost)
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
        let shareHost = ShareHost(session: session, load: { try settingsStore.load() })
        host = shareHost
        hostView(shareHost)

        let extensionItems = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
        shareHost.start(items: extensionItems)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Belt-and-suspenders: `EditorSession`'s own `isolated deinit`
        // already cancels its in-flight run once nothing retains it, but
        // `ShareHost`'s extraction task and the session itself can
        // otherwise both outlive the dismissed sheet for a moment — cancel
        // explicitly rather than rely on deallocation timing.
        host?.cancel()
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
        host?.cancel()
        if cancelled {
            extensionContext?.cancelRequest(
                withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            )
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Hosts a `ShareHostView` for `shareHost` through a `UIHostingController`,
    /// created exactly once per `ShareViewController` — there is no later
    /// re-render by swapping `rootView`; `ShareHostView` itself observes
    /// `shareHost` and re-renders on every state change.
    private func hostView(_ shareHost: ShareHost) {
        let rootView = ShareHostView(
            host: shareHost,
            onClose: { [weak self] in
                self?.finishRequest(cancelled: true)
            },
            onFinish: { [weak self] in
                self?.finishRequest(cancelled: false)
            }
        )

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
