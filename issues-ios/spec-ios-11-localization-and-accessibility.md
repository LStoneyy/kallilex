# Spec ios-11 — Localization and accessibility

Status: ready-for-agent
Phase: Phase 5 (Polish)
Depends on: ios-09, ios-10

## Problem Statement

The iOS app must support English and German users with complete string
localization, German UI voice that matches iOS conventions, accessible
controls for all users regardless of ability, and proper handling of dynamic
text scaling and motion preferences. The catalog must have no "new" or
"needs review" states at completion, every screen must work with VoiceOver,
and Reduce Motion must be respected. Accessibility testing must be automated
in CI and manual in the share flow across real apps.

## Solution

Create and manage `Localizable.xcstrings` catalogs in the app, the
ShareExtension, and the package targets KallilexKit and KallilexUI. Provide
translations for every user-facing string and all default prompt labels in
English and German. Write German UI in the informal second person ("du"),
plain language without anglicisms. Use a glossary for consistent terminology
across the app. Implement VoiceOver labels and hints on every control, state
announcements for long-running operations, sufficient color contrast,
minimum 44-point hit targets, and Dynamic Type scaling up to accessibility
sizes (AX5). Respect Reduce Motion for animations. Run automated catalog
completeness and truncation tests in CI, and record a manual VoiceOver pass
through the share flow in a real app.

## User Stories

1. As a German user, I want the app UI in German, so that I understand every
   control and button label in my language.
2. As a German user, I want German that sounds natural ("du", no anglicisms
   like "API-Key"), so that the app fits with other iOS apps I know.
3. As a user with a text scaling preference, I want buttons and chips to wrap
   and reflow instead of truncate, so that I can read everything at my
   preferred size.
4. As a user with motion sensitivity, I want animations to stop or fade to
   instant transitions when I turn on Reduce Motion, so that I avoid
   discomfort.
5. As a VoiceOver user, I want every button, input, and chip to have a clear
   spoken label, so that I understand what each control does.
6. As a VoiceOver user, I want to hear when the app is rewriting text or when
   it finishes, so that I know what is happening.
7. As a user with color blindness or low vision, I want sufficient contrast
   between all text and backgrounds, so that I can read the content.
8. As a user with a large hit-target preference or fine-motor difficulty, I
   want all tappable areas to be at least 44 points, so that I can reliably
   tap what I mean to tap.
9. As a developer, I want automated tests to catch missing translations and
   truncation in German, so that the release gates pass without manual
   catalog review.

## Implementation Decisions

### String catalogs

**Files:**

- `Kallilex/Resources/Localizable.xcstrings` (app)
- `ShareExtension/Resources/Localizable.xcstrings` (extension)
- `ios/KallilexKit/Sources/Resources/Localizable.xcstrings` (KallilexKit
  library)
- `ios/KallilexKit/Sources/Resources/Localizable.xcstrings` (KallilexUI
  library, if separate)

All catalogs use the string-catalog format introduced in Xcode 15 (JSON with
per-string metadata). Both targets and package targets include the Xcode
build setting `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` to enforce
catalogs.

**KallilexKit Package setup:**

```swift
// In Package.swift
let package = Package(
    name: "KallilexKit",
    platforms: [.iOS(.v26)],
    products: [...],
    targets: [
        .target(
            name: "KallilexKit",
            dependencies: [],
            defaultLocalization: "en",
            resources: [.process("Resources")]
        ),
        .target(
            name: "KallilexUI",
            dependencies: ["KallilexKit"],
            defaultLocalization: "en",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KallilexKitTests",
            dependencies: ["KallilexKit"]
        )
    ]
)
```

Code in package targets uses:

```swift
Text(String(localized: "label_key", bundle: .module))
```

### String keys and English base

Every user-facing string introduced in ios-04 through ios-10 gets a key and
English translation. Examples:

- `prompt.label.rewrite` → "Rewrite"
- `prompt.label.shorten` → "Shorten"
- `prompt.label.improve_clarity` → "Improve clarity"
- `action.copy` → "Copy"
- `action.retry` → "Retry"
- `action.cancel` → "Cancel"
- `action.undo` → "Undo"
- `state.rewriting` → "Rewriting…"
- `state.done` → "Done"
- `error.too_long` → "Text is too long for the on-device model"
- `error.not_configured` → "Set up a provider in the Kallilex app"
- `consent.message` → "The text you share is sent to {{host}} to be
  processed."
- `scratchpad.paste` → "Paste"

Use hierarchical key names (dots for grouping) for maintainability.

### German translations

**Glossary (EN → DE):**

| EN | DE | Notes |
|---|---|---|
| prompt | Prompt | Noun, stays "Prompt" in German |
| provider | Anbieter | The service providing the model |
| share sheet | Teilen-Menü | iOS's native share UI |
| API key | API-Schlüssel | No English; German compound |
| consent | Zustimmung | Permission for sending data |
| on device | Auf dem Gerät | Apple's phrasing in German iOS |
| your network | Dein Netzwerk | Informal "dein" for LAN privacy badge |
| Scratchpad | Notizblock | Fallback editor in the app |
| Copy | Kopieren | Action button |
| Retry | Erneut versuchen | Redo a request |
| Undo | Widerrufen | Revert to original text |
| Cancel | Abbrechen | Close without action |

**Voice:**

- Use informal second person: "Dein Netzwerk" not "Ihr Netzwerk"
- Avoid anglicisms: "Umschreiben" not "Rewritten", "Klarer formulieren" not
  "Improve"
- Keep sentences short and plain
- Match iOS's own German localization style (from system Settings)

**Default prompt labels (localized; instructions stay English):**

- "Rewrite" → "Umschreiben"
- "Shorten" → "Kürzen"
- "Improve clarity" → "Klarer formulieren"

Once stored in the user's app settings, labels are never re-translated;
the user has authored them and they become part of their data. Only the
seed prompts on first setup are localized.

### Accessibility — VoiceOver

**Labels and hints:**

- Every chip, button, and interactive control has an `accessibilityLabel`
  (what it is) and `accessibilityHint` (what it does).
- Example: a prompt chip with label "Rewrite" gets `accessibilityLabel:
  "Rewrite prompt"` and `accessibilityHint: "Double-tap to run"` in English,
  and the German equivalents in German.
- The text editor has `accessibilityLabel: "Input text"` and behaves as a
  text field (VoiceOver automatically announces it is editable).

**State announcements:**

- When a request starts: announce "Rewriting" (or the prompt name) + "in
  progress".
- When it finishes: announce "Done" + "Result is ready".
- On error: announce the error message ("Text is too long for the on-device
  model", etc.).
- Use `UIAccessibility.post(notification: .announcement, argument: text)` in
  UIKit contexts, or `.accessibilityAnnouncement(text)` in SwiftUI.

**Hierarchy and grouping:**

- Group the text editor and the result into a single accessible container
  so that VoiceOver users see them as one logical unit when using navigation
  rotor.
- Group prompt chips into a "Prompts" container with multiple children
  rather than a flat list.

### Accessibility — Motor and perception

**Dynamic Type (Text Size):**

- The app must scale from the default (Size 3) to AX5 (Extra Large 3,
  accessibility size).
- Text scales automatically with `.font(.body)` and custom sizes tied to
  `UIFont.preferredFont(forTextStyle:)`.
- Prompt chips stack vertically into a list at sizes AX3 and above, instead
  of a horizontal scrolling row. The "Custom…" field stays below the list.

**Color contrast:**

- All text meets WCAG AA (4.5:1 for normal text, 3:1 for large text).
- Verify in both light and dark mode using Xcode's accessibility inspector
  or WebAIM's contrast checker.
- Error messages, success states, and badges use color + text (never color
  alone) to convey status.

**Hit targets:**

- Every button, chip, and input is at least 44×44 points (Apple's standard
  minimum). Measure in the accessibility inspector.

**Reduce Motion:**

- Fade animations (0.3 s) become 0 s (instant) when `UIAccessibility
  .isReduceMotionEnabled` is true.
- The "Copied" confirmation toast still appears (not an animation; a state
  change) but its transition is instant.
- Example:

```swift
let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0 : 0.3
withAnimation(.easeInOut(duration: duration)) {
    state = .result(...)
}
```

## Testing Decisions

### Catalog completeness test

**File:** `ios/KallilexKit/Tests/KallilexKitTests/StringCatalogTests.swift`

It checks every catalog under `ios/` (app, extension, `InfoPlist`, and the
package targets), not only the package's own resources.

```swift
import Foundation
import Testing

/// Walks up from this file to the repo root (the directory containing
/// `ios/`) and returns every `.xcstrings` catalog under `ios/`.
private func stringCatalogs() throws -> [URL] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: dir.appending(path: "ios").path) {
        let parent = dir.deletingLastPathComponent()
        guard parent != dir else {
            Issue.record("Repo root (directory containing ios/) not found")
            return []
        }
        dir = parent
    }
    let ios = dir.appending(path: "ios")
    let files = FileManager.default.enumerator(at: ios, includingPropertiesForKeys: nil)
    return (files?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "xcstrings" && !$0.path.contains("/.build/") }
}

private struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]
}
private struct Entry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: Localization]?
}
private struct Localization: Decodable {
    let stringUnit: StringUnit?
    let variations: [String: [String: Localization]]?  // e.g. plural → one/other
}
private struct StringUnit: Decodable {
    let state: String
    let value: String
}

private func isTranslated(_ l: Localization) -> Bool {
    if let unit = l.stringUnit {
        return unit.state == "translated" && !unit.value.isEmpty
    }
    guard let variations = l.variations, !variations.isEmpty else { return false }
    return variations.values.allSatisfy { $0.values.allSatisfy(isTranslated) }
}

@Test(arguments: try stringCatalogs())
func catalogHasGermanForEveryKey(_ url: URL) throws {
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    for (key, entry) in catalog.strings where entry.shouldTranslate != false {
        let de = entry.localizations?["de"]
        #expect(de.map(isTranslated) == true,
                "\(url.lastPathComponent): \"\(key)\" has no translated German value")
    }
}
```

**Catalog format (.xcstrings JSON):**

The `.xcstrings` file is JSON shaped as:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "<key>": {
      "localizations": {
        "de": {
          "stringUnit": {
            "state": "translated",
            "value": "…"
          }
        }
      },
      "shouldTranslate": false?
    }
  }
}
```

A key passes completeness if: `shouldTranslate == false`, or it has a `de`
localization whose `stringUnit.state == "translated"` with non-empty value, or
it has a `de` localization with `variations` (plurals/devices) where every leaf
`stringUnit` is translated.

Run this test in CI (in `ios.yml`) to catch missing or incomplete translations
before release.

### Truncation test (German)

**File:** `ios/KallilexKit/Tests/KallilexKitTests/GermanTruncationTests.swift`

Use `XCUITest` to render the main screens (Scratchpad, Providers, Prompts)
with the `-AppleLanguages (de)` launch argument and measure text width to
ensure German strings don't truncate in their containers. This is optional
but recommended for the release checklist (ios-13).

### VoiceOver manual pass

**Before release (ios-13 checklist item):**

Run through the share flow in a real app (Notes, Mail, or Safari) with
VoiceOver enabled:

1. Open Notes.
2. Select some text.
3. Tap Share → Kallilex.
4. With VoiceOver on, navigate the sheet:
   - Announce the header ("Kallilex").
   - Read the text editor content aloud (edited by the user or original).
   - Announce each prompt chip and its hint ("Double-tap to run").
   - Tap a chip; hear the state announcement ("Rewriting…") and later ("Done").
   - Navigate to Copy; hear its label and hint.
   - Tap Copy; hear "Copied" announced.
5. Return to Notes and verify the text was pasted correctly.

This is a manual gate; record the result in the release matrix (ios-13).

## Out of Scope

- Localization beyond English and German in v1 (Spanish, French, etc. are
  later phases).
- A localized on-device model (the Foundation Model provides English
  responses; German support depends on Apple's model updates).
- Braille or specialized screen-reader integrations beyond VoiceOver.
- Dyslexia-friendly fonts (not in v1).
- Audio descriptions for UI elements (VoiceOver labels cover the
  requirement).

## Further Notes

- PLAN.md §11 defines the localization scope and German voice style.
- String catalogs (Xcode 15+) manage all translations in a single JSON file
  per target, preventing the drift and merge conflicts of `.strings` files.
- The package's `defaultLocalization: "en"` ensures the build succeeds if a
  German translation is missing (it falls back to English); the CI test
  catches the gap.
- Catalog completeness and the lack of "new" states must be verified at
  release time (ios-13 gate).
- The glossary in this spec ensures consistent terminology; update it if a
  translation decision changes later.
