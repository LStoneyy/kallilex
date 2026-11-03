# Spec ios-02 — Project skeleton and iOS CI

Status: ready-for-agent
Phase: Phase 1 (Foundation)
Depends on: ios-01 (unknowns answered or deferred with fallbacks)

## Problem Statement

The iOS app needs an Xcode project, Swift package structure, build
configuration, entitlements, and a CI workflow that ensures the project
builds and tests pass on every commit. The project must have synchronized
folders, a clear layout for app and extension targets, and configuration
files that keep secrets out of git while supporting signing for simulator
builds.

## Solution

Create an Xcode 26+ project at `ios/Kallilex.xcodeproj` with:

- Two targets: Kallilex (container app) and Kallilex Share Extension
- A local Swift package `KallilexKit` linked by both targets
- `.xcconfig` files for bundle IDs, version, and team ID (team ID read from
  environment, never committed)
- Entitlements for App Group and Keychain sharing
- `Info.plist` entries for network permissions, URL scheme, and extension
  activation rules
- A `.github/workflows/ios.yml` CI workflow that runs `xcodebuild test` on
  simulator and verifies that an empty app and extension build and launch
- `.gitignore` updates to exclude build artifacts and user-specific Xcode
  files

The project passes `xcodebuild test` in CI with no warnings, and the app and
extension launch in the simulator.

## User Stories

1. As an iOS developer, I want an Xcode project that builds and runs on
   simulator with no manual setup, so that I can start implementing
   immediately after cloning.
2. As a developer, I want `xcodebuild test` to pass in CI without signing
   secrets in the repo, so that every pull request verifies that the build
   is sound.
3. As a maintainer, I want bundle IDs, app identifiers and version numbers
   to be easy to version-bump, so that the release spec can update them
   atomically.
4. As a developer, I want the app and extension to share settings via an
   App Group and API keys via Keychain, so that the architecture from
   PLAN.md §7.6 works from the start.
5. As a user, I want the app to declare that it uses local networking and
   needs the Local Network permission, so that I can control access in
   Settings (PLAN.md §10.3).
6. As a developer, I want the extension to activate only for text (not
   images or files), so that the share sheet is clean and App Review
   accepts it (PLAN.md §8.1).

## Implementation Decisions

### Repository layout

```
ios/
  Kallilex.xcodeproj
    project.pbxproj              # minimal, synchronized folders
  Kallilex/                      # container app target
    Sources/
    Resources/
  ShareExtension/                # share extension target
    Sources/
    Resources/
  KallilexKit/                   # local Swift package
    Package.swift                # iOS 26.0 min, Swift 6
    Sources/
      KallilexKit/
    Tests/
      KallilexKitTests/
  Config/
    Common.xcconfig               # Shared; swift version, deploymin, versions
    Kallilex.xcconfig             # App settings; inherits Common
    ShareExtension.xcconfig       # Extension settings; inherits Common
    Local.xcconfig.example        # Team ID documentation (not committed)
    Local.xcconfig                # Team ID for local builds (gitignored)
  PrivacyInfo.xcprivacy          # One per target (added in ios-12)
```

### Identifiers and versions

| Item | Value | Notes |
|---|---|---|
| App bundle ID | `com.webcommits.kallilex` | Same as desktop (PLAN.md §6) |
| Extension bundle ID | `com.webcommits.kallilex.share` | Must be prefixed by app ID |
| App Group | `group.com.webcommits.kallilex` | Settings JSON in App Group container |
| Keychain access group | `$(AppIdentifierPrefix)com.webcommits.kallilex.shared` | API keys (PLAN.md §6) |
| URL scheme | `kallilex://` | Deep links into settings (PLAN.md §4.3, unknown 4) |
| Minimum iOS | iOS 26.0 | Foundation Models (PLAN.md §6, §18 Q6) |
| Swift | 6, strict concurrency | Language version and warning flags |
| Version | 1.0.0 | Independent semver from desktop; tags `ios-v1.0.0` (PLAN.md §6, §13) |
| Build number | 1 | Incremented per release; CURRENT_PROJECT_VERSION in xcconfig |

### Xcconfig files

#### Config/Common.xcconfig

```
IPHONEOS_DEPLOYMENT_TARGET = 26.0
SWIFT_VERSION = 6.0
COPY_PHASE_STRIP = NO
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 1
#include? "Local.xcconfig"
```

(Swift 6 has strict concurrency by default; no explicit `SWIFT_STRICT_CONCURRENCY` setting needed.)

#### Config/Kallilex.xcconfig

```
#include "Common.xcconfig"
PRODUCT_NAME = Kallilex
PRODUCT_BUNDLE_IDENTIFIER = com.webcommits.kallilex
```

#### Config/ShareExtension.xcconfig

```
#include "Common.xcconfig"
PRODUCT_NAME = ShareExtension
PRODUCT_BUNDLE_IDENTIFIER = com.webcommits.kallilex.share
```

#### Config/Local.xcconfig.example

```
DEVELOPMENT_TEAM = ABC1234567
```

(Developers copy this to `Local.xcconfig` and fill in their team ID. `Local.xcconfig` is gitignored.)

#### Config/Local.xcconfig

This file is created locally by each developer and gitignored:
```
DEVELOPMENT_TEAM = <team-id>
```

### Entitlements

#### Kallilex.entitlements (container app)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.webcommits.kallilex</string>
  </array>
  <key>keychain-access-groups</key>
  <array>
    <string>$(AppIdentifierPrefix)com.webcommits.kallilex.shared</string>
  </array>
</dict>
</plist>
```

#### ShareExtension.entitlements (share extension)

Identical to Kallilex.entitlements (both targets share the same App Group and
Keychain group).

### Info.plist

#### Kallilex app Info.plist

```
<dict>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Kallilex connects to AI servers on your local
network, such as Ollama on your Mac, when you set one up.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLScheme</key>
      <string>kallilex</string>
      <key>CFBundleURLName</key>
      <string>Kallilex Deep Link</string>
    </dict>
  </array>
</dict>
```

`NSLocalNetworkUsageDescription` text is exactly from PLAN.md §10.3.

#### Share Extension Info.plist

```
<dict>
  <key>CFBundleDisplayName</key>
  <string>Kallilex</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>NSExtensionActivationRule</key>
      <dict>
        <key>NSExtensionActivationSupportsText</key>
        <true/>
        <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
        <integer>1</integer>
      </dict>
    </dict>
  </dict>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Kallilex connects to AI servers on your local
network, such as Ollama on your Mac, when you set one up.</string>
</dict>
```

(No storyboard. The activation rule uses the dictionary form, not `TRUEPREDICATE`
as App Review prefers; PLAN.md §8.1.)

### KallilexKit Swift package

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KallilexKit",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "KallilexKit", targets: ["KallilexKit"]),
    ],
    targets: [
        .target(
            name: "KallilexKit",
            dependencies: []
        ),
        .testTarget(
            name: "KallilexKitTests",
            dependencies: ["KallilexKit"]
        ),
    ]
)
```

The package has no external dependencies in Phase 1. Tests use Swift Testing
(`import Testing`), not XCTest. Both the app and extension link it in
`Build Phases` → `Link Binary with Libraries`.

### Dummy targets (Phase 1)

- **Kallilex app:** A SwiftUI App with an empty ContentView. Builds and
  launches on simulator with no errors or warnings.
- **ShareExtension:** A principal class `ShareViewController` (a `UIViewController`
  hosting a SwiftUI view via `UIHostingController`). Receives input from
  `extensionContext.inputItems`, renders "Hello from Kallilex", and a Close
  button. Builds and launches from the share sheet.
- **KallilexKit:** Empty placeholder module. Tests import it successfully.

### CI workflow: `.github/workflows/ios.yml`

Triggers:

- `on: [push, pull_request]` targeting `ios/**` or `contracts/**` paths (other
  paths skip the job).
- `workflow_dispatch` for manual runs.

Runs on: `macos-26` (or a suitable macOS version with Xcode 26.x available)

Steps:

1. Check out the repo.
2. Select the newest available Xcode 26.x, fail if none:
   ```bash
   sudo xcode-select -s /Applications/Xcode_26.*.app/Contents/Developer
   ```
   (Or use `maxim-lobanov/setup-xcode` action to install a specific version.)
3. Verify Xcode version: `xcodebuild -version`.
4. Test KallilexKit:
   ```bash
   xcodebuild test \
     -scheme KallilexKit \
     -configuration Debug \
     -destination "platform=iOS Simulator,name=iPhone 17" \
     -derivedDataPath build \
     CODE_SIGNING_ALLOWED=NO
   ```
   (Or use `xcrun simctl list devices available -j` to resolve the first
   available iPhone simulator dynamically.)
5. Build the app (which embeds and builds the extension):
   ```bash
   xcodebuild build \
     -scheme Kallilex \
     -configuration Debug \
     -destination "platform=iOS Simulator,name=iPhone 17" \
     CODE_SIGNING_ALLOWED=NO
   ```
6. Fail the job if any step fails.

No code signing secrets, no provisioning profiles.

### Guard rails against cross-triggering

(PLAN.md §13: iOS tags are `ios-v*`, desktop tags are `v*`.)

- The ios.yml workflow paths filter on `ios/**` and `contracts/**`, so it never
  runs on desktop-only commits.
- The `release.yml` workflow (if it exists) triggers on `push: tags: ["v*"]`
  (a tag filter glob, anchored at the start). iOS-v* tags do not match this
  pattern, so `ios-v1.0.0` will not trigger `release.yml`.
- `homebrew.yml` runs on any published GitHub Release; therefore, **do not
  publish GitHub Releases for iOS builds** (PLAN.md §13). Desktop CI publishes
  releases; iOS releases are manual or handled separately.

## Testing Decisions

### Xcode

- Project opens without errors or warnings.
- `xcodebuild test` passes on simulator.
- App and ShareExtension schemes build and launch without errors.

### CI

- The ios.yml workflow runs on every push and PR touching `ios/**` or
  `contracts/**`.
- The workflow passes with a clean build and test output.
- No code signing secrets are present in the repo or workflow file.

### Manual (before CI goes live)

- Run `xcodebuild test` locally on a Mac with Xcode 26+.
- Launch the app and extension in the simulator and verify both appear
  without crashing.

## Out of Scope

- Signing for device builds or app distribution (done in Phase 6).
- Full app and extension UI (implemented in later phases).
- KallilexKit implementation beyond placeholder code (Phase 1 later specs).
- The Scratchpad, prompts, providers or any business logic.
- Localization, accessibility, or app branding.

## Further Notes

- PLAN.md §6 defines the identifiers and layout.
- PLAN.md §8.1 covers the extension activation rule.
- PLAN.md §10.3 provides the exact NSLocalNetworkUsageDescription text.
- PLAN.md §13 covers CI and release automation.
- Once the empty project builds and the CI is green, the next spec ios-03
  (contract fixtures) can proceed in parallel with spec ios-04 (models and
  stores).
