//! Thin Tauri command wrappers. Business logic lives in [`crate::core`];
//! these functions only adapt it to the `#[tauri::command]` calling
//! convention (extracting app state, mapping errors to `String`).

use tauri::{AppHandle, Manager};

use crate::core::capture::CaptureResult;
use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::core::spellcheck::SpellcheckResult;
use crate::{CaptureState, ReplaceInFlight};

/// RAII guard clearing [`ReplaceInFlight`] on drop, so every exit path out
/// of `replace_back` — success, error, or an unexpected panic — releases the
/// guard the global-shortcut trigger checks. See `ReplaceInFlight`'s doc
/// comment in `lib.rs` for why this guard exists.
#[cfg(target_os = "macos")]
struct InFlightGuard<'a>(&'a ReplaceInFlight);

#[cfg(target_os = "macos")]
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

#[tauri::command]
pub fn set_settings(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    let store = TauriStoreSettings::new(app);
    settings::set_settings(&store, settings).map_err(|e| e.to_string())
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

/// Whether Kallilex currently holds the macOS Accessibility permission.
#[tauri::command]
pub fn accessibility_status() -> Result<bool, String> {
    #[cfg(target_os = "macos")]
    {
        use crate::core::capture::SelectionBackend;
        Ok(crate::platform::MacosSelectionBackend.permission_granted())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(false)
    }
}

/// Deep-links into System Settings -> Privacy & Security -> Accessibility.
#[tauri::command]
pub fn open_accessibility_settings() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        crate::platform::open_accessibility_settings()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(())
    }
}

/// Runs a local, offline spell check over `text` via the platform
/// `SpellChecker` (macOS: `NSSpellChecker`, marshalled to the main thread).
/// `async` so the blocking wait for that main-thread round trip runs on the
/// async runtime rather than on Tauri's own main thread — which is exactly
/// the thread the check itself needs to marshal onto, so running this
/// synchronously would deadlock.
#[tauri::command]
pub async fn spellcheck(app: AppHandle, text: String) -> Result<SpellcheckResult, String> {
    #[cfg(target_os = "macos")]
    {
        use crate::core::spellcheck::run_spellcheck;
        use crate::platform::MacosSpellChecker;

        let checker = MacosSpellChecker::new(app);
        run_spellcheck(&checker, &text).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, text);
        Ok(SpellcheckResult::default())
    }
}

/// Writes `text` back into the remembered source app: clipboard backup ->
/// write the result -> focus the source app by pid -> synthetic ⌘V -> settle
/// -> restore the backup. See [`crate::core::replace::replace_back`] for the
/// full orchestration and its race-guard/fallback-coordination rules.
/// `async` for the same reason as `spellcheck` — the settle delays must not
/// block the main thread.
#[tauri::command]
pub async fn replace_back(app: AppHandle, text: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use crate::core::clipboard::BackupLifecycle;
        use crate::core::replace::{self, StdSleeper};
        use crate::platform::{MacosAppActivator, MacosClipboard, MacosKeyboard};

        let source_app = {
            let state = app.state::<CaptureState>();
            let captured = state
                .0
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            captured.as_ref().and_then(|result| result.source_app.clone())
        };

        let clipboard = MacosClipboard;
        let keyboard = MacosKeyboard;
        let activator = MacosAppActivator::new(app.clone());
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
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, text);
        Ok(())
    }
}

/// Copies `text` to the clipboard (overwriting it, no restore) and discards
/// any pending fallback backup so the result stays on the clipboard even
/// after the popover's close/cancel path runs.
#[tauri::command]
pub fn copy_result(app: AppHandle, text: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use crate::core::clipboard::BackupLifecycle;
        use crate::core::replace;
        use crate::platform::MacosClipboard;

        let clipboard = MacosClipboard;
        let lifecycle = app.state::<BackupLifecycle>();
        replace::copy_result(&text, &clipboard, &lifecycle)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, text);
        Ok(())
    }
}
