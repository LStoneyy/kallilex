import Foundation
import SwiftUI
import KallilexKit

/// What couldn't be loaded when a `ShareHost` is constructed through
/// `settingsError(session:)`: a placeholder so the (never actually called)
/// `load` closure on that path still type-checks.
private enum ShareHostUnreachableError: Error {
    case appGroupUnavailable
}

/// Owns everything `ShareViewController` used to juggle by hand (ios-09,
/// PLAN.md §8): the `EditorSession`, the `ShareFlow`, the derived
/// `contentState`/`settings`/`activeProfile`, and the one `Task` that
/// extracts input and loads settings. Extracted into `KallilexUI` so it's
/// unit-testable with fakes (`KallilexKitTests`) and reusable by the app's
/// own DEBUG-only harness (part B of this spec), neither of which can link
/// against the Share Extension target.
@MainActor
@Observable
public final class ShareHost {
    public let session: EditorSession
    public let shareFlow: ShareFlow

    public private(set) var contentState: ShareContentState = .loadingInput
    public private(set) var settings: AppSettings?
    /// The active, enabled profile from `settings`, if any — `nil` while
    /// `settings` itself is `nil` (loading, or `.settingsError`).
    public private(set) var activeProfile: ProviderProfile?

    private let load: @MainActor () throws -> AppSettings
    private let extractor: InputExtractor
    private var startTask: Task<Void, Never>?

    public init(
        session: EditorSession,
        load: @escaping @MainActor () throws -> AppSettings,
        extractor: InputExtractor = InputExtractor()
    ) {
        self.session = session
        self.shareFlow = ShareFlow()
        self.load = load
        self.extractor = extractor
    }

    /// The App-Group-unavailable path (`AppGroupSettingsStore(appGroupId:)`
    /// itself threw): there is no settings to load and no profile to run
    /// against, so this starts directly in `.settingsError` rather than
    /// going through `start(items:)` at all. `session` still needs *some*
    /// `any ActionRunning`/`any ConsentGranting` to exist, but the
    /// settings-error card never lets the user reach a state that would
    /// call either — the caller (`ShareViewController`) is responsible for
    /// passing unreachable fakes.
    public static func settingsError(session: EditorSession) -> ShareHost {
        let host = ShareHost(session: session) {
            throw ShareHostUnreachableError.appGroupUnavailable
        }
        host.contentState = .settingsError
        return host
    }

    /// Starts the one extraction/settings-load `Task` for this launch:
    /// extracts `session.text` from `items`, loads settings via `load`
    /// (a thrown error maps to `.settingsError`, same as a missing App
    /// Group), then sets `contentState`/`settings`/`activeProfile` from the
    /// result. Replaces (cancelling) any previous call's task, though
    /// callers are expected to call this at most once per launch.
    /// Returns the underlying `Task` (`@discardableResult`) so tests can
    /// await it deterministically, mirroring `EditorSession.run`.
    @discardableResult
    public func start(items: [NSExtensionItem]) -> Task<Void, Never> {
        startTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let text = await self.extractor.extract(from: items)
            guard !Task.isCancelled else { return }
            self.session.text = text

            var loadedSettings: AppSettings?
            var settingsLoadFailed = false
            do {
                loadedSettings = try self.load()
            } catch {
                settingsLoadFailed = true
            }

            guard !Task.isCancelled else { return }
            self.settings = loadedSettings
            self.activeProfile = Self.activeProfile(in: loadedSettings)
            self.contentState = self.shareFlow.contentState(text: text, settingsLoadFailed: settingsLoadFailed)
        }
        startTask = task
        return task
    }

    /// Cancels the in-flight `start(items:)` task, if any, and the session's
    /// own in-flight run — called by both `onClose`/`onFinish` paths and the
    /// `viewDidDisappear` fallback, before the host itself is torn down.
    public func cancel() {
        startTask?.cancel()
        session.cancel()
    }

    private static func activeProfile(in settings: AppSettings?) -> ProviderProfile? {
        guard let settings, let activeID = settings.activeProfileID else { return nil }
        return settings.profiles.first { $0.id == activeID && $0.enabled }
    }
}

/// Renders a `ShareHost`'s current `contentState`/`settings`/`activeProfile`
/// through `ShareRootView`. The thin seam between `ShareHost` and
/// `ShareRootView` that both the Share Extension's `ShareViewController`
/// and the app's DEBUG-only harness (part B of this spec) host, each with
/// their own `onClose`/`onFinish` closures and `copiedDuration`.
public struct ShareHostView: View {
    private let host: ShareHost
    private let copiedDuration: Duration
    private let onClose: () -> Void
    private let onFinish: () -> Void

    public init(
        host: ShareHost,
        copiedDuration: Duration = shareRootViewDefaultCopiedDuration,
        onClose: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.host = host
        self.copiedDuration = copiedDuration
        self.onClose = onClose
        self.onFinish = onFinish
    }

    public var body: some View {
        ShareRootView(
            session: host.session,
            shareFlow: host.shareFlow,
            contentState: host.contentState,
            settings: host.settings,
            activeProfile: host.activeProfile,
            copiedDuration: copiedDuration,
            onClose: onClose,
            onFinish: onFinish
        )
    }
}
