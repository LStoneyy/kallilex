use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

use super::{Settings, SettingsError, SettingsStore};

const STORE_FILE: &str = "settings.json";
const SETTINGS_KEY: &str = "settings";

/// [`SettingsStore`] implementation backed by `tauri-plugin-store`,
/// persisting to `settings.json` in the app's config/data directory.
pub struct TauriStoreSettings {
    app: AppHandle,
}

impl TauriStoreSettings {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl SettingsStore for TauriStoreSettings {
    fn load(&self) -> Result<Settings, SettingsError> {
        let store = self
            .app
            .store(STORE_FILE)
            .map_err(|e| SettingsError::Load(e.to_string()))?;

        match store.get(SETTINGS_KEY) {
            Some(value) => serde_json::from_value(value).map_err(|e| SettingsError::Load(e.to_string())),
            None => Ok(Settings::default()),
        }
    }

    fn save(&self, settings: &Settings) -> Result<(), SettingsError> {
        let store = self
            .app
            .store(STORE_FILE)
            .map_err(|e| SettingsError::Save(e.to_string()))?;

        let value = serde_json::to_value(settings).map_err(|e| SettingsError::Save(e.to_string()))?;
        store.set(SETTINGS_KEY, value);
        store.save().map_err(|e| SettingsError::Save(e.to_string()))?;
        Ok(())
    }
}
