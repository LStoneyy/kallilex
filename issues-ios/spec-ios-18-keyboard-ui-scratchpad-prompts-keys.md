# Spec ios-18 — Keyboard UI: Scratchpad, prompts, keys

Status: done (Instruments memory measurement still open, see ios-23)
Phase: Keyboard K2 (keyboard UI)
Depends on: ios-17

## Problem Statement

The keyboard has two modes in the same frame (PLAN-keyboard.md §5):

- **Prompt mode:** a large Scratchpad, the prompt chips, and an action row.
- **Keys mode:** a compact Scratchpad, the typing target switch, and the
  keys.

It has to feel like a real keyboard (fast keys, popups, long-press) while
staying under the memory budget, and the Scratchpad has to behave like the
app's Scratchpad.

## Solution

- **`KeyboardViewController`** composes three parts:
  - a UIKit **key grid** driven by `KeyboardState` and `EditRouter`
    (ios-17);
  - a UIKit **Scratchpad** text view;
  - one `UIHostingController` for the SwiftUI parts: the chips, the action
    row, the status and the target switch.
- **`EditorSession`** (unchanged) owns the Scratchpad text and the prompt
  runs.
- **Keyboard harness:** a DEBUG-only harness in the app hosts the real view
  controller for UI tests.

Insert, Undo, the selection take-over, consent and the Full Access states
are ios-19. The prompt chips here already run prompts on the Scratchpad
text.

## User Stories

1. As a user, I want a large Scratchpad with my prompts below it when I
   switch to Kallilex, so that I can run a prompt right away.
2. As a user, I want ⌨ to show the keys and ⌨ ✓ to bring the prompts back.
3. As a user, I want to tap into the Scratchpad to place the cursor and type
   there with the keys.
4. As a user, I want to switch the typing target to "App" to type straight
   into the app I'm in.
5. As a user, I want a key popup when I press a key and accents on
   long-press, as on the system keyboard.
6. As a user, I want running a prompt to replace the Scratchpad text with
   the result, with Undo, Retry, Copy and Show original, like in the app.
7. As a user, I want the keyboard to keep the same height in both modes, so
   that the app behind it doesn't jump.
8. As a VoiceOver user, I want every key and control to be labelled.
9. As a developer, I want a harness that hosts the real keyboard in the app,
   so that UI tests can drive it on the simulator.

## Implementation Decisions

### Frame and height

- One fixed height for both modes, from the spike (unknown 9). Target:
  300 pt on a 6.1" iPhone, scaled by the screen height for other sizes.
  It's set as a height constraint on `inputView`, priority 999.
- Prompt mode, top to bottom:
  - Scratchpad (flexible);
  - chips row (44 pt);
  - action row (44 pt): 🌐 (if `needsInputModeSwitchKey`), ⌨, 🎤 (ios-21;
    hidden until then), `PrivacyBadge`, **Insert** (ios-19; hidden until
    then).
- Keys mode, top to bottom:
  - Scratchpad (3 lines, about 66 pt);
  - toolbar (36 pt): the target switch "Scratchpad | App", ⌨ ✓;
  - key grid (the rest).
- Mode changes animate the swap only (0.2 s crossfade), never the height.

### Key grid (UIKit)

- `KeyGridView: UIView` draws the keys with `CALayer`s (rounded rect plus a
  text layer per key). It uses no `UIButton` per key and does its own hit
  testing from `KeyboardLayout.rows`:
  - a touch goes to the nearest key in its row;
  - touches in the gaps go to the nearest key, so there are no dead zones.
- **Popups:** a callout layer above the pressed letter key. Long-press
  (0.4 s) shows the alternates; sliding selects one, lifting inserts it.
- **Delete:** a `Timer` calls `KeyboardState.deleteRepeatEdit(heldFor:)`.
- **Globe:** forwards the touch to `handleInputModeList(from:with:)`, so
  long-press shows the system keyboard list.
- **Return** label:
  - target App: from `textDocumentProxy.returnKeyType`;
  - target Scratchpad: always "return".
- **Feedback:** none in v1 (spike unknown 15). Both haptics and input clicks
  didn't work in the spike; if wanted later, retest with a prepared,
  retained generator and with "Keyboard Feedback" system settings on.
- **Appearance:** dark and light from `textDocumentProxy.keyboardAppearance`
  and the trait collection. The colors follow the system keyboard.
- **Accessibility:** every key is a `UIAccessibilityElement` with the
  `.keyboardKey` trait and a spoken label: "shift", "caps lock", "delete",
  "space", "return", "next keyboard", "numbers", "ä", …

### Scratchpad text view (UIKit)

- `ScratchpadTextView: UITextView` with `inputView = UIView()`. It becomes
  first responder when tapped in keys mode, with Scratchpad as the target,
  without trying to show another keyboard.
- `ScratchpadDocument: TextDocument` (ios-17) wraps it, using `insertText`,
  `deleteBackward`, and the text before and after the selected range.
- **iOS 26 scroll edge effects:** in a short text view, the top and bottom
  edge effects (and left/right if present) meet and hide the text. Hide all
  four with `topEdgeEffect.isHidden = true`, `bottomEdgeEffect.isHidden = true`
  (and left/right), and set `contentInsetAdjustmentBehavior = .never` as a
  precaution.
- **Sync with `EditorSession.text`:**
  - user edits update `session.text` (`textViewDidChange`);
  - a result or Undo from the session sets the text view's text and moves
    the caret to the end;
  - while `session.isEditable` is false (a run in flight), the view isn't
    editable.
- An empty Scratchpad shows a placeholder: "Select text, type or dictate"
  ("Text markieren, tippen oder diktieren").
- The editor controls from `EditorToolbar` (Undo, Retry, Copy, Show
  original) sit in a compact row at the Scratchpad's bottom edge, visible
  in prompt mode only.
- **UI test:** add a test that the Scratchpad text is visible and hittable
  (label value).

### SwiftUI parts (KallilexUI)

- **`KeyboardPromptPanel`:**
  - `PromptChipsBar` with the user's prompts (from the loaded settings);
  - a `StatusBanner` that replaces the chips row during a run, an error or
    the not-configured state;
  - the action row.
- Reuse the existing `PromptChipsBar`, `PrivacyBadge`, `StatusBanner`,
  `EditorToolbar`; add compact variants only where the 44 pt rows need them.
- **`KeyboardTargetSwitch`:** a segmented control "Scratchpad | App".
- One `UIHostingController`, created once, whose root view observes a small
  `@Observable KeyboardModel` holding:
  - the mode;
  - the target;
  - the settings snapshot;
  - the `EditorSession`.

### Session and lifecycle

- **Keyboard state** (`KeyboardModel`, the Scratchpad text, the last result)
  lives in a process-wide object, not in the `UIInputViewController`. The
  controller is deallocated on every disappearance (keyboard switch, app
  switch, dismissal); the state survives for the lifetime of the keyboard
  process (spike unknown 10).
- **Never persisted to disk.**
- `viewDidLoad`:
  - build the stores (ios-16), `ActionRunner`, `EditorSession`;
  - the session's `Pasteboard` is a `KeyboardPasteboard` that writes
    `UIPasteboard.general` only when `hasFullAccess`, otherwise it does
    nothing. ios-19 adds the Full Access hint for Copy.
- `viewWillAppear`: load the settings. Read-only without Full Access
  (ios-16). It isn't loaded per keystroke.
- `viewWillDisappear`: `session.cancel()`.
- `textDidChange`: rebuild the `KeyboardContext` for auto-capitalization
  (target App).

### Keyboard harness (app, DEBUG)

- Launch argument `-uiTestKeyboardHarness` shows a `KeyboardHarnessView`:
  - a `UITextView` ("harness.hostText");
  - its `inputViewController` returns the real `KeyboardViewController`;
  - the harness links the keyboard sources the same way the share harness
    links `ShareHost`. If linking the extension's sources into the app
    isn't clean, move `KeyboardViewController`'s body into `KallilexUI` as
    `KallilexKeyboardController` and keep only a thin subclass in the
    extension.
- Works with `-uiTestStubProvider`, `-uiTestSkipOnboarding`,
  `-uiTestResetState`.
- Accessibility identifiers:
  - `keyboard.scratchpad`;
  - `keyboard.mode.keys`, `keyboard.mode.prompts`;
  - `keyboard.target.scratchpad`, `keyboard.target.app`;
  - `keyboard.key.<name>` (`a`, `shift`, `delete`, `space`, `return`,
    `numbers`);
  - the existing `editor.chip.<id>`, `editor.undo`, `editor.retry`,
    `editor.copy`.

### Memory

- No SwiftUI `TextEditor`/`TextField`, one hosting controller, no images
  except SF Symbols.
- Target: **60 MB** at peak (budget). Measure the harness and the device
  keyboard with Instruments; the numbers go into `issues-ios/release-ios-1.0.0-matrix.md`.

### Strings

New keys in `KallilexUI`'s String Catalog, EN and DE: the placeholder, the
target switch, the mode buttons, the key accessibility labels.

## Testing Decisions

- **Unit tests:** `KeyboardModel` with a stub runner and fake documents:
  - mode switching keeps the session text;
  - target switching;
  - a run result updates the text and the Scratchpad document;
  - `viewWillDisappear` cancels a run.
- **UI tests** (`KeyboardUITests`, harness):
  - typing "Hallo" in keys mode with target Scratchpad puts it into
    `keyboard.scratchpad`, not into `harness.hostText`;
  - target App puts it into `harness.hostText`;
  - shift once and auto-capitalization in the Scratchpad;
  - ⌨ ✓ back to prompts, run `editor.chip.builtin-rewrite` with the stub
    provider, the Scratchpad shows the stub result, `editor.undo` restores
    it;
  - the accessibility audit (the same audit types as
    `AccessibilityUITests`) in both modes.
- **Manual (device):**
  - typing speed and popups in Notes;
  - long-press accents;
  - the globe key list;
  - dark mode;
  - the measured memory.

## Out of Scope

- Insert into the host, Undo Insert, the selection take-over, consent and
  the Full Access states (ios-19).
- Dictation (ios-21).
- Autocorrect, suggestions, swipe typing.

## Further Notes

- PLAN-keyboard.md §5, §6, §7.1, §10.4.
