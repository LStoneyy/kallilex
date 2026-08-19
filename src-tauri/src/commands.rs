//! Thin Tauri command wrappers. Business logic lives in [`crate::core`];
//! these functions only adapt it to the `#[tauri::command]` calling
//! convention (extracting app state, mapping errors to `String`).

use tauri::{AppHandle, Manager};

use crate::core::capture::CaptureResult;
use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::CaptureState;

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
