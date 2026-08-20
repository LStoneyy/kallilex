//! Application settings: the [`Settings`] value type, the [`SettingsStore`]
//! persistence seam, and pure functions that operate on it.
//!
//! The Tauri-backed implementation ([`TauriStoreSettings`]) lives behind the
//! `tauri_store` submodule so unit tests can exercise the pure logic against
//! [`InMemorySettingsStore`] without spinning up a Tauri runtime.

#[cfg(test)]
mod in_memory;
mod tauri_store;

#[cfg(test)]
pub use in_memory::InMemorySettingsStore;
pub use tauri_store::TauriStoreSettings;

use serde::{Deserialize, Serialize};

use crate::core::providers::ProviderProfile;

/// The platform's default global shortcut: ⌥⌘K on macOS, Ctrl+Alt+K
/// elsewhere.
pub fn default_shortcut() -> &'static str {
    if cfg!(target_os = "macos") {
        "Alt+Cmd+K"
    } else {
        "Ctrl+Alt+K"
    }
}

/// Persisted, non-secret user settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub active_profile_id: Option<String>,
    pub shortcut: String,
    pub spellcheck_enabled: bool,
    pub popover_pinned: bool,
    /// Whether the first-run Accessibility permission onboarding panel has
    /// already been shown. Defaults to `false` (and to `false` when absent
    /// from previously-persisted settings) so existing installs still see
    /// onboarding once after upgrading.
    #[serde(default)]
    pub accessibility_onboarding_shown: bool,
    /// AI provider profiles (spec-05). Defaults to empty (and to empty when
    /// absent from settings persisted before spec-05) so existing installs
    /// upgrade cleanly with no profiles configured.
    #[serde(default)]
    pub profiles: Vec<ProviderProfile>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            active_profile_id: None,
            shortcut: default_shortcut().to_string(),
            spellcheck_enabled: true,
            popover_pinned: false,
            accessibility_onboarding_shown: false,
            profiles: Vec::new(),
        }
    }
}

/// Errors surfaced by a [`SettingsStore`] implementation.
#[derive(Debug, thiserror::Error)]
pub enum SettingsError {
    #[error("failed to read settings: {0}")]
    Load(String),
    #[error("failed to write settings: {0}")]
    Save(String),
}

/// Persistence seam for [`Settings`]. Implementations may be backed by a
/// file-based store (production) or an in-memory fake (tests).
pub trait SettingsStore: Send + Sync {
    fn load(&self) -> Result<Settings, SettingsError>;
    fn save(&self, settings: &Settings) -> Result<(), SettingsError>;
}

/// Loads the current settings, falling back to [`Settings::default`] when
/// nothing has been persisted yet.
pub fn get_settings(store: &dyn SettingsStore) -> Result<Settings, SettingsError> {
    store.load()
}

/// Persists `settings` and returns it back to the caller.
pub fn set_settings(
    store: &dyn SettingsStore,
    settings: Settings,
) -> Result<Settings, SettingsError> {
    store.save(&settings)?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_returned_when_nothing_is_stored() {
        let store = InMemorySettingsStore::new();

        let settings = get_settings(&store).expect("load should succeed");

        assert_eq!(settings, Settings::default());
    }

    #[test]
    fn save_then_load_round_trips_the_full_value() {
        let store = InMemorySettingsStore::new();
        let saved = Settings {
            active_profile_id: Some("profile-1".to_string()),
            shortcut: "Ctrl+Alt+K".to_string(),
            spellcheck_enabled: false,
            popover_pinned: true,
            accessibility_onboarding_shown: true,
            profiles: vec![crate::core::providers::ProviderProfile {
                id: "profile-1".to_string(),
                name: "My Profile".to_string(),
                base_url: "http://localhost:11434/v1".to_string(),
                model: "llama3".to_string(),
                timeout_secs: 30,
                custom_headers: vec![],
                enabled: true,
                has_api_key: false,
            }],
        };

        let returned = set_settings(&store, saved.clone()).expect("save should succeed");
        let loaded = get_settings(&store).expect("load should succeed");

        assert_eq!(returned, saved);
        assert_eq!(loaded, saved);
    }

    #[test]
    fn each_field_is_persisted_independently() {
        let store = InMemorySettingsStore::new();

        let base = Settings::default();
        set_settings(&store, base.clone()).unwrap();
        assert_eq!(get_settings(&store).unwrap().active_profile_id, None);

        let with_profile = Settings {
            active_profile_id: Some("abc".to_string()),
            ..base.clone()
        };
        set_settings(&store, with_profile.clone()).unwrap();
        assert_eq!(
            get_settings(&store).unwrap().active_profile_id,
            Some("abc".to_string())
        );

        let with_shortcut = Settings {
            shortcut: "Cmd+Shift+K".to_string(),
            ..with_profile.clone()
        };
        set_settings(&store, with_shortcut.clone()).unwrap();
        assert_eq!(get_settings(&store).unwrap().shortcut, "Cmd+Shift+K");

        let with_spellcheck = Settings {
            spellcheck_enabled: false,
            ..with_shortcut.clone()
        };
        set_settings(&store, with_spellcheck.clone()).unwrap();
        assert!(!get_settings(&store).unwrap().spellcheck_enabled);

        let with_pinned = Settings {
            popover_pinned: true,
            ..with_spellcheck.clone()
        };
        set_settings(&store, with_pinned.clone()).unwrap();
        assert!(get_settings(&store).unwrap().popover_pinned);

        let with_onboarding_shown = Settings {
            accessibility_onboarding_shown: true,
            ..with_pinned.clone()
        };
        set_settings(&store, with_onboarding_shown.clone()).unwrap();
        assert!(get_settings(&store).unwrap().accessibility_onboarding_shown);
    }

    #[test]
    fn pre_spec_05_persisted_json_without_profiles_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        assert!(settings.profiles.is_empty());
    }

    #[test]
    fn default_shortcut_parses_as_a_global_shortcut_plugin_shortcut() {
        use std::str::FromStr;
        use tauri_plugin_global_shortcut::Shortcut;

        let shortcut = Shortcut::from_str(&Settings::default().shortcut);

        assert!(
            shortcut.is_ok(),
            "default shortcut string must parse via the global-shortcut plugin: {:?}",
            shortcut.err()
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn default_shortcut_is_the_macos_chord() {
        assert_eq!(default_shortcut(), "Alt+Cmd+K");
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn default_shortcut_is_the_non_macos_chord() {
        assert_eq!(default_shortcut(), "Ctrl+Alt+K");
    }
}
