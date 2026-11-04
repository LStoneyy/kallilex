import KallilexKit
import KallilexUI
import UIKit

/// Writes to `UIPasteboard.general` — the app target's production
/// `Pasteboard` (ios-08). The Share Extension (ios-09) provides its own,
/// since it can't depend on this app target. Shared by `ScratchpadView` and
/// the DEBUG-only `ShareHarnessView` (ios-09 part B), which both own a real
/// `EditorSession` wired to the app's own `UIPasteboard`.
struct DevicePasteboard: Pasteboard {
    func setString(_ string: String) {
        UIPasteboard.general.string = string
    }
}

/// Wraps `SettingsServiceConsentGranter`'s underlying `SettingsService`
/// call so a successful grant also reloads `AppEnvironment.settings`:
/// without this, the Settings tab's consent list wouldn't reflect a grant
/// made from the Scratchpad (or the DEBUG-only `ShareHarnessView`, ios-09
/// part B) until the scene next became active.
struct ReloadingConsentGranter: ConsentGranting {
    let settingsService: SettingsService
    let reload: @Sendable () -> Void

    func grantConsent(profileID: String, host: String) throws {
        try settingsService.grantConsent(profileID: profileID, host: host)
        reload()
    }
}
