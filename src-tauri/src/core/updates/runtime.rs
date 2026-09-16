//! Update runtime: the managed [`UpdateRuntime`] state, the pure [`Inner`]
//! status state machine, and the async glue (two-stage check, install,
//! scheduler, tray label) that drives it. See the parent module
//! ([`crate::core::updates`]) for the pure channel/version-resolution logic
//! this module calls into, and [`crate::core::updates::state`] for the
//! "when did we last check" persistence this module reads and writes.
//!
//! Kept testable without a live `AppHandle`: every phase transition goes
//! through a named function on [`Inner`] (`begin_check`, `finish_up_to_date`,
//! ...) that mutates state and returns the tray label that state implies.
//! The `tauri`-dependent glue ([`UpdateRuntime`], `apply_and_broadcast`, the
//! two-stage [`run_check`], [`install`], the scheduler) wraps those
//! functions with a `Mutex`, an event emit, and a tray-label refresh, but
//! contains no decision logic of its own — so the in-memory status, the
//! `update:status` event the Settings window renders, and the tray label
//! can never drift from one another.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::menu::MenuItem;
use tauri::{AppHandle, Emitter, Manager, Wry};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_updater::UpdaterExt;
use url::Url;

use crate::core::settings::{self, TauriStoreSettings};
use crate::core::updates::state::{TauriUpdateStateStore, UpdateCheckState, UpdateStateStore};
use crate::core::updates::{self as updates, Availability, ResolvedRelease, Tick, UpdateChannel};
use crate::core::SETTINGS_WINDOW_LABEL;

/// Event emitted to the `settings` window every time [`UpdateStatus`]
/// changes, via `Emitter::emit_to`.
const UPDATE_STATUS_EVENT: &str = "update:status";

/// Event that asks the (already-shown) Settings window to switch to its
/// Updates tab; payload is always the literal string `"updates"`.
const SETTINGS_SHOW_TAB_EVENT: &str = "settings:show-tab";

/// The tray entry's label while no update is known to be available.
const TRAY_LABEL_STATIC: &str = "Check for Updates…";

/// GitHub REST API root used in production ([`crate::core::updates`]'s own
/// `fetch_releases` tests point this at a `wiremock` server instead).
const GITHUB_API_BASE: &str = "https://api.github.com";

/// How long `setup()` waits before the scheduler's first (`Tick::Startup`)
/// check, so launch, portal binding and onboarding settle first.
const SCHEDULER_STARTUP_DELAY: Duration = Duration::from_secs(30);

/// How often the scheduler re-evaluates `is_check_due` after its first run.
const SCHEDULER_PERIOD: Duration = Duration::from_secs(3600);

/// Minimum spacing between `update:status` progress emits during a
/// download — about 10/s, generous enough to feel live without flooding the
/// IPC channel on a fast connection. The final chunk is always emitted
/// regardless (see [`install`]'s `on_finish`), so the UI never gets stuck
/// short of the real end state.
const PROGRESS_EMIT_INTERVAL: Duration = Duration::from_millis(100);

fn github_api_base() -> Url {
    Url::parse(GITHUB_API_BASE).expect("GITHUB_API_BASE must be a valid URL")
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// --- Status model ---------------------------------------------------------

/// The Settings window's live view of Kallilex's update state. Pushed via
/// [`UPDATE_STATUS_EVENT`] on every change and returned by
/// `get_update_status`/`check_for_updates`. Mirrored in
/// `src/shared/types.ts`; keep the two in sync.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub current_version: String,
    pub channel: UpdateChannel,
    pub last_check_at: Option<u64>,
    pub phase: UpdatePhase,
    pub available: Option<AvailableUpdate>,
    pub progress: Option<DownloadProgress>,
    pub error: Option<String>,
}

/// Which stage of the check/install flow [`UpdateStatus`] currently
/// reflects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdatePhase {
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Error,
}

/// The release [`UpdateStatus::available`] describes, once stage 1 (or
/// stage 1 + 2) has resolved one. `installable` is `false` for a
/// notify-only release (see [`install_supported`]): the UI offers the
/// release page instead of a "Download & install" button.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AvailableUpdate {
    pub version: String,
    pub tag: String,
    pub release_url: String,
    pub notes: Option<String>,
    pub published_at: Option<String>,
    pub installable: bool,
}

/// A single (throttled) download progress tick — see [`install`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub downloaded: u64,
    pub total: Option<u64>,
}

/// Whether *this* running build can replace itself in place: `false` for
/// debug builds (a `cargo run`/dev binary must never try to overwrite
/// itself), and otherwise `true` only for the bundle types the updater
/// plugin can actually install — the macOS `.app`, the Windows NSIS
/// installer, and the Linux AppImage. Every other Linux package
/// (`.deb`/`.rpm`) — and an unrecognized/unpatched bundle — is
/// notify-only: this is the entire deb/rpm decision, per the product call
/// (the plugin *could* install them via `pkexec`, but doesn't here).
/// `bundle` comes from `tauri::utils::platform::bundle_type()`, patched
/// into the binary at bundle time; its type, despite the function living in
/// the `platform` module, is `tauri::utils::config::BundleType`.
pub fn install_supported(
    bundle: Option<tauri::utils::config::BundleType>,
    debug_build: bool,
) -> bool {
    use tauri::utils::config::BundleType;

    if debug_build {
        return false;
    }

    matches!(
        bundle,
        Some(BundleType::AppImage) | Some(BundleType::App) | Some(BundleType::Nsis)
    )
}

// --- Pure state machine ----------------------------------------------------

/// The runtime's mutable core: today's [`UpdateStatus`] plus the pieces that
/// aren't serialized to the frontend — the verified pending update
/// [`install`] will act on (generic over its payload type `P`, normally
/// [`tauri_plugin_updater::Update`]; tests use a cheap stand-in so they can
/// construct a real `Some` without a live `AppHandle` — see this module's
/// `tests` submodule), whether a check or an install is currently in flight
/// (the guards `begin_check`/`begin_download` enforce, mutually exclusive
/// with each other), and `generation`, bumped by both `begin_check` and
/// `reset_for_channel` so a check's completion can tell whether the channel
/// changed out from under it — see `complete_check`.
/// `Update` is neither `Debug` nor `PartialEq`, so both are implemented
/// manually below, comparing `pending` only by presence.
struct Inner<P = tauri_plugin_updater::Update> {
    status: UpdateStatus,
    pending: Option<P>,
    check_in_flight: bool,
    install_in_flight: bool,
    generation: u64,
}

impl<P> std::fmt::Debug for Inner<P> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Inner")
            .field("status", &self.status)
            .field("pending", &self.pending.is_some())
            .field("check_in_flight", &self.check_in_flight)
            .field("install_in_flight", &self.install_in_flight)
            .field("generation", &self.generation)
            .finish()
    }
}

impl<P> PartialEq for Inner<P> {
    fn eq(&self, other: &Self) -> bool {
        self.status == other.status
            && self.pending.is_some() == other.pending.is_some()
            && self.check_in_flight == other.check_in_flight
            && self.install_in_flight == other.install_in_flight
            && self.generation == other.generation
    }
}

impl<P> Inner<P> {
    fn new(current_version: String, channel: UpdateChannel) -> Self {
        Self {
            status: UpdateStatus {
                current_version,
                channel,
                last_check_at: None,
                phase: UpdatePhase::Idle,
                available: None,
                progress: None,
                error: None,
            },
            pending: None,
            check_in_flight: false,
            install_in_flight: false,
            generation: 0,
        }
    }
}

/// The tray label [`Inner`]'s current status implies: the static
/// "Check for Updates…" unless a verified-or-not update is known
/// (`phase == Available`), in which case it names the version.
fn tray_label<P>(inner: &Inner<P>) -> String {
    match (inner.status.phase, &inner.status.available) {
        (UpdatePhase::Available, Some(available)) => {
            format!("Update to v{} available…", available.version)
        }
        _ => TRAY_LABEL_STATIC.to_string(),
    }
}

/// Starts a check, guarding against a second one running concurrently, and
/// against one starting while an install is in progress: if either is
/// already in flight, `inner` is left untouched and the *current* status is
/// returned as `Err` so the caller can hand it straight back (spec: "if a
/// check is in flight, return the current status — no second request").
/// Otherwise moves to `Checking`, clears any previous error, bumps
/// `generation` (see `Inner`'s doc comment and `complete_check`), and
/// returns `Ok` with the tray label and the generation this check started
/// under.
///
/// `UpdateStatus` is meaningfully larger than the success case's payload —
/// expected and fine here: this runs at most once per check attempt (a
/// user click or a scheduler tick), never in a hot loop, so the clarity of
/// returning the real status beats shaving bytes off an `Err` that's cloned
/// once and immediately handed back to the caller.
#[allow(clippy::result_large_err)]
fn begin_check<P>(inner: &mut Inner<P>) -> Result<(String, u64), UpdateStatus> {
    if inner.check_in_flight || inner.install_in_flight {
        return Err(inner.status.clone());
    }
    inner.check_in_flight = true;
    inner.generation = inner.generation.wrapping_add(1);
    inner.status.phase = UpdatePhase::Checking;
    inner.status.error = None;
    Ok((tray_label(inner), inner.generation))
}

/// The single place a check's completion (stage 1 or stage 2, success or
/// failure) goes through, so the channel-change race is handled exactly
/// once rather than at every one of `run_check`'s five completion sites.
///
/// If `inner`'s `generation` no longer matches `started_generation` — i.e.
/// `reset_for_channel` ran (and bumped it) while this check was still in
/// flight — the check that's completing now is stale: whatever it found
/// applied to a channel the user has since moved away from, and
/// `reset_for_channel` already put `inner` in the right `Idle` state for
/// the new channel, so `apply` is skipped entirely and only the in-flight
/// flag this check itself owns is cleared. The tray label is still
/// recomputed and returned either way, so callers never need to branch on
/// staleness themselves.
fn complete_check<P>(
    inner: &mut Inner<P>,
    started_generation: u64,
    apply: impl FnOnce(&mut Inner<P>) -> String,
) -> String {
    if inner.generation != started_generation {
        inner.check_in_flight = false;
        return tray_label(inner);
    }
    apply(inner)
}

/// Stage 1 (or a completed stage 1 + 2) found nothing newer.
fn finish_up_to_date<P>(inner: &mut Inner<P>) -> String {
    inner.status.phase = UpdatePhase::UpToDate;
    inner.status.available = None;
    inner.status.progress = None;
    inner.status.error = None;
    inner.pending = None;
    inner.check_in_flight = false;
    tray_label(inner)
}

/// A release was resolved (with or without a stage-2 verified update to
/// install). `pending` is `Some` only when stage 2 verified an installable
/// artifact for this exact release.
fn finish_available<P>(
    inner: &mut Inner<P>,
    available: AvailableUpdate,
    pending: Option<P>,
) -> String {
    inner.status.phase = UpdatePhase::Available;
    inner.status.available = Some(available);
    inner.status.progress = None;
    inner.status.error = None;
    inner.pending = pending;
    inner.check_in_flight = false;
    tray_label(inner)
}

/// A check (stage 1 or stage 2) failed. Any previously known `available`
/// release is left as-is — a failed *retry* doesn't invalidate a release
/// already confirmed on an earlier check — but there is nothing left to
/// install until the next successful check re-verifies it, so `pending` is
/// cleared.
fn finish_error<P>(inner: &mut Inner<P>, message: String) -> String {
    inner.status.phase = UpdatePhase::Error;
    inner.status.error = Some(message);
    inner.status.progress = None;
    inner.pending = None;
    inner.check_in_flight = false;
    tray_label(inner)
}

/// A verified update starts downloading, guarding against a second install
/// starting concurrently and against one starting while a check is in
/// flight: if either is already true, `inner` is left untouched and the
/// *current* status is returned as `Err`, mirroring `begin_check`'s guard
/// (see its doc comment for why `Err(UpdateStatus)` rather than a smaller
/// error type is the right call here too).
#[allow(clippy::result_large_err)]
fn begin_download<P>(inner: &mut Inner<P>) -> Result<String, UpdateStatus> {
    if inner.install_in_flight || inner.check_in_flight {
        return Err(inner.status.clone());
    }
    inner.install_in_flight = true;
    inner.status.phase = UpdatePhase::Downloading;
    inner.status.error = None;
    inner.status.progress = Some(DownloadProgress {
        downloaded: 0,
        total: None,
    });
    Ok(tray_label(inner))
}

/// A download progress tick (throttled by the caller, see [`install`]). A
/// no-op outside `Downloading` — a chunk callback that fires after the
/// phase has already moved on (e.g. a late tick racing a `fail_download`)
/// must not resurrect stale progress.
fn set_progress<P>(inner: &mut Inner<P>, downloaded: u64, total: Option<u64>) -> String {
    if inner.status.phase == UpdatePhase::Downloading {
        inner.status.progress = Some(DownloadProgress { downloaded, total });
    }
    tray_label(inner)
}

/// The download or install step failed: back to a retryable state. Clears
/// `pending` (whatever was downloading is no longer trustworthy) so a retry
/// re-checks from scratch rather than re-attempting a possibly-corrupt
/// download, and clears `install_in_flight` so a retry (or a check) can
/// start.
fn fail_download<P>(inner: &mut Inner<P>, message: String) -> String {
    inner.status.phase = UpdatePhase::Error;
    inner.status.error = Some(message);
    inner.status.progress = None;
    inner.pending = None;
    inner.install_in_flight = false;
    tray_label(inner)
}

/// The user switched update channels: whatever this runtime previously
/// found no longer necessarily applies, so it's discarded rather than
/// offered against the new channel. The next check re-resolves for
/// `channel` from scratch. Bumps `generation` so a check already in flight
/// under the old channel completes as a no-op (see `complete_check`) rather
/// than resurrecting the old channel's release once it finishes;
/// `check_in_flight` itself is deliberately left alone — the in-flight
/// check still owns clearing it once it (harmlessly) completes.
fn reset_for_channel<P>(inner: &mut Inner<P>, channel: UpdateChannel) -> String {
    inner.status.phase = UpdatePhase::Idle;
    inner.status.channel = channel;
    inner.status.available = None;
    inner.status.progress = None;
    inner.status.error = None;
    inner.pending = None;
    inner.generation = inner.generation.wrapping_add(1);
    tray_label(inner)
}

// --- last_check_at bookkeeping ---------------------------------------------

/// Persists `last_check_at = now` when a check's stage 1 completed
/// (`outcome_ok`, true for both "up to date" and "available" — see
/// [`run_check`]), and does nothing on a stage-1 failure, so the scheduler
/// retries at its next tick instead of waiting out a full period. Pure
/// aside from the store write, so it's testable with
/// [`crate::core::updates::state::InMemoryUpdateStateStore`] and an
/// injected clock rather than real time.
pub fn record_check_outcome(
    store: &dyn UpdateStateStore,
    outcome_ok: bool,
    now: u64,
) -> Result<(), String> {
    if !outcome_ok {
        return Ok(());
    }
    store.save(&UpdateCheckState {
        last_check_at: Some(now),
    })
}

// --- Runtime state -----------------------------------------------------

/// Managed app state: the current [`UpdateStatus`] plus the pieces that
/// drive it, behind one `Mutex` so every transition is atomic (in
/// particular, `begin_check`'s in-flight guard). `tray_item` is set once,
/// right after the tray menu is built in `setup()` — a `OnceLock` because
/// `UpdateRuntime` itself is constructed (via `.manage()`) before the tray
/// exists. `client` is a single `reqwest::Client`, reused for every stage-1
/// check rather than built per call.
pub struct UpdateRuntime {
    inner: Mutex<Inner>,
    tray_item: OnceLock<MenuItem<Wry>>,
    client: reqwest::Client,
}

impl UpdateRuntime {
    /// `current_version` is this build's own version
    /// (`env!("CARGO_PKG_VERSION")`); the channel starts at the
    /// build-dependent default and is refreshed from persisted `Settings`
    /// on the first status read or check, since `Settings` isn't available
    /// yet at `.manage()` time (before `setup()` runs).
    pub fn new(current_version: String) -> Self {
        let channel = updates::default_update_channel();
        Self {
            inner: Mutex::new(Inner::new(current_version, channel)),
            tray_item: OnceLock::new(),
            client: reqwest::Client::new(),
        }
    }

    /// Registers the tray menu item whose label `apply_and_broadcast` keeps
    /// in sync with the current phase. A no-op (never overwrites) if called
    /// more than once.
    pub fn set_tray_item(&self, item: MenuItem<Wry>) {
        let _ = self.tray_item.set(item);
    }
}

/// Runs `f` against the runtime's locked [`Inner`], then — whatever `f`
/// did — emits the resulting [`UpdateStatus`] to the Settings window and
/// refreshes the tray label. The single choke point every transition goes
/// through, so the in-memory status, the event the UI renders, and the tray
/// label can never drift from one another.
fn apply_and_broadcast<T>(app: &AppHandle, f: impl FnOnce(&mut Inner) -> T) -> (T, UpdateStatus) {
    let runtime = app.state::<UpdateRuntime>();
    let (result, status, label) = {
        let mut inner = runtime
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let result = f(&mut inner);
        let label = tray_label(&inner);
        (result, inner.status.clone(), label)
    };
    let _ = app.emit_to(SETTINGS_WINDOW_LABEL, UPDATE_STATUS_EVENT, &status);
    if let Some(item) = runtime.tray_item.get() {
        let _ = item.set_text(&label);
    }
    (result, status)
}

/// Read-only status, filling in `last_check_at` from
/// [`TauriUpdateStateStore`] the first time it's asked (the runtime itself
/// never persists — only [`record_check_outcome`], called from
/// [`run_check`], does) and refreshing `channel` from the persisted
/// `Settings` so a channel changed before the first check (or from outside
/// this process) still reads correctly.
pub fn get_status(app: &AppHandle) -> UpdateStatus {
    let runtime = app.state::<UpdateRuntime>();
    let mut inner = runtime
        .inner
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    if inner.status.last_check_at.is_none() {
        let store = TauriUpdateStateStore::new(app.clone());
        if let Ok(state) = store.load() {
            inner.status.last_check_at = state.last_check_at;
        }
    }

    if let Ok(current_settings) = settings::get_settings(&TauriStoreSettings::new(app.clone())) {
        inner.status.channel = current_settings.update_channel;
    }

    inner.status.clone()
}

/// The shared two-stage check both the `check_for_updates` command and the
/// scheduler call. Guarded by `begin_check`'s in-flight check (see its doc
/// comment); on any completed stage 1 (up to date, or available — whether
/// or not stage 2 then runs), persists `last_check_at` via
/// [`record_check_outcome`]; on a stage-1 failure, it doesn't, so the next
/// scheduler tick retries rather than waiting out a full period.
///
/// Every completion site below goes through [`complete_check`] with the
/// generation `begin_check` returned, so a channel change (`set_settings`
/// calling `reset_for_channel_change` while this check is still awaiting
/// stage 1 or stage 2) makes this check's eventual completion a no-op
/// instead of resurrecting the old channel's release — see `complete_check`
/// and `reset_for_channel`'s doc comments.
pub async fn run_check(app: &AppHandle) -> UpdateStatus {
    let (begin_result, status_after_begin) = apply_and_broadcast(app, begin_check);
    let started_generation = match begin_result {
        Ok((_, generation)) => generation,
        Err(_) => return status_after_begin,
    };

    let settings_store = TauriStoreSettings::new(app.clone());
    let current_settings = settings::get_settings(&settings_store).unwrap_or_default();
    let current_version = semver::Version::parse(env!("CARGO_PKG_VERSION"))
        .expect("CARGO_PKG_VERSION must be a valid semver version");

    let releases = {
        let runtime = app.state::<UpdateRuntime>();
        updates::fetch_releases(&runtime.client, &github_api_base()).await
    };

    let releases = match releases {
        Ok(releases) => releases,
        Err(err) => {
            // Stage-1 failure: `last_check_at` is deliberately not touched.
            let (_, status) = apply_and_broadcast(app, |inner| {
                complete_check(inner, started_generation, |inner| {
                    finish_error(inner, err.to_string())
                })
            });
            return status;
        }
    };

    // Stage 1 completed (whether or not anything qualifies): persist
    // `last_check_at` regardless of what stage 2 (if any) decides below.
    let now = now_secs();
    let update_state_store = TauriUpdateStateStore::new(app.clone());
    let _ = record_check_outcome(&update_state_store, true, now);
    let channel = current_settings.update_channel;

    let resolved = updates::select_release(&releases, channel);
    let availability = updates::evaluate(resolved.as_ref(), &current_version);

    let release = match availability {
        Availability::UpToDate => {
            let (_, status) = apply_and_broadcast(app, |inner| {
                complete_check(inner, started_generation, |inner| {
                    let label = finish_up_to_date(inner);
                    inner.status.last_check_at = Some(now);
                    inner.status.channel = channel;
                    label
                })
            });
            return status;
        }
        Availability::Available(release) => release,
    };

    let bundle = tauri::utils::platform::bundle_type();
    let installable = install_supported(bundle, cfg!(debug_assertions));

    if !installable {
        let available = available_from_release(&release, false);
        let (_, status) = apply_and_broadcast(app, |inner| {
            complete_check(inner, started_generation, |inner| {
                let label = finish_available(inner, available, None);
                inner.status.last_check_at = Some(now);
                inner.status.channel = channel;
                label
            })
        });
        return status;
    }

    match stage_two_check(app, &release).await {
        Ok((pending, verified_installable)) => {
            let available = available_from_release(&release, verified_installable);
            let (_, status) = apply_and_broadcast(app, |inner| {
                complete_check(inner, started_generation, |inner| {
                    let label = finish_available(inner, available, pending);
                    inner.status.last_check_at = Some(now);
                    inner.status.channel = channel;
                    label
                })
            });
            status
        }
        Err(message) => {
            let (_, status) = apply_and_broadcast(app, |inner| {
                complete_check(inner, started_generation, |inner| {
                    let label = finish_error(inner, message);
                    inner.status.last_check_at = Some(now);
                    inner.status.channel = channel;
                    label
                })
            });
            status
        }
    }
}

fn available_from_release(release: &ResolvedRelease, installable: bool) -> AvailableUpdate {
    AvailableUpdate {
        version: release.version.to_string(),
        tag: release.tag.clone(),
        release_url: release.release_url.clone(),
        notes: release.notes.clone(),
        published_at: release.published_at.clone(),
        installable,
    }
}

/// Stage 2: points the updater plugin at this release's own `latest.json`
/// and asks it to verify a signed artifact for this platform. `Ok((Some,
/// true))` means it found and verified one (ready to install); `Ok((None,
/// false))` means the manifest doesn't cover this platform — still a real
/// release, just notify-only (never an error just because this platform's
/// key is missing); `Err` is a genuine transport or signature failure,
/// worth surfacing.
async fn stage_two_check(
    app: &AppHandle,
    release: &ResolvedRelease,
) -> Result<(Option<tauri_plugin_updater::Update>, bool), String> {
    let endpoint = release.manifest_url.clone();

    let updater = app
        .updater_builder()
        .endpoints(vec![endpoint])
        .and_then(|builder| builder.build());

    let updater = match updater {
        Ok(updater) => updater,
        Err(err) => return Err(stage_two_error(&release.version, &err)),
    };

    match updater.check().await {
        Ok(Some(update)) => Ok((Some(update), true)),
        Ok(None) => Ok((None, false)),
        Err(tauri_plugin_updater::Error::TargetsNotFound(_)) => Ok((None, false)),
        Err(err) => Err(stage_two_error(&release.version, &err)),
    }
}

fn stage_two_error(version: &semver::Version, err: &dyn std::fmt::Display) -> String {
    format!("Kallilex found version {version} but couldn't verify the download: {err}")
}

/// Downloads and installs the pending verified update (set by a prior
/// [`run_check`]'s stage 2), then restarts. Guarded by `begin_download`'s
/// in-flight check (see its doc comment) so two overlapping calls — or a
/// call racing a check — can't both start `download_and_install` or have a
/// check's `Checking` phase stomped mid-download; the second caller gets
/// back an explanatory error instead. Progress is throttled to at most ~10
/// emits/second (`PROGRESS_EMIT_INTERVAL`); the final chunk is always
/// emitted via the plugin's `on_finish` callback regardless of the
/// throttle, so the UI never gets stuck short of the real end state. On
/// macOS/Linux, `app.restart()` relaunches the (now-replaced) binary; on
/// Windows the plugin's own installer exits the process first, so
/// `restart()` is unreachable there — no platform guard is needed,
/// `restart()`'s `!` return type makes that structurally true either way.
pub async fn install(app: &AppHandle) -> Result<(), String> {
    let pending = {
        let runtime = app.state::<UpdateRuntime>();
        let inner = runtime
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        inner.pending.clone()
    };
    let Some(update) = pending else {
        return Err("No verified update is ready to install.".to_string());
    };

    let (begin_result, status_after_begin) = apply_and_broadcast(app, begin_download);
    if begin_result.is_err() {
        let message = match status_after_begin.phase {
            UpdatePhase::Downloading => "An update is already being installed.",
            _ => "A check is currently in progress. Try again once it finishes.",
        };
        return Err(message.to_string());
    }

    let tally = Arc::new(Mutex::new((0u64, None::<u64>)));
    let last_emit = Arc::new(Mutex::new(
        Instant::now()
            .checked_sub(PROGRESS_EMIT_INTERVAL)
            .unwrap_or_else(Instant::now),
    ));

    let on_chunk = {
        let tally = tally.clone();
        let last_emit = last_emit.clone();
        let app = app.clone();
        move |chunk_len: usize, total: Option<u64>| {
            let (downloaded, total) = {
                let mut t = tally.lock().unwrap_or_else(|p| p.into_inner());
                t.0 = t.0.saturating_add(chunk_len as u64);
                if total.is_some() {
                    t.1 = total;
                }
                *t
            };
            let now = Instant::now();
            let mut last = last_emit.lock().unwrap_or_else(|p| p.into_inner());
            if now.duration_since(*last) >= PROGRESS_EMIT_INTERVAL {
                *last = now;
                apply_and_broadcast(&app, |inner| set_progress(inner, downloaded, total));
            }
        }
    };

    let on_finish = {
        let tally = tally.clone();
        let app = app.clone();
        move || {
            let (downloaded, total) = *tally.lock().unwrap_or_else(|p| p.into_inner());
            apply_and_broadcast(&app, |inner| set_progress(inner, downloaded, total));
        }
    };

    match update.download_and_install(on_chunk, on_finish).await {
        Ok(()) => {
            app.restart();
        }
        Err(err) => {
            apply_and_broadcast(app, |inner| fail_download(inner, err.to_string()));
            Err(err.to_string())
        }
    }
}

/// Opens the currently-available release's page in the browser via
/// `tauri-plugin-opener`. Errors (rather than silently no-oping) when
/// nothing is available — the frontend only shows the button when
/// `UpdateStatus::available` is `Some`, so reaching here otherwise means a
/// stale UI, worth surfacing.
pub fn open_release_page(app: &AppHandle) -> Result<(), String> {
    let runtime = app.state::<UpdateRuntime>();
    let url = {
        let inner = runtime
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        inner
            .status
            .available
            .as_ref()
            .map(|available| available.release_url.clone())
    };
    let Some(url) = url else {
        return Err("No update is currently available.".to_string());
    };
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|err| err.to_string())
}

/// `set_settings`'s side effect when `update_channel` changed — see
/// `reset_for_channel`'s doc comment.
pub fn reset_for_channel_change(app: &AppHandle, channel: UpdateChannel) {
    apply_and_broadcast(app, |inner| reset_for_channel(inner, channel));
}

/// The tray "Check for Updates…" entry's handler: shows Settings on the
/// Updates tab, then — only if nothing is already known or in progress —
/// starts a check. Shared between `lib.rs`'s menu-event match and any
/// future caller, so the "don't stomp an available/downloading phase" rule
/// lives in exactly one place.
pub fn handle_tray_click(app: &AppHandle) {
    crate::show_settings(app);
    let _ = app.emit_to(SETTINGS_WINDOW_LABEL, SETTINGS_SHOW_TAB_EVENT, "updates");

    let phase = get_status(app).phase;
    if !matches!(phase, UpdatePhase::Available | UpdatePhase::Downloading) {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            run_check(&app).await;
        });
    }
}

/// The app's first app-lifetime background task (every other background
/// job — the popover drag watchdog, the portal shortcut listener — is
/// on-demand and exits once its one job is done). A `loop` is the right
/// shape here specifically because there is no natural end: as long as
/// Kallilex runs, *something* should periodically ask "is a check due?", so
/// the task holds only a cloned `AppHandle` and outlives every window; it
/// exits only when the process does.
///
/// Waits `SCHEDULER_STARTUP_DELAY` before its first check (`Tick::Startup`)
/// so launch, Wayland portal binding, and onboarding have a chance to
/// settle, then re-evaluates every `SCHEDULER_PERIOD` (`Tick::Periodic`).
/// Each tick reads `Settings` and `UpdateCheckState` fresh rather than
/// caching them, so a frequency change the user makes while the app is
/// running takes effect on the very next tick with no extra plumbing.
pub fn spawn_scheduler(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(SCHEDULER_STARTUP_DELAY).await;
        scheduled_check(&app, Tick::Startup).await;
        loop {
            tokio::time::sleep(SCHEDULER_PERIOD).await;
            scheduled_check(&app, Tick::Periodic).await;
        }
    });
}

/// One scheduler tick: due-or-not is decided fresh from persisted state
/// every time (see `spawn_scheduler`'s doc comment), and a settings-load
/// failure is swallowed exactly like every other `setup`-adjacent step in
/// `lib.rs` — a broken check must never surface a dialog. The status the UI
/// would show is still updated by `run_check` itself when a check does run,
/// so opening Settings later shows the last real outcome.
async fn scheduled_check(app: &AppHandle, tick: Tick) {
    let settings_store = TauriStoreSettings::new(app.clone());
    let Ok(current_settings) = settings::get_settings(&settings_store) else {
        return;
    };

    let update_state_store = TauriUpdateStateStore::new(app.clone());
    let last_check_at = update_state_store
        .load()
        .map(|state| state.last_check_at)
        .unwrap_or(None);

    let now = now_secs();
    if updates::is_check_due(
        current_settings.update_check_frequency,
        last_check_at,
        now,
        tick,
    ) {
        run_check(app).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::updates::state::InMemoryUpdateStateStore;

    // `u8` stands in for `tauri_plugin_updater::Update`, which can't be
    // constructed in tests: it lets `pending` genuinely hold `Some` value so
    // the "clears pending" assertions below prove something.
    fn inner() -> Inner<u8> {
        Inner::new("0.5.0".to_string(), UpdateChannel::Stable)
    }

    fn available(version: &str, installable: bool) -> AvailableUpdate {
        AvailableUpdate {
            version: version.to_string(),
            tag: format!("v{version}"),
            release_url: format!("https://github.com/LStoneyy/kallilex/releases/tag/v{version}"),
            notes: None,
            published_at: None,
            installable,
        }
    }

    // --- install_supported ---------------------------------------------

    #[test]
    fn install_supported_debug_build_is_always_false() {
        use tauri::utils::config::BundleType;
        for bundle in [
            None,
            Some(BundleType::AppImage),
            Some(BundleType::App),
            Some(BundleType::Nsis),
            Some(BundleType::Deb),
            Some(BundleType::Rpm),
        ] {
            assert!(!install_supported(bundle.clone(), true), "{bundle:?}");
        }
    }

    #[test]
    fn install_supported_linux_appimage_is_true() {
        use tauri::utils::config::BundleType;
        assert!(install_supported(Some(BundleType::AppImage), false));
    }

    #[test]
    fn install_supported_linux_deb_rpm_and_none_are_false() {
        use tauri::utils::config::BundleType;
        assert!(!install_supported(Some(BundleType::Deb), false));
        assert!(!install_supported(Some(BundleType::Rpm), false));
        assert!(!install_supported(None, false));
    }

    #[test]
    fn install_supported_macos_app_is_true() {
        use tauri::utils::config::BundleType;
        assert!(install_supported(Some(BundleType::App), false));
    }

    #[test]
    fn install_supported_windows_nsis_is_true() {
        use tauri::utils::config::BundleType;
        assert!(install_supported(Some(BundleType::Nsis), false));
    }

    // --- state machine ----------------------------------------------------

    #[test]
    fn checking_to_up_to_date() {
        let mut state = inner();
        let (label, _generation) = begin_check(&mut state).unwrap();
        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::Checking);
        assert!(state.check_in_flight);

        let label = finish_up_to_date(&mut state);
        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::UpToDate);
        assert!(state.status.available.is_none());
        assert!(!state.check_in_flight);
    }

    #[test]
    fn checking_to_available_installable_to_downloading_to_error_clears_pending() {
        let mut state = inner();
        begin_check(&mut state).unwrap();

        let label = finish_available(&mut state, available("0.6.0", true), Some(1));
        assert_eq!(label, "Update to v0.6.0 available…");
        assert_eq!(state.status.phase, UpdatePhase::Available);
        assert!(!state.check_in_flight);
        assert!(state.pending.is_some());

        // The named-version label is specific to the `Available` phase (see
        // `tray_label`'s doc comment) — once downloading starts, the tray
        // reverts to the static label.
        let label = begin_download(&mut state).unwrap();
        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::Downloading);
        assert!(state.install_in_flight);

        let label = fail_download(&mut state, "boom".to_string());
        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::Error);
        assert_eq!(state.status.error.as_deref(), Some("boom"));
        assert!(state.pending.is_none());
        assert!(!state.install_in_flight);
    }

    #[test]
    fn channel_change_resets_to_idle_and_clears_available_and_pending() {
        let mut state = inner();
        begin_check(&mut state).unwrap();
        finish_available(&mut state, available("0.6.0", true), Some(1));

        let label = reset_for_channel(&mut state, UpdateChannel::Preview);
        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::Idle);
        assert_eq!(state.status.channel, UpdateChannel::Preview);
        assert!(state.status.available.is_none());
        assert!(state.pending.is_none());
    }

    #[test]
    fn a_second_check_while_one_is_in_flight_returns_the_current_status_unchanged() {
        let mut state = inner();
        begin_check(&mut state).unwrap();

        let guarded = begin_check(&mut state);
        assert_eq!(guarded, Err(state.status.clone()));
        assert_eq!(state.status.phase, UpdatePhase::Checking);
    }

    #[test]
    fn tray_label_is_static_outside_the_available_phase() {
        let mut state = inner();
        assert_eq!(tray_label(&state), TRAY_LABEL_STATIC);
        begin_check(&mut state).unwrap();
        assert_eq!(tray_label(&state), TRAY_LABEL_STATIC);
        finish_up_to_date(&mut state);
        assert_eq!(tray_label(&state), TRAY_LABEL_STATIC);
    }

    #[test]
    fn tray_label_names_the_version_in_the_available_phase() {
        let mut state = inner();
        finish_available(&mut state, available("0.7.0", true), None);
        assert_eq!(tray_label(&state), "Update to v0.7.0 available…");
    }

    // --- channel-change / in-flight-check race (generation) ---------------

    #[test]
    fn a_stale_check_completion_after_a_channel_change_is_discarded() {
        let mut state = inner();
        let (_, started_generation) = begin_check(&mut state).unwrap();

        // The channel changes while the check above is still in flight.
        reset_for_channel(&mut state, UpdateChannel::Preview);

        // The old check now completes, still carrying its original
        // generation: it must not resurrect the old channel's release.
        let label = complete_check(&mut state, started_generation, |inner| {
            finish_available(inner, available("0.6.0", true), Some(1))
        });

        assert_eq!(label, TRAY_LABEL_STATIC);
        assert_eq!(state.status.phase, UpdatePhase::Idle);
        assert_eq!(state.status.channel, UpdateChannel::Preview);
        assert!(state.status.available.is_none());
        assert!(state.pending.is_none());
        assert!(!state.check_in_flight);
    }

    #[test]
    fn a_current_check_completion_still_applies_normally() {
        let mut state = inner();
        let (_, started_generation) = begin_check(&mut state).unwrap();

        let label = complete_check(&mut state, started_generation, |inner| {
            finish_available(inner, available("0.6.0", true), Some(1))
        });

        assert_eq!(label, "Update to v0.6.0 available…");
        assert_eq!(state.status.phase, UpdatePhase::Available);
        assert!(state.pending.is_some());
        assert!(!state.check_in_flight);
    }

    // --- install exclusivity -----------------------------------------------

    #[test]
    fn a_second_install_while_one_is_in_flight_is_refused_and_state_is_unchanged() {
        let mut state = inner();
        state.pending = Some(1);
        begin_download(&mut state).unwrap();
        let status_before = state.status.clone();

        let guarded = begin_download(&mut state);
        assert_eq!(guarded, Err(status_before.clone()));
        assert_eq!(state.status, status_before);
        assert!(state.install_in_flight);
    }

    #[test]
    fn a_check_while_installing_is_refused() {
        let mut state = inner();
        state.pending = Some(1);
        begin_download(&mut state).unwrap();

        let guarded = begin_check(&mut state);
        assert_eq!(guarded, Err(state.status.clone()));
        assert_eq!(state.status.phase, UpdatePhase::Downloading);
        assert!(!state.check_in_flight);
    }

    #[test]
    fn an_install_while_checking_is_refused() {
        let mut state = inner();
        begin_check(&mut state).unwrap();

        let guarded = begin_download(&mut state);
        assert_eq!(guarded, Err(state.status.clone()));
        assert_eq!(state.status.phase, UpdatePhase::Checking);
        assert!(!state.install_in_flight);
    }

    #[test]
    fn set_progress_outside_downloading_is_a_no_op() {
        let mut state = inner();
        assert_eq!(state.status.phase, UpdatePhase::Idle);
        set_progress(&mut state, 42, Some(100));
        assert!(state.status.progress.is_none());

        begin_check(&mut state).unwrap();
        set_progress(&mut state, 42, Some(100));
        assert!(state.status.progress.is_none());
        assert_eq!(state.status.phase, UpdatePhase::Checking);
    }

    // --- last_check_at bookkeeping ------------------------------------

    #[test]
    fn record_check_outcome_writes_last_check_at_on_success() {
        let store = InMemoryUpdateStateStore::new();
        record_check_outcome(&store, true, 1_700_000_000).unwrap();
        assert_eq!(store.load().unwrap().last_check_at, Some(1_700_000_000));
    }

    #[test]
    fn record_check_outcome_does_not_write_on_failure() {
        let store = InMemoryUpdateStateStore::new();
        record_check_outcome(&store, false, 1_700_000_000).unwrap();
        assert_eq!(store.load().unwrap().last_check_at, None);
    }
}
