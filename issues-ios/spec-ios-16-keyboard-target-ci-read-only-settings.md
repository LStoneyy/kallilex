# Spec ios-16 — Keyboard target, CI, read-only settings

Status: ready-for-agent
Phase: Keyboard K1 (foundation)
Depends on: ios-15

## Problem Statement

The keyboard needs its own extension target, wired into the project, the
signing setup and CI like the Share Extension. It also has to read the
shared settings without Full Access, when the App Group container is
read-only. `AppGroupSettingsStore.load()` coordinates the file with write
intent (so it can rename a corrupt file), which fails on a read-only container
without Full Access (spike unknown 2: coordinated reads fail with
`NSCocoaErrorDomain 256`).

## Solution

1. Add a `KeyboardExtension` target: an empty `UIInputViewController` that
   shows one row with a globe key and a placeholder label, embedded in the
   app.
2. Add a read-only settings load to `AppGroupSettingsStore`.
3. Extend `ios.yml` with checks for the new bundle.

## User Stories

1. As a user, I want "Kallilex" to appear under Settings → Keyboards → Add
   New Keyboard after installing the app, so that I can add it.
2. As a user without Full Access, I want the keyboard to read my prompts and
   providers, so that it shows my setup even before I allow Full Access.
3. As a release engineer, I want CI to fail if the keyboard bundle loses its
   App Group, Keychain group, `RequestsOpenAccess` or ATS setting, so that a
   misconfiguration doesn't reach a release.
4. As a developer, I want the keyboard to fail loudly on a missing App Group
   identifier, as the Share Extension does, so that a build misconfiguration
   can't silently point at the wrong storage.

## Implementation Decisions

### Target

- **Folder:** `ios/KeyboardExtension/` with `Sources/`, `Resources/`,
  `Info.plist`, `KeyboardExtension.entitlements`, `PrivacyInfo.xcprivacy`.
  `Sources` and `Resources` are synchronized folders, as for the
  ShareExtension.
- **`ios/Config/KeyboardExtension.xcconfig`:**

  ```
  #include "Common.xcconfig"
  PRODUCT_NAME = KeyboardExtension
  PRODUCT_BUNDLE_IDENTIFIER = $(KALLILEX_APP_ID).keyboard
  INFOPLIST_FILE = KeyboardExtension/Info.plist
  CODE_SIGN_ENTITLEMENTS = KeyboardExtension/KeyboardExtension.entitlements
  APPLICATION_EXTENSION_API_ONLY = YES
  SKIP_INSTALL = YES
  ```

- **pbxproj:** a new app-extension target in the same style as
  ShareExtension. It links `KallilexKit` and `KallilexUI`, is a dependency of
  the app, and is embedded in the app's "Embed App Extensions" phase. Edit
  the pbxproj by hand in the existing style; don't regenerate it.
- **Info.plist:**
  - `CFBundleDisplayName` "Kallilex";
  - `NSExtension` → `NSExtensionPointIdentifier` `com.apple.keyboard-service`;
  - `NSExtensionPrincipalClass` `$(PRODUCT_MODULE_NAME).KeyboardViewController`;
  - `NSExtensionAttributes`:
    - `IsASCIICapable` YES;
    - `PrefersRightToLeft` NO;
    - `PrimaryLanguage` `de-DE`. One keyboard serves both layouts (QWERTZ,
      QWERTY); revisit if the spike shows `PrimaryLanguage` matters for
      dictation or spell checking in the host;
    - `RequestsOpenAccess` YES;
  - `KallilexAppGroup` and `KallilexKeychainAccessGroup` as in the
    ShareExtension (read by `InfoPlist`);
  - `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` YES, no
    `NSAllowsLocalNetworking` (ios-14);
  - `NSLocalNetworkUsageDescription` (same text as the ShareExtension).
- **Entitlements:** identical to `ShareExtension.entitlements` (App Group,
  Keychain access group).
- **Privacy manifest:** the same as the ShareExtension's. Add
  required-reason API entries only if the target uses them.
- **`KeyboardViewController`** (placeholder for ios-18):
  - a `UIInputViewController` subclass;
  - builds the stores like `ShareViewController` (`InfoPlist.kallilexAppGroup`,
    no hardcoded fallback);
  - shows a placeholder strip with the globe key. The globe key is shown only
    when `needsInputModeSwitchKey` is true and is wired to
    `handleInputModeList(from:with:)`;
  - shows a label with the number of prompts it could load, which proves the
    read path in a device test;
  - no `UIApplication.shared`.

### Read-only settings load

- New method on `AppGroupSettingsStore`:
  `public func loadReadOnly() throws -> AppSettings`.
  - It reads with a plain `Data(contentsOf:)`, **not** `NSFileCoordinator`.
    Without Full Access even a read-only coordinated read fails (spike unknown
    2). The app writes atomically, so a plain read sees either the old or the
    new file.
  - A missing file returns `AppSettings.seeded()`, like `load()`.
  - A corrupt file throws the same error `load()` would report after its
    recovery, but **doesn't rename** the file and doesn't set the
    "recovered from corruption" flag. The app repairs it on its next launch.
  - It runs the same `SettingsMigrator` in memory and never writes the
    migrated result back.
- `SettingsStore` gets no new requirement. The keyboard calls
  `loadReadOnly()` on the concrete store when `hasFullAccess` is false and
  `load()` otherwise.
- `ActionRunner` takes its settings through `SettingsStore.load()`. For the
  keyboard without Full Access, add a small `ReadOnlySettingsStore` adapter
  (KallilexKit) whose `load()` calls `loadReadOnly()` and whose `save`/`update`
  throw a new case `SettingsStoreError.readOnly` (the enum in
  `SettingsStore.swift`).

### CI (`.github/workflows/ios.yml`)

Extend the existing verification steps to the keyboard appex
(`Kallilex.app/PlugIns/KeyboardExtension.appex`):

- "Verify app and extension share the same App Group": all three bundles
  have the same App Group and Keychain group.
- "Verify plain HTTP is allowed to any server": the keyboard too.
- "Verify the privacy manifests": the keyboard too.
- New step "Verify the keyboard requests Full Access": `RequestsOpenAccess`
  is true, and the extension point is `com.apple.keyboard-service`.

## Testing Decisions

- **Unit tests** (KallilexKitTests), for `loadReadOnly()` against a temporary
  directory:
  - missing file → defaults, nothing created;
  - valid file → same result as `load()`;
  - corrupt file → error, file unchanged, not renamed;
  - an old schema → migrated in memory, file unchanged;
  - read-only directory (POSIX permissions) → still loads.
- **`ReadOnlySettingsStore`:** `save` and `update` throw `.readOnly` and
  don't touch the file.
- **CI:** the new and extended bundle checks.
- **Manual (device):** add the keyboard, open Notes, switch to Kallilex. The
  globe key and the prompt count show, with Full Access off and on.

## Out of Scope

- Keys, layouts, the Scratchpad and any AI features (ios-17 to ios-19).
- Onboarding and setup in the app (ios-22).

## Further Notes

- PLAN-keyboard.md §10.1, §10.3.
- **Setup note:** on the free Personal Team, `xcodebuild
  -allowProvisioningUpdates` sometimes registers a new App ID without its App
  Group (seen in the spike, not for the real keyboard). If the first device
  build fails with "Provisioning profile … doesn't match the entitlements
  file's value for the com.apple.security.application-groups entitlement",
  tick "App Groups" once in Xcode (target → Signing & Capabilities).
