#if DEBUG
import SwiftUI
import UIKit
import KallilexKit
import KallilexUI

/// DEBUG-only in-app harness that hosts the real `KallilexKeyboardController`
/// 's view directly inside the app's own view hierarchy, so XCUITests can
/// drive the keyboard's UI from inside the app itself — mirrors
/// `ShareHarnessView`'s rationale for the Share Extension (ios-09), just for
/// the keyboard (ios-18 spec part B): there's no way to drive a real custom
/// keyboard extension from XCUITest either.
///
/// This embeds the controller's `view` as a child view controller
/// (`KeyboardControllerContainer`) rather than through the documented
/// `UIResponder.inputViewController` mechanism: empirically, on this
/// Simulator/iOS version, naming a `KallilexKeyboardController` instance as
/// a plain in-app `UITextView`'s `inputViewController` creates UIKit's
/// remote-keyboard-input window shell but never actually loads/renders the
/// controller's view inside it (confirmed with a bright debug background
/// color that never appeared on screen) — this is exactly the "doesn't work
/// on the simulator" case the ios-18 spec's decision boundary calls out,
/// with "embedding the controller's view directly with a fake
/// `textDocumentProxy`" as the named alternative, which is what this does.
/// `HarnessKeyboardController.textDocumentProxy` is overridden to a fake
/// (`FakeTextDocumentProxy`) backed directly by `harness.hostText`, since a
/// directly-embedded `UIInputViewController` has no real text input session
/// wiring it to whichever responder is first responder the way a true
/// input-view-controller presentation would.
///
/// Shown by `KallilexApp` instead of `RootTabView` when launched with
/// `-uiTestKeyboardHarness`. `-uiTestResetState` also clears
/// `KeyboardModelStore.shared`'s process-wide model, so each test starts
/// from a fresh keyboard state even though (unlike the real keyboard
/// extension's own process) the app process survives across XCUITest
/// launches within a test target run.
struct KeyboardHarnessView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var controller: HarnessKeyboardController?

    var body: some View {
        Group {
            if let controller {
                VStack(spacing: 0) {
                    KeyboardHarnessHostTextView(controller: controller)
                        .frame(maxHeight: .infinity)
                    KeyboardControllerContainer(controller: controller)
                        .frame(height: KallilexKeyboardController.baseHeight)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard controller == nil else { return }
            if ProcessInfo.processInfo.arguments.contains("-uiTestResetState") {
                KeyboardModelStore.shared.reset()
            }
            controller = HarnessKeyboardController(settingsStore: appEnv.settingsStore, secretStore: appEnv.secretStore)
        }
    }
}

/// Wraps `HarnessHostTextView` as a SwiftUI view, and points
/// `controller.hostTextView` at it. Identifier `harness.hostText` (ios-18
/// spec).
private struct KeyboardHarnessHostTextView: UIViewRepresentable {
    let controller: HarnessKeyboardController

    func makeUIView(context: Context) -> HarnessHostTextView {
        let textView = HarnessHostTextView()
        textView.accessibilityIdentifier = "harness.hostText"
        textView.accessibilityLabel = "Host text"
        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        // An empty `inputView`, same trick as `ScratchpadTextView`: becoming
        // first responder (below) places a visible caret without summoning
        // the real system keyboard, which would otherwise cover the
        // directly-embedded `KeyboardControllerContainer` underneath.
        textView.inputView = UIView()
        controller.hostTextView = textView
        return textView
    }

    func updateUIView(_ uiView: HarnessHostTextView, context: Context) {}
}

/// A plain `UITextView` that becomes first responder as soon as it's placed
/// in a window, with no extra tap needed, matching the ios-18 spec ("the
/// harness text view becomes first responder on appear").
final class HarnessHostTextView: UITextView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }
}

/// Embeds `controller`'s own `view` as a real child view controller, pinned
/// to every edge, so UIKit's normal containment lifecycle
/// (`viewWillAppear`/`viewDidAppear`/`viewWillDisappear`) fires exactly as
/// it would for any other child view controller — unlike the
/// `inputViewController` route this replaces (see `KeyboardHarnessView`'s
/// doc comment).
private struct KeyboardControllerContainer: UIViewControllerRepresentable {
    let controller: HarnessKeyboardController

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addChild(controller)
        container.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        controller.didMove(toParent: container)
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// The app-side `KallilexKeyboardController` subclass part B needs (ios-18
/// spec, "Keyboard harness (app, DEBUG)"): Full Access is always on (this
/// harness has no Settings toggle to flip it), and the settings/secret
/// stores are the app's own — the same App Group/Keychain the real keyboard
/// extension would read from — so state set up through the app's own UI
/// (providers, prompts) is visible to the harness too. `makeProviderFactory
/// ()` honors `-uiTestStubProvider`/`-uiTestStubProviderFails` exactly
/// like `AppEnvironment`'s own provider factory does on the app side.
///
/// `textDocumentProxy` is overridden to `FakeTextDocumentProxy`, backed by
/// `hostTextView` (set once `KeyboardHarnessHostTextView.makeUIView` builds
/// it) — see `KeyboardHarnessView`'s doc comment for why. `needsInputModeSwitchKey`
/// is overridden to `false`: this harness never offers another keyboard to
/// switch to, and the real getter's behavior outside a genuine keyboard
/// extension process is unverified.
final class HarnessKeyboardController: KallilexKeyboardController {
    private let harnessSettingsStore: any SettingsStore
    private let harnessSecretStore: any SecretStore
    private let fakeHostProxy = FakeTextDocumentProxy()

    /// Set by `KeyboardHarnessHostTextView.makeUIView` once the real
    /// `harness.hostText` view exists — `HarnessKeyboardController` itself
    /// is constructed first (in `KeyboardHarnessView.onAppear`), before
    /// SwiftUI builds that `UIViewRepresentable`.
    var hostTextView: UITextView? {
        get { fakeHostProxy.textView }
        set { fakeHostProxy.textView = newValue }
    }

    init(settingsStore: any SettingsStore, secretStore: any SecretStore) {
        self.harnessSettingsStore = settingsStore
        self.harnessSecretStore = secretStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var effectiveHasFullAccess: Bool { true }

    override var textDocumentProxy: UITextDocumentProxy { fakeHostProxy }

    override var needsInputModeSwitchKey: Bool { false }

    override func makeSettingsStore() throws -> any SettingsStore { harnessSettingsStore }

    override func makeSecretStore() -> any SecretStore { harnessSecretStore }

    override func makeProviderFactory() -> @Sendable (ProviderProfile, String?) -> any TextProvider {
        if ProcessInfo.processInfo.arguments.contains("-uiTestStubProviderFails") {
            return { _, _ in FailingStubProvider() }
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestStubProvider") {
            return { _, _ in UppercasingStubProvider() }
        }
        return ActionRunner.defaultProviderFactory
    }
}

/// A minimal `UITextDocumentProxy` backed directly by a plain `UITextView`
/// (`harness.hostText`), standing in for the real system-provided proxy a
/// genuinely-presented `UIInputViewController` would get. Only the members
/// `KallilexKeyboardController`/`HostDocument` actually read/call are
/// meaningfully implemented; the rest are inert, well-typed stand-ins.
private final class FakeTextDocumentProxy: NSObject, UITextDocumentProxy {
    weak var textView: UITextView?

    var hasText: Bool { !(textView?.text ?? "").isEmpty }

    func insertText(_ text: String) {
        textView?.insertText(text)
    }

    func deleteBackward() {
        textView?.deleteBackward()
    }

    var documentContextBeforeInput: String? {
        guard let textView, let range = textView.selectedTextRange,
              let start = textView.textRange(from: textView.beginningOfDocument, to: range.start)
        else { return nil }
        return textView.text(in: start)
    }

    var documentContextAfterInput: String? {
        guard let textView, let range = textView.selectedTextRange,
              let end = textView.textRange(from: range.end, to: textView.endOfDocument)
        else { return nil }
        return textView.text(in: end)
    }

    var selectedText: String? {
        guard let textView, let range = textView.selectedTextRange, !range.isEmpty else { return nil }
        return textView.text(in: range)
    }

    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }

    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}

    // MARK: - UITextInputTraits

    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var isSecureTextEntry: Bool = false
}
#endif
