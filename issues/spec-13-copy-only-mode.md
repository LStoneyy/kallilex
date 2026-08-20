# Spec 13 — Copy-only mode: opting out of input synthesis, and auto-copying results

Status: ready-for-agent
Phase: platform polish (gives Wayland users a first-class alternative to the
permission spec-12 introduced)
Depends on: spec-12 (portal capability probing, the GlobalShortcuts binding,
and the RemoteDesktop input-synthesis path this spec makes optional). The
Windows port moves to spec-14+.

## Problem Statement

Spec-12 made the full loop work on portal-capable Wayland compositors, but it
buys that with a permission dialog whose wording ("remote desktop", "control
this computer") is far scarier than what Kallilex actually asks for: keyboard
device only, two chords, Ctrl+C and Ctrl+V.

What makes the trade genuinely questionable is what the permission buys *on
Wayland specifically*. On macOS and X11, Replace does something the user
cannot do by hand: it activates the exact source window by pid or window
handle and pastes there. On Wayland there is no cross-client activation, so
Replace is implemented as "hide the popover, let the compositor return focus
to whatever had it, then synthesize Ctrl+V". The paste lands in exactly the
same place the user's own Ctrl+V would. The permission buys the keystroke,
not the aim.

Today a user who would rather not grant it has no way to say so. Declining
the dialog is not a durable answer: the capture fallback synthesizes Ctrl+C
too, so the next capture with an empty primary selection asks again. And the
copy-only path that remains costs an extra click, which makes the honest
choice feel like the punished one.

Two settings fix both halves: one to keep Kallilex out of input synthesis
entirely, one to make the copy-only flow feel finished.

## Solution

Two persisted, user-visible settings, in three slices:

- **A) `input_synthesis_enabled`** — a Wayland-only opt-out that gates every
  path spec-12 routes through the RemoteDesktop portal. Off means: Replace
  disappears, capture uses the primary selection only, no portal session is
  ever created, and the permission dialog never appears.
- **B) `auto_copy_result`** — puts the result on the clipboard as soon as
  Kallilex changes the text, so the copy-only flow needs no Copy click.
- **C)** Settings UI for both, each with a short explanation underneath, plus
  the doc updates.

Nothing in the portal layer, the token lifecycle, or core orchestration
changes: both settings are gates in front of machinery spec-12 already built.

## User Stories

1. As a Wayland user who doesn't want to grant remote-input permission, I want a setting that stops Kallilex asking at all, so that declining is a decision I make once rather than a dialog I dismiss repeatedly.
2. As that user, I want capture to keep working from my selection, so that opting out costs me the paste-back step and nothing else.
3. As any user, I want the result to land on the clipboard automatically, so that the copy-only flow is "act, close, paste" rather than "act, click Copy, close, paste".
4. As a user reading Settings, I want each checkbox to say in one or two lines what it changes, so that I can choose without consulting the README.
5. As a user who turned input synthesis off, I want the app to say so plainly rather than claiming my compositor lacks a portal, so that the UI never misreports my own choice as a system limitation.
6. As a user who turns it back on, I want my earlier permission grant to still count, so that re-enabling isn't punished with another dialog.
7. As a macOS or X11 user, I want zero behavior change from this spec.

## Implementation Decisions

### Slice A — the input-synthesis opt-out

- `Settings` gains `input_synthesis_enabled: bool`, defaulting to **`true`**
  — via `#[serde(default = "...")]` with a small helper, not bare
  `#[serde(default)]`, so settings persisted before this spec keep today's
  behavior instead of silently losing Replace. Document that at the field.
- The setting is honored **on Wayland sessions only**, and only surfaced
  there. On macOS and X11 synthetic input needs no permission, so there is
  nothing to opt out of; honoring it there would only let a Wayland-era
  choice quietly degrade an X11 session on the same machine. Document this
  scoping at the field and at the gate.
- New gate in `platform/linux/wayland/`: `input_synthesis_live()` =
  `capabilities().input_synthesis && user_enabled()`, where `user_enabled()`
  reads a process-wide `AtomicBool`. The probe result stays in its
  `OnceLock` — it describes the compositor and never changes; the user flag
  is separately mutable so toggling takes effect without a restart.
- Seam `platform::set_input_synthesis_enabled(bool)` (no-op on macOS),
  called from `lib.rs` right after settings are loaded at startup, and from
  `set_settings` whenever the value changes.
- Every current reader of `capabilities().input_synthesis` moves to the new
  gate: `platform/linux/keyboard.rs`, `platform/linux/activation.rs`,
  `platform/linux/selection.rs` (`frontmost_app`). `platform_info_for` stays
  a pure function and takes the user flag as a third parameter rather than
  reading global state.
- With the gate closed, `LinuxKeyboard` returns the same `Err` it returns on
  a compositor without the portal, so `core::capture`'s existing early
  return applies unchanged (no synthetic copy, no fallback wait, clipboard
  untouched) and `frontmost_app()` returns `None`, so `replace_back`'s
  "no source app → error, touch nothing" contract keeps Replace inert.
  `PlatformInfo.replace_back_available` becomes false, so the frontend hides
  the button. **No new code path is introduced** — the opt-out reuses the
  degraded path Sway users already run.
- Turning the setting off drops any live RemoteDesktop session (a new
  message to the spec-12 manager task), so Kallilex never sits holding an
  open remote-input session it has decided not to use. The stored
  `wayland_restore_token` is deliberately **kept**: the portal-side grant
  outlives our setting either way, and discarding the token would make
  re-enabling cost a fresh dialog for no security gain. Revoking for real
  stays the desktop's job, which the Settings text should say.
- Reporting honesty: `PlatformInfo.wayland` keeps meaning *what the
  compositor offers* (probe results, untouched by the setting). The user's
  choice is a separate fact the frontend already has, since it loads
  `Settings`. The popover notice and the Settings capability list must
  combine them: a missing portal keeps today's wording; a portal that exists
  but is switched off says so as a choice, never as a compositor
  limitation. With input synthesis off by choice and the shortcut working,
  no notice is shown at all — nothing is wrong.

### Slice B — auto-copy

- `Settings` gains `auto_copy_result: bool`, `#[serde(default)]` (false), so
  nothing changes for anyone who doesn't ask for it. Cross-platform: it has
  the same value on macOS and X11 as on Wayland.
- Trigger: whenever **Kallilex itself** changes the result text — a
  successful AI action, or applying a spellcheck suggestion. Not while the
  user types: firing per keystroke would clobber the clipboard mid-edit, and
  a rule the user cannot predict is worse than one extra click. The last
  such change wins. The Copy button stays exactly as it is, for manual edits
  and for users who leave the setting off; the checkbox explanation must be
  honest that hand-edits after the last change still need it.
- Implementation is the existing `copy_result` command — no new backend
  surface. It discards the pending fallback backup, which is precisely the
  intended meaning here: the user asked for the result to end up on the
  clipboard, so the capture-time backup must not be restored over it later.
- Auto-copy must **not** fire as part of a successful Replace. Replace owns
  the clipboard for the whole of its backup → write → paste → restore
  sequence, and a copy landing inside that window would defeat the restore.
  The two settings are usable together (someone may want automatic paste-back
  *and* the result kept on the clipboard), so this is an ordering rule, not a
  mutual exclusion.

### Slice C — Settings UI and docs

- Both checkboxes live in the **General** tab under one heading, so a related
  pair isn't split across tabs. The input-synthesis checkbox renders only on
  Wayland sessions; the auto-copy checkbox always renders.
- Each checkbox gets a short explanation directly underneath — one or two
  lines, in the existing `.hint` styling, no new visual language. Suggested
  copy, to be adjusted to fit the surrounding voice:
  - *Use automatic paste-back* — "Lets Kallilex press Ctrl+C and Ctrl+V for
    you so Replace can put the result straight back where you were. Your
    desktop asks for input permission once. Turn it off and Kallilex never
    asks: capture then uses only the text you have selected, and results are
    copied instead."
  - *Copy the result automatically* — "Puts the result on the clipboard as
    soon as Kallilex changes the text, so you can close the popover and
    paste. This replaces what was on the clipboard; edits you type yourself
    afterwards still need the Copy button."
- The Accessibility tab's Wayland capability list must not contradict the
  setting: with the portal present but the setting off, the Replace row
  reads as switched off in Settings, not as unavailable.
- README's Wayland section gains a sentence that the paste-back permission
  is optional and how the copy-only flow reads. The release checklist's
  Linux matrix gains: opt-out pass (no dialog ever appears, capture and Copy
  still work) and an auto-copy pass.

## Testing Decisions

- The gate is a pure combination and is unit-tested as one: capability ×
  setting, all four combinations, including that a disabled setting on a
  capable compositor produces exactly the same outward result as an
  incapable compositor.
- `platform_info_for` gains coverage for the user flag: capability present +
  setting off → `replace_back_available` false while
  `PlatformInfo.wayland.input_synthesis` stays **true**, since the two
  report different facts.
- Settings coverage: round-trip of both fields, and backward compatibility —
  JSON persisted before this spec deserializes with
  `input_synthesis_enabled: true` and `auto_copy_result: false`.
- Frontend: Replace hidden when the setting is off; the notice distinguishes
  "compositor lacks the portal" from "switched off in Settings"; auto-copy
  calls `copyResult` after an action when enabled and not when disabled; and
  it does not fire on the Replace path.
- Live portal behavior stays manual-matrix only, as in spec-12: the headless
  tests pin the orchestration, not the dialogs.
- macOS and X11 legs must stay green with zero behavior diffs.

## Out of Scope

- Exposing the input-synthesis opt-out on macOS or X11.
- Auto-copying on popover dismiss, or after text the user typed by hand.
- Revoking the portal grant from inside Kallilex, or clearing the stored
  restore token when the setting is turned off.
- Any change to the portal session lifecycle, the restore-token rules, the
  GlobalShortcuts binding, or core capture/replace orchestration.
- A per-app or per-profile variant of either setting.

## Further Notes

- **The GNOME primary-selection concern from spec-12 is resolved.** That
  spec flagged, correctly for its time, that Mutter implemented no
  data-control protocol and that arboard would therefore read the primary
  selection through the XWayland bridge. Verified on GNOME Shell 50.1: a
  data-control client reads the primary selection of a native Wayland client
  (no terminal appears among the XWayland clients), and the
  `wl-clipboard-rs 0.9.3` that arboard's `wayland-data-control` feature
  builds on supports both `zwlr_data_control_manager_v1` and
  `ext_data_control_manager_v1`, which recent Mutter ships. Copy-only is a
  first-class mode on GNOME 48+, not a fallback that quietly loses
  selections. Older Mutter without either protocol remains untested and is
  the case to watch in the manual matrix.
- The opt-out deliberately produces no new runtime state: it steers Wayland
  sessions onto the degraded path spec-11 already defined and spec-12 left
  in place for wlroots compositors. Reviewers should reject any
  implementation that introduces a third behavior instead of reusing that
  one.
- Slices land as separate coder tasks A → B → C with review gates between
  them, one commit per slice, matching the spec-11/spec-12 workflow.
