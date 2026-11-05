import UIKit
import KallilexKit

/// Principal class for the Keyboard Extension (ios-16, PLAN-keyboard.md
/// §10.1/§10.3). A placeholder ahead of the real Scratchpad keyboard
/// (ios-18): one row with a globe key, shown only when
/// `needsInputModeSwitchKey` is true, and a label with the number of
/// prompts it could load — which proves the read-without-Full-Access path
/// (ios-15 spike, unknown 2) on a device. `APPLICATION_EXTENSION_API_ONLY`
/// (set on the target) means no `UIApplication.shared` anywhere in this
/// file or in anything it calls.
final class KeyboardViewController: UIInputViewController {
    /// Matches the spike's measured height budget (ios-15, unknown 9):
    /// a fixed height is fine for this placeholder; ios-18 may revisit it.
    private static let placeholderHeight: CGFloat = 216

    private let promptCountLabel = UILabel()
    private var globeKey: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: Self.placeholderHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        promptCountLabel.translatesAutoresizingMaskIntoConstraints = false
        promptCountLabel.font = .preferredFont(forTextStyle: .body)
        promptCountLabel.textAlignment = .center
        view.addSubview(promptCountLabel)
        NSLayoutConstraint.activate([
            promptCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            promptCountLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        updateGlobeKey()
        promptCountLabel.text = promptCountText()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateGlobeKey()
    }

    /// Adds or removes the globe key as `needsInputModeSwitchKey` changes
    /// (it can change after `viewDidLoad`, e.g. once another keyboard is
    /// installed or removed), wiring it to the standard
    /// `handleInputModeList(from:with:)` action on every touch event, as
    /// Apple's own templates do.
    private func updateGlobeKey() {
        guard needsInputModeSwitchKey else {
            globeKey?.removeFromSuperview()
            globeKey = nil
            return
        }
        guard globeKey == nil else { return }

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("🌐", for: .normal)
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        globeKey = button
    }

    /// Reads `InfoPlist.kallilexAppGroup` exactly like `ShareViewController`
    /// — no hardcoded fallback, so a build misconfiguration fails loudly
    /// (via `InfoPlist`'s own `preconditionFailure`) rather than silently
    /// pointing at the wrong shared storage. Uses `loadReadOnly()` without
    /// Full Access (a plain, uncoordinated read — even a read-only
    /// coordinated access fails there, ios-15 spike unknown 2) and
    /// `load()` with it.
    private func promptCountText() -> String {
        guard let store = try? AppGroupSettingsStore(appGroupId: InfoPlist.kallilexAppGroup) else {
            return "App Group unavailable"
        }
        let settings: AppSettings
        do {
            settings = hasFullAccess ? try store.load() : try store.loadReadOnly()
        } catch {
            return "Settings unreadable"
        }
        return "\(settings.prompts.count) prompts"
    }
}
