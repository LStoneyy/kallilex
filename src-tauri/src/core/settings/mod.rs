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
pub(crate) use tauri_store::STORE_FILE;

use serde::{Deserialize, Serialize};

use crate::core::prompts::CustomPrompt;
use crate::core::providers::ProviderProfile;
use crate::core::updates::{UpdateChannel, UpdateCheckFrequency};

/// The platform's default global shortcut: ⌥⌘K on macOS, Ctrl+Alt+K
/// elsewhere.
pub fn default_shortcut() -> &'static str {
    if cfg!(target_os = "macos") {
        "Alt+Cmd+K"
    } else {
        "Ctrl+Alt+K"
    }
}

/// A user-chosen popover position, in physical pixels — the origin the
/// popover's top-left corner was last dragged to. See
/// [`Settings::popover_position`] for when this is populated vs. `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PopoverPosition {
    pub x: i32,
    pub y: i32,
}

/// Persisted, non-secret user settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub active_profile_id: Option<String>,
    pub shortcut: String,
    pub spellcheck_enabled: bool,
    pub popover_pinned: bool,
    /// Legacy (pre-onboarding-feature) flag: whether the old first-run
    /// Settings-window prompt for the Accessibility permission had been
    /// shown. No longer written by anything — [`Settings::onboarding_completed`]
    /// is the current first-run signal — but it stays in the struct because
    /// `evaluate_onboarding` reads it as the migration signal that recognizes
    /// existing macOS installs as already set up (see `core::onboarding`).
    #[serde(default)]
    pub accessibility_onboarding_shown: bool,
    /// AI provider profiles. Defaults to empty (and to empty when
    /// absent from settings written before this field was introduced) so
    /// existing installs
    /// upgrade cleanly with no profiles configured.
    #[serde(default)]
    pub profiles: Vec<ProviderProfile>,
    /// An XDG `RemoteDesktop` portal *session restore token*, not
    /// a credential: storing it in the Tauri Store is correct because it
    /// only lets this app skip re-prompting the user for the
    /// input-synthesis permission on future launches, and the compositor
    /// can revoke it at any time (in which case the next session request
    /// simply re-prompts, same as never having had a token). Defaults to
    /// `None` (and to `None` when absent from settings written before this
    /// field was introduced) so existing installs upgrade cleanly with no
    /// stored token.
    #[serde(default)]
    pub wayland_restore_token: Option<String>,
    /// Whether Kallilex may synthesize keystrokes (Ctrl+C / Ctrl+V) through
    /// the Wayland `RemoteDesktop` portal. Defaults to
    /// `true` via [`default_input_synthesis_enabled`] rather than a bare
    /// `#[serde(default)]` (which would be `false` for a `bool`): settings
    /// written before this field was introduced have no opinion on it at
    /// all, and
    /// the correct reading of "no opinion" is "keep today's behavior" —
    /// Replace kept working before this setting existed, so it must keep
    /// working after upgrading, not silently disappear because a missing
    /// key defaulted to `false`. The flag is honored on Wayland sessions
    /// **only**: on macOS and X11, synthetic input needs no portal
    /// permission at all, so there is nothing to opt out of, and honoring
    /// it there would let a Wayland-era choice quietly degrade an X11
    /// session on the same machine (e.g. a laptop that runs both).
    #[serde(default = "default_input_synthesis_enabled")]
    pub input_synthesis_enabled: bool,
    /// Whether Kallilex puts the result on the clipboard as soon as it
    /// changes the text itself — a successful AI action or an applied
    /// spellcheck suggestion — so the copy-only flow needs no Copy click.
    /// Plain `#[serde(default)]` (`false`) is correct
    /// here, unlike [`Settings::input_synthesis_enabled`] above: this is a
    /// new opt-in convenience, so "no opinion persisted" must mean "nothing
    /// changes for anyone who didn't ask for it". Cross-platform: it has the
    /// same value on macOS, X11 and Wayland, unlike the Wayland-only
    /// opt-out above.
    #[serde(default)]
    pub auto_copy_result: bool,
    /// Whether the first-run onboarding window has been completed (or
    /// auto-completed for a recognizably-already-set-up install — see
    /// `core::onboarding::evaluate_onboarding`). Plain `#[serde(default)]`
    /// (`false`) is correct: settings persisted before this field existed
    /// belong to installs that never saw the onboarding window, so "no
    /// opinion persisted" must mean "still show it" — `evaluate_onboarding`
    /// then decides whether that's a real first run or a migration that
    /// auto-completes without ever showing the window.
    #[serde(default)]
    pub onboarding_completed: bool,
    /// The popover's user-dragged position (its window's top-left corner,
    /// in physical pixels), persisted after the popover is hidden following
    /// a drag. `None` means automatic positioning: `show_popover` anchors
    /// the popover at the cursor (see `platform::position_popover`) exactly
    /// as it always has, and `Some` means it reopens at this position
    /// instead, clamped back on-screen (see
    /// `platform::positioning::clamp_saved_position`) in case the monitor
    /// layout changed since it was saved. Plain `#[serde(default)]` (`None`)
    /// is correct: settings persisted before this field existed belong to
    /// installs that never moved the popover, so "no opinion persisted"
    /// must mean "keep positioning automatically". Inherently machine-local
    /// like `wayland_restore_token` above — a saved pixel position from one
    /// machine's monitor layout would be meaningless (or off-screen) on
    /// another — so, like that field, it is never round-tripped through any
    /// settings-export/sync feature if one is ever added.
    #[serde(default)]
    pub popover_position: Option<PopoverPosition>,
    /// User-managed AI prompts offered as buttons in the popover's action
    /// row. Defaults to the three prompts Kallilex used to bundle
    /// unconditionally (Rewrite / Shorten / Improve clarity) via the named
    /// [`crate::core::prompts::default_prompts`] rather than a bare
    /// `#[serde(default)]` (which would be an empty `Vec`): that same
    /// function is also this field's *value* default (see `impl Default for
    /// Settings` below), so the seeded list appears both for a fresh install
    /// and for a pre-existing settings.json written before this field
    /// existed — neither has "no opinion" about which prompts to offer, the
    /// way an install that never touched Wayland has "no opinion" about
    /// `wayland_restore_token`. A user who deletes every prompt via the
    /// Settings window's Prompts tab persists an explicit empty `Vec`,
    /// which then stays empty: only a *missing* key falls back to the
    /// seeded default, not an explicitly empty one.
    #[serde(default = "crate::core::prompts::default_prompts")]
    pub prompts: Vec<CustomPrompt>,
    /// Which GitHub release channel to check for updates against — see
    /// `core::updates` for the resolution logic. Defaults via
    /// [`crate::core::updates::default_update_channel`] rather than a bare
    /// `#[serde(default)]` (which would silently resolve to `Stable` for
    /// every existing install, including preview testers) because the
    /// correct default is build-dependent, not fixed: a build whose own
    /// version carries a semver pre-release suffix (`0.6.0-beta.1`)
    /// defaults to `Preview` so a tester who installed one keeps following
    /// pre-releases with no setup, while a build without one defaults to
    /// `Stable` so a pre-release never lands on a regular install by
    /// surprise. Settings persisted before this field existed have no
    /// opinion on it, and "no opinion" must read as "keep following
    /// whatever channel this build's own version implies" — see
    /// [`crate::core::updates::channel_for_build_version`]. A persisted
    /// choice always wins once one exists; this default only fires while
    /// none does.
    #[serde(default = "crate::core::updates::default_update_channel")]
    pub update_channel: UpdateChannel,
    /// How often Kallilex looks for updates: never, at launch, daily or
    /// weekly — see `core::updates::is_check_due`. Plain `#[serde(default)]`
    /// is correct here, unlike [`Settings::update_channel`] above:
    /// [`UpdateCheckFrequency`]'s `Default` impl is `Daily`, and there is no
    /// build-dependent signal for *how often* to check the way there is for
    /// *which channel* — every install, new or upgraded from settings
    /// persisted before this field existed, gets the same sensible default
    /// until it says otherwise.
    #[serde(default)]
    pub update_check_frequency: UpdateCheckFrequency,
}

/// See [`Settings::input_synthesis_enabled`]'s doc comment for why this is a
/// named helper rather than bare `#[serde(default)]`.
fn default_input_synthesis_enabled() -> bool {
    true
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
            wayland_restore_token: None,
            input_synthesis_enabled: true,
            auto_copy_result: false,
            onboarding_completed: false,
            popover_position: None,
            prompts: crate::core::prompts::default_prompts(),
            update_channel: crate::core::updates::default_update_channel(),
            update_check_frequency: UpdateCheckFrequency::default(),
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
            wayland_restore_token: Some("restore-token-abc".to_string()),
            input_synthesis_enabled: false,
            auto_copy_result: true,
            onboarding_completed: true,
            popover_position: Some(PopoverPosition { x: 120, y: 340 }),
            prompts: vec![crate::core::prompts::CustomPrompt {
                id: "prompt-1".to_string(),
                label: "Translate".to_string(),
                instruction: "Translate to French".to_string(),
            }],
            update_channel: crate::core::updates::UpdateChannel::Preview,
            update_check_frequency: crate::core::updates::UpdateCheckFrequency::Weekly,
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

        let with_restore_token = Settings {
            wayland_restore_token: Some("token-xyz".to_string()),
            ..with_onboarding_shown.clone()
        };
        set_settings(&store, with_restore_token.clone()).unwrap();
        assert_eq!(
            get_settings(&store).unwrap().wayland_restore_token,
            Some("token-xyz".to_string())
        );

        let with_input_synthesis_disabled = Settings {
            input_synthesis_enabled: false,
            ..with_restore_token.clone()
        };
        set_settings(&store, with_input_synthesis_disabled.clone()).unwrap();
        assert!(!get_settings(&store).unwrap().input_synthesis_enabled);

        let with_auto_copy_result = Settings {
            auto_copy_result: true,
            ..with_input_synthesis_disabled.clone()
        };
        set_settings(&store, with_auto_copy_result.clone()).unwrap();
        assert!(get_settings(&store).unwrap().auto_copy_result);

        let with_onboarding_completed = Settings {
            onboarding_completed: true,
            ..with_auto_copy_result.clone()
        };
        set_settings(&store, with_onboarding_completed.clone()).unwrap();
        assert!(get_settings(&store).unwrap().onboarding_completed);

        let with_popover_position = Settings {
            popover_position: Some(PopoverPosition { x: 50, y: 75 }),
            ..with_onboarding_completed.clone()
        };
        set_settings(&store, with_popover_position.clone()).unwrap();
        assert_eq!(
            get_settings(&store).unwrap().popover_position,
            Some(PopoverPosition { x: 50, y: 75 })
        );

        let with_prompts = Settings {
            prompts: vec![crate::core::prompts::CustomPrompt {
                id: "prompt-1".to_string(),
                label: "Translate".to_string(),
                instruction: "Translate to French".to_string(),
            }],
            ..with_popover_position.clone()
        };
        set_settings(&store, with_prompts.clone()).unwrap();
        assert_eq!(get_settings(&store).unwrap().prompts, with_prompts.prompts);

        let with_update_channel = Settings {
            update_channel: crate::core::updates::UpdateChannel::Preview,
            ..with_prompts.clone()
        };
        set_settings(&store, with_update_channel.clone()).unwrap();
        assert_eq!(
            get_settings(&store).unwrap().update_channel,
            crate::core::updates::UpdateChannel::Preview
        );

        let with_update_check_frequency = Settings {
            update_check_frequency: crate::core::updates::UpdateCheckFrequency::Weekly,
            ..with_update_channel.clone()
        };
        set_settings(&store, with_update_check_frequency.clone()).unwrap();
        assert_eq!(
            get_settings(&store).unwrap().update_check_frequency,
            crate::core::updates::UpdateCheckFrequency::Weekly
        );
    }

    #[test]
    fn pre_onboarding_feature_persisted_json_without_onboarding_completed_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        assert!(!settings.onboarding_completed);
    }

    #[test]
    fn pre_spec_12_persisted_json_without_wayland_restore_token_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": []
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        assert_eq!(settings.wayland_restore_token, None);
    }

    #[test]
    fn pre_spec_13_persisted_json_without_the_new_fields_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        // `input_synthesis_enabled` keeps today's behavior (Replace working)
        // for existing installs; `auto_copy_result` is a new opt-in
        // convenience that must not turn itself on for anyone who never
        // asked for it. "No opinion persisted" reads differently for each
        // field, by design — see their doc comments on `Settings`.
        assert!(settings.input_synthesis_enabled);
        assert!(!settings.auto_copy_result);
    }

    #[test]
    fn pre_spec_14_persisted_json_without_popover_position_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false,
            "onboardingCompleted": false
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        assert_eq!(settings.popover_position, None);
    }

    #[test]
    fn pre_spec_15_persisted_json_without_prompts_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false,
            "onboardingCompleted": false,
            "popoverPosition": null
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        // A missing `prompts` key has "no opinion" — it falls back to the
        // same three seeded prompts a fresh install gets, not an empty list.
        let seeds = crate::core::prompts::default_prompts();
        assert_eq!(settings.prompts.len(), seeds.len());
        for (actual, expected) in settings.prompts.iter().zip(seeds.iter()) {
            assert_eq!(actual.id, expected.id);
            assert_eq!(actual.label, expected.label);
        }
    }

    #[test]
    fn pre_spec_16_persisted_json_without_update_fields_still_deserializes() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false,
            "onboardingCompleted": false,
            "popoverPosition": null,
            "prompts": []
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        // A missing `updateCheckFrequency` has no build-dependent signal to
        // read, so it falls back to the fixed `Daily` default. A missing
        // `updateChannel` is different: it must resolve to *this build's*
        // channel default, not a fixed value — see `Settings::update_channel`'s
        // doc comment — so an existing preview install upgrading across this
        // field's introduction keeps following pre-releases.
        assert_eq!(
            settings.update_check_frequency,
            crate::core::updates::UpdateCheckFrequency::Daily
        );
        assert_eq!(
            settings.update_channel,
            crate::core::updates::default_update_channel()
        );
    }

    #[test]
    fn an_explicit_empty_prompts_list_in_persisted_json_stays_empty() {
        let json = r#"{
            "activeProfileId": null,
            "shortcut": "Alt+Cmd+K",
            "spellcheckEnabled": true,
            "popoverPinned": false,
            "accessibilityOnboardingShown": true,
            "profiles": [],
            "waylandRestoreToken": null,
            "inputSynthesisEnabled": true,
            "autoCopyResult": false,
            "onboardingCompleted": false,
            "popoverPosition": null,
            "prompts": []
        }"#;

        let settings: Settings = serde_json::from_str(json).expect("should deserialize");

        // Unlike a *missing* key, an explicitly empty list means the user
        // deleted every prompt — it must not be resurrected back to the
        // seeded defaults.
        assert!(settings.prompts.is_empty());
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
