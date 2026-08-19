//! In-memory `SecretStore` fake used by unit tests. Never touches the real
//! macOS Keychain.

use std::collections::HashMap;
use std::sync::Mutex;

use super::{SecretStore, SecretsError};

/// Configurable `SecretStore` fake backed by a `HashMap`, with an optional
/// injected failure so tests can exercise the "secrets read fails, action
/// degrades to no key" path.
#[derive(Default)]
pub struct InMemorySecretStore {
    state: Mutex<HashMap<String, String>>,
    fail_get: Mutex<bool>,
}

impl InMemorySecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// After this call, every `get` returns `Err(SecretsError::Backend(_))`
    /// instead of looking up the in-memory map.
    pub fn fail_next_get(&self) {
        *self.fail_get.lock().unwrap() = true;
    }
}

impl SecretStore for InMemorySecretStore {
    fn get(&self, profile_id: &str) -> Result<Option<String>, SecretsError> {
        let mut fail_get = self.fail_get.lock().unwrap();
        if *fail_get {
            *fail_get = false;
            return Err(SecretsError::Backend(
                "simulated keychain failure".to_string(),
            ));
        }
        Ok(self.state.lock().unwrap().get(profile_id).cloned())
    }

    fn set(&self, profile_id: &str, secret: &str) -> Result<(), SecretsError> {
        self.state
            .lock()
            .unwrap()
            .insert(profile_id.to_string(), secret.to_string());
        Ok(())
    }

    fn delete(&self, profile_id: &str) -> Result<(), SecretsError> {
        self.state.lock().unwrap().remove(profile_id);
        Ok(())
    }
}
