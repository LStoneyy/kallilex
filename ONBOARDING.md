# First-Run Onboarding

Kallilex currently has no real onboarding: on macOS, the first launch (when the
Accessibility permission is missing) opens the Settings window once
(`src-tauri/src/lib.rs:424–444`, flag `accessibility_onboarding_shown`) — and
lands on the General tab, not Accessibility. Windows and Linux have no
first-run experience at all. New users never learn what the app does, which
shortcut it uses, or that AI actions need a provider profile (spell check works
with zero configuration).

Goal: a dedicated onboarding window on first launch — on all platforms, with
platform-conditional steps, a full (skippable) provider setup, a Wayland
paste-back choice, and an autostart opt-in. Existing users who are recognizably
set up never see it.

**Decided:** full provider step · all platforms · existing users skip ·
autostart opt-in on the finish page · Wayland users choose whether to use
automatic paste-back (RemoteDesktop portal) during onboarding.

## User flow

The step list derives from `platformInfo` (loads async; "Get started" on step 1
is disabled until it resolves, so the step list never changes mid-wizard):

- **macOS:** Welcome → Permission → Provider → Finish
- **Windows:** Welcome → Windows spell-check note → Provider → Finish
- **Linux Wayland:** Welcome → Paste-back choice → Provider → Finish
- **Linux X11:** Welcome → Provider → Finish

All UI copy in English, "Attic Oxide" visual identity (dark-first,
`src/shared/tokens.css`, `docs/visual-identity.md`).

1. **Welcome** — "Welcome to Kallilex": explains the core loop (select text in
   any app → `{defaultShortcut}` → popover with spell check + AI actions →
   Replace writes it back). Button "Get started".
2. **Permission (macOS only,** `platformInfo.permissionRequired`**)** — why
   Accessibility is needed; live Granted/Not granted status pill (1 s poll via
   `accessibilityStatus()`, same pattern as `src/settings/App.svelte`); "Open
   System Settings" button (`openAccessibilitySettings()`); restart hint.
   "Continue" is never blocked (hint: spell check inside the popover works
   without capture).
   - *Windows variant:* note that the native Windows spell checker needs
     "Basic typing" installed for the user's language (Settings → Time &
     Language).
   - *Wayland variant — paste-back choice:* explains that Replace can paste
     the result back into the source app via the RemoteDesktop portal (the
     desktop asks for confirmation on the first Replace), and that the global
     shortcut may also need a one-time portal confirmation. Toggle **"Use
     automatic paste-back"**, initialized from the persisted
     `inputSynthesisEnabled` (default on). Turning it off means Replace copies
     the result to the clipboard for manual pasting — the user decides here
     whether the RemoteDesktop portal is used at all. If the compositor does
     not support input synthesis (`!platformInfo.wayland?.inputSynthesis`),
     show the "not available on this desktop" note instead of the toggle.
3. **Provider (skippable)** — "Spell check works out of the box. AI actions
   need a provider." Three sub-views mirroring the Settings window
   (`pick` → `form` → `saved`): preset picker from `getPresets()` (Ollama /
   LM Studio / OpenAI / Custom), form with Name / Base URL / Model / API key
   (password input, hint "Stored in your system keychain"), Save via
   `saveProfile(profile, apiKey)` — the first saved profile automatically
   becomes active (`save_profile_core`). Then optional "Test connection"
   (`testConnection(id)` → "OK · {n} ms" / error text, never blocks). Footer:
   "Skip for now", replaced by "Continue" once a profile is saved.
4. **Finish** — "You're all set": autostart toggle (default off,
   `enableAutostart()`/`disableAutostart()`, errors inline, never blocks) +
   "Try it now: select some text and press `{defaultShortcut}`". Button
   "Done" → `completeOnboarding()`.

**Lifecycle:** the window is created at runtime (not statically declared),
one-shot. Closing without finishing (X) → flag stays unset → onboarding shows
again on the next launch (the wizard is skippable in ~3 clicks, so this is not
a nag problem). "Done" → flag persisted, window destroyed (not a hide-shell
like the Settings window). No "re-run onboarding" affordance in v1 — Settings
covers everything after the fact.

## Gating & migration

New field `onboarding_completed: bool` with `#[serde(default)]` (convention:
doc comment + backward-compat deserialization test, like `auto_copy_result`).

New testable module `src-tauri/src/core/onboarding.rs`:

```rust
pub enum OnboardingDisposition { Show, AlreadyCompleted, AutoCompleted }
pub fn evaluate_onboarding(store: &dyn SettingsStore) -> Result<OnboardingDisposition, SettingsError>
pub fn complete_onboarding_core(store: &dyn SettingsStore) -> Result<(), SettingsError>
pub fn set_input_synthesis_core(store: &dyn SettingsStore, enabled: bool) -> Result<(), SettingsError>
```

- `onboarding_completed == true` → `AlreadyCompleted` (no write).
- Else if `accessibility_onboarding_shown == true || !profiles.is_empty()` →
  persist `onboarding_completed = true` once, return `AutoCompleted`
  (existing-user migration).
- Else → `Show`, persist nothing.

`accessibility_onboarding_shown` becomes legacy: it stays in the struct (it is
the migration signal), is never written anymore; its doc comment is updated
accordingly. The old first-run block in `lib.rs` is replaced by the new gate.

**Deliberately accepted:** Windows/Linux existing users without a provider
profile are not recognizable as "set up" (the legacy flag was never written on
those platforms) and will see the onboarding exactly once after updating.
Acceptable — they never had a first-run experience, and no more reliable
signal exists.

All onboarding writes happen Rust-side as load-mutate-save
(`complete_onboarding_core`, `set_input_synthesis_core`, `save_profile_core`);
the onboarding frontend never calls `setSettings` → no clobber risk against
the (hidden but live) Settings window.

## Work items

### 1. Backend: settings field + migration core

- `src-tauri/src/core/settings/mod.rs`: field `onboarding_completed`
  (+ `Default`, doc comment, legacy comment on the old flag). Extend tests:
  round-trip/independence + `..._still_deserializes` compat test.
- `src-tauri/src/core/onboarding.rs` (new): enum + the three core functions +
  inline tests against `InMemorySettingsStore`.
- `src-tauri/src/core/mod.rs`: `pub mod onboarding;` +
  `pub const ONBOARDING_WINDOW_LABEL: &str = "onboarding";` (next to the
  existing labels).

### 2. Backend: commands, window helper, setup gate

- `src-tauri/src/commands.rs`:
  - `complete_onboarding(app)` — calls `complete_onboarding_core`, then
    `window.close()` on the onboarding window (close is posted to the event
    loop, so the IPC response is sent first).
  - `set_input_synthesis(app, enabled)` — calls `set_input_synthesis_core`,
    then pushes the new value via `platform::set_input_synthesis_enabled`
    (same push `set_settings` does at `commands.rs:80–81`), so the choice
    takes effect immediately.
- `src-tauri/src/lib.rs`:
  - Register both commands in `generate_handler!`.
  - Helper `show_onboarding(app)` next to `show_settings`:
    `WebviewWindowBuilder::new(app, ONBOARDING_WINDOW_LABEL, WebviewUrl::App("onboarding.html"))`,
    ~640×560, resizable with a matching min size (see the GTK risk below),
    centered, `.focused(true)` + `set_focus()`
    (Accessory apps don't auto-activate otherwise). **Runtime creation instead
    of a static entry:** most launches never show it (no permanent webview
    cost), and creating it in `setup` after `Builder::manage` structurally
    avoids the WebView2 early-IPC hazard described in the comment at
    `lib.rs:361–372`. No CloseRequested intercept — closing destroys the
    window (intended, one-shot).
  - Replace the block at `lib.rs:424–444` with:
    `if let Ok(Show) = evaluate_onboarding(&settings_store) { show_onboarding(app.handle()); }`
    (store errors swallowed as before — launch must not fail).
- `src-tauri/capabilities/onboarding.json` (new): copy of
  `capabilities/settings.json` with `"identifier"/"windows": ["onboarding"]` —
  `core:default` + the three `autostart:*` permissions (capabilities match by
  label, which works for runtime-created windows too).

### 3. Frontend plumbing

- `vite.config.ts`: add `onboarding: "onboarding.html"` to
  `build.rollupOptions.input`.
- `onboarding.html` (repo root, clone of `settings.html`, title "Welcome to
  Kallilex") + `src/onboarding/main.ts` (clone of `src/settings/main.ts`).
- `src/shared/types.ts`: `onboardingCompleted: boolean` on the `Settings`
  interface (deliberately breaks every fixture constructing a full settings
  object — the compiler enumerates them).
- `src/shared/invoke.ts`: wrappers `completeOnboarding()` and
  `setInputSynthesis(enabled)`.

### 4. Frontend: `src/onboarding/App.svelte`

One component, Svelte 5 runes, scoped CSS on `tokens.css`. Navigation:
`$state` index over a `$derived` step list from `platformInfo`. Permission
polling only when `permissionRequired`, `POLL_INTERVAL_MS = 1000`, cleanup in
`onDestroy` — pattern 1:1 from `src/settings/App.svelte`. The Wayland step is
gated on `platformInfo.session === "wayland"`; its toggle initializes from
`getSettings().inputSynthesisEnabled` and writes through
`setInputSynthesis(enabled)`.

**No component extraction in v1:** the provider step is duplicated as a leaner
variant (create-only: no edit/delete, no timeout, no custom headers; defaults
`timeoutSecs: 30`, `customHeaders: []`, `enabled: true`, `id: ""`) instead of
refactoring the 1000-line `settings/App.svelte` mid-feature. Extraction to
`src/shared/components/` is a follow-up.

"Done": `void completeOnboarding().catch(() => {})` — the window closes from
the Rust side; an IPC response lost during teardown is cosmetic (the flag is
persisted before the close).

### 5. Tests

**Rust** (`core/onboarding.rs`, against `InMemorySettingsStore`):

- Fresh install → `Show`, nothing persisted.
- Legacy flag set → `AutoCompleted` + persisted; profiles present → same.
- Auto-complete preserves all other fields unchanged (clobber guard).
- `AlreadyCompleted` is stable (no further write).
- `complete_onboarding_core` sets the flag, preserves fields.
- `set_input_synthesis_core` flips only that field, preserves the rest.
- Plus the serde tests in `settings/mod.rs` (work item 1).

**Frontend** (`src/onboarding/App.test.ts`, Vitest + @testing-library/svelte,
`vi.mock("../shared/invoke")` pattern + `resetPlatformInfoForTests()` as in
`src/settings/App.test.ts`):

- Welcome shows the platform shortcut; "Get started" only after
  `platformInfo` resolves.
- macOS: permission step with poll (fake timers), pill flips live, deep-link
  call.
- Windows: spell-check note instead of permission, `accessibilityStatus`
  never called; Linux X11: 3-step flow; Wayland: paste-back step present.
- Wayland paste-back: toggle initialized from settings (on by default),
  toggling calls `setInputSynthesis`; compositor without input synthesis →
  note instead of toggle.
- Provider: presets rendered, preset pre-fills Base URL, Save calls
  `saveProfile` with draft + key, success → "saved" view; Skip never calls
  `saveProfile`; save failure stays on the step, Skip remains available;
  test-connection success/failure never blocks.
- Finish: autostart toggle default off, toggling calls `enableAutostart`;
  errors don't block "Done"; "Done" calls `completeOnboarding`.
- Existing fixtures (`defaultSettings()` in `src/settings/App.test.ts` etc.)
  gain `onboardingCompleted: false`.

## Verification

- `pnpm check`, `pnpm test`, `cd src-tauri && cargo test` (+ `cargo clippy`).
- Manual pass with `pnpm tauri dev`:
  1. Delete the store
     (`~/Library/Application Support/com.webcommits.kallilex/settings.json`) →
     onboarding appears centered; walk all steps; permission pill flips live
     when granting; save + test an Ollama profile; enable autostart; Done →
     window closes; relaunch → no onboarding.
  2. Fresh store → X on step 1 → relaunch → onboarding reappears.
  3. Simulate legacy: store with `"accessibilityOnboardingShown": true` and no
     `onboardingCompleted` → no onboarding; store now contains
     `"onboardingCompleted": true`.
  4. Settings window still opens from the tray; its Providers tab shows the
     profile created during onboarding; on Wayland, General shows the
     paste-back toggle in the state chosen during onboarding.

## Release

This feature ships as **v0.5.0** (new user-facing feature → minor bump):

1. Bump the version in `package.json`, `src-tauri/tauri.conf.json`, and
   `src-tauri/Cargo.toml` (all currently `0.4.0`; keep `Cargo.lock` in sync
   via a build).
2. Mention the onboarding in `README.md` if the feature list there warrants
   it.
3. Tag `v0.5.0` and push the tag — `.github/workflows/release.yml` triggers on
   `v*` tags and builds/signs the release artifacts.

## Risks

- **Capability gap (silent):** without `capabilities/onboarding.json` the
  autostart plugin calls fail silently at runtime — no compile-time signal.
  Covered by manual pass 1.
- **WebView2 early IPC:** structurally avoided (runtime creation after
  `Builder::manage`); do not make the window static later without need.
- **Async `platformInfo`:** the step list depends on it → "Get started" is
  gated, the flow never reshapes mid-wizard.
- **macOS Accessory activation:** runtime windows can open behind others →
  `.focused(true)` + `set_focus()` as in `show_settings`.
- **Linux GTK CSD first-map bug:** without the `resync_frame_extents`
  workaround (see `show_settings`) the window's Close button can be
  unclickable on first display, breaking the close-without-finishing →
  re-show contract. The onboarding window applies the same guarded resync
  and is therefore resizable (with a min size at the design size), since
  window managers refuse to maximize non-resizable windows and the
  workaround re-syncs via a maximize/restore cycle.
