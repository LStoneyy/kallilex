import UIKit
import os
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
    /// Prompt mode's expanded layout (ios-19 part B, "Expanded panel"):
    /// hides `scratchpadTextView` and lets `hostingController.view` take
    /// the full height down to the bottom, its top pinned where the
    /// Scratchpad's own top is — active instead of `promptsModeConstraints`
    /// while `model.isPanelExpanded` is `true`. The keyboard's own fixed
    /// `heightConstraint` never changes either way.
    private var expandedPromptsModeConstraints: [NSLayoutConstraint] = []
    private var showsGlobeInPanel = false

    // MARK: - Seams (overridable by the thin extension subclass and by
    // the app's DEBUG-only harness, part B)

    /// Whether the keyboard currently has Full Access — `hasFullAccess`
    /// by default. Overridable so a harness/test can force either state
    /// without actually toggling it in Settings.
    open var effectiveHasFullAccess: Bool { hasFullAccess }

    /// The process-wide Full Access flag the long-lived pasteboard and
    /// settings-store closures read (ios-19 part B, latent-bug fix).
    /// `makeSession()` runs once per process, but the controller it runs
    /// on is deallocated on the first `viewWillDisappear` — a `[weak
    /// self]` capture there went `false` (read-only, no Copy) forever.
    /// Every controller writes this on `viewDidLoad`/`viewWillAppear`.
    /// A lock rather than a `@MainActor` read, because `ActionRunner.run`
    /// calls `settings.load()` off the main actor.
    nonisolated static let sharedHasFullAccess = OSAllocatedUnfairLock(initialState: false)

    private func publishFullAccess() {
        let value = effectiveHasFullAccess
        Self.sharedHasFullAccess.withLock { $0 = value }
        model?.hasFullAccess = value
    }

    /// Builds the `SettingsStore` the keyboard loads/runs against:
    /// read-write with Full Access, read-only (ios-16) without — chosen
    /// fresh on every call via `sharedHasFullAccess`, so a Full Access
    /// change takes effect without the keyboard needing to be relaunched.
    /// Overridable for a harness that needs a different App Group or a
    /// different store entirely.
    open func makeSettingsStore() throws -> any SettingsStore {
        let appGroupStore = try AppGroupSettingsStore(appGroupId: InfoPlist.kallilexAppGroup)
        return DynamicAccessSettingsStore(store: appGroupStore, hasFullAccess: { @Sendable in
            KallilexKeyboardController.sharedHasFullAccess.withLock { $0 }
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

    /// Opens iOS Settings through the responder chain (ios-19 part B,
    /// "Opening Settings") — the Full Access card's Settings button.
    /// Never `UIApplication.shared` (unavailable to extensions) and never
    /// `App-prefs:` (private API); proven on device by the ios-15 spike's
    /// `KeyboardViewController.openViaResponderChain`.
    open func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
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
        publishFullAccess()
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

        applyLayout(animated: false)
        trackModeChanges()
        trackPanelExpansion()
        trackEditableChanges()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeightConstraint()
        reattachDocuments()
        publishFullAccess()
        reloadSettings()
        // `setUpKeyGrid` sets `keyGridView.layoutID` once, in `viewDidLoad`
        // — but the process-wide `KeyboardModel` (and the settings
        // `reloadSettings()` just refreshed) can outlive that single
        // `viewDidLoad` across many `viewWillAppear`s, so a fresh process
        // would otherwise keep showing whatever layout was current at
        // `viewDidLoad` time (the device language, before any stored
        // `AppSettings.keyboardLayout` was even loaded) instead of the
        // layout the user picked (ios-22). `KeyGridView.layoutID`'s
        // `didSet` already rebuilds only on an actual change, so this is a
        // cheap no-op on every appearance after the first.
        if let model {
            keyGridView?.layoutID = model.keyboardLayoutID
        }
        model?.resetSelectionSharingHintForAppearance()
        model?.refreshHostSelection()
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
        model?.invalidateHostUndoOnDisappear()
        // ios-19 part B, "the flag is also cleared when … viewWillDisappear
        // runs": the card is about to disappear along with everything
        // else; nothing about why it was shown can be trusted on return.
        model?.showsFullAccessCard = false
        keyGridView?.cancelActivePress()
        hostDocumentWrapper?.detach()
        scratchpadDocumentWrapper?.detach()
    }

    /// Forwards to `KeyboardModel.hostTextDidChange()` unconditionally
    /// (ios-19 spec: the Undo Insert guard tracks the host's own text
    /// regardless of the current typing target), then — only while typing
    /// into the host — rebuilds the `KeyboardContext` for auto-
    /// capitalization (the Scratchpad's own context is rebuilt by
    /// `ScratchpadTextView`'s `onTextChanged`/`onSelectionChanged`).
    open override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model?.hostTextDidChange()
        guard let model, model.target == .host else { return }
        model.contextDidChange(currentKeyboardContext())
    }

    /// Forwards to `KeyboardModel.hostSelectionDidChange()` (the Undo
    /// Insert guard plus the take-over rules) unconditionally, same
    /// reasoning as `textDidChange(_:)` above, then rebuilds the host's
    /// `KeyboardContext` only while typing into it.
    open override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model?.hostSelectionDidChange()
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

    /// `makeSession()` runs exactly once per process (the model/session it
    /// builds are process-wide via `KeyboardModelStore`) — see
    /// `sharedHasFullAccess` for why `pasteboard`'s own `hasFullAccess`
    /// closure doesn't capture `self`.
    private func makeSession() -> EditorSession {
        publishFullAccess()
        let pasteboard = KeyboardPasteboard(hasFullAccess: { @Sendable in
            KallilexKeyboardController.sharedHasFullAccess.withLock { $0 }
        })
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
        KeyboardRootView(
            model: model,
            showsGlobe: showsGlobeInPanel,
            onGlobe: { [weak self] in
                guard let self else { return }
                // The SwiftUI 🌐 (prompt mode's action row) has no real
                // touch event to forward, unlike `KeyGridView`'s own globe
                // key — `handleInputModeList(from:with:)` still shows the
                // list for a single tap; only long-press-for-the-list
                // needs a genuine touch stream, which only the UIKit key
                // grid can provide.
                self.handleInputModeList(from: self.view, with: UIEvent())
            },
            onOpenSettings: { [weak self] in self?.openSystemSettings() }
        )
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

        // ios-19 part B, "Expanded panel": the Scratchpad is hidden
        // (`isHidden`), but its own top/leading/trailing anchors above
        // stay active, so it still needs a well-defined height — zero —
        // rather than an ambiguous one. `hostingController.view` then
        // spans from exactly that (now zero-height) top point down to the
        // margins' bottom, i.e. the same vertical space
        // `scratchpadTextView` + `promptsModeConstraints`' hosting view
        // together occupy today, just reassigned entirely to the hosting
        // view.
        expandedPromptsModeConstraints = [
            scratchpadTextView.heightAnchor.constraint(equalToConstant: 0),
            hostingController.view.topAnchor.constraint(equalTo: scratchpadTextView.topAnchor),
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

    /// Applies whichever of the three constraint sets currently matches
    /// `model.mode`/`model.isPanelExpanded` (ios-18's mode crossfade, plus
    /// ios-19 part B's expanded panel within prompt mode). The keyboard's
    /// own fixed `heightConstraint` is untouched by any of the three.
    private func applyLayout(animated: Bool) {
        let apply = { [weak self] in
            guard let self, let model = self.model else { return }
            switch model.mode {
            case .prompts:
                NSLayoutConstraint.deactivate(self.keysModeConstraints)
                self.keyGridView.isHidden = true
                if model.isPanelExpanded {
                    NSLayoutConstraint.deactivate(self.promptsModeConstraints)
                    NSLayoutConstraint.activate(self.expandedPromptsModeConstraints)
                    self.scratchpadTextView.isHidden = true
                } else {
                    NSLayoutConstraint.deactivate(self.expandedPromptsModeConstraints)
                    NSLayoutConstraint.activate(self.promptsModeConstraints)
                    self.scratchpadTextView.isHidden = false
                }
            case .keys:
                NSLayoutConstraint.deactivate(self.promptsModeConstraints)
                NSLayoutConstraint.deactivate(self.expandedPromptsModeConstraints)
                NSLayoutConstraint.activate(self.keysModeConstraints)
                self.keyGridView.isHidden = false
                self.scratchpadTextView.isHidden = false
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
                    guard let self, self.model != nil else { return }
                    self.applyLayout(animated: true)
                    self.trackModeChanges()
                }
            }
        )
    }

    /// Same pattern as `trackModeChanges()`, for `model.isPanelExpanded`
    /// (ios-19 part B) — both call the same `applyLayout(animated:)`,
    /// which reads both properties fresh every time, so whichever one
    /// changes first still produces the right constraint set.
    private func trackPanelExpansion() {
        withObservationTracking(
            { [weak self] in _ = self?.model?.isPanelExpanded },
            onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.model != nil else { return }
                    self.applyLayout(animated: true)
                    self.trackPanelExpansion()
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
/// `@unchecked Sendable`: `SettingsStore` requires `Sendable`, and the
/// stored closure type is a plain `() -> Bool`; the production closure is
/// `@Sendable` and only reads the lock-protected
/// `KallilexKeyboardController.sharedHasFullAccess`, so calling it from
/// `ActionRunner.run` off the main actor is safe.
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
