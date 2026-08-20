# Spec 11 — Linux port: X11-first cross-platform support with Wayland degraded mode

Status: ready-for-agent
Phase: post-MVP platform expansion (first non-macOS target; Windows follows in
a later spec)
Depends on: spec-01…spec-09 (the complete macOS app). No open dependency on
spec-10 (website SEO) — the website gains its Linux section only after this
ships.

## Problem Statement

From a Linux user's perspective: Kallilex does not exist. The app is
macOS-only — every platform call (Accessibility API, NSPasteboard, CGEvent,
NSSpellChecker, NSRunningApplication, Keychain) lives behind
`#[cfg(target_os = "macos")]` in `src-tauri/src/platform/macos.rs`, the crate
does not even compile on Linux, and CI never tries. The good news the porting
work builds on: all seven platform seams are already traits
(`SelectionBackend`, `Clipboard`, `Keyboard`, `SpellChecker`, `AppActivator`,
`SettingsStore`, `SecretStore`) with platform-independent orchestration tested
against fakes — the port is fundamentally "write `platform/linux.rs` plus
packaging", not a rewrite.

The hard constraint is the display-server split: under X11 everything the app
needs exists (global hotkeys, key synthesis, window activation, selections);
under native Wayland none of it is directly available without
compositor-specific portals. Pretending otherwise would ship a broken app.

## Solution

Linux v1 targets X11 sessions as tier 1 with the full capture → check →
replace-back loop, and defines an honest degraded mode for Wayland sessions
(tray-triggered capture from the primary selection, copy-only results, a
visible notice). The work lands in three slices inside this one spec:
**A) cross-platform restructuring** so the crate builds and tests on Linux and
the frontend stops assuming macOS, **B) the `platform/linux.rs`
implementations** (arboard clipboard with primary selection, enigo key
synthesis, x11rb window activation, spellbook/Hunspell spell check, Secret
Service keys), and **C) packaging & CI** (deb/rpm/AppImage bundles, Linux CI
matrix, docs). Native Wayland support via portals is a declared follow-up
spec, not a stretch goal of this one.

## User Stories

1. As a Linux/X11 user, I want to select text in any app, press my shortcut (default Ctrl+Alt+K), and get the Kallilex popover with my text captured, so that the core flow works exactly as on macOS.
2. As a Linux/X11 user, I want Replace to put the corrected text back into the app I came from and restore my clipboard, so that the round-trip is seamless.
3. As a Linux user, I want offline spell check with suggestions using Hunspell dictionaries, so that the local-first promise holds without Apple APIs.
4. As a Linux user, I want my provider API keys stored in my desktop keyring (GNOME Keyring/KWallet via Secret Service), so that secrets never land in config files.
5. As a Wayland-session user, I want the app to detect my session, tell me plainly what works (tray-triggered capture of my last selection, Copy) and what doesn't (global shortcut, auto replace-back), so that I'm degraded, not deceived.
6. As a GNOME user, I want the README to tell me I need the AppIndicator extension for the tray icon, so that a missing icon doesn't look like a broken app.
7. As a Linux user, I want to install via a `.deb`, `.rpm`, or AppImage from GitHub Releases, so that installation matches my distro's habits.
8. As the maintainer, I want Linux clippy + tests + build in CI on every push, so that the platform can't silently rot.
9. As a macOS user, I want zero behavior change from this spec, so that the port doesn't regress the shipped product.

## Implementation Decisions

### Slice A — cross-platform restructuring (no new features)

- `src-tauri/src/platform/` becomes `mod macos` / `mod linux`, each fully
  `cfg`-gated; a small `platform::current()`-style constructor set returns the
  right implementations so `lib.rs` and `commands.rs` contain no
  `target_os` branching beyond that seam.
- `Cargo.toml`: new `[target.'cfg(target_os = "linux")'.dependencies]`
  section; `keyring` features become per-target (`apple-native` on macOS,
  `sync-secret-service` on Linux). macOS-only crates stay exactly where they
  are.
- macOS-only startup calls (`set_activation_policy(Accessory)`, the
  `x-apple.systempreferences` deep link, `MacosLauncher::LaunchAgent`
  autostart arg, `windowEffects: ["popover"]` vibrancy) are isolated behind
  the platform seam. On Linux: no activation-policy equivalent needed
  (tray-only is achieved by simply not showing windows), autostart uses the
  plugin's XDG `.desktop` mechanism, and the popover window gets no
  `windowEffects`.
- Frontend: a `platform` value exposed once (via existing settings/status
  command or Tauri's OS plugin-free `navigator` check is not enough — pass it
  from Rust) drives (a) shortcut display labels (`Cmd` ↔ `Ctrl`, `⌥⌘K` ↔
  `Ctrl+Alt+K`), (b) the default-shortcut placeholder in Settings, and (c) a
  solid (non-vibrancy) popover background: the popover's CSS must render
  fully opaque on Linux — compositor-less X11 renders transparency as
  garbage. macOS keeps the vibrancy look unchanged.
- `Settings::default()` shortcut becomes platform-dependent: `"Alt+Cmd+K"`
  on macOS, `"Ctrl+Alt+K"` on Linux/other. Stored settings are never
  rewritten — only the default changes.
- The permission concept diverges: Linux has no Accessibility permission.
  `SelectionBackend::permission_granted()` returns `true` on Linux; the
  onboarding path (`accessibility_onboarding_shown`) is skipped, and the
  Settings permission section renders a platform-appropriate block (X11:
  nothing to grant; Wayland: the degraded-mode notice from Slice B).
- `SourceApp` gains an opaque platform window handle
  (`window: Option<PlatformWindowId>`, an `u64`/newtype) captured at
  capture-time; macOS keeps using pid (field stays), Linux activation uses
  the X11 window id. Core structs stay serializable; the handle is not sent
  to the frontend.

### Slice B — `platform/linux.rs` (X11 tier 1, Wayland degraded)

- **Session detection**: `XDG_SESSION_TYPE` / presence of `WAYLAND_DISPLAY`
  decides `x11` vs `wayland` once at startup; exposed to frontend for the
  notice. XWayland use from a Wayland session counts as Wayland (global
  X grabs don't see native-Wayland keystrokes).
- **Clipboard**: `arboard` for both clipboard and primary selection
  (`LinuxClipboardKind::Primary`). Capture path order on Linux: primary
  selection first (selected text lands there automatically — no synthetic
  copy needed), clipboard + synthetic Ctrl+C as fallback. `ClipboardBackup`
  on Linux is text-only (arboard limitation); non-text clipboard contents
  are not restored — documented limitation, mirrored in a code comment at
  the trait impl.
  `change_count`/`wait_for_change` are emulated by polling content hashes at
  the existing 20 ms interval (X11 has no pasteboard counter).
- **Keyboard**: `enigo` (XTest backend) for synthetic Ctrl+C / Ctrl+V, key
  codes layout-independent where enigo supports it. On Wayland sessions the
  `Keyboard` impl returns `Err` immediately — orchestration already treats
  synthesis failure as a handled path.
- **Activation**: `x11rb` sends `_NET_ACTIVE_WINDOW` to the window id stored
  in `SourceApp.window` (captured as the focused window at capture time).
  On Wayland: `activate()` returns `Err`; replace-back is unavailable (see
  degraded mode).
- **Spell check**: `spellbook` crate (pure Rust, Hunspell-compatible).
  Dictionary resolution order: system dirs (`/usr/share/hunspell`,
  `/usr/share/myspell`) → bundled fallback dictionaries shipped as Tauri
  resources (at minimum `en_US` and `de_DE`, licenses permitting —
  SCOWL/LibreOffice dictionaries are redistributable; include their license
  files). Language handling v1: check against all loaded dictionaries and
  flag a word only if no dictionary accepts it; suggestions come from the
  dictionary that yields the best candidates. No auto-orthography detection
  (NSSpellChecker parity is explicitly not required). Offsets: convert to
  UTF-16 code units to match the existing `Misspelling` contract.
- **Secrets**: `KeyringSecretStore` works unchanged via the `keyring` crate's
  Secret Service backend; only the Cargo feature differs. If no Secret
  Service is available (headless/rare), key save fails with the existing
  error path — no plaintext fallback, ever.
- **Tray & popover**: tray icon via Tauri's Linux support (StatusNotifier /
  libayatana-appindicator). Tray-relative positioning is unreliable on
  Linux — the positioner's `TrayBottomCenter` is not used; the popover
  positions at the current cursor position clamped to the work area
  (X11 pointer query), falling back to top-right. Left-click-toggle may not
  be delivered on all trays (SNI is menu-oriented): the tray menu gains an
  explicit "Open Kallilex" first entry so the popover is always reachable;
  left-click toggle stays wired for trays that deliver it.
- **Wayland degraded mode** (explicit, minimal, honest):
  - Global shortcut registration is attempted; when it fails (expected), no
    dialog spam — a one-line notice in the popover and Settings.
  - Trigger path: tray menu "Open Kallilex" → capture reads the primary
    selection only (works on Wayland via arboard) — no synthetic copy, no
    fallback path.
  - Results offer Copy only; the Replace button is hidden when the platform
    reports replace-back unavailable (new capability flag passed to the
    frontend alongside the existing capture payload).
  - Nothing else is attempted (no portals, no libei) — that is spec-12+.

### Slice C — packaging, CI, docs

- CI (`ci.yml`): add `ubuntu-latest` to a matrix alongside `macos-latest` —
  apt deps `libwebkit2gtk-4.1-dev`, `libayatana-appindicator3-dev`,
  `librsvg2-dev`, `build-essential`; run the same steps (pnpm check/test,
  clippy `-D warnings`, cargo test, `pnpm tauri build`).
- Release (`release.yml`): new `ubuntu-latest` job building
  `deb`, `rpm`, and `appimage` bundles via `pnpm tauri build`; artifacts
  named `Kallilex-vX.Y.Z-linux-x86_64.{deb,rpm,AppImage}` and attached (with
  `.sha256` files, matching spec-08's convention) to the same draft release.
  x86_64 only in v1; aarch64-linux deferred.
- `tauri.conf.json`: bundle targets extended accordingly; Linux bundle
  metadata (category, desktop-entry comment) filled in.
- README: new Linux section — supported tier (X11), Wayland degraded-mode
  honesty, GNOME AppIndicator-extension note, install per format,
  dictionary note (system Hunspell dirs are picked up automatically).
- PRD.md: platform-support paragraph updated to reflect macOS + Linux/X11
  tiers (small, factual edit; product scope itself is unchanged).

## Testing Decisions

- All existing fake-based core tests must pass unchanged on both OSes — they
  are the contract that the orchestration didn't fork per platform. New
  platform-neutral behavior (capture order primary-selection-first, the
  replace-capability flag, platform-dependent default shortcut) gets tests at
  the same seams using the existing fakes.
- `spellbook` spell check is headless-testable: unit tests with a bundled
  test dictionary assert misspelling detection, UTF-16 offsets (including a
  non-BMP/umlaut fixture), and suggestion presence — these run in Linux CI.
- Session detection and dictionary-resolution order are pure functions —
  unit-test them with injected env/paths.
- X11 integration (real capture → replace round-trip against gedit/Kate/
  Firefox on GNOME-Xorg and KDE-Xorg; clipboard restored; shortcut
  registers) cannot run in headless CI: it is a documented manual checklist
  executed by the maintainer before tagging, plus a Wayland-session pass
  verifying the degraded mode does exactly what it claims.
- CI on `ubuntu-latest` must be green (clippy, tests, full bundle build)
  before the spec is done; macOS CI must stay green with zero app-behavior
  diffs.

## Out of Scope

- Native Wayland support (GlobalShortcuts portal via ashpd, libei/
  RemoteDesktop input synthesis, xdg-activation focus return) — the next
  platform spec builds on the seams laid here.
- Windows port (UI Automation, SendInput, ISpellChecker, Credential
  Manager) — a later spec; Slice A's restructuring is its prerequisite.
- AT-SPI2 as an additional Linux `SelectionBackend` path.
- Flatpak and Snap packaging (sandboxing conflicts with input synthesis and
  Secret Service; revisit after the Wayland/portal spec).
- Non-text clipboard backup fidelity on Linux.
- NSSpellChecker-parity automatic language detection.
- aarch64-linux builds, a Linux auto-updater, and any repository
  submissions (AUR, Flathub etc.).

## Further Notes

- Slices land as separate coder tasks in order A → B → C with review gates
  between them; A must leave macOS behavior bit-identical (the diff for A is
  moves + gates, reviewable as such). One commit per slice is acceptable in
  place of one-commit-per-spec — the history helps here.
- The `enigo`/`arboard`/`x11rb`/`spellbook` crate choices are decided; if a
  concrete blocker surfaces (e.g. arboard primary-selection gap), escalate
  to the orchestrator rather than swapping crates unilaterally.
- Dictionary licenses must be checked at bundling time (Hunspell dictionaries
  vary: LGPL/MPL/SCOWL); ship only compatible ones with their license texts
  under the resources dir.
- The website's "also on Linux" section and per-OS SEO landing content
  deliberately wait until the first Linux release is published (spec-10 Out
  of Scope already records this).
- Source of truth for the flow contracts: `src-tauri/src/core/capture/mod.rs`,
  `core/replace/mod.rs`, `core/clipboard/mod.rs` doc comments — the Linux
  implementations must honor the same sequencing (backup lifecycle, settle
  delays, race guards) that the fakes already pin down.
