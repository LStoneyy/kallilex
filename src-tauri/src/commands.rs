//! Thin Tauri command wrappers. Business logic lives in [`crate::core`];
//! these functions only adapt it to the `#[tauri::command]` calling
//! convention (extracting app state, mapping errors to `String`).

use tauri::{AppHandle, Manager};

use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::core::POPOVER_WINDOW_LABEL;

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

#[tauri::command]
pub fn hide_popover(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}
