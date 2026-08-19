//! Secret storage seam: API keys for provider profiles live in the macOS
//! Keychain, never in the plain-JSON settings store. [`ProviderProfile`]
//! only ever carries a `has_api_key` marker; the key itself is looked up
//! separately through this seam.

#[cfg(test)]
pub mod fakes;

/// Errors surfaced by a [`SecretStore`] implementation.
#[derive(Debug, thiserror::Error)]
pub enum SecretsError {
    #[error("keychain error: {0}")]
    Backend(String),
}

/// Persistence seam for per-profile API keys, keyed by provider profile id.
pub trait SecretStore: Send + Sync {
    fn get(&self, profile_id: &str) -> Result<Option<String>, SecretsError>;
    fn set(&self, profile_id: &str, secret: &str) -> Result<(), SecretsError>;
    fn delete(&self, profile_id: &str) -> Result<(), SecretsError>;
}

const SERVICE: &str = "com.xr-essential.kallilex";

/// [`SecretStore`] implementation backed by the macOS Keychain via the
/// `keyring` crate.
pub struct KeyringSecretStore;

impl KeyringSecretStore {
    fn entry(profile_id: &str) -> Result<keyring::Entry, SecretsError> {
        keyring::Entry::new(SERVICE, &format!("provider:{profile_id}"))
            .map_err(|e| SecretsError::Backend(e.to_string()))
    }
}

impl SecretStore for KeyringSecretStore {
    fn get(&self, profile_id: &str) -> Result<Option<String>, SecretsError> {
        let entry = Self::entry(profile_id)?;
        match entry.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(SecretsError::Backend(e.to_string())),
        }
    }

    fn set(&self, profile_id: &str, secret: &str) -> Result<(), SecretsError> {
        let entry = Self::entry(profile_id)?;
        entry
            .set_password(secret)
            .map_err(|e| SecretsError::Backend(e.to_string()))
    }

    fn delete(&self, profile_id: &str) -> Result<(), SecretsError> {
        let entry = Self::entry(profile_id)?;
        match entry.delete_credential() {
            Ok(()) => Ok(()),
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(SecretsError::Backend(e.to_string())),
        }
    }
}
