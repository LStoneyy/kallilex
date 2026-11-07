import UIKit
import SwiftUI
import Observation
import KallilexKit
import KallilexKeyboardCore

/// The keyboard's real `UIInputViewController` (ios-18, PLAN-keyboard.md
/// §10.1/§10.3): composes the UIKit `ScratchpadTextView` and `KeyGridView`
/// with one SwiftUI `UIHostingController` (`KeyboardRootView`), reattaches
/// to the process-wide `KeyboardModel` on every appearance, and loads
/// settings (with or without Full Access) on `viewWillAppear`.
///
/// `KeyboardExtension`'s `KeyboardViewController` is a thin subclass of
/// this; the app's own DEBUG-only keyboard harness (part B of ios-18) is
/// another. Both reach the real UI/behavior through the `open` seams
/// below rather than duplicating this class: `effectiveHasFullAccess`,
/// `makeSettingsStore()`, `makeSecretStore()`, and
/// `makeProviderFactory()` — the same seam `AppEnvironment`'s
/// `-uiTestStubProvider` uses on the app side, mirrored here so the
/// harness can swap in a stub provider the same way.
///
/// Stays extension-API-safe: no `UIApplication.shared` anywhere in this
/// file, since `KallilexUI` is also linked by the Share Extension.
open class KallilexKeyboardController: UIInputViewController {
    /// The keyboard's fixed height on a 6.1" iPhone (ios-15 spike,
    /// unknown 9), scaled by the current screen's height for other sizes.
    public static let baseHeight: CGFloat = 300
    /// The reference screen height `baseHeight` was measured against: a
    /// 6.1" iPhone's logical point height (e.g. iPhone 16).
    public static let referenceScreenHeight: CGFloat = 852

    private var model: KeyboardModel?
    private var hostDocumentWrapper: HostDocument?
    private var scratchpadDocumentWrapper: ScratchpadDocument?

    private let scratchpadTextView = ScratchpadTextView()
    private var keyGridView: KeyGridView!
    private var hostingController: UIHostingController<KeyboardRootView>!

    private var heightConstraint: NSLayoutConstraint?
    private var promptsModeConstraints: [NSLayoutConstraint] = []
    private var keysModeConstraints: [NSLayoutConstraint] = []
    private var showsGlobeInPanel = false

    // MARK: - Seams (overridable by the thin extension subclass and by
    // the app's DEBUG-only harness, part B)

    /// Whether the keyboard currently has Full Access — `hasFullAccess`
    /// by default. Overridable so a harness/test can force either state
    /// without actually toggling it in Settings.
    open var effectiveHasFullAccess: Bool { hasFullAccess }

    /// Builds the `SettingsStore` the keyboard loads/runs against:
    /// read-write with Full Access, read-only (ios-16) without — chosen
    /// fresh on every call via `effectiveHasFullAccess`, so a Full Access
    /// change takes effect without the keyboard needing to be relaunched.
    /// Overridable for a harness that needs a different App Group or a
    /// different store entirely.
    open func makeSettingsStore() throws -> any SettingsStore {
        let appGroupStore = try AppGroupSettingsStore(appGroupId: InfoPlist.kallilexAppGroup)
        return DynamicAccessSettingsStore(store: appGroupStore, hasFullAccess: { [weak self] in
            self?.effectiveHasFullAccess ?? false
        })
    }

    /// Builds the `SecretStore` for API keys. Overridable for a harness.
    open func makeSecretStore() -> any SecretStore {
        KeychainSecretStore(accessGroup: InfoPlist.kallilexKeychainAccessGroup)
    }

    /// Builds the provider factory `ActionRunner` uses.
    /// `ActionRunner.defaultProviderFactory` by default; the app's
    /// DEBUG-only harness overrides this to return a stub provider under
    /// `-uiTestStubProvider`, the same launch argument `AppEnvironment`
    /// checks on the app side.
    open func makeProviderFactory() -> @Sendable (ProviderProfile, String?) -> any TextProvider {
        ActionRunner.defaultProviderFactory
    }

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        setUpHeightConstraint()

        let (model, hostDocument, scratchpadDocument) = KeyboardModelStore.shared.modelOrMake {
            self.makeModel()
        }
        self.model = model
        hostDocumentWrapper = hostDocument
        scratchpadDocumentWrapper = scratchpadDocument
        reattachDocuments()
        model.activeContextProvider = { [weak self] in
            self?.currentKeyboardContext() ?? KeyboardContext(autocapitalization: .sentences)
        }

        setUpScratchpad(model: model)
        scratchpadTextView.text = model.session.displayedText
        scratchpadTextView.isEditable = model.session.isEditable

        setUpKeyGrid(model: model)
        setUpHostingController(model: model)
        setUpLayoutConstraints()

        applyMode(model.mode, animated: false)
        trackModeChanges()
        trackEditableChanges()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeightConstraint()
        reattachDocuments()
        reloadSettings()
    }

    /// Disables `delaysTouchesBegan` on the window's own gesture
    /// recognizers once the keyboard is actually in a window: in a
    /// keyboard extension, the system's edge-gesture gate (for the
    /// interactive dismiss/switch-keyboard gesture) otherwise delays
    /// `touchesBegan` for touches near the screen edges — the left
    /// column and bottom row of keys — which reads as sluggish fast
    /// typing even though this view's own touch handling is instant.
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeightConstraint()
        keyGridView?.showsGlobe = needsInputModeSwitchKey
        keyGridView?.keyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
        if showsGlobeInPanel != needsInputModeSwitchKey {
            showsGlobeInPanel = needsInputModeSwitchKey
            rebuildHostingRootView()
        }
    }

    /// Cancels an in-flight run (PLAN-keyboard.md §10.3's "Session and
    /// lifecycle"). The model itself survives — only the controller is
    /// about to be deallocated (ios-15 spike, unknown 10) — so the host/
    /// Scratchpad document wrappers are detached too, rather than left
    /// pointing at a `textDocumentProxy`/`UITextView` that's going away.
    /// Also cancels any in-progress key press: a held delete (or a
    /// letter mid-long-press) must not keep its `Timer` firing, or keep
    /// its popup on screen, once the keyboard is gone.
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model?.cancelForDisappear()
        keyGridView?.cancelActivePress()
        hostDocumentWrapper?.detach()
        scratchpadDocumentWrapper?.detach()
    }

    /// Rebuilds the `KeyboardContext` for auto-capitalization when typing
    /// into the host app (the Scratchpad's own context is rebuilt by
    /// `ScratchpadTextView`'s `onTextChanged`/`onSelectionChanged`).
    open override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard let model, model.target == .host else { return }
        model.contextDidChange(currentKeyboardContext())
    }

    open override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard let model, model.target == .host else { return }
        model.contextDidChange(currentKeyboardContext())
    }

    // MARK: - Model / session construction

    private func makeModel() -> (KeyboardModel, HostDocument, ScratchpadDocument) {
        let hostDocument = HostDocument()
        let scratchpadDocument = ScratchpadDocument()
        let session = makeSession()
        let model = KeyboardModel(session: session, scratchpadDocument: scratchpadDocument, hostDocument: hostDocument)
        return (model, hostDocument, scratchpadDocument)
    }

    private func makeSession() -> EditorSession {
        let pasteboard = KeyboardPasteboard(hasFullAccess: { [weak self] in self?.effectiveHasFullAccess ?? false })
        do {
            let settingsStore = try makeSettingsStore()
            let secretStore = makeSecretStore()
            let runner = ActionRunner(settings: settingsStore, secrets: secretStore, makeProvider: makeProviderFactory())
            return EditorSession(
                actionRunner: runner,
                pasteboard: pasteboard,
                consentGranting: SettingsServiceConsentGranter(
                    settingsService: SettingsService(settings: settingsStore, secrets: secretStore)
                )
            )
        } catch {
            // The App Group container itself is unavailable: there is no
            // settings to load and no profile to run against, mirroring
            // `ShareViewController`'s same fallback.
            return EditorSession(
                actionRunner: UnreachableActionRunner(),
                pasteboard: pasteboard,
                consentGranting: UnreachableConsentGranter()
            )
        }
    }

    /// Re-points the host/Scratchpad document wrappers at this
    /// controller's own `textDocumentProxy`/`scratchpadTextView` — called
    /// from `viewWillAppear` (idempotent) as well as `viewDidLoad`,
    /// because `KeyboardModelStore` can hand back an *existing* model
    /// whose documents were `detach()`ed by a previous controller's
    /// `viewWillDisappear`; without this, UIKit reusing a controller
    /// instance (appear → disappear → appear again without a fresh
    /// `viewDidLoad`) would leave typing silently going nowhere.
    private func reattachDocuments() {
        hostDocumentWrapper?.attach(textDocumentProxy)
        if let scratchpadDocumentWrapper {
            scratchpadDocumentWrapper.attach(scratchpadTextView)
        }
    }

    private func reloadSettings() {
        guard let model else { return }
        do {
            model.settings = try makeSettingsStore().load()
        } catch {
            // Leave whatever snapshot is already loaded (if any) rather
            // than clearing prompts the user can already see.
        }
    }

    // MARK: - View setup

    private func setUpHeightConstraint() {
        let constraint = view.heightAnchor.constraint(equalToConstant: Self.baseHeight)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func updateHeightConstraint() {
        let screenHeight = view.window?.windowScene?.screen.bounds.height ?? Self.referenceScreenHeight
        guard screenHeight > 0 else { return }
        let scale = screenHeight / Self.referenceScreenHeight
        heightConstraint?.constant = (Self.baseHeight * scale).rounded()
    }

    private func setUpScratchpad(model: KeyboardModel) {
        scratchpadTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scratchpadTextView)
        scratchpadTextView.onTextChanged = { [weak model] text in
            guard let model, model.session.isEditable else { return }
            model.session.text = text
            model.contextDidChange(KeyboardContext(
                autocapitalization: .sentences,
                textBeforeCursor: model.scratchpadDocument.documentContextBeforeInput
            ))
        }
        scratchpadTextView.onSelectionChanged = { [weak model] in
            guard let model else { return }
            model.contextDidChange(KeyboardContext(
                autocapitalization: .sentences,
                textBeforeCursor: model.scratchpadDocument.documentContextBeforeInput
            ))
        }
        // A tap into the Scratchpad places the caret (default `UITextView`
        // behavior) and sets the typing target to Scratchpad, in either
        // mode — but never switches the mode itself: prompt mode's own
        // Scratchpad tap (e.g. to reposition the caret before running a
        // prompt) must not silently jump to keys mode underneath the user
        // (ios-18 bugfix item 8).
        scratchpadTextView.onBeginEditing = { [weak model] in
            model?.target = .scratchpad
        }
    }

    private func setUpKeyGrid(model: KeyboardModel) {
        let grid = KeyGridView(model: model)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.layoutID = model.keyboardLayoutID
        grid.showsGlobe = needsInputModeSwitchKey
        grid.keyboardAppearance = textDocumentProxy.keyboardAppearance ?? .default
        grid.returnKeyLabel = { [weak self] in self?.currentReturnKeyLabel() ?? "return" }
        grid.buildContext = { [weak self] in self?.currentKeyboardContext() ?? KeyboardContext(autocapitalization: .sentences) }
        grid.onGlobeTouch = { [weak self] touchView, event in
            self?.handleInputModeList(from: touchView, with: event)
        }
        view.addSubview(grid)
        keyGridView = grid
    }

    private func setUpHostingController(model: KeyboardModel) {
        showsGlobeInPanel = needsInputModeSwitchKey
        let hosting = UIHostingController(rootView: makeRootView(model: model))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    private func makeRootView(model: KeyboardModel) -> KeyboardRootView {
        KeyboardRootView(model: model, showsGlobe: showsGlobeInPanel, onGlobe: { [weak self] in
            guard let self else { return }
            // The SwiftUI 🌐 (prompt mode's action row) has no real touch
            // event to forward, unlike `KeyGridView`'s own globe key —
            // `handleInputModeList(from:with:)` still shows the list for a
            // single tap; only long-press-for-the-list needs a genuine
            // touch stream, which only the UIKit key grid can provide.
            self.handleInputModeList(from: self.view, with: UIEvent())
        })
    }

    private func rebuildHostingRootView() {
        guard let model, let hostingController else { return }
        hostingController.rootView = makeRootView(model: model)
    }

    private func setUpLayoutConstraints() {
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scratchpadTextView.topAnchor.constraint(equalTo: margins.topAnchor, constant: 4),
            scratchpadTextView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            scratchpadTextView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            hostingController.view.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            keyGridView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            keyGridView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            keyGridView.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])

        promptsModeConstraints = [
            scratchpadTextView.bottomAnchor.constraint(equalTo: hostingController.view.topAnchor, constant: -4),
            hostingController.view.heightAnchor.constraint(equalToConstant: KeyboardPromptMetrics.total),
            hostingController.view.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ]

        keysModeConstraints = [
            scratchpadTextView.heightAnchor.constraint(equalToConstant: 66),
            hostingController.view.topAnchor.constraint(equalTo: scratchpadTextView.bottomAnchor, constant: 2),
            hostingController.view.heightAnchor.constraint(equalToConstant: 36),
            keyGridView.topAnchor.constraint(equalTo: hostingController.view.bottomAnchor, constant: 2),
        ]
    }

    // MARK: - Mode crossfade (0.2 s; the height itself never animates)

    private func applyMode(_ mode: KeyboardUIMode, animated: Bool) {
        let apply = { [weak self] in
            guard let self else { return }
            switch mode {
            case .prompts:
                NSLayoutConstraint.deactivate(self.keysModeConstraints)
                NSLayoutConstraint.activate(self.promptsModeConstraints)
                self.keyGridView.isHidden = true
            case .keys:
                NSLayoutConstraint.deactivate(self.promptsModeConstraints)
                NSLayoutConstraint.activate(self.keysModeConstraints)
                self.keyGridView.isHidden = false
            }
            self.view.layoutIfNeeded()
        }
        guard animated else {
            apply()
            return
        }
        UIView.transition(with: view, duration: 0.2, options: .transitionCrossDissolve, animations: apply)
    }

    /// Re-registers itself on every change — the standard pattern for
    /// consuming `@Observable` state outside of a SwiftUI `body`.
    private func trackModeChanges() {
        withObservationTracking(
            { [weak self] in _ = self?.model?.mode },
            onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, let model = self.model else { return }
                    self.applyMode(model.mode, animated: true)
                    self.trackModeChanges()
                }
            }
        )
    }

    private func trackEditableChanges() {
        withObservationTracking(
            { [weak self] in _ = self?.model?.session.isEditable },
            onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, let model = self.model else { return }
                    self.scratchpadTextView.isEditable = model.session.isEditable
                    self.trackEditableChanges()
                }
            }
        )
    }

    // MARK: - Context / return key label

    private func currentKeyboardContext() -> KeyboardContext {
        guard let model else { return KeyboardContext(autocapitalization: .sentences) }
        switch model.target {
        case .scratchpad:
            return KeyboardContext(
                autocapitalization: .sentences,
                textBeforeCursor: model.scratchpadDocument.documentContextBeforeInput
            )
        case .host:
            return KeyboardContext(
                autocapitalization: Self.autocapitalization(for: textDocumentProxy.autocapitalizationType ?? .sentences),
                textBeforeCursor: textDocumentProxy.documentContextBeforeInput
            )
        }
    }

    private func currentReturnKeyLabel() -> String {
        guard let model else { return "return" }
        switch model.target {
        case .scratchpad:
            return "return"
        case .host:
            return Self.returnKeyLabel(for: textDocumentProxy.returnKeyType ?? .default)
        }
    }

    private static func autocapitalization(for type: UITextAutocapitalizationType) -> Autocapitalization {
        switch type {
        case .none: return .none
        case .words: return .words
        case .sentences: return .sentences
        case .allCharacters: return .allCharacters
        @unknown default: return .sentences
        }
    }

    private static func returnKeyLabel(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: return "Go"
        case .google: return "Google"
        case .join: return "Join"
        case .next: return "Next"
        case .route: return "Route"
        case .search: return "Search"
        case .send: return "Send"
        case .yahoo: return "Yahoo"
        case .done: return "Done"
        case .emergencyCall: return "SOS"
        case .continue: return "Continue"
        default: return "return"
        }
    }
}

/// Wraps `AppGroupSettingsStore`, choosing `load()` vs `loadReadOnly()` on
/// every call based on `hasFullAccess()` — read fresh each time, so
/// `ActionRunner` (built once, in `viewDidLoad`, and kept alive by the
/// process-wide `KeyboardModel`) still respects a Full Access change
/// without the keyboard needing to be relaunched. Writes always require
/// Full Access; the keyboard's own `ActionRunner` never writes, but a
/// future caller that tried to would get `SettingsStoreError.readOnly`
/// rather than a silent no-op.
///
/// `@unchecked Sendable`: `SettingsStore` requires `Sendable`, but
/// `hasFullAccess` captures `[weak self]` on the (non-`Sendable`)
/// controller that builds this. Safe in practice for the same reason as
/// `KeyboardPasteboard`: both the closure and every `SettingsStore`
/// method here are only ever called from the main actor.
private struct DynamicAccessSettingsStore: SettingsStore, @unchecked Sendable {
    let store: AppGroupSettingsStore
    let hasFullAccess: () -> Bool

    func load() throws -> AppSettings {
        hasFullAccess() ? try store.load() : try store.loadReadOnly()
    }

    func save(_ settings: AppSettings) throws {
        guard hasFullAccess() else { throw SettingsStoreError.readOnly }
        try store.save(settings)
    }

    @discardableResult
    func update(_ body: (inout AppSettings) throws -> Void) throws -> AppSettings {
        guard hasFullAccess() else { throw SettingsStoreError.readOnly }
        return try store.update(body)
    }
}

/// Used only on the `makeSettingsStore()` failure path (no App Group),
/// where there is no working `ActionRunner` to speak of — mirrors
/// `ShareViewController`'s private fallback of the same name/shape.
private struct UnreachableActionRunner: ActionRunning {
    func run(text: String, action: Action) async -> RunOutcome { .notConfigured }
}

private struct UnreachableConsentGranter: ConsentGranting {
    func grantConsent(profileID: String, host: String) throws {}
}
