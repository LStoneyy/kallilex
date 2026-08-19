use std::sync::Mutex;

use super::{Settings, SettingsError, SettingsStore};

/// In-memory [`SettingsStore`] fake used in unit tests.
pub struct InMemorySettingsStore {
    state: Mutex<Option<Settings>>,
}

impl InMemorySettingsStore {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(None),
        }
    }
}

impl Default for InMemorySettingsStore {
    fn default() -> Self {
        Self::new()
    }
}

impl SettingsStore for InMemorySettingsStore {
    fn load(&self) -> Result<Settings, SettingsError> {
        let state = self
            .state
            .lock()
            .map_err(|e| SettingsError::Load(e.to_string()))?;
        Ok(state.clone().unwrap_or_default())
    }

    fn save(&self, settings: &Settings) -> Result<(), SettingsError> {
        let mut state = self
            .state
            .lock()
            .map_err(|e| SettingsError::Save(e.to_string()))?;
        *state = Some(settings.clone());
        Ok(())
    }
}
