# Spec ios-17 — Keyboard core: layouts, state, input routing

Status: ready-for-agent
Phase: Keyboard K1 (foundation)
Depends on: ios-16

## Problem Statement

The keyboard's typing logic has to be correct, and it has to be testable
without a running keyboard extension:

- which keys exist in which layout;
- what shift and caps lock do;
- when to auto-capitalize;
- how delete repeats;
- where an edit goes (the Scratchpad or the host app).

Keeping this logic out of the UIKit views makes it unit-testable and keeps
the view code thin.

## Solution

A new package library target **`KallilexKeyboardCore`**, with no UIKit and
no SwiftUI dependency. It contains:

- the layouts;
- a pure state machine;
- the routing of abstract edits to a typing target;
- a `TextDocument` protocol that the extension implements on top of
  `UITextDocumentProxy`.

## User Stories

1. As a German user, I want a QWERTZ layout with ü, ö, ä keys, so that I can
   type German naturally.
2. As an English user, I want a QWERTY layout, so that the keys are where I
   expect them.
3. As a user, I want umlauts, ß and accented letters on long-press in both
   layouts.
4. As a user, I want shift for one capital letter, a double tap for caps
   lock, and automatic capitals at the start of a sentence.
5. As a user, I want "double space" to insert a period, as on the system
   keyboard.
6. As a user, I want holding delete to delete repeatedly, then word by word.
7. As a user, I want the keys to type into the Scratchpad or straight into
   the app, depending on the target I picked.
8. As a developer, I want all of this covered by fast unit tests.

## Implementation Decisions

### Package

`Package.swift` gets a library product and target `KallilexKeyboardCore`
(no dependencies, no resources) and a test target `KallilexKeyboardCoreTests`.
The scheme `KallilexKit-Package` runs its tests, so CI picks them up without
a workflow change.

### Layouts

```swift
public enum KeyboardLayoutID: String, Codable, Sendable, CaseIterable {
    case qwertz, qwerty
}

public enum KeyboardLayer: Sendable { case letters, numbers, symbols }

public struct Key: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case character(String)        // lower-case base output
        case shift, delete, space, returnKey, layerSwitch(KeyboardLayer), globe
    }
    public var kind: Kind
    public var alternates: [String]   // long-press, lower-case
    public var widthUnits: Double     // 1.0 = one letter key
}

public struct KeyboardLayout: Sendable {
    public static func rows(_ id: KeyboardLayoutID,
                            layer: KeyboardLayer,
                            showsGlobe: Bool) -> [[Key]]
}
```

- **QWERTZ letters:**
  - `q w e r t z u i o p ü`
  - `a s d f g h j k l ö ä`
  - ⇧ `y x c v b n m` ⌫
  - `123` 🌐 space `.` return
- **QWERTY letters:**
  - `q w e r t y u i o p`
  - `a s d f g h j k l`
  - ⇧ `z x c v b n m` ⌫
  - `123` 🌐 space `.` return
- **Numbers and symbols layers:** follow the system keyboard of the same
  language (`1–0`, `- / : ; ( ) € & @ "`, `. , ? ! '` …; the symbols layer
  `[ ] { } # % ^ * + =` …). The euro sign is on the numbers layer for QWERTZ,
  the dollar sign for QWERTY; the other currency signs go on long-press.
- **Long-press alternates (both layouts):**
  - `a`: ä à á â æ ã å
  - `o`: ö ò ó ô œ õ ø
  - `u`: ü ù ú û
  - `s`: ß
  - `e`: é è ê ë
  - `i`: î ï í ì
  - `c`: ç
  - `n`: ñ
  - `y`/`z`: as on the system keyboard.
- `showsGlobe` comes from `needsInputModeSwitchKey`. Without it, the space
  key gets wider.

### State machine

```swift
public enum Edit: Equatable, Sendable {
    case insert(String), deleteBackward, deleteWordBackward
}

public struct KeyboardContext: Sendable {
    public var autocapitalization: Autocapitalization  // none, words, sentences, allCharacters
    public var textBeforeCursor: String?               // short, may be nil
}

public struct KeyboardState: Sendable {
    public var layer: KeyboardLayer
    public var shift: ShiftState                       // off, once, locked
    public mutating func press(_ key: Key, context: KeyboardContext, now: Date) -> [Edit]
    public mutating func longPressSelect(_ alternate: String, context: KeyboardContext) -> [Edit]
    public mutating func contextDidChange(_ context: KeyboardContext)  // auto-shift
}
```

- **Shift:**
  - one tap → `.once`, cleared after the next letter;
  - two taps within 0.3 s → `.locked`;
  - a tap while locked → `.off`.
- **Auto-capitalization:** `contextDidChange` sets `.once` when
  `autocapitalization` asks for it. That means:
  - `.sentences`: at the start of the text, or after `. ! ?` and a space;
  - `.words`: after a space;
  - `.allCharacters`: always.

  A user's explicit shift-off wins until the next context change.
- **Double space:** a second space within 0.5 s after a letter or digit
  becomes `[.deleteBackward, .insert(". ")]`, then `.once`.
- **Layer switching:**
  - `123` → numbers, `#+=` → symbols, `ABC` → letters;
  - after typing a space or `'` on the numbers layer, it switches back to
    letters (system behavior).
- **Delete repeat** is driven by the view's timer, but the timing rules live
  here:

  ```swift
  public func deleteRepeatEdit(heldFor: TimeInterval) -> Edit?
  ```

  - first delete on press;
  - repeat every 0.1 s after 0.5 s held;
  - `.deleteWordBackward` every 0.25 s after 2 s held.
- `now` and `heldFor` are parameters, so tests need no clock.

### Typing target and routing

```swift
public protocol TextDocument: AnyObject {
    var selectedText: String? { get }
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

public enum TypingTargetKind: Sendable { case scratchpad, host }

public final class EditRouter {
    public var target: TypingTargetKind
    public init(scratchpad: any TextDocument, host: any TextDocument)
    public func apply(_ edits: [Edit])
    public var activeDocument: any TextDocument { get }
}
```

- `.deleteWordBackward` is resolved against `documentContextBeforeInput` of
  the active document. It deletes back to the previous word boundary, plus
  the whitespace in front of it, by counting `Character`s. Each counted
  `Character` becomes one `deleteBackward`; counting is confirmed in Notes,
  Mail and a UITextView (spike unknown 11). Web views are checked in ios-19's
  matrix; if any app class miscounts, disable Undo for those characters.
- The extension implements `TextDocument` twice:
  - a `HostDocument` around `textDocumentProxy`;
  - a `ScratchpadDocument` around the Scratchpad `UITextView` (ios-18).
- `KeyboardContext` is built from the active document. For the Scratchpad
  it always uses `.sentences`.

### Layout setting

`AppSettings` gets an optional `keyboardLayout: KeyboardLayoutID?`.
- It's decoded with `decodeIfPresent`; `nil` means "follow the device
  language" (German → QWERTZ, everything else → QWERTY).
- It's an additive iOS-only field, so there's no schema version bump.
  Older builds ignore the key, because `Codable` skips unknown keys.
- `KallilexKit` can't depend on `KallilexKeyboardCore`, so the field is
  stored as a `String?`. `KallilexKeyboardCore` maps it to the enum.
- The setting UI is ios-22.

## Testing Decisions

`KallilexKeyboardCoreTests` (Swift Testing):

- **Layouts:**
  - row counts and contents per layout and layer;
  - every alternate is a single `Character`;
  - the globe key is present only with `showsGlobe`.
- **Shift:**
  - once, then cleared;
  - a double tap locks;
  - a tap unlocks.
- **Auto-capitalization:**
  - per mode, at the start and after `. `, `! `, `? `;
  - none for `.none`;
  - a user override is respected.
- **Double space:**
  - becomes `. ` after a letter;
  - doesn't fire after a space or at the start;
  - doesn't fire after 0.5 s.
- **Layer switching** and the return to letters after a space.
- **Delete repeat timing:** the edits at 0.4 s, 0.6 s, 2.1 s.
- **`EditRouter`** with two fake documents:
  - edits go to the right one;
  - target switching;
  - word deletion with emoji and combining accents counts `Character`s.
- **`AppSettings`:**
  - a settings file without `keyboardLayout` decodes to `nil`;
  - a value round-trips;
  - existing contract fixtures still pass.

## Out of Scope

- Drawing keys, popups, timers (ios-18).
- Haptics and input clicks (none in v1).
- Autocorrect and suggestions.

## Further Notes

- PLAN-keyboard.md §6, §10.2.
