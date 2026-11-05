import KallilexUI

/// Principal class for the Keyboard Extension (ios-18, PLAN-keyboard.md
/// §10.1/§10.3). The real UI and behavior all live in
/// `KallilexKeyboardController` (`KallilexUI`), which already reads the
/// App Group and Keychain access group straight from `Info.plist` via
/// `InfoPlist` — the same thing the ios-16 placeholder this replaces did
/// — so there is nothing extension-specific left to add here.
/// `APPLICATION_EXTENSION_API_ONLY` (set on the target) means no
/// `UIApplication.shared` anywhere in the base class either.
final class KeyboardViewController: KallilexKeyboardController {}
