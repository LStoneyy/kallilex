# Spec 15 — Windows port: tray-native capture, replace-back, and an installer

Status: ready-for-agent
Phase: post-MVP platform expansion (third and final desktop target)
Depends on: spec-11 (the cross-platform seam and Slice A restructuring this
port builds on), spec-13 (the `input_synthesis_enabled` / `auto_copy_result`
settings the seam already carries), spec-14 (the truthfulness conventions for
README/website/checklist that this spec extends to a third platform). No
dependency on spec-12 (Wayland portals) beyond the seam functions it added.

## Problem Statement

From a Windows user's perspective, Kallilex does not exist — and unlike the
pre-spec-11 Linux situation, that is now the *only* gap left: macOS is tier 1,
Linux X11 is tier 1, Linux Wayland is portal-backed, and Windows is the one
platform where the crate does not even compile.

Concretely, today:

- `src-tauri/src/platform/mod.rs` has `#[cfg(target_os = "linux")]` and
  `#[cfg(target_os = "macos")]` blocks and nothing else, so on Windows the
  seventeen re-exported seam functions (`app_activator`, `clipboard`,
  `keyboard`, `spell_checker`, `selection_backend`, `platform_info`, `setup`,
  `position_popover`, `tray_icon_bytes`, …) simply do not exist. The crate
  fails to build before it fails to run.
- `Cargo.toml` declares `keyring` only under the macOS and Linux target
  sections, so `core::secrets::KeyringSecretStore` has no backend on Windows.
- `lib.rs::resync_frame_extents` — a GTK client-side-decoration workaround
  from the Linux work — runs unconditionally on every `show_settings`. On
  Windows it would maximise and restore the Settings window on every open:
  a visible, wrong flicker caused by a fix for a toolkit Windows does not use.
- `PlatformInfo.os` is typed `"macos" | "linux"` in `src/shared/types.ts`, and
  the popover's opaque-surface CSS override is keyed on `html.platform-linux`
  only.
- CI builds macOS and Ubuntu; `release.yml` ships `.app`, `.deb`, `.rpm` and
  `.AppImage`; README, PRD, website and the release checklist all describe a
  two-platform product and explicitly list the Windows build as unbuilt.

The good news is the same as it was for Linux, and stronger: every platform
capability is already a trait behind a seam that two implementations have
exercised (`SelectionBackend`, `Clipboard`, `Keyboard`, `SpellChecker`,
`AppActivator`, `SettingsStore`, `SecretStore`), the orchestration in
`core::capture` / `core::replace` is platform-neutral and pinned by fakes, and
`SourceApp` already carries the opaque `window: Option<PlatformWindowId>`
handle that a Windows `HWND` needs. This is "write `platform/windows/` plus
packaging", not a rewrite — and the seam surface is already the exact contract
to implement against.

Windows also brings genuinely new hazards that neither existing platform has,
and which the port must handle rather than discover in the field:

1. **Modifier hygiene.** The default Windows shortcut is `Ctrl+Alt+K`. When
   the handler fires, the user is physically still holding Ctrl **and Alt** —
   and on Windows `Ctrl+Alt` is AltGr. Synthesising Ctrl+C on top of a held
   Alt does not reliably produce a copy; in many apps it produces nothing or a
   different command. macOS (⌥⌘K → ⌘C) and X11 tolerate this; Windows does
   not.
2. **Foreground-window rules.** `SetForegroundWindow` only succeeds for a
   process that currently owns the foreground (or has just received a
   registered hotkey). Replace-back must therefore order its steps so that
   Kallilex still holds foreground rights when it hands them back.
3. **UIPI.** Synthetic input cannot reach windows of a process running at a
   higher integrity level. Capture-from and replace-into an elevated app is
   impossible without a UIAccess manifest, and must fail honestly instead of
   silently doing nothing.
4. **UI Automation reach.** `TextPattern` is not implemented by every app
   (several Electron and custom-toolkit apps expose nothing usable), so the
   clipboard + synthetic-Ctrl+C fallback carries much more traffic on Windows
   than the Accessibility path does on macOS.

## Solution

Add Windows as a tier-1 platform with the full capture → check → replace-back
loop, using native APIs at every seam: **UI Automation** (`IUIAutomation` +
`TextPattern`) for instant selection reading, **SendInput** for synthetic
Ctrl+C/Ctrl+V, **`SetForegroundWindow`** on the remembered `HWND` for
replace-back activation, the **Windows Spell Checking API**
(`ISpellCheckerFactory`/`ISpellChecker`) for offline spell check with
suggestions, and **Credential Manager** (via `keyring`'s `windows-native`
feature) for API keys. There is no degraded tier: Windows has no
display-server split, so the only honest limitations to document are elevated
windows (UIPI) and apps that expose no `TextPattern` (covered by the existing
fallback).

The work lands in four slices inside this one spec:

- **A) cross-platform restructuring** — the crate builds, tests, and *runs* on
  Windows with a tray icon, popover, Settings, global shortcut, and
  clipboard-fallback capture; the frontend stops assuming two platforms; the
  GTK workaround gets gated. No native capture, replace, or spell check yet.
- **B) native capture & replace-back** — UI Automation selection reading,
  foreground-window identity, SendInput with modifier hygiene,
  `SetForegroundWindow` activation.
- **C) native spell check** — the Windows Spell Checking API behind the
  existing `SpellChecker` seam, with the same UTF-16 offset contract.
- **D) packaging, CI, docs** — NSIS installer, `windows-latest` in CI and in
  the release workflow, README/PRD/website/release-checklist updated to a
  three-platform product.

**Hard constraint, applying to every slice: macOS and Linux behavior must not
change.** Every seam addition is a new `#[cfg(target_os = "windows")]` branch
or a new file; the only edits to shared code are (a) adding a third arm where
two exist, (b) gating `resync_frame_extents` behind the seam, and (c) the pure
extraction of the popover-clamping helper described in Slice A. macOS and
Linux CI staying green — clippy, tests, and full bundle build — is an
acceptance criterion of each slice, not just the last one.

## User Stories

1. As a Windows user, I want to select text in any app, press `Ctrl+Alt+K`,
   and get the Kallilex popover with my text already captured, so that the
   core flow works exactly as it does on macOS and Linux.
2. As a Windows user, I want Replace to put the corrected text back into the
   app I came from and restore my clipboard afterwards, so that the round trip
   is seamless.
3. As a Windows user, I want offline spell check with suggestions in my
   installed Windows display languages, so that the local-first promise holds
   without Apple APIs or bundled dictionaries.
4. As a Windows user, I want my provider API keys stored in Windows Credential
   Manager, so that secrets never land in a config file.
5. As a Windows user, I want Kallilex to live in the notification area and
   never in the taskbar or Alt-Tab, so that it behaves like the menu-bar
   utility it is on macOS.
6. As a Windows user, I want a single installer (`.exe`) from GitHub Releases
   that installs per-user without admin rights, so that I can install it on a
   managed machine.
7. As a Windows user, I want the README and the website to tell me plainly
   that the download is unsigned and how to get past SmartScreen, so that a
   scary dialog is not my first impression.
8. As a Windows user working in an app that exposes no accessible text, I want
   capture to fall back to a synthetic copy rather than silently return
   nothing, so that Kallilex still works there.
9. As a Windows user, I want capture and Replace against an app running as
   administrator to fail with a clear message rather than do nothing, so that
   I know it is a Windows restriction and not a bug.
10. As the maintainer, I want Windows clippy + tests + build in CI on every
    push, so that the third platform cannot silently rot.
11. As a macOS or Linux user, I want zero behavior change from this spec, so
    that the port does not regress the shipped product.

## Implementation Decisions

### Slice A — cross-platform restructuring (builds and runs, no native features)

- **`platform/windows/` module**, structured like `platform/linux/`:
  `mod.rs` (seam surface + `platform_info`), `clipboard.rs`, `keyboard.rs`,
  `selection.rs`, `activation.rs`, `spellcheck.rs`. `platform/mod.rs` gains a
  third `#[cfg(target_os = "windows")] mod windows;` plus the matching
  `pub use windows::{…}` block listing the *same* seventeen names, in the same
  order, as the two existing blocks.
- **Seam answers for Windows** (final values, not placeholders):
  - `setup(app)` — no-op. Tray-only is achieved by `skipTaskbar: true` on both
    windows (already in `tauri.conf.json`) plus never showing a taskbar
    window; Windows has no activation-policy equivalent.
  - `open_permission_settings()` — `Ok(())`, no-op: Windows has no grantable
    capture permission to deep-link into.
  - `platform_info()` — `os: "windows"`, `session: None`,
    `replace_back_available: true`, `permission_required: false`,
    `default_shortcut: default_shortcut()` (already `"Ctrl+Alt+K"` via the
    non-macOS branch — do **not** touch `core::settings::default_shortcut`),
    `wayland: None`.
  - `set_input_synthesis_enabled(_)` — no-op, like macOS: SendInput needs no
    grant, so there is nothing for the spec-13 opt-out to gate. The setting
    stays persisted and unread.
  - `wants_tray_open_entry()` — `false`. The Windows notification area
    delivers left-click reliably and `show_menu_on_left_click(false)` already
    gives the conventional left-opens / right-menus behavior. (If the Slice D
    manual matrix shows click delivery problems in the overflow flyout,
    flipping this to `true` is a one-line follow-up — do not pre-empt it.)
  - `tray_open_captures()` — `false`: the synthetic-copy fallback exists here.
  - `global_shortcut_failure_expected()` — `false`: `RegisterHotKey` failure
    is a real, reportable error (usually a conflicting registration), and the
    existing dialog is the right response.
  - `use_portal_global_shortcut()` — `false`; `spawn_portal_shortcut(…)` — an
    empty body with the macOS module's "never actually called" doc comment.
  - `tray_icon_as_template()` — `false` (no template-image concept).
  - `tray_icon_bytes()` — a new `src-tauri/icons/tray-windows@2x.png`: the
    same verdigris (#2faf9b) K glyph as the Linux tray icon, 32×32, which the
    notification area scales to 16 px logical and which stays legible on both
    the light and dark taskbar. Commit it as its own artwork file rather than
    `include_bytes!`-ing the Linux raster across module boundaries.
- **`clipboard()`** — `arboard` (already a vetted dependency; move it from the
  Linux-only target section into a shared one, or declare it a second time
  under the Windows target with `default-features = false` and no Linux
  features — whichever keeps the Linux feature set *byte-identical*).
  `read_text`/`write_text`/`backup`/`restore` mirror the Linux text-only
  implementation, including its documented limitation. `change_count()` is the
  one place Windows does better than Linux: use the real
  `GetClipboardSequenceNumber()` instead of a content hash, so identical
  consecutive copies are distinguishable; `wait_for_change` keeps the same
  20 ms poll loop and timeout contract. Document that a clipboard locked by
  another process degrades to the trait's existing best-effort contract
  (`write_text` swallows errors) rather than surfacing an error.
- **`keyboard()`** and **`selection_backend()`** and **`app_activator()`** get
  their real files in Slice B. For Slice A they are honest stubs: `Keyboard`
  returns `Err("not yet implemented on Windows")`, `SelectionBackend` returns
  `permission_granted() = true` (final answer), `frontmost_app() = None`,
  `ax_selected_text() = None`, `AppActivator::activate` returns `Err`. This is
  the same staging spec-11 Slice A used, and it leaves a working app: capture
  falls back to the clipboard path, Replace stays hidden.
  **Exception:** if the coder can land the SendInput keyboard cheaply within
  Slice A's review budget, it belongs in Slice B anyway — do not blur the
  slices.
- **`spell_checker()`** — Slice A stub returning
  `SpellcheckError::Backend("spell check is not yet available on Windows")`;
  real implementation in Slice C. Verify the popover surfaces this as a
  handled spellcheck error and not as a crash or an empty result claiming
  "no misspellings".
- **`Cargo.toml`** — new `[target.'cfg(target_os = "windows")'.dependencies]`
  section: `keyring = { version = "3", features = ["windows-native"] }`, the
  `windows` crate (current release at implementation time; pin the minor
  version) with only the feature modules actually used — Slice A needs
  `Win32_System_DataExchange` for `GetClipboardSequenceNumber` and
  `Win32_Foundation`; Slices B and C add `Win32_UI_Accessibility`,
  `Win32_UI_Input_KeyboardAndMouse`, `Win32_UI_WindowsAndMessaging`,
  `Win32_System_Com`, `Win32_System_Threading`, `Win32_Globalization`. macOS
  and Linux dependency sections stay untouched.
- **`core::secrets`** — no code change beyond the module/`KeyringSecretStore`
  doc comments, which currently say "macOS Keychain"; make them name all
  three backends (Keychain / Secret Service / Credential Manager). The
  `SERVICE` constant and the `provider:{id}` key layout stay as they are.
- **`lib.rs::resync_frame_extents` gating** — this is the one shared-code
  behavior change in the slice, and it must be exactly neutral on Linux and
  macOS. Add a seam function (`platform::needs_frame_extents_resync() -> bool`
  — `true` on Linux, `false` on macOS and Windows) and make `show_settings`
  call the workaround only when it returns `true`. Keep the whole explanatory
  doc comment; it documents a GTK defect, and moving it must not lose the
  "if a future GTK/tao release fixes this, delete the function" note. Do not
  restructure `show_settings` beyond adding the guard.
- **Popover positioning** — `position_popover` on Windows anchors the popover
  at the cursor and clamps it into the current monitor's **work area** (which
  excludes the taskbar), falling back to the work area's **bottom-right**
  corner (nearest the notification area) when the cursor position is
  unreadable. The Linux implementation already does exactly this with a
  top-right fallback, so extract its body into a shared, pure helper
  (`platform/positioning.rs` or equivalent) parameterised by the fallback
  corner, and have both platforms call it. **Linux behavior must come out
  bit-identical**; the extraction is a move, and the new pure clamp function
  gets unit tests with injected monitor/work-area/window sizes.
  `tauri_plugin_positioner`'s tray-relative positions are deliberately not
  used on Windows: the taskbar can live on any edge and be auto-hidden, and
  the cursor is always where the user just triggered from.
- **Frontend** — `PlatformInfo.os` becomes `"macos" | "linux" | "windows"` in
  `src/shared/types.ts`; the popover's opaque-surface rule extends to
  `:global(html.platform-windows) .popover` (WebView2 renders the transparent
  surface, but the vibrancy look it was designed for is macOS-only, so Windows
  gets the same solid `--color-basalt` treatment Linux gets — adjust the
  comment, which currently explains only the X11 reason). `applyPlatformClass`
  needs no change. Verify no other string literal narrows the platform set:
  the Settings "Accessibility permission" tab already branches on
  `permissionRequired` and its Wayland sub-block on `session === "wayland"`,
  both of which resolve correctly for Windows without edits — confirm this in
  review rather than assuming it.
- **`tauri.windows.conf.json`** — a new platform overlay, mirroring
  `tauri.linux.conf.json`, created in this slice with the bundle settings
  Slice D needs. Also verify at first run whether the popover's
  `windowEffects: { effects: ["popover"] }` (a macOS-only effect) is tolerated
  or rejected by Tauri on Windows. If it is rejected, move `windowEffects`
  **and** `macOSPrivateApi` into a new `tauri.macos.conf.json` overlay so the
  macOS window configuration stays byte-identical while the base config stops
  carrying a macOS-only key.
- **Acceptance for Slice A:** on Windows, `cargo clippy --all-targets -D
  warnings` and `cargo test` pass, `pnpm tauri build` produces a bundle, and
  the built app launches with a tray icon, an openable popover that captures
  via the clipboard fallback after a manual Ctrl+C, a working Settings window
  with no maximise/restore flicker, a registered `Ctrl+Alt+K`, and API keys
  that round-trip through Credential Manager. macOS and Linux CI green.

### Slice B — native capture & replace-back

- **Selection reading (`selection.rs`)** — UI Automation:
  `CoInitializeEx(COINIT_MULTITHREADED)` on a dedicated worker thread, create
  the `CUIAutomation` object (`IUIAutomation`), `GetFocusedElement()`,
  `GetCurrentPattern(UIA_TextPatternId)` → `IUIAutomationTextPattern`,
  `GetSelection()`, take the first range, `GetText(-1)`. Empty or absent at any
  step → `None`, which is exactly what makes `core::capture` fall through to
  the clipboard + synthetic Ctrl+C path. `TextPattern` only — no
  `ValuePattern` or legacy `IAccessible` fallback in this spec (Out of Scope).
- **Bounded wait.** UIA calls cross process boundaries and can block
  indefinitely on an unresponsive target. Run the UIA work on the worker
  thread and bound it from the caller with an `mpsc::recv_timeout` — the same
  shape `MacosSpellChecker::check` and `MacosAppActivator::activate` already
  use, but marshalling *off* the UI thread rather than onto it. Budget
  ~400 ms: long enough for a healthy app, short enough that the fallback path
  still feels instant. A timeout is `None`, not an error.
- **Frontmost app identity** — `GetForegroundWindow()` gives the `HWND`, stored
  as `SourceApp.window = Some(PlatformWindowId(hwnd as u64))` (this is what
  replace-back actually needs); `GetWindowThreadProcessId` gives the pid;
  `name` comes from the process image file stem via `QueryFullProcessImageNameW`
  (falling back to the window title via `GetWindowTextW`); `bundle_id` is
  `None`. A missing pid or name is not fatal — a bare `HWND` is still a usable
  `SourceApp`, exactly as the X11 implementation documents.
- **Capture order stays unchanged**: instant path first (UIA), clipboard +
  synthetic Ctrl+C as fallback. Do not reorder for Windows even though the
  fallback carries more traffic here — the ordering is core behavior pinned by
  fakes, and swapping it would churn the clipboard on every capture.
- **Key synthesis (`keyboard.rs`)** — `SendInput` with virtual-key codes:
  `VK_CONTROL` down, `VK_C`/`VK_V` down, up, `VK_CONTROL` up. Virtual keys, not
  scan codes: applications interpret `WM_KEYDOWN` by virtual key, so this is
  layout-independent in the way that matters. Once the Ctrl press has been
  sent, the Ctrl release is always attempted regardless of whether the letter
  press succeeded, so a failure can never leave Ctrl logically stuck — mirror
  the Linux implementation's explicit comment on this.
- **Modifier hygiene (the Windows-specific hazard).** Before synthesising,
  query `GetAsyncKeyState` for `VK_MENU`, `VK_SHIFT`, `VK_LWIN`, `VK_RWIN` and
  send a key-up for each that is physically held; synthesise the chord; then
  restore the held state by sending key-downs again only for those that are
  *still* physically held at that point. Rationale, and this belongs in a code
  comment: the default shortcut is `Ctrl+Alt+K`, so Alt is almost always still
  down when the handler runs, and `Ctrl+Alt` is AltGr on Windows — an
  un-cleaned Ctrl+C is not a copy. Add a short settle delay (~20 ms) after the
  clean-up before the chord, so the target app has processed the modifier
  releases.
- **Activation (`activation.rs`)** — `AppActivator::activate` marshals onto the
  main thread (the message-loop thread) with an `mpsc::recv_timeout`, the same
  shape as `MacosAppActivator`, and there:
  1. Rejects a missing `SourceApp.window` (`Err`, "no window handle recorded
     for the source application") and a dead one (`IsWindow` false → `Err`,
     "the source application is no longer running").
  2. Hides the popover window first — Windows hands foreground rights to the
     next window more reliably when the current foreground window gives them
     up, and the popover is the current foreground window at this point. Use
     plain `window.hide()`, not the crate's `hide_popover` helper, for exactly
     the reason `platform/linux/activation.rs` documents: replace-back owns its
     own state cleanup.
  3. Calls `SetForegroundWindow(hwnd)`, plus `ShowWindow(hwnd, SW_RESTORE)`
     first if the target is minimised (`IsIconic`).
  4. On failure, applies the documented `AttachThreadInput` fallback (attach to
     the target window's thread input queue, retry `SetForegroundWindow`,
     detach) and only then reports `Err`.
  `core::replace`'s existing `FOCUS_SETTLE_DELAY` covers the latency before the
  synthetic Ctrl+V — do not add a second delay in the activator.
- **UIPI, documented honestly.** When the target runs at a higher integrity
  level, `GetFocusedElement` returns nothing usable *and* `SendInput` is
  dropped by the OS. The result is a capture that finds no text and a Replace
  that reports failure. Both already route through existing user-visible
  paths (`CaptureFailureReason::NoSelection`; the replace error dialog) — the
  work here is a precise code comment plus a README line, not new UI.
- **Acceptance for Slice B:** a real round trip in Notepad, WordPad/Word, Edge,
  Chrome, VS Code and Windows Terminal — select, `Ctrl+Alt+K`, popover shows
  the text, Replace writes it back, and the original clipboard contents are
  restored afterwards. Where `TextPattern` is absent, the fallback still
  produces the text.

### Slice C — native spell check

- **`spellcheck.rs`** uses the Windows Spell Checking API (Windows 8+):
  `SpellCheckerFactory` → `ISpellCheckerFactory::IsSupported(tag)` →
  `CreateSpellChecker(tag)` → `ISpellChecker::Check(text)` →
  `IEnumSpellingError` → `ISpellingError::{StartIndex, Length,
  CorrectiveAction}`, and `ISpellChecker::Suggest(word)` → `IEnumString`.
- **The offset contract lines up exactly**: `ISpellingError` reports UTF-16
  code-unit offsets, which is precisely what `core::spellcheck::Misspelling`
  documents (`start`/`length` are UTF-16 units, so the frontend can `.slice()`
  them directly). No re-indexing, no `unicode-segmentation` tokenizer, no
  bundled dictionaries — this is the reason to prefer the native API over
  reusing `spellbook`.
- **`Check`, not `ComprehensiveCheck`**: spelling only. Filter results by
  `CorrectiveAction` — `GetSuggestions` and `Replace` are misspellings,
  `CORRECTIVE_ACTION_NONE` is not. Grammar/style stays out (PRD scope).
- **Language selection** mirrors the Linux multi-dictionary rule: build the
  candidate list from `GetUserPreferredUILanguages` (falling back to
  `GetUserDefaultLocaleName`), keep those where `IsSupported` is true, and
  create one `ISpellChecker` per surviving tag, lazily on first use
  (`OnceLock`). A word counts as correct if **any** checker accepts it;
  suggestions come from the first checker that returns a non-empty list. This
  is the same "any dictionary accepts it" semantics `LinuxSpellChecker` uses,
  so multilingual users get the same forgiving behavior on all three
  platforms. Keep the candidate-filtering step a **pure function** over an
  injected supported-tags list so it is unit-testable without COM.
- **Threading.** The spell checker objects are apartment-affine. Own them on a
  dedicated long-lived worker thread that initialises COM once and serves
  check requests over a channel, with the caller bounded by
  `recv_timeout` (reuse the 5 s `SPELLCHECK_TIMEOUT` value macOS uses, with
  the same "only fires if the worker is wedged" comment).
- **No supported language** (e.g. an installed language with no spell-check
  feature) → `SpellcheckError::Backend` with a message that names the actual
  situation ("no Windows spell-checking language is installed for your display
  languages") rather than a generic failure. Confirm the popover renders it as
  an error, not as "no misspellings found".
- **Rejected alternative, recorded:** reusing `spellbook` plus the bundled
  `en_US`/`de_DE` dictionaries. It would work and would be less code, but it
  ships ~10 MB of dictionaries Windows already has, ignores the user's actual
  installed languages, and duplicates a solved problem. If `ISpellChecker`
  turns out to be unusable in practice, **escalate to the orchestrator**
  rather than swapping unilaterally (spec-11's crate-choice rule).

### Slice D — packaging, CI, docs

- **`tauri.windows.conf.json`**: `bundle.targets: ["nsis"]`; NSIS
  `installMode: "perUser"` (no admin rights, installs into the user profile —
  the right default for a tray utility on a managed machine);
  `webviewInstallMode: { type: "downloadBootstrapper" }`; publisher and
  short/long description filled in to match the Linux overlay's wording. No
  `resources` entry (Slice C ships no dictionaries). `icons/icon.ico` is
  already referenced by the base config.
  **MSI/WiX is deliberately not built** — one installer, per-user, is the
  whole story for v1.
- **CI (`ci.yml`)**: add `windows-latest` to the existing matrix. It needs no
  extra system dependencies (WebView2 and the MSVC toolchain are present on
  the runner); the Linux apt step is already `if`-gated. Every step runs
  unchanged: `pnpm check`, `pnpm test`, clippy `-D warnings`, `cargo test`,
  `pnpm tauri build`. Keep `fail-fast: false`.
- **Release (`release.yml`)**: a new `build-release-windows` job
  (`runs-on: windows-latest`, `needs: build-release` so it uploads into the
  existing draft), building with `pnpm tauri build` and attaching
  `Kallilex-vX.Y.Z-windows-x86_64-setup.exe` plus a matching `.sha256` file.
  Generate the checksum with PowerShell `Get-FileHash` but write it in
  `sha256sum` format (lowercase hash, two spaces, filename) so all three
  platforms' checksum files verify the same way — this is a stated convention
  from spec-08 and must not fork per platform. x86_64 only.
- **README**: a `## Windows` section parallel to `## Linux` — supported
  versions (Windows 10 21H2+ and Windows 11, x86_64), install from the
  installer, the SmartScreen note (unsigned binary: "More info" → "Run
  anyway", stated as plainly as the existing macOS Gatekeeper note), spell
  check via the built-in Windows Spell Checking API using installed display
  languages, keys in Credential Manager, and the two honest limitations
  (elevated windows; apps exposing no accessible text falling back to a
  synthetic copy). Also update the two places that currently describe Windows
  as unbuilt: line ~150 ("A future Windows build plugs into the same seam")
  and the `## Later` list entry `- Windows build;` (remove it — with this spec
  there is no unbuilt platform left in that list). The `## Installation (macOS)`
  heading and the Linux section stay factually untouched.
- **PRD.md**: the platform-support sentence in the constraints section
  currently ends "…; Windows remains unsupported (planned)." — replace with
  the shipped reality (Windows tier 1, notification-area, full capture/replace
  loop). Also drop "Windows builds" from the `Later` list at line ~260. Small,
  factual edits; product scope is unchanged.
- **Website** (extending spec-14 Slice B's conventions, same files and same
  JSON-LD structure): `operatingSystem` becomes `"macOS, Linux, Windows"`;
  title/description/OG/Twitter strings gain Windows; the download button's
  platform detection (`data-download-label`, `main.js`) learns Windows and
  points at the installer asset; the requirements note gains
  `Windows · x86_64 (.exe)`; the two FAQ answers about the Accessibility
  permission and about offline spell check gain their Windows sentences (no
  permission to grant; Windows Spell Checking API); the keychain paragraph
  gains Credential Manager; the "menu bar / tray" phrasings gain
  "notification area". `sitemap.xml` needs no new URL.
- **`docs/release-checklist.md`**: a new "Windows manual matrix" section
  parallel to the macOS one — Notepad, Word, Outlook, Edge, Chrome, VS Code,
  Windows Terminal, Slack, each with capture / spell check / Replace /
  clipboard-restored boxes; plus a password-field row (same expectation as
  macOS: graceful failure, no crash, no secret left on the clipboard); plus
  Windows-specific rows: an **elevated** app (e.g. Registry Editor run as
  admin) fails clearly rather than silently; the tray icon is legible on both
  the light and dark taskbar; the installer installs per-user without an admin
  prompt and the app starts from the Start menu; the autostart toggle in
  Settings survives a reboot. Extend the existing "Platform accuracy check"
  gate from "*both* platforms" to all three.
- **Version bump** to `0.4.0` in `package.json`, `src-tauri/Cargo.toml`,
  `src-tauri/tauri.conf.json` (and `Cargo.lock` via a build), following
  spec-14 Slice D's precedent of bumping in the readiness slice — a new
  supported platform is a minor bump.

## Testing Decisions

- **The fake-based core tests are the contract that the orchestration did not
  fork.** Every existing test in `core::capture`, `core::replace`,
  `core::clipboard`, `core::providers`, `core::settings` and `core::spellcheck`
  must pass unchanged on `windows-latest`. If one needs a `cfg` to compile,
  that is a signal the port leaked into core — escalate rather than gate the
  test.
- **New pure functions get unit tests, and only pure functions can:** the
  extracted popover clamp helper (injected monitor/work-area/window
  geometry, both fallback corners), the spell-check language-candidate filter
  (injected supported-tags list), and the process-name derivation from an
  image path.
- **`platform_info()` for Windows** gets the same style of assertion the Linux
  `platform_info_for` tests use: `os == "windows"`, `session.is_none()`,
  `replace_back_available`, `!permission_required`, `wayland.is_none()`.
- **Frontend tests** (`src/popover/App.test.ts`, `src/settings/App.test.ts`):
  add a `os: "windows"` platform-info case asserting that Replace is offered,
  no Wayland notice renders, the Settings permission tab shows the
  "no system permission is needed" branch without the Wayland sub-block, and
  the shortcut placeholder shows the backend-provided `Ctrl+Alt+K`. Existing
  macOS/Linux cases must not be edited.
- **UIA, SendInput, `SetForegroundWindow` and COM spell check are not
  headlessly testable** — they need a real desktop session with real apps.
  They are covered by the Slice D manual matrix, executed by the maintainer
  before tagging, exactly as the X11 and Wayland round trips are.
- **CI gate:** `windows-latest` must be green (clippy `-D warnings`, cargo
  test, full `pnpm tauri build`) before the spec is done, and macOS and Ubuntu
  must stay green with zero app-behavior diffs. A behavior diff on either
  existing platform is a blocking finding, not a note.

## Out of Scope

- ARM64 Windows builds (`aarch64-pc-windows-msvc`) — x86_64 only in v1.
- Code signing (Authenticode/EV certificate), and therefore SmartScreen
  reputation. Unsigned + a documented click-through, matching the current
  ad-hoc-signed macOS story.
- MSI/WiX bundles, winget manifests, Microsoft Store submission, Chocolatey —
  and any auto-updater on any platform.
- Multi-format clipboard backup on Windows (`EnumClipboardFormats` over
  HGLOBAL formats). Text-only, matching Linux, with the same documented
  limitation.
- UI Automation fallbacks beyond `TextPattern` (`ValuePattern`, legacy
  `IAccessible`/MSAA, `WM_GETTEXT` probing).
- Elevated-window support via a UIAccess manifest (requires a signed binary in
  a protected path — blocked on code signing anyway).
- `ComprehensiveCheck` grammar/style checking, and NSSpellChecker-parity
  automatic language detection.
- Windows 11 Mica/Acrylic window effects for the popover — Windows gets the
  same solid surface Linux gets.
- Jump lists, toast notifications, taskbar integration, and any Windows-only
  UI surface. The product is the same three windows on every platform.
- Changes to macOS or Linux behavior of any kind.

## Further Notes

- **Slices land as separate coder tasks in order A → B → C → D with review
  gates between them.** One commit per slice is acceptable in place of one
  commit per spec — as with spec-11, the history helps here. Slice A's diff
  should read as "new module + three-arm gates + one guarded workaround + one
  pure extraction"; anything else in it is scope creep.
- **Development-machine prerequisites** (the maintainer's Windows machine
  currently has none of the Rust half): `rustup` with the
  `x86_64-pc-windows-msvc` toolchain, Visual Studio Build Tools 2022 with the
  "Desktop development with C++" workload (MSVC + Windows SDK), and pnpm via
  `corepack enable`. Node 24 and the WebView2 runtime (151.x) are already
  present, so no WebView2 install step is needed for development. `pnpm tauri
  dev` is the fast loop; the NSIS bundle only needs to be exercised once per
  slice-D iteration.
- **The `windows` crate is decided**, as `enigo`/`arboard`/`x11rb`/`spellbook`
  were for Linux: direct windows-rs bindings rather than a wrapper crate, with
  feature modules enabled one slice at a time so the dependency surface stays
  auditable. If a concrete blocker surfaces (a UIA binding gap, a
  `SendInput` behavior that cannot be made reliable), escalate to the
  orchestrator instead of swapping crates.
- **Source of truth for the flow contracts** is unchanged:
  `src-tauri/src/core/capture/mod.rs`, `core/replace/mod.rs`,
  `core/clipboard/mod.rs` doc comments. The Windows implementations must honor
  the same sequencing (backup lifecycle, settle delays, race guards) the fakes
  already pin down — in particular `ReplaceInFlight` and
  `BackupLifecycle::take_pending`, which the hide-then-activate ordering in
  Slice B interacts with directly.
- **The seam is the deliverable as much as the port is.** After this spec,
  `platform/mod.rs` carries three identical `pub use` blocks; if a fourth
  platform ever appears, nothing outside `platform/` should have to change.
  A finding that Windows code leaked into `lib.rs`, `commands.rs` or `core/`
  is blocking.
