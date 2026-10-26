# Spec 21 — Keyboard shortcuts in the popover

Status: ready-for-agent
Phase: popover keyboard control (one spec, four slices: A model and Rust
core, B popover, C settings, D onboarding and docs)
Depends on: 0.6.0 on `main` (user-managed prompts, movable popover). The
release itself (0.7.0-beta.1, then 0.7.0) is a follow-up spec modeled on
spec-20, not part of this one.

## Problem Statement

The global shortcut opens Kallilex without the mouse, but the popover itself
can only be driven by clicking: every prompt, Custom, Replace and Copy is a
button, and nothing is focused when the popover opens. The only key the
popover understands is Escape. A user who opened Kallilex with the keyboard
has to switch to the mouse for every step after that.

There is also a latent bug that a keyboard flow would surface:
`handleCustomKeydown` in `src/popover/App.svelte` runs the custom prompt on
*any* Enter, including ⌘↩ — so once ⌘↩ means Replace, pressing it in the
custom field would run the prompt and replace at the same time.

## Solution

Every popover action gets a user-configurable keyboard shortcut, with
sensible defaults: ⌘1–⌘9 for the saved prompts, ⌘↩ for Replace, ⌘⇧C for
Copy, ⌘L for Custom prompt, ⌘, for Settings (Ctrl instead of ⌘ on Windows
and Linux). The popover focuses the text field on open, returns focus to it
after an AI action, shows each button's shortcut as a small badge while the
user holds ⌘/Ctrl, and gives a visible response to every shortcut press. A
new **Shortcuts** tab in Settings lists and edits every shortcut — including
the global one, which moves there from General — through a shared recorder
control that captures key presses instead of asking for typed text.

## User Stories

1. As a keyboard user, I want the cursor to be in the text field as soon as
   the popover opens, so that I can edit the captured text without clicking.
2. As a keyboard user, I want ⌘1, ⌘2, ⌘3 … to run my first, second, third …
   saved prompt, so that rewriting is a single key press.
3. As a keyboard user, I want ⌘↩ to replace the text in the source app and
   ⌘⇧C to copy it, so that I can finish without the mouse.
4. As a keyboard user, I want ⌘L to open the custom-prompt field with the
   cursor in it, so that I can type an instruction right away and run it
   with ↩.
5. As a keyboard user, I want the focus back in the text field after an AI
   action finishes, so that I can keep editing or press ⌘↩.
6. As a user, I want to hold ⌘ (Ctrl on Windows/Linux) and see which
   shortcut each button has, so that I don't have to memorize them or open
   Settings.
7. As a user, I want a pressed shortcut to visibly press its button, and an
   unavailable one to shake its button, so that I always know whether the
   key arrived and whether it did anything.
8. As a user, I want to assign, change and remove shortcuts for each prompt,
   Replace, Copy, Custom prompt, Check spelling and Open Settings in one
   place, by pressing the keys rather than typing their names.
9. As a user, I want to be told when a combination is already taken and be
   offered to take it over, so that I never end up with two actions on one
   key — or with a dead binding.
10. As a user, I want to set a prompt's shortcut while creating or editing
    the prompt, and a new prompt to get the next free ⌘N automatically.
11. As a user upgrading from 0.6.0, I want my existing prompts to get
    ⌘1–⌘9 once, in their current order, without later overriding anything
    I changed.
12. As a user on a German (or other non-US) layout, I want shortcuts to work
    with the keys printed on my keyboard, and never to swallow characters I
    type with AltGr or ⌥ (such as @).
13. As a new user, I want the onboarding to tell me the key shortcuts exist
    and where to change them.

## Implementation Decisions

### Shortcut format (popover shortcuts)

- Stored as strings with the grammar `[Mod+][Alt+][Shift+]Key`, in that
  fixed modifier order. `Mod` means ⌘ on macOS and Ctrl on Windows/Linux, so
  defaults and stored values are platform-neutral.
- `Key` is one of: `A`–`Z`, `0`–`9`, `F1`–`F12`, `Enter`, or a single
  printable punctuation character as the layout produces it unshifted
  (e.g. `,` `.` `-`). Arrows, Space, Tab, Escape, Backspace and Delete are not
  bindable.
- A shortcut must contain `Mod`, except a bare `F1`–`F12` (optionally with
  `Shift`/`Alt`), which is allowed without a modifier.
- Not bindable at all: macOS ⌃ (Control) — ⌃A/⌃E/⌃K are text-navigation keys
  in macOS text fields; ⌥ or ⇧ without `Mod` on non-F-keys — on macOS ⌥+key
  types characters (⌥L is @ on the German layout); the Windows/Super key.
- Reserved (rejected with a reason), after normalization, on every platform
  so stored settings stay portable:
  - text editing: `Mod+C`, `Mod+V`, `Mod+X`, `Mod+A`, `Mod+Z`,
    `Mod+Shift+Z`, `Mod+Y`;
  - macOS system: `Mod+Q`, `Mod+W`, `Mod+H`, `Mod+M`;
  - webview accelerators (WebView2 and others): `Mod+R`, `Mod+P`, `Mod+F`,
    `Mod+G`, `F5`, `F7`, `F12`;
  - the chord the current global shortcut maps to (see below).
- On Linux, `Mod+Alt+F1`–`F12` is allowed but shows a non-blocking warning:
  many desktops reserve Ctrl+Alt+F-keys for switching virtual terminals.

### Defaults

| Target | Default |
| --- | --- |
| Prompts 1–9 (list order) | `Mod+1` … `Mod+9` |
| Replace | `Mod+Enter` |
| Copy | `Mod+Shift+C` |
| Custom prompt | `Mod+L` |
| Open Settings | `Mod+,` |
| Check spelling | none |

Not configurable and unchanged: Escape (cancel the AI action → close
suggestions → close the custom row → close the popover, as today), Tab /
Shift+Tab (focus order), ↩ in the custom field (run). Pin has no shortcut.

### Data model (Rust, mirrored in `src/shared/types.ts`)

- `CustomPrompt` gains `shortcut: Option<String>` with `#[serde(default)]`.
  `default_prompts()` seeds `Mod+1`, `Mod+2`, `Mod+3`.
- `Settings` gains `popover_shortcuts: PopoverShortcuts` with fields
  `replace`, `copy`, `custom_prompt`, `open_settings`, `check_spelling`, each
  `Option<String>`. The struct has `#[serde(default)]` at struct level and an
  `impl Default` returning the defaults table above, so a missing field
  (an older settings.json, or a field added later) takes its default, while
  an explicit `null` (the user removed it) stays `None`.
- `Settings` gains `prompt_shortcuts_seeded: bool` with plain
  `#[serde(default)]` (`false`); `Settings::default()` sets it `true`.
- One-time migration, called from `lib.rs`'s `setup` next to
  `evaluate_onboarding` (errors swallowed the same way): when
  `prompt_shortcuts_seeded` is `false`, walk the first nine prompts in
  order; give prompt *i* `Mod+i` if it has no shortcut and `Mod+i` is not
  used by anything else; then set the flag and save. Idempotent; it never
  runs again, so a shortcut the user removes later stays removed.
- Shortcuts are machine-local in spirit, like `popover_position`, but carry
  no machine-specific data; no special treatment for export.

### Rust core: `core/shortcuts.rs` (new)

- `Chord` (`mod`, `alt`, `shift`, `key`) with `parse(&str)` and a canonical
  `Display`; `validate(&Chord) -> Result<(), String>` applying the rules
  above with user-facing messages ("⌘C is reserved for copying text.",
  "Add ⌘ — plain keys would get in the way of typing.").
- `chord_for_global(accelerator: &str) -> Option<Chord>` maps the global
  shortcut string (`Alt+Cmd+K`, `Ctrl+Alt+K`, `CommandOrControl+…`) onto the
  same chord space for the current OS (macOS: Cmd → `mod`, Ctrl → no
  equivalent so never equal; elsewhere Ctrl → `mod`), so "equals the global
  shortcut" is a chord comparison, not a string comparison.
- `ShortcutTarget` (serde-tagged): `{ kind: "action", action: "replace" |
  "copy" | "customPrompt" | "openSettings" | "checkSpelling" }`,
  `{ kind: "prompt", id }`, `{ kind: "global" }`.
- `holder_of(&Settings, &Chord) -> Option<ShortcutTarget>`.
- `assign_shortcut_core(store, target, shortcut: Option<String>, take_over:
  bool) -> Result<Settings, ShortcutOpError>`: one load → mutate → save.
  Validates; on a conflict either fails (`take_over == false`) or clears the
  other holder in the same write. For `global`, `None` is rejected (the
  global shortcut is required) and the global shortcut can never be *taken
  over* by a popover shortcut — that conflict is always an error.
- `reset_popover_shortcuts_core(store)`: popover shortcuts back to the
  defaults table; all prompt shortcuts cleared, then the first nine
  re-assigned `Mod+1`…`Mod+9`. The global shortcut is not touched.
- Integrity on the existing write paths: `set_settings` validates popover
  and prompt shortcuts **only when they changed** compared with the stored
  settings (so a hand-edited invalid file never blocks unrelated saves from
  other tabs), and checks a changed global shortcut against the popover
  chords. `save_prompt_core` validates `prompt.shortcut` and takes a
  `take_over: bool` with the same semantics as `assign_shortcut_core`.

### Commands and TS wrappers

- New: `assign_shortcut(target, shortcut, takeOver) -> Settings`,
  `reset_popover_shortcuts() -> Settings`. When the target is `global`,
  `assign_shortcut` goes through the same unregister/register sequence as
  `set_settings` does today (factor that sequence into a helper rather than
  duplicating it), and is unavailable when
  `platform::use_portal_global_shortcut()` is true.
- Changed: `save_prompt(prompt, takeOverShortcut?: boolean)`.
- `src/shared/invoke.ts` gets typed wrappers; `types.ts` gets
  `PopoverShortcuts`, `ShortcutTarget`, the new `Settings` fields and
  `CustomPrompt.shortcut: string | null`.

### Frontend core: `src/shared/shortcuts.ts` (new)

- `chordFromEvent(event, os): string | null` — the only place a
  `KeyboardEvent` becomes a chord string; used by both the popover matcher
  and the recorder so recording and matching can never disagree.
  - Returns `null` for modifier-only presses, `event.repeat`,
    `event.isComposing`, and any event where
    `event.getModifierState("AltGraph")` is true (Windows reports AltGr as
    Ctrl+Alt — without this, a Ctrl+Alt+Q shortcut would eat every @ typed
    on a German keyboard).
  - `Mod` is `metaKey` on macOS and `ctrlKey` elsewhere; `ctrlKey` on macOS
    and `metaKey` elsewhere make the event unbindable (`null`).
  - Key: if `event.key` is a single ASCII letter or digit, use it
    (uppercased) — this follows the printed layout, so Z on a German
    keyboard is `Z`. Otherwise derive from `event.code` (`KeyA` → `A`,
    `Digit1` → `1`) — this covers ⌥ on macOS (`event.key` is `å`) and Shift
    on digits (`event.key` is `!`). `Enter` and `F1`–`F12` from `event.key`;
    other single printable characters from `event.key` when no Shift/Alt is
    held.
- `formatChord(chord, os): string[]` — display tokens: macOS `⌘ ⌥ ⇧` plus
  `↩` for Enter; elsewhere `Ctrl`, `Alt`, `Shift`, `Enter`. Rendered by a
  small `Kbd.svelte` (joined with `+` off macOS).
- `validateChord`, `holderOf(settings, chord)`, `nextFreePromptShortcut
  (settings)` — mirrors of the Rust rules for instant feedback; the Rust
  side stays authoritative.
- `acceleratorFromEvent(event, os): string | null` for the **global**
  recorder: emits the Tauri accelerator format (`Ctrl+Alt+Shift+Cmd+K` order
  on macOS, `Ctrl+Alt+Shift+K` elsewhere; at least one of Cmd/Ctrl/Alt
  required; Super/Win not allowed). The global shortcut is matched by the OS
  on **physical** keys, so this one derives the key from `event.code`, not
  `event.key`. Verify with a Rust unit test that every emitted token parses
  with `Shortcut::from_str` (use `KeyX`/`DigitN` if bare letters/digits do
  not).

### Popover (`src/popover/App.svelte`)

- **Keymap.** A `$derived` map from chord → action, built from `prompts`
  and `popoverShortcuts` (both refreshed by `refreshContext`, which already
  runs on focus gain, so edits in Settings apply on the next focus).
- **Handler.** `handleWindowKeydown` first keeps the Escape cascade as is,
  then: `chord = chordFromEvent(…)`; if it matches, `preventDefault()` and
  dispatch. This runs regardless of which element has focus (text field,
  custom field, a button).
- **Dispatch rules.** Each action goes through the same guard as its button
  (`canRunAction`, `canReplace`, `canCopy`, `busy`); `runAiAction` keeps its
  own guard. If the guard passes, the button gets a `.key-pressed` class for
  ~150 ms and the action runs. If it does not (no text, an action already
  running, Replace without a source app), the button gets `.key-denied` (a
  ~300 ms horizontal shake; with `prefers-reduced-motion`, a brief outline
  flash instead) and nothing runs. With no provider configured, prompt
  shortcuts behave like the buttons: the existing "No AI provider" hint.
  When Replace is hidden (platform has no replace, or input synthesis is
  switched off) its shortcut does nothing.
- **Custom prompt shortcut.** Opens the custom row if closed (never toggles
  it shut), then focuses the input. Opening it by click also focuses the
  input now.
- **Bug fix.** `handleCustomKeydown` only runs on a bare Enter (no
  `metaKey`/`ctrlKey`/`altKey`/`shiftKey`, not composing), so ⌘↩ in the
  custom field is Replace only.
- **Focus.** After `refreshCapture` has assigned the new text: focus the
  textarea with the caret at the end. On window focus gain, when
  `document.activeElement` is `body`, do the same (covers tray-opened
  popovers). After `runAiAction` settles (ok, error or cancelled, in the
  current generation), focus the textarea, caret at end — it was `disabled`
  while running and dropped focus.
- **Hints.** While the `Mod` key (`Meta` on macOS, `Control` elsewhere) is
  held for ≥ 400 ms with no other key, show `.shortcut-badge` overlays
  (absolutely positioned inside the top-right corner of each button, so the
  layout never shifts and the action row's `overflow-y: auto` does not clip
  them) on: prompt buttons, Custom, Replace, Copy, Check spelling. Hide on
  `keyup` of that key, on any other keydown, and on window blur. Buttons
  without a shortcut get no badge.
- **Tooltips.** Every button with a shortcut gets `title="Label (⌘1)"`.

### Settings: new Shortcuts tab (`src/settings/App.svelte`)

- `Tab` gains `"shortcuts"`, placed second: General, Shortcuts, Providers,
  Prompts, Updates, Accessibility; added to `KNOWN_TABS`.
- The global shortcut section **moves** here from General, including the
  Wayland read-only variant (portal trigger text and hints) unchanged. On
  other sessions the text field is replaced by the recorder; ↺ resets it to
  `platformInfo.defaultShortcut`; it has no ✕.
- Layout:

  ```
  Shortcuts
    Open Kallilex (global)     [ ⌥ ⌘ K ]          ↺
  In the popover
    Replace                    [ ⌘ ↩ ]       ↺  ✕
    Copy                       [ ⌘ ⇧ C ]     ↺  ✕
    Custom prompt              [ ⌘ L ]       ↺  ✕
    Check spelling             [ Not set ]
    Open Settings              [ ⌘ , ]       ↺  ✕
  Prompts
    Rewrite                    [ ⌘ 1 ]           ✕
    Shorten                    [ ⌘ 2 ]           ✕
    Improve clarity            [ ⌘ 3 ]           ✕
  Always: Esc cancels or closes · Tab moves focus · ↩ runs a custom prompt
  Reset popover shortcuts
  ```

  - ↺ only where the current value differs from the default; ✕ only when
    set.
  - Replace shows a hint "Not available on this system" when
    `replaceBackAvailable` is false (still editable).
  - No prompts: "No prompts yet — add them in the Prompts tab."
  - "Reset popover shortcuts" is a two-click armed button ("Confirm
    reset?"), the same pattern as the Prompts tab's delete; it calls
    `reset_popover_shortcuts`.
- Every row saves immediately through `assign_shortcut`; there is no Save
  button. A short `.confirm` "Saved" appears on the row; a backend error
  appears as `.error` on the row.

### Recorder (`src/shared/ShortcutRecorder.svelte`, new)

- Props: current value, OS, a validator, a conflict lookup, `clearable`,
  `onCommit(value, takeOver)`.
- **Idle:** a button showing the `Kbd` tokens, or "Not set". Its
  `aria-label` names the action and the current shortcut.
- **Recording** (click, Enter or Space): shows "Press a shortcut…" with a
  live preview of held modifiers and the hint "Esc to cancel, ⌫ to clear".
  `keydown` is handled on the recorder with `preventDefault()`; Escape
  cancels, bare Backspace/Delete clears (only if `clearable`), Tab cancels
  and lets focus move on, blur cancels.
- **Result of a key press:**
  - invalid or reserved → inline `.error` with the reason; stays recording;
  - equal to the global shortcut → error "Already used to open Kallilex.";
  - held by another target → "⌘2 is used by "Rewrite"." with
    **[Take over]** (commit with `takeOver = true`) and **[Cancel]**;
  - Linux `Mod+Alt+F-key` → commit, plus the non-blocking warning;
  - valid and free → commit.
- Used for popover rows, prompt rows, the global row (with
  `acceleratorFromEvent` and global rules), and the prompt form.

### Prompts tab

- Each prompt row shows its shortcut as a `Kbd` chip (nothing if unset).
- The add/edit form gets a "Shortcut" field with the recorder; a new prompt
  is pre-filled with `nextFreePromptShortcut` (none if ⌘1–⌘9 are all used).
  The value is saved with the prompt through `save_prompt`; a confirmed
  Take over in the form is passed as `takeOverShortcut: true`.

### Onboarding (`src/onboarding/App.svelte`)

- The "You're all set" step gets one hint line after the existing "Try it
  now" line, formatted for the platform: "In the popover, ⌘1 runs your
  first prompt, ⌘↩ replaces and ⌘⇧C copies — hold ⌘ to see every shortcut.
  Change them in Settings → Shortcuts." Without Replace available, leave
  out the "⌘↩ replaces" part.

### Docs

- README: a "Keyboard" subsection under Popover (defaults table, hold-⌘
  hints, Settings → Shortcuts, the AltGr and macOS ⌃ notes); one sentence in
  the workflow list (step 4/5) that every step has a shortcut.
- Website: one line in the feature copy that the popover is fully keyboard
  driven; no new section.
- `docs/release-checklist.md`: a keyboard row per platform matrix (open →
  edit → ⌘1 → ⌘↩ with no mouse; ⌘⇧C; ⌘L + ↩; hints on hold), plus: German
  layout on macOS (⌥L still types @ in the popover; Z/Y labels match),
  Windows with a German layout (AltGr+Q types @ in the popover), and a
  Wayland session.

## Slices

- **A — Model and Rust core.** Settings and prompt fields, migration,
  `core/shortcuts.rs`, `assign_shortcut` / `reset_popover_shortcuts`,
  `save_prompt` change, integrity checks in `set_settings`, the global
  register helper, TS types and wrappers. No UI.
- **B — Popover.** Keymap, handler, dispatch with press/deny feedback,
  focus handling, hold-to-show hints, tooltips, the `handleCustomKeydown`
  fix, `src/shared/shortcuts.ts` and `Kbd.svelte`.
- **C — Settings.** `ShortcutRecorder.svelte`, the Shortcuts tab (including
  the move of the global shortcut and its Wayland variant), Prompts tab
  chips and form field.
- **D — Onboarding and docs.** Onboarding line, README, website, release
  checklist.

Each slice leaves CI green (`pnpm check`, `pnpm test`, `cargo clippy
--all-targets -D warnings`, `cargo test`).

## Testing Decisions

### Rust (`core/shortcuts.rs`, `core/prompts.rs`, `core/settings`)

- Parse/format round-trips; canonical modifier order; rejection of every
  reserved chord, of non-`Mod` non-F-key chords, and of unknown keys.
- `chord_for_global`: `Alt+Cmd+K` on macOS and `Ctrl+Alt+K` elsewhere map to
  `Mod+Alt+K`; a popover `Mod+Alt+K` is rejected as equal to it.
- `assign_shortcut_core`: assigns; conflict without take-over fails and
  writes nothing; take-over clears the other holder in one save; `None`
  clears; `global` + `None` fails; a popover chord can't take over the
  global one.
- `reset_popover_shortcuts_core`: defaults restored; prompts re-seeded in
  order; global untouched.
- Migration: an old settings.json with three prompts without `shortcut`
  gets ⌘1–⌘3 and the flag; a second run changes nothing; a prompt whose
  `Mod+i` is already taken by an action is skipped; prompts 10+ get nothing.
- Serde: missing `popoverShortcuts` → defaults; explicit `null` for one
  field stays `None` while the others default.
- `set_settings` integrity: an unchanged invalid stored shortcut does not
  block an unrelated save; a changed duplicate is rejected.
- `acceleratorFromEvent` outputs used in tests parse with
  `Shortcut::from_str`.

### Frontend (`src/shared/shortcuts.test.ts`, new)

Table-driven `chordFromEvent` tests that double as the shared reference:

| os | event | result |
| --- | --- | --- |
| macos | meta, key `1`, code `Digit1` | `Mod+1` |
| macos | meta+shift, key `!`, code `Digit1` | `Mod+Shift+1` |
| macos | meta+alt, key `å`, code `KeyA` | `Mod+Alt+A` |
| macos | meta, key `z`, code `KeyY` (German layout) | `Mod+Z` |
| macos | meta, key `Enter` | `Mod+Enter` |
| macos | meta, key `,`, code `Comma` | `Mod+,` |
| macos | ctrl, key `a` | `null` |
| macos | key `Meta` only | `null` |
| windows | ctrl+alt, AltGraph, key `@`, code `KeyQ` | `null` |
| windows | ctrl+shift, key `C` | `Mod+Shift+C` |
| linux | key `F6` | `F6` |
| any | `repeat: true` | `null` |

Plus `formatChord` per OS and `validateChord` messages.

### Popover (`src/popover/App.test.ts`)

- Each default shortcut triggers its action (prompt N with the right
  instruction, Replace, Copy, Custom opens and focuses, Settings, Check
  spelling when bound).
- A user-changed binding from `getSettings` replaces the default; an
  unbound action does nothing.
- Guards: no text / `busy` / Replace without source app → the action is not
  invoked and the button gets `key-denied`; success adds `key-pressed`.
- ⌘↩ in the custom field calls `replaceBack` and not `runAction`; bare ↩
  still runs the custom prompt.
- AltGraph events never trigger anything; repeats don't double-run.
- Focus: textarea focused with caret at end after `capture:done`, and again
  after an action settles.
- Hints: badges appear after holding `Meta` for 400 ms (fake timers),
  disappear on keyup and blur; none for unbound buttons.
- Escape cascade unchanged (existing tests stay green).

### Settings (`src/settings/App.test.ts`)

- The Shortcuts tab renders all rows with formatted tokens; General no
  longer has the shortcut section; the Wayland read-only variant renders on
  the Shortcuts tab.
- Recording a free chord calls `assignShortcut` with the right target; Esc
  cancels; ⌫ clears; a reserved chord shows the reason and does not save.
- A taken chord shows the conflict line; Take over calls with
  `takeOver: true`; Cancel saves nothing.
- ↺ and ✕ visibility and calls; Reset popover shortcuts needs two clicks.
- Prompt form: a new prompt is pre-filled with the next free ⌘N; the chip
  shows in the list; Take over in the form passes `takeOverShortcut: true`.
- `settings:show-tab` with `"shortcuts"` switches to the tab.

### Onboarding

- The finish step shows the shortcut line with platform tokens and omits
  Replace when it is unavailable.

## Out of Scope

- Keyboard navigation of spell-check suggestions (decided: not needed).
- A shortcut for Pin.
- Closing the popover after Copy (it stays open; Escape closes it).
- Reordering prompts.
- A setting for hint visibility (always / never); hints are hold-to-show
  only.
- A command palette or a cheat-sheet overlay.
- Version bump and release (follow-up spec for 0.7.0-beta.1 → 0.7.0).

## Further Notes

- WebView accelerators: it is not verified whether a `keydown`
  `preventDefault()` reliably suppresses WebView2's built-in accelerators
  (Ctrl+R reload, Ctrl+P print). Reserving them sidesteps the question for
  bindings; whether Tauri should disable browser accelerator keys on the
  popover window altogether is a separate decision, not part of this spec.
- On AltGr layouts on Windows, `Mod+Alt+…` chords are effectively
  unrecordable because the browser reports `AltGraph` for them. That is
  intended — the alternative is shortcuts that eat typed characters.
- On macOS, `keyup` events are not delivered for keys pressed while ⌘ is
  held; the hint overlay only depends on the `Meta` key's own `keydown` /
  `keyup` and on blur, so this does not affect it.
- The global recorder records physical keys (`event.code`), so on layouts
  where a letter's position differs from US (Z/Y on German) the stored
  accelerator names the US key position. The OS matches it on the key the
  user pressed, so it works; only the label can differ. Acceptable; noted
  in the manual matrix.
