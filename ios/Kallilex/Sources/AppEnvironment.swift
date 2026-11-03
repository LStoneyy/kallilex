import Foundation
import KallilexKit
#if DEBUG
import Security
#endif

/// Why `AppEnvironment.start()` couldn't produce a working environment.
/// `KallilexApp` shows a `StartupErrorView` with specific copy for the two
/// cases `SettingsStore` distinguishes, and generic copy for everything
/// else — never crashes.
enum AppStartupError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case appGroupUnavailable(String)
    case other(String)

    init(_ error: Error) {
        switch error {
        case let storeError as SettingsStoreError:
            switch storeError {
            case .appGroupUnavailable(let id):
                self = .appGroupUnavailable(id)
            case .unsupportedSchemaVersion(let version):
                self = .unsupportedSchemaVersion(version)
            case .underlying(let message):
                self = .other(message)
            }
        default:
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .unsupportedSchemaVersion:
            String(
                localized: "startup.error.unsupportedSchemaVersion",
                defaultValue: "These settings were saved by a newer version of Kallilex. Update the app to continue."
            )
        case .appGroupUnavailable:
            String(
                localized: "startup.error.appGroupUnavailable",
                defaultValue: "Kallilex couldn't access its shared storage. Try reinstalling the app."
            )
        case .other:
            String(
                localized: "startup.error.generic",
                defaultValue: "Kallilex couldn't load its settings. Try restarting the app."
            )
        }
    }
}

/// Root app state, injected through `.environment(_:)` and shared by every
/// tab (ios-06). `settings` is the single source of truth for the UI;
/// mutations go through `perform(_:)`, which composes a `SettingsService`
/// operation with a reload and error surfacing, so views never call
/// `settingsStore`/`secretStore` directly.
@Observable @MainActor
final class AppEnvironment: Sendable {
    let settingsStore: any SettingsStore
    let secretStore: any SecretStore
    let actionRunner: ActionRunner
    let service: SettingsService

    private(set) var settings: AppSettings
    var lastError: String?

    init(
        settingsStore: any SettingsStore,
        secretStore: any SecretStore,
        actionRunner: ActionRunner,
        settings: AppSettings
    ) {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.actionRunner = actionRunner
        self.service = SettingsService(settings: settingsStore, secrets: secretStore)
        self.settings = settings
    }

    /// Reloads `settings` from `settingsStore`, so the UI picks up anything
    /// the Share Extension wrote while the app was backgrounded. Called
    /// when the scene becomes active. Never throws: a failure is reported
    /// through `lastError`, same as `perform(_:)`.
    func reload() {
        do {
            settings = try settingsStore.load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs `op` against `service`, reloads `settings` on success, and
    /// surfaces a failure through `lastError` instead of throwing — every
    /// profile/prompt/consent mutation goes through this single seam.
    func perform(_ op: (SettingsService) throws -> Void) {
        do {
            try op(service)
            reload()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Same pattern as `perform(_:)`, but for the plain `AppSettings` flags
    /// (`autoRunFirstPrompt`, `autoCopyResult`, `onboardingCompleted`) that
    /// `SettingsService` has no dedicated operation for — it only covers
    /// profiles, prompts and consents. Goes straight through
    /// `settingsStore.update(_:)`, the same atomic read-modify-write seam
    /// every `SettingsService` operation itself is built on.
    func updateSettings(_ body: (inout AppSettings) throws -> Void) {
        do {
            settings = try settingsStore.update(body)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The production startup path (`KallilexApp.init`): builds the real
    /// stores from `Info.plist`, loads the first settings snapshot, and
    /// reports whether that load recovered from a corrupt settings file.
    /// Never throws — every failure (App Group unavailable, an unsupported
    /// schema version, or anything else) is reported through the `Result`.
    static func start() -> Result<(environment: AppEnvironment, recoveredFromCorruption: Bool), AppStartupError> {
        #if DEBUG
        applyUITestLaunchArguments()
        #endif
        do {
            let settingsStore = try AppGroupSettingsStore(appGroupId: InfoPlist.kallilexAppGroup)
            let secretStore = KeychainSecretStore(accessGroup: InfoPlist.kallilexKeychainAccessGroup)
            let runner = ActionRunner(
                settings: settingsStore,
                secrets: secretStore,
                makeProvider: Self.providerFactory()
            )
            let loaded = try settingsStore.load()
            let recovered = settingsStore.consumeRecoveredFromCorruption()
            let environment = AppEnvironment(
                settingsStore: settingsStore,
                secretStore: secretStore,
                actionRunner: runner,
                settings: loaded
            )
            return .success((environment, recovered))
        } catch {
            return .failure(AppStartupError(error))
        }
    }

    /// The production provider factory, except under `DEBUG` when launched
    /// with `-uiTestStubProvider`: then every profile resolves to a stub
    /// provider that echoes the input text uppercased, so XCUITests (part
    /// 2 of this spec) can exercise "Test connection" and the Scratchpad
    /// without a real network call.
    private static func providerFactory() -> @Sendable (ProviderProfile, String?) -> any TextProvider {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestStubProvider") {
            return { _, _ in UppercasingStubProvider() }
        }
        #endif
        return ActionRunner.defaultProviderFactory
    }

    #if DEBUG
    /// The Keychain service `KeychainSecretStore` uses for provider API keys,
    /// so `-uiTestResetState` clears exactly what the app stores.
    private static let uiTestKeychainService = KeychainSecretStore.defaultService

    /// Applies the two UI-test-only launch arguments (ios-06 part 2),
    /// before any `SettingsStore`/`SecretStore` is created, so every test
    /// starts from known state:
    /// - `-uiTestResetState`: deletes `settings.json`, any
    ///   `settings.corrupt-*.json` backup, and every stored API key, so
    ///   each test starts from a fresh install.
    /// - `-uiTestCorruptSettings`: writes an unparseable `settings.json`,
    ///   so the corruption-recovery path (and its one-time alert) can be
    ///   exercised deterministically. Applied after the reset above, so
    ///   combining both arguments always yields exactly one corrupt file.
    /// - `-uiTestSkipOnboarding` (ios-07): writes `onboardingCompleted =
    ///   true` through the real `SettingsStore` (merging onto whatever's
    ///   already there — a fresh install after `-uiTestResetState`, or an
    ///   existing file from an earlier launch in the same test), so every
    ///   pre-existing UI test (which never expects a first-run onboarding
    ///   cover) keeps passing once `RootTabView` starts gating the tab UI
    ///   behind it. Independent of `-uiTestResetState`: `KallilexUITestCase
    ///   .launchApp` passes it on *every* launch by default, including a
    ///   `resetState: false` relaunch — e.g. right after
    ///   `-uiTestCorruptSettings`'s own recovery leaves no file on disk at
    ///   all, a plain relaunch would otherwise see a fresh
    ///   `onboardingCompleted == false` and show onboarding instead of the
    ///   tab UI that test actually wants to assert on. Applied *before*
    ///   `-uiTestCorruptSettings` below, so a launch requesting both still
    ///   ends up with a genuinely corrupt file — onboarding's own tests
    ///   opt out of this argument entirely.
    private static func applyUITestLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTestResetState")
            || arguments.contains("-uiTestCorruptSettings")
            || arguments.contains("-uiTestSkipOnboarding") else {
            return
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: InfoPlist.kallilexAppGroup
        ) else {
            return
        }
        if arguments.contains("-uiTestResetState") {
            resetUITestState(in: container)
        }
        if arguments.contains("-uiTestSkipOnboarding") {
            skipOnboardingUITestState(in: container)
        }
        if arguments.contains("-uiTestCorruptSettings") {
            writeCorruptSettingsFile(in: container)
        }
    }

    private static func resetUITestState(in container: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: container.appendingPathComponent("settings.json"))
        if let contents = try? fileManager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("settings.corrupt-") {
                try? fileManager.removeItem(at: url)
            }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: uiTestKeychainService,
        ]
        let accessGroup = InfoPlist.kallilexKeychainAccessGroup
        if !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Sets `onboardingCompleted = true` through the same
    /// `AppGroupSettingsStore` the app itself will use — `update`'s own
    /// read-modify-write merges onto whatever's already on disk (seeded
    /// defaults if `settings.json` is missing, e.g. right after
    /// `resetUITestState` or after a corruption-recovery rename; the
    /// existing file's every other field, otherwise) instead of needing any
    /// hand-rolled JSON kept in sync with `AppSettings`'s own encoding.
    private static func skipOnboardingUITestState(in container: URL) {
        let store = AppGroupSettingsStore(directory: container)
        _ = try? store.update { $0.onboardingCompleted = true }
    }

    private static func writeCorruptSettingsFile(in container: URL) {
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let data = Data("{not valid json".utf8)
        try? data.write(to: container.appendingPathComponent("settings.json"), options: .atomic)
    }
    #endif
}

#if DEBUG
/// A `TextProvider` that returns `userText` uppercased, ignoring
/// `systemPrompt` — used only for XCUITests via `-uiTestStubProvider`.
private struct UppercasingStubProvider: TextProvider {
    func complete(systemPrompt: String, userText: String) async throws -> String {
        userText.uppercased()
    }
}
#endif
