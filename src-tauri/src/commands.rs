//! Thin Tauri command wrappers. Business logic lives in [`crate::core`];
//! these functions only adapt it to the `#[tauri::command]` calling
//! convention (extracting app state, mapping errors to `String`).

use tauri::{AppHandle, Manager};

use crate::core::capture::CaptureResult;
use crate::core::providers::openai::{self, OpenAiCompatibleAdapter};
use crate::core::providers::{
    self, Action, ActionContext, Preset, ProviderProfile, RunActionOutcome,
};
use crate::core::secrets::{KeyringSecretStore, SecretStore};
use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::core::spellcheck::SpellcheckResult;
use crate::platform::{self, PlatformInfo};
use crate::{ActionInFlight, CaptureState, ReplaceInFlight};

/// RAII guard clearing [`ReplaceInFlight`] on drop, so every exit path out
/// of `replace_back` — success, error, or an unexpected panic — releases the
/// guard the global-shortcut trigger checks. See `ReplaceInFlight`'s doc
/// comment in `lib.rs` for why this guard exists.
struct InFlightGuard<'a>(&'a ReplaceInFlight);

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        self.0 .0.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

#[tauri::command]
pub fn get_settings(app: AppHandle) -> Result<Settings, String> {
    let store = TauriStoreSettings::new(app);
    settings::get_settings(&store).map_err(|e| e.to_string())
}

/// Persists `settings`. When the shortcut string has changed, the new
/// shortcut is parsed *before* anything is saved (a parse failure aborts
/// the whole save, so a typo can never silently lose the rest of the
/// settings change); once saved, the old shortcut is unregistered and the
/// new one registered. Settings stay saved even if that registration step
/// fails — the popover and tray icon are fully usable without a working
/// global shortcut, and rolling the save back on a transient registration
/// error would just leave the user unable to retry the shortcut change.
///
/// When [`platform::use_portal_global_shortcut`] is true, the whole
/// parse/unregister/register dance (and its validation) is skipped: the
/// GlobalShortcuts portal, not the tauri plugin, owns the trigger there, and
/// the Settings UI shows the field read-only on that session. The shortcut
/// string is still persisted as-is — it remains the default the same
/// on-disk settings would use on an X11 session on the same machine.
#[tauri::command]
pub fn set_settings(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    use std::str::FromStr;
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

    let store = TauriStoreSettings::new(app.clone());
    let previous = settings::get_settings(&store).map_err(|e| e.to_string())?;

    let shortcut_changed =
        !platform::use_portal_global_shortcut() && settings.shortcut != previous.shortcut;
    let new_shortcut = if shortcut_changed {
        Some(Shortcut::from_str(&settings.shortcut).map_err(|e| {
            format!(
                "Kallilex couldn't understand the shortcut \"{}\": {e}",
                settings.shortcut
            )
        })?)
    } else {
        None
    };

    let saved = settings::set_settings(&store, settings).map_err(|e| e.to_string())?;

    if let Some(new_shortcut) = new_shortcut {
        if let Ok(old_shortcut) = Shortcut::from_str(&previous.shortcut) {
            let _ = app.global_shortcut().unregister(old_shortcut);
        }
        if let Err(err) = app.global_shortcut().register(new_shortcut) {
            return Err(format!(
                "Settings were saved, but the new shortcut could not be registered: {err}"
            ));
        }
    }

    Ok(saved)
}

/// The GlobalShortcuts portal-reported human-readable trigger for the
/// "capture" shortcut (spec-12 Slice B), or `None` when unbound — the portal
/// declined/hasn't confirmed a bind, or this isn't a portal-managed session
/// at all (the state is `manage`d unconditionally but only ever written to
/// from the portal task). Used by the Settings window's General tab to show
/// the shortcut read-only on sessions where `platform::use_portal_global_shortcut()`
/// is true.
#[tauri::command]
pub fn get_wayland_shortcut_trigger(app: AppHandle) -> Result<Option<String>, String> {
    let state = app.state::<platform::PortalShortcutTrigger>();
    let trigger = state
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Ok(trigger.clone())
}

/// Hides the popover, restoring any pending clipboard backup and clearing
/// the stored capture (cancel: Escape, or closing without an action).
#[tauri::command]
pub fn hide_popover(app: AppHandle) -> Result<(), String> {
    crate::hide_popover(&app);
    Ok(())
}

/// Returns the most recently captured selection (populated by the global
/// shortcut's trigger flow), or an empty result if the popover was opened
/// without a capture (e.g. a tray click).
#[tauri::command]
pub fn capture_selection(app: AppHandle) -> Result<CaptureResult, String> {
    let state = app.state::<CaptureState>();
    let captured = state
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    Ok(captured.clone().unwrap_or_else(CaptureResult::empty))
}

/// Whether Kallilex currently holds the platform's capture permission
/// (macOS Accessibility). Always `true` on platforms with no grantable
/// permission (Linux).
#[tauri::command]
pub fn accessibility_status() -> Result<bool, String> {
    use crate::core::capture::SelectionBackend;
    Ok(platform::selection_backend().permission_granted())
}

/// Deep-links into System Settings -> Privacy & Security -> Accessibility
/// (macOS). A no-op on platforms with no grantable permission (Linux).
#[tauri::command]
pub fn open_accessibility_settings() -> Result<(), String> {
    platform::open_permission_settings()
}

/// Runs a local, offline spell check over `text` via the platform
/// `SpellChecker` (macOS: `NSSpellChecker`, marshalled to the main thread).
/// `async` so the blocking wait for that main-thread round trip runs on the
/// async runtime rather than on Tauri's own main thread — which is exactly
/// the thread the check itself needs to marshal onto, so running this
/// synchronously would deadlock.
#[tauri::command]
pub async fn spellcheck(app: AppHandle, text: String) -> Result<SpellcheckResult, String> {
    use crate::core::spellcheck::run_spellcheck;

    let checker = platform::spell_checker(app);
    run_spellcheck(&checker, &text).map_err(|e| e.to_string())
}

/// Writes `text` back into the remembered source app: clipboard backup ->
/// write the result -> focus the source app by pid -> synthetic ⌘V -> settle
/// -> restore the backup. See [`crate::core::replace::replace_back`] for the
/// full orchestration and its race-guard/fallback-coordination rules.
/// `async` for the same reason as `spellcheck` — the settle delays must not
/// block the main thread.
#[tauri::command]
pub async fn replace_back(app: AppHandle, text: String) -> Result<(), String> {
    use crate::core::clipboard::BackupLifecycle;
    use crate::core::replace::{self, StdSleeper};

    let source_app = {
        let state = app.state::<CaptureState>();
        let captured = state
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        captured
            .as_ref()
            .and_then(|result| result.source_app.clone())
    };

    let clipboard = platform::clipboard();
    let keyboard = platform::keyboard();
    let activator = platform::app_activator(app.clone());
    let lifecycle = app.state::<BackupLifecycle>();
    let sleeper = StdSleeper;

    // Guard against a global-shortcut capture racing this in-flight
    // replace (see `ReplaceInFlight`'s doc comment in lib.rs). The guard
    // clears the flag on every exit path, including an unexpected panic.
    let in_flight = app.state::<ReplaceInFlight>();
    in_flight.0.store(true, std::sync::atomic::Ordering::SeqCst);
    let _guard = InFlightGuard(in_flight.inner());

    let result = replace::replace_back(
        &text,
        source_app.as_ref(),
        &clipboard,
        &keyboard,
        &activator,
        &lifecycle,
        &sleeper,
    );

    if let Err(ref err) = result {
        // Activating the source app (a step that can succeed even when a
        // later step, e.g. the synthetic paste, fails) steals focus from
        // the popover, which blurs and hides it. The frontend's inline
        // `actionError` would then render into an invisible, hidden
        // webview and the user would never learn the replace failed — so
        // when that's happened, surface the error via a dialog instead.
        let popover_visible = app
            .get_webview_window(crate::core::POPOVER_WINDOW_LABEL)
            .map(|window| window.is_visible().unwrap_or(false))
            .unwrap_or(false);
        if !popover_visible {
            crate::show_error_dialog(&app, format!("Replace failed: {err}"));
        }
    }

    result
}

/// Copies `text` to the clipboard (overwriting it, no restore) and discards
/// any pending fallback backup so the result stays on the clipboard even
/// after the popover's close/cancel path runs.
#[tauri::command]
pub fn copy_result(app: AppHandle, text: String) -> Result<(), String> {
    use crate::core::clipboard::BackupLifecycle;
    use crate::core::replace;

    let clipboard = platform::clipboard();
    let lifecycle = app.state::<BackupLifecycle>();
    replace::copy_result(&text, &clipboard, &lifecycle)
}

/// Platform metadata for the frontend: OS, display-server session,
/// feature availability (Replace, permission model), and the default
/// global shortcut for UI labels/placeholders.
#[tauri::command]
pub fn get_platform_info() -> Result<PlatformInfo, String> {
    Ok(platform::platform_info())
}

/// Runs an AI action (Rewrite/Shorten/ImproveClarity/Custom) against the
/// active provider profile. `async` so the request itself, and the
/// `tokio::select!` race against a cancel, run on the async runtime.
///
/// At most one action runs at a time: starting a new one replaces the
/// stored cancel sender in [`ActionInFlight`], which drops (and thereby
/// cancels, via the sender's `Drop` firing the receiver) whatever request
/// was previously in flight — exactly as an explicit `cancel_action` call
/// would. See [`ActionInFlight`]'s doc comment for the generation-counter
/// race guard this relies on.
#[tauri::command]
pub async fn run_action(
    app: AppHandle,
    text: String,
    action: Action,
) -> Result<RunActionOutcome, String> {
    let store = TauriStoreSettings::new(app.clone());
    let current_settings = settings::get_settings(&store).map_err(|e| e.to_string())?;
    let active = providers::active_profile(
        &current_settings.profiles,
        current_settings.active_profile_id.as_deref(),
    );

    let secrets = KeyringSecretStore;
    let adapter = OpenAiCompatibleAdapter;

    let in_flight = app.state::<ActionInFlight>();
    let (mut cancel_rx, generation) = in_flight.begin();

    let outcome = tokio::select! {
        outcome = providers::run_action(active, &secrets, &adapter, &text, &action) => outcome,
        _ = &mut cancel_rx => RunActionOutcome::Cancelled,
    };

    in_flight.clear(generation);

    Ok(outcome)
}

/// Cancels the currently in-flight `run_action` call, if any. A no-op
/// (never an error) when nothing is in flight, or the request just
/// finished on its own — the send failing in that race is expected and
/// harmless.
#[tauri::command]
pub fn cancel_action(app: AppHandle) -> Result<(), String> {
    let in_flight = app.state::<ActionInFlight>();
    in_flight.cancel();
    Ok(())
}

/// Summary of the active profile (if any) for the popover's AI actions
/// panel: whether an action can even be attempted, and — if so — which
/// profile and what privacy class its endpoint falls into.
#[tauri::command]
pub fn get_action_context(app: AppHandle) -> Result<ActionContext, String> {
    let store = TauriStoreSettings::new(app);
    let current_settings = settings::get_settings(&store).map_err(|e| e.to_string())?;
    Ok(providers::action_context(
        &current_settings.profiles,
        current_settings.active_profile_id.as_deref(),
    ))
}

#[tauri::command]
pub fn list_profiles(app: AppHandle) -> Result<Vec<ProviderProfile>, String> {
    let store = TauriStoreSettings::new(app);
    providers::list_profiles_core(&store).map_err(|e| e.to_string())
}

/// Creates or updates a provider profile; see
/// [`providers::save_profile_core`] for the id-generation, upsert, and API
/// key handling rules.
#[tauri::command]
pub fn save_profile(
    app: AppHandle,
    profile: ProviderProfile,
    api_key: Option<String>,
) -> Result<Vec<ProviderProfile>, String> {
    let store = TauriStoreSettings::new(app);
    let secrets = KeyringSecretStore;
    providers::save_profile_core(&store, &secrets, profile, api_key).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn delete_profile(app: AppHandle, id: String) -> Result<Vec<ProviderProfile>, String> {
    let store = TauriStoreSettings::new(app);
    let secrets = KeyringSecretStore;
    providers::delete_profile_core(&store, &secrets, &id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn set_active_profile(app: AppHandle, id: Option<String>) -> Result<(), String> {
    let store = TauriStoreSettings::new(app);
    providers::set_active_profile_core(&store, id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_presets() -> Result<Vec<Preset>, String> {
    Ok(providers::presets())
}

/// Shows (and focuses) the settings window. Used by the popover's
/// "no provider configured" hint so the user can jump straight to Settings
/// -> Providers without hunting for the tray menu.
#[tauri::command]
pub fn open_settings(app: AppHandle) -> Result<(), String> {
    crate::show_settings(&app);
    Ok(())
}

/// Sends a minimal request to the profile's endpoint and returns the
/// round-trip latency in milliseconds, or the same `ProviderError` message
/// a real action against this profile would surface.
#[tauri::command]
pub async fn test_connection(app: AppHandle, id: String) -> Result<u128, String> {
    let store = TauriStoreSettings::new(app);
    let current_settings = settings::get_settings(&store).map_err(|e| e.to_string())?;
    let profile = current_settings
        .profiles
        .into_iter()
        .find(|p| p.id == id)
        .ok_or_else(|| format!("No profile with id \"{id}\"."))?;

    let secrets = KeyringSecretStore;
    let api_key = if profile.has_api_key {
        secrets.get(&profile.id).map_err(|e| e.to_string())?
    } else {
        None
    };

    openai::test_connection(&profile, api_key.as_deref())
        .await
        .map_err(|e| e.to_string())
}
