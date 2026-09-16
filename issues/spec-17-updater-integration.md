# Spec 17 — Updater integration: plugin, commands, scheduled checks, tray entry

Status: ready-for-agent
Phase: distribution (second of five; wires the spec-16 core into the running
app)
Depends on: spec-16 (`core::updates`, the settings fields, the update state
store). spec-18 consumes the commands and events defined here; spec-19
produces the signed artifacts the install path needs.

## Problem Statement

After spec-16 the app can *decide* which release a user should see, but
nothing asks the question, nothing remembers the answer, and nothing can act
on it. Three runtime pieces are missing:

1. a **check** the user can trigger and a **schedule** that triggers it
   without them, both feeding one shared status the UI can render;
2. an **install** path that downloads the right artifact, verifies its
   signature, replaces the running app, and restarts — on the platforms and
   package types where that is possible;
3. a way to be **told** when a scheduled check finds something, in an app
   that has no dock icon and no visible window most of the time.

The install mechanics are exactly what `tauri-plugin-updater` provides
(minisign verification, `.app` replacement on macOS, NSIS passive update on
Windows, AppImage replacement on Linux, all from Rust). Its endpoint is
per-call configurable, so spec-16's resolved `manifest_url` plugs straight
in. What the plugin does *not* do is channels, scheduling, status, or
"notify only" — that is this spec.

## Solution

- Register `tauri-plugin-updater` (install/verify) and `tauri-plugin-opener`
  (open the release page in the browser — the only cross-platform URL
  opener the app currently lacks). Both are used **from Rust only**; the
  frontend keeps talking to `invoke` wrappers, so no capability changes.
- One managed `UpdateRuntime` state holding the current `UpdateStatus`,
  the pending verified `Update` (if any), and the tray menu item handle.
- Commands `get_update_status`, `check_for_updates`, `install_update`,
  `open_update_release_page`; every status change is also pushed to the
  Settings window as event `update:status` so a running check or download
  renders live.
- A **two-stage check**: stage 1 is spec-16's GitHub resolution, which
  always yields "up to date" or "vX available (+ notes URL)"; stage 2 runs
  the updater plugin against that release's `latest.json` **only when this
  install can update itself**. Everything else is *notify-only*: the app
  says a version is available and offers the release page.
- A scheduler task started in `setup()` that honors
  `update_check_frequency` via spec-16's `is_check_due`.
- One tray entry, **"Check for Updates…"**, whose label changes to
  **"Update to vX.Y.Z available…"** while an update is known. Either way it
  opens Settings on the Updates tab; when nothing is known it also starts a
  check.

## User Stories

1. As a user, I want a "Check for Updates" action that tells me within a few
   seconds whether I'm current, which version exists, and what's new, so
   that I never have to open GitHub to find out.
2. As a macOS, Windows or AppImage user, I want "Download & install" to
   fetch, verify and apply the update and restart Kallilex, so that updating
   is one click.
3. As a macOS user, I want my Accessibility permission to survive the
   update, so that the first capture after restarting just works.
4. As a `.deb`/`.rpm` user, I want to be told an update exists and taken to
   the release page, so that I can install it the way I installed the app —
   with no password prompt from Kallilex.
5. As a user who chose daily or weekly checks, I want Kallilex to check
   quietly in the background and never interrupt me with a dialog, so that
   an update is something I notice in the tray menu, not something that
   steals focus.
6. As a user who chose "never", I want Kallilex to make no update request
   at all unless I press the button, so that the setting means what it
   says.
7. As a user who switches channels, I want a previously found update that
   no longer applies to disappear, so that the UI never offers a release
   from the channel I just left.
8. As a user whose update check fails (offline, rate-limited, bad
   signature), I want a plain sentence saying so and a working button to
   retry, so that failure is never silent and never a crash.

## Implementation Decisions

### Prerequisite: the updater signing key (maintainer action, not agent work)

- The plugin refuses to initialize without `plugins.updater.pubkey`, so the
  key pair must exist before this spec can run. The maintainer generates it
  once, locally: `pnpm tauri signer generate -w ~/.kallilex-signing/updater.key`
  (a password is recommended). The **public** key goes into
  `src-tauri/tauri.conf.json` under `plugins.updater.pubkey` in this spec;
  the private key and its password go to GitHub Actions secrets in spec-19
  and to nowhere else — never into the repo, a prompt, or a log.
- The `.key` and its password are kept next to the Apple signing material
  in `~/.kallilex-signing/`. Losing the key means no existing install can
  ever verify another update (they would all need a manual reinstall);
  spec-19's checklist section says so.

### Plugin wiring

- `Cargo.toml`: `tauri-plugin-updater = "2"`, `tauri-plugin-opener = "2"`.
  No JS packages.
- `lib.rs` builder: `.plugin(tauri_plugin_updater::Builder::new().build())`
  and `.plugin(tauri_plugin_opener::init())`, next to the existing plugins.
- `tauri.conf.json`: `"plugins": { "updater": { "pubkey": "<generated>",
  "windows": { "installMode": "passive" } } }`. **No `endpoints`** in the
  config: the endpoint is chosen per check from the resolved release
  (`UpdaterBuilder::endpoints(vec![manifest_url])`), which is what makes
  channels work without two config files.
- No capability changes: nothing in JS calls the plugins.

### Status model

- `UpdateStatus` (Rust, `Serialize`, camelCase; TS mirror added in
  `src/shared/types.ts` now so spec-18 only adds UI):

  ```
  UpdateStatus {
    current_version: String,
    channel: UpdateChannel,
    last_check_at: Option<u64>,
    phase: UpdatePhase,            // idle | checking | upToDate | available | downloading | error
    available: Option<AvailableUpdate>,
    progress: Option<DownloadProgress>,   // { downloaded: u64, total: Option<u64> }
    error: Option<String>,
  }
  AvailableUpdate {
    version: String, tag: String, release_url: String,
    notes: Option<String>, published_at: Option<String>,
    installable: bool,             // false ⇒ notify-only: offer the release page
  }
  ```
- `installable` is decided by a pure
  `install_supported(bundle: Option<tauri::utils::platform::BundleType>,
  debug_build: bool) -> bool`: `false` for debug builds (dev runs must never
  try to replace themselves), `false` on Linux unless the bundle is
  `AppImage`, `true` otherwise (macOS `App`, Windows `Nsis`). The
  `BundleType` is read via `tauri::utils::platform::bundle_type()` (patched
  into the binary at bundle time). This is the entire deb/rpm decision:
  per the product call, deb/rpm are notify-only even though the plugin
  could install them via `pkexec`.
- A stage-2 result of `Ok(None)` or a targets-not-found error (manifest
  present but without this platform's key) downgrades the status to
  `available` with `installable: false` — never to an error: the user can
  still get the release by hand.

### Runtime state and commands

- `UpdateRuntime` (managed before `setup`, like the other state):
  `Mutex<Inner { status: UpdateStatus, pending: Option<Update>,
  check_in_flight: bool }>` plus `OnceLock<MenuItem<Wry>>` for the tray
  item. All transitions go through one `set_status(app, |inner| …)` helper
  that (a) mutates, (b) emits `update:status` to the `settings` window via
  `emit_to`, (c) refreshes the tray label — so the three can never drift.
- `get_update_status(app) -> UpdateStatus` — read-only; also fills
  `last_check_at` from the state store on first call.
- `check_for_updates(app) -> Result<UpdateStatus, String>` (async):
  - if a check is in flight, return the current status (no second request);
  - phase `checking`; stage 1 via spec-16 with a `reqwest::Client` built
    once and kept in `UpdateRuntime`; on error → phase `error` with the
    `UpdateError` display text; on `UpToDate` → phase `upToDate`;
  - on `Available` and `installable` → stage 2:
    `app.updater_builder().endpoints(vec![manifest_url])?.build()?.check().await`;
    `Some(update)` → keep it as `pending`, phase `available`; `None` /
    targets-not-found → phase `available`, `installable: false`; a
    signature or transport error here → phase `error` with the plugin's
    message prefixed by *"Kallilex found version X but couldn't verify the
    download: "*;
  - on `Available` and not installable → phase `available` directly;
  - on any completed stage 1 (success or `UpToDate`), persist
    `last_check_at = now`; a stage-1 *failure* does not update it, so the
    scheduler retries at its next tick.
- `install_update(app) -> Result<(), String>` (async): requires `pending`;
  phase `downloading`; `update.download_and_install(on_chunk, on_finish)`
  where `on_chunk` updates `progress` through `set_status` (throttle emits
  to at most ~10/s); on success, `app.restart()`. On Windows the plugin
  launches the NSIS installer and exits the process itself — the restart
  call is unreachable there, and nothing needs flushing first (the store
  saves synchronously). On failure, phase `error`, `pending` cleared, the
  user can re-check.
- `open_update_release_page(app)`: opens `available.release_url` via
  `tauri_plugin_opener::OpenerExt`; error if nothing is available.
- `set_settings` side effect: when `update_channel` changed, reset the
  runtime to `idle` (drop `pending`/`available`, clear the tray label) —
  the next check re-resolves for the new channel. A frequency change needs
  no action; the scheduler reads settings fresh every tick.
- `invoke.ts` gains typed wrappers `getUpdateStatus`, `checkForUpdates`,
  `installUpdate`, `openUpdateReleasePage`; `App.test.ts`'s hoisted mock
  list gains them (spec-18 writes the tests that use them).

### Scheduler

- Spawned once in `setup()` with `tauri::async_runtime::spawn`:
  sleep 30 s (let launch, portal binding and onboarding settle), run
  `scheduled_check(Tick::Startup)`, then `loop { sleep 1 h;
  scheduled_check(Tick::Periodic) }`.
- `scheduled_check` reads `Settings` and `UpdateCheckState` fresh, applies
  `is_check_due`, and if due calls the same code path as
  `check_for_updates`. Errors are swallowed exactly like the other `setup`
  steps (a broken check must never surface a dialog); the status the UI
  would show is still updated, so opening Settings later shows the last
  outcome.
- The task holds only an `AppHandle`; it exits with the process. This is
  the app's first app-lifetime background task, so its doc comment says why
  a loop is the right shape here (vs. the on-demand watchdog threads
  elsewhere).

### Tray

- New `UPDATES_MENU_ID` item **"Check for Updates…"**, inserted directly
  after "Settings" on every platform. Handler: `show_settings(app)`, then
  `emit_to("settings", "settings:show-tab", "updates")`, then — only if the
  current phase is not `available`/`downloading` — spawn
  `check_for_updates`.
- Label rule (applied in `set_status`): phase `available` →
  `format!("Update to v{} available…", version)`; anything else → the
  static label. Implemented with `MenuItem::set_text`; the item is never
  disabled or removed.
- No dialogs, no notifications plugin: the tray label is the sole passive
  signal, per the product call.

## Testing Decisions

- `install_supported` full table: debug → false; Linux × {AppImage → true,
  Deb/Rpm/None → false}; macOS App → true; Windows Nsis → true.
- Status transitions are unit-tested on the pure `Inner` state machine
  (functions that take `&mut Inner` and return the label the tray should
  show): checking → upToDate, checking → available(installable) →
  downloading → error clears `pending`, channel change → idle, in-flight
  guard.
- The stage-1 path is already covered by spec-16's wiremock tests; the
  stage-2 plugin call and `download_and_install` are not unit-tested
  (they need signed artifacts) — they are spec-20's manual gate.
- `last_check_at` bookkeeping: written on success and on up-to-date, not on
  failure (test via the in-memory state store and an injected clock).
- `pnpm check`, `pnpm test`, `cargo clippy -D warnings`, `cargo test` green
  on the host; CI on all three OSes green (the plugin adds native
  dependencies — Linux CI needs no new apt packages, but verify).

## Out of Scope

- The Settings UI (spec-18); this spec only emits events and exposes
  commands. Until spec-18 lands, the tray item opens Settings on the
  current tab — acceptable for one commit.
- In-app install for deb/rpm, "skip this version", release-notes rendering,
  delta/partial downloads, rollback.
- Any change to signing, CI, or the release layout (spec-19).
- Checking on a metered-connection or battery condition.

## Further Notes

- Why two stages instead of pointing the plugin at a per-channel URL: the
  plugin only understands its own manifest format, so a channel would need
  a server or a Pages deployment that rewrites manifests. Resolving the
  release in-app keeps GitHub Releases the single source of truth and costs
  one small JSON request.
- Why the plugin is driven from Rust: the frontend convention is "UI code
  always goes through `invoke` wrappers"; the scheduler needs the check in
  Rust anyway; and it avoids granting the settings webview `updater:*`
  permissions.
- macOS: the update is downloaded by the app itself, so the replaced
  bundle carries no quarantine attribute and should start without a new
  Gatekeeper approval; the stable "Kallilex Signing" identity keeps the TCC
  grant. Both are asserted, not assumed, in spec-20's beta.1 → beta.2 gate.
- The manifest keys the pipeline must produce (spec-19) follow from the
  plugin's lookup order `{os}-{arch}-{installer}` then `{os}-{arch}` and
  the fact that there is **no** `darwin-universal` fallback:
  `darwin-aarch64` and `darwin-x86_64` (same universal `.app.tar.gz`),
  `linux-x86_64` (AppImage), `windows-x86_64` (NSIS).
