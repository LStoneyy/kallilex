# Spec 12 — Native Wayland support: portal-backed shortcuts, input synthesis, and focus-return replace

Status: ready-for-agent
Phase: platform expansion (upgrades spec-11's Wayland degraded mode to a
near-full experience on portal-capable compositors)
Depends on: spec-11 (the complete Linux port — session detection, the
platform seam, the degraded mode, packaging). Windows (spec-13+) is
independent of this spec.

## Problem Statement

From a Wayland user's perspective: Kallilex works, but grudgingly. Spec-11's
degraded mode is honest — tray-triggered capture of the primary selection,
copy-only results, a visible notice — but the two things that make Kallilex
feel instant are missing: the global shortcut and automatic replace-back.
Both are missing because Wayland, by design, gives apps no global keyboard
access and no way to synthesize input or activate other clients directly.

What has changed since that design decision: the XDG Desktop Portal layer
now covers exactly these gaps, and the compositors Kallilex users actually
run have caught up:

- **GlobalShortcuts portal** (`org.freedesktop.portal.GlobalShortcuts`):
  supported by KDE Plasma (since 5.25), GNOME 48+, and Hyprland's own
  portal. Not implemented by wlroots' `xdg-desktop-portal-wlr` (Sway, and
  Niri support is still in development).
- **RemoteDesktop portal** (`org.freedesktop.portal.RemoteDesktop`):
  keyboard input synthesis via `NotifyKeyboardKeycode`, with permission
  dialogs and persistable sessions (restore tokens, portal v2). Implemented
  by GNOME (mutter/gnome-remote-desktop) and KDE; NOT implemented by
  `xdg-desktop-portal-wlr` or `xdg-desktop-portal-hyprland`.

So support is a *per-capability* matter, not per-session: a Plasma user can
get essentially the full macOS-grade loop; a Sway user keeps spec-11's
degraded mode; a Hyprland user gets the shortcut but stays copy-only. The
app must probe what is actually available and degrade per capability —
never pretend, never dialog-spam.

## Solution

Wayland sessions get a portal-backed capability layer in three functional
slices plus docs: **A) capability probing + seam extensions** (detect which
portals exist, surface it in `PlatformInfo`, extend settings for the
restore token), **B) global shortcut via the GlobalShortcuts portal**
(ashpd; the existing tauri plugin stays for macOS/X11), and **C) input
synthesis + replace-back via the RemoteDesktop portal** (synthetic
Ctrl+C/Ctrl+V through `NotifyKeyboardKeycode`, focus-return activation,
restore-token persistence). **D)** updates docs and the manual test matrix.

libei/`ConnectToEIS` is explicitly NOT used in this spec (see Out of
Scope): the plain RemoteDesktop `Notify*` path is portable across GNOME and
KDE, needs only `ashpd`, and avoids a second protocol stack. The seams laid
in spec-11 absorb all of this — no core orchestration fork.

## User Stories

1. As a Plasma/GNOME-48+ Wayland user, I want to press my shortcut and get the popover with my selection captured, so that the core flow matches X11/macOS.
2. As a Wayland user, I want Replace to type the corrected text back into the app I came from, so that the round trip no longer ends at Copy.
3. As a Wayland user, I want to grant the input permission once via my desktop's own portal dialog and not again on every launch, so that security stays visible but not annoying.
4. As a Sway/wlroots user, I want Kallilex to keep working exactly as in spec-11 (tray capture, copy-only) with an accurate notice about what my compositor supports, so that I'm degraded, not deceived.
5. As a Hyprland user, I want the global shortcut to work even though replace-back can't, so that I get every capability my portal actually offers.
6. As a user on any compositor, I want Settings to show which Wayland capabilities are live (shortcut, replace) and why, so that missing features are explained, not mysterious.
7. As a macOS or X11 user, I want zero behavior change from this spec.
8. As the maintainer, I want the portal layer behind testable seams with the same fake-based tests as everything else, so that headless CI keeps covering the orchestration.

## Implementation Decisions

### Slice A — capability probing + seam extensions

- New dependency (Linux target only): `ashpd` (async XDG portal client,
  zbus-based; use its tokio feature — the app already runs tauri's tokio
  runtime). No other new crates in this spec.
- New module `platform/linux/wayland/` with a capability probe run once at
  startup (Wayland sessions only): D-Bus-query the portal service for the
  `GlobalShortcuts` and `RemoteDesktop` interfaces and their versions
  (interface absent → capability off; RemoteDesktop v2+ → restore tokens
  available). Probing is read-only and MUST NOT trigger any permission
  dialog.
- `WaylandCapabilities { global_shortcut: bool, input_synthesis: bool,
  can_persist_session: bool }`, exposed through the capability probe behind
  a small trait (`PortalProbe`-style) so orchestration-level decisions are
  testable with fakes.
- `PlatformInfo` gains `wayland: Option<WaylandCapabilitiesInfo>` (serde
  camelCase; `None` on macOS and X11). `replace_back_available` on a
  Wayland session becomes `capabilities.input_synthesis` instead of
  hard-coded `false`. Frontend `PlatformInfo` type mirrors this.
- `Settings` gains `wayland_restore_token: Option<String>` (`#[serde
  (default)]`, absent for existing installs). It is a portal session
  restore token, not a credential: storing it in the Tauri Store is
  correct — it only lets *this app* skip re-prompting, and the compositor
  can revoke it. Document exactly that at the field.
- Frontend: the spec-11 Wayland notices become capability-driven. With both
  capabilities live, no notice at all; otherwise the notice names precisely
  what is missing ("your compositor doesn't offer the GlobalShortcuts
  portal" / "…the RemoteDesktop portal"), in one line, same styling as
  today. The Settings Accessibility/Wayland block becomes a small
  capability table (shortcut: portal-managed/unavailable; replace:
  available/unavailable) — text, no new visual language.

### Slice B — global shortcut via the GlobalShortcuts portal

- On Wayland sessions with `global_shortcut`: skip the tauri
  global-shortcut plugin registration entirely (today it is attempted and
  expected to fail; with the portal present it must not even be attempted —
  one owner per trigger). macOS/X11 keep the plugin unchanged.
- ashpd flow at startup: `CreateSession` → `BindShortcuts` with one
  shortcut (id `"capture"`, description "Capture the current selection",
  preferred trigger derived from the stored/default shortcut string,
  translated to the portal's trigger format) → listen to the `Activated`
  signal → call the existing `trigger_capture` path (the same function the
  plugin handler calls; capture itself is unchanged).
- The compositor owns the actual binding UX (Plasma shows a bind dialog,
  users can rebind in system settings). Consequence for Settings on
  Wayland-with-portal: the free-text shortcut field is replaced by a
  read-only display of the portal-reported trigger (`ListShortcuts`) plus a
  hint that the binding is managed by the system; `set_settings`'s shortcut
  registration branch is skipped on this path (persisting the string is
  harmless and stays, as the default for X11 sessions on the same machine).
- Failure honesty: `BindShortcuts` failing or the user declining leaves the
  spec-11 tray path as the trigger; the notice reflects it. No dialogs from
  Kallilex itself.

### Slice C — input synthesis + focus-return replace-back

- **Session management**: one lazily-created RemoteDesktop portal session
  (devices: KEYBOARD), created on *first use* — the first fallback-copy or
  Replace — never at startup, so the permission dialog appears in an
  action context the user just initiated. With `can_persist_session`,
  request persistence and store the returned restore token in settings;
  on the next session creation pass the stored token so no dialog appears.
  A revoked/invalid token (portal error) clears the stored token and
  retries once without it (dialog appears again — correct).
- **`WaylandKeyboard`** (Keyboard seam impl, replacing the unconditional
  `Err` from spec-11 when `input_synthesis` is live): `send_copy`/
  `send_paste` = `NotifyKeyboardKeycode` press/release sequences for
  Ctrl+C / Ctrl+V using Linux evdev keycodes (`KEY_LEFTCTRL`, `KEY_C`,
  `KEY_V`). Keycodes are positional: on layouts where the C/V positions
  differ this can mistype — accepted v1 caveat, documented in code (same
  class of caveat enigo has on X11; a keymap-aware lookup is a follow-up).
  Sessions without the capability keep returning `Err` immediately —
  spec-11's early-return in `capture()` then still applies unchanged.
- **Focus-return activation**: Wayland has no cross-client activation.
  The Wayland `AppActivator` implementation instead hides the popover
  window (via the `AppHandle` its constructor already receives, marshalled
  to the main thread) and returns `Ok` — the compositor returns focus to
  the previously focused surface, which is exactly the capture source in
  the shortcut/tray flow. The popover hide triggers the existing
  focus-loss cancel path, which is already harmless mid-replace thanks to
  `BackupLifecycle::take_pending` (the spec-04 race guard) — no core
  changes needed. The existing `FOCUS_SETTLE_DELAY` before the paste
  stays.
- **SourceApp on Wayland**: `frontmost_app()` cannot identify the focused
  client. When (and only when) `input_synthesis` is live, it returns a
  documented focus-return placeholder via a new
  `SourceApp::focus_return()` constructor (`bundle_id: None, pid: 0,
  name: None, window: None`) so the unchanged core `replace_back`
  contract ("no source app → error, touch nothing") and the frontend's
  `canReplace` gating both keep working. The placeholder's meaning —
  "replace targets whatever window regains focus" — is documented on the
  constructor. Without input synthesis, `frontmost_app()` stays `None`
  and Replace stays hidden (spec-11 behavior).
- **Popover focus on show**: verify during implementation that the popover
  actually receives keyboard focus when shown on GNOME/KDE Wayland (tao's
  xdg-activation handling). If it does not, that is a blocking finding to
  escalate, not to work around ad hoc.

### Slice D — docs + manual test matrix

- README Linux section: replace the flat "Wayland = degraded" story with
  the capability tiers (Plasma/GNOME 48+: full loop via portals, one
  permission dialog; Hyprland: shortcut yes / replace copy-only; Sway and
  other wlroots: spec-11 degraded mode), keeping the honest tone.
- PRD platform paragraph: Wayland upgraded from "degraded" to
  "portal-backed on supported compositors, degraded elsewhere".
- Manual pre-release checklist (extends spec-11's): GNOME 48+ Wayland and
  Plasma 6 Wayland full round-trip (shortcut → capture → replace →
  clipboard restored; permission dialog exactly once across restarts),
  Hyprland shortcut-only pass, Sway degraded-mode regression pass, and a
  token-revocation pass (revoke in system settings → next replace
  re-prompts once).

## Testing Decisions

- All portal interaction sits behind the existing seams (`Keyboard`,
  `AppActivator`, `SelectionBackend`) plus the new capability-probe trait —
  every orchestration decision (which trigger path, which notice, when
  Replace shows, session-creation laziness, token retry-once) is
  unit-tested against fakes, headless, in the existing Linux CI.
- Capability→`PlatformInfo` mapping and the portal-trigger string
  translation (settings shortcut string → portal trigger format) are pure
  functions with direct tests.
- The restore-token lifecycle (store on grant, reuse, clear-and-retry on
  revocation) is tested at the settings/orchestration level with a fake
  portal; real dialogs are manual-checklist only.
- Live portal behavior (dialogs, actual key injection, focus return,
  compositor rebinding) is not headless-testable: it is covered by the
  Slice D manual matrix, exercised by the maintainer before tagging.
- macOS and X11 CI legs must stay green with zero behavior diffs.

## Out of Scope

- libei / `ConnectToEIS` input synthesis (and the `reis` crate) — revisit
  only if the `Notify*` path proves insufficient in practice.
- The InputCapture portal, layer-shell popover positioning, and any
  compositor-specific protocols or hacks (wlr-*, KWin scripting).
- Keymap-aware keycode lookup for non-QWERTY-positioned C/V (documented
  caveat in v1).
- Reading the *focused app's* selection via AT-SPI2 (still out, as in
  spec-11).
- Flatpak packaging — portals bring it closer, but sandboxing the
  clipboard/primary-selection path is its own spec.
- Windows port (spec-13+).

## Further Notes

- Crate choice is decided: `ashpd` only. If an ashpd API gap or a portal
  incompatibility surfaces (e.g. trigger-format quirks per compositor),
  escalate to the orchestrator; do not add crates unilaterally.
- Primary-selection capture on GNOME Wayland deserves an implementation-
  time verification: Mutter implements no data-control protocol (privacy
  stance), so arboard's read there goes through its X11 fallback via the
  XWayland clipboard bridge — it works on default GNOME setups (XWayland
  present), but test a GNOME session explicitly before declaring the
  capture path solid; KDE and wlroots compositors serve data-control
  natively.
- The GlobalShortcuts portal identifies the app by app id; verify the
  identifier Tauri exposes on Wayland (`com.webcommits.kallilex`) is what
  the portal sees, so bindings persist across restarts.
- Slices land as separate coder tasks A → B → C → D with review gates
  between them, one commit per slice, matching the spec-11 workflow. A and
  B are independently shippable; C is where the permission UX must be
  polished before it lands.
- Source of truth for flow contracts remains the `core/capture`,
  `core/replace`, `core/clipboard` doc comments; the Wayland
  implementations must honor the same sequencing (backup lifecycle, settle
  delays, race guards) the fakes pin down — spec-11's seams were built so
  this spec changes no core orchestration.
