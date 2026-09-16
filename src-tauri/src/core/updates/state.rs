//! Machine-local update-check bookkeeping: *when did Kallilex last check
//! GitHub for a new release*. Deliberately not part of
//! [`crate::core::settings::Settings`] — it isn't a preference, it's a
//! timestamp that changes every time a scheduled check runs, and keeping it
//! out of `Settings` keeps the Settings window's fetch-then-spread saves
//! and its round-trip tests untouched by something that changes daily.
//!
//! [`TauriUpdateStateStore`] is constructed by [`crate::core::updates::runtime`]
//! — the scheduler and the update commands' shared `run_check` — to read
//! and write the timestamp this module defines.

use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

use crate::core::settings::STORE_FILE;

/// Key [`TauriUpdateStateStore`] writes this value under, in the same
/// `settings.json` store file [`crate::core::settings::TauriStoreSettings`]
/// uses — reusing that file rather than opening a second one.
const UPDATE_STATE_KEY: &str = "updateState";

/// When Kallilex last checked GitHub for a new release, in seconds since
/// the Unix epoch. Epoch seconds rather than a date type: no new time
/// dependency, and the only consumers are due-check arithmetic and a UI
/// label.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheckState {
    #[serde(default)]
    pub last_check_at: Option<u64>,
}

/// Persistence seam for [`UpdateCheckState`], mirroring
/// [`crate::core::settings::SettingsStore`]'s shape.
pub trait UpdateStateStore: Send + Sync {
    fn load(&self) -> Result<UpdateCheckState, String>;
    fn save(&self, state: &UpdateCheckState) -> Result<(), String>;
}

/// In-memory [`UpdateStateStore`] fake used in unit tests.
#[cfg(test)]
pub struct InMemoryUpdateStateStore {
    state: std::sync::Mutex<Option<UpdateCheckState>>,
}

#[cfg(test)]
impl InMemoryUpdateStateStore {
    pub fn new() -> Self {
        Self {
            state: std::sync::Mutex::new(None),
        }
    }
}

#[cfg(test)]
impl Default for InMemoryUpdateStateStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
impl UpdateStateStore for InMemoryUpdateStateStore {
    fn load(&self) -> Result<UpdateCheckState, String> {
        let state = self.state.lock().map_err(|e| e.to_string())?;
        Ok(state.unwrap_or_default())
    }

    fn save(&self, state: &UpdateCheckState) -> Result<(), String> {
        let mut guard = self.state.lock().map_err(|e| e.to_string())?;
        *guard = Some(*state);
        Ok(())
    }
}

/// [`UpdateStateStore`] implementation backed by `tauri-plugin-store`,
/// writing the `updateState` key into the same `settings.json` file
/// [`crate::core::settings::TauriStoreSettings`] uses.
pub struct TauriUpdateStateStore {
    app: AppHandle,
}

impl TauriUpdateStateStore {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl UpdateStateStore for TauriUpdateStateStore {
    fn load(&self) -> Result<UpdateCheckState, String> {
        let store = self.app.store(STORE_FILE).map_err(|e| e.to_string())?;

        match store.get(UPDATE_STATE_KEY) {
            Some(value) => serde_json::from_value(value).map_err(|e| e.to_string()),
            None => Ok(UpdateCheckState::default()),
        }
    }

    fn save(&self, state: &UpdateCheckState) -> Result<(), String> {
        let store = self.app.store(STORE_FILE).map_err(|e| e.to_string())?;

        let value = serde_json::to_value(state).map_err(|e| e.to_string())?;
        store.set(UPDATE_STATE_KEY, value);
        store.save().map_err(|e| e.to_string())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_state_loads_as_none() {
        let store = InMemoryUpdateStateStore::new();

        let state = store.load().expect("load should succeed");

        assert_eq!(
            state,
            UpdateCheckState {
                last_check_at: None
            }
        );
    }

    #[test]
    fn save_then_load_round_trips() {
        let store = InMemoryUpdateStateStore::new();
        let saved = UpdateCheckState {
            last_check_at: Some(1_700_000_000),
        };

        store.save(&saved).expect("save should succeed");
        let loaded = store.load().expect("load should succeed");

        assert_eq!(loaded, saved);
    }

    #[test]
    fn missing_update_state_key_deserializes_as_none() {
        let json = r#"{}"#;

        let state: UpdateCheckState = serde_json::from_str(json).expect("should deserialize");

        assert_eq!(state.last_check_at, None);
    }
}
