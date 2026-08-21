//! First-run onboarding gate: decides whether the onboarding window should
//! be shown, and the load-mutate-save helpers the onboarding frontend's
//! commands wrap thinly (`complete_onboarding`, `set_input_synthesis`).
//!
//! `evaluate_onboarding` is the sole gate — `lib.rs`'s `setup` calls it once
//! at startup and shows the window only on [`OnboardingDisposition::Show`].

use crate::core::settings::{Settings, SettingsError, SettingsStore};

/// Outcome of evaluating whether the onboarding window should be shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnboardingDisposition {
    /// A genuine first run: nothing persisted yet recognizes this install as
    /// already set up. The caller shows the onboarding window; nothing is
    /// written here — `complete_onboarding_core` persists the flag once the
    /// user finishes (or never, if they close the window early).
    Show,
    /// `onboarding_completed` was already `true`. Stable: evaluating again
    /// returns the same disposition without writing anything.
    AlreadyCompleted,
    /// A pre-onboarding-feature install recognized as already set up (the
    /// legacy Accessibility-onboarding flag was set, or provider profiles
    /// already exist) — see the module doc comment on
    /// [`Settings::accessibility_onboarding_shown`]. `onboarding_completed`
    /// is persisted as `true` so this is a one-time migration, not a
    /// per-launch check.
    AutoCompleted,
}

/// Decides whether the onboarding window should be shown, migrating
/// recognizably-already-set-up existing installs to `onboarding_completed =
/// true` without ever showing them the window. See [`OnboardingDisposition`]
/// for what each outcome means and writes.
pub fn evaluate_onboarding(
    store: &dyn SettingsStore,
) -> Result<OnboardingDisposition, SettingsError> {
    let settings = store.load()?;

    if settings.onboarding_completed {
        return Ok(OnboardingDisposition::AlreadyCompleted);
    }

    if settings.accessibility_onboarding_shown || !settings.profiles.is_empty() {
        let updated = Settings {
            onboarding_completed: true,
            ..settings
        };
        store.save(&updated)?;
        return Ok(OnboardingDisposition::AutoCompleted);
    }

    Ok(OnboardingDisposition::Show)
}

/// Persists `onboarding_completed = true`, preserving every other field.
/// Called by the `complete_onboarding` command when the user clicks "Done".
pub fn complete_onboarding_core(store: &dyn SettingsStore) -> Result<(), SettingsError> {
    let settings = store.load()?;
    let updated = Settings {
        onboarding_completed: true,
        ..settings
    };
    store.save(&updated)
}

/// Persists `input_synthesis_enabled`, preserving every other field. Called
/// by the `set_input_synthesis` command from the onboarding window's Wayland
/// paste-back toggle — load-mutate-save, same shape as
/// [`complete_onboarding_core`], so the onboarding frontend never needs
/// `setSettings` and can't clobber the (hidden but live) Settings window.
pub fn set_input_synthesis_core(
    store: &dyn SettingsStore,
    enabled: bool,
) -> Result<(), SettingsError> {
    let settings = store.load()?;
    let updated = Settings {
        input_synthesis_enabled: enabled,
        ..settings
    };
    store.save(&updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::settings::InMemorySettingsStore;

    #[test]
    fn fresh_install_shows_onboarding_and_persists_nothing() {
        let store = InMemorySettingsStore::new();

        let disposition = evaluate_onboarding(&store).expect("should succeed");

        assert_eq!(disposition, OnboardingDisposition::Show);
        assert!(!store.load().unwrap().onboarding_completed);
    }

    #[test]
    fn legacy_accessibility_flag_auto_completes_and_persists() {
        let store = InMemorySettingsStore::new();
        store
            .save(&Settings {
                accessibility_onboarding_shown: true,
                ..Settings::default()
            })
            .unwrap();

        let disposition = evaluate_onboarding(&store).expect("should succeed");

        assert_eq!(disposition, OnboardingDisposition::AutoCompleted);
        assert!(store.load().unwrap().onboarding_completed);
    }

    #[test]
    fn existing_profiles_auto_complete_and_persist() {
        let store = InMemorySettingsStore::new();
        store
            .save(&Settings {
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
                ..Settings::default()
            })
            .unwrap();

        let disposition = evaluate_onboarding(&store).expect("should succeed");

        assert_eq!(disposition, OnboardingDisposition::AutoCompleted);
        assert!(store.load().unwrap().onboarding_completed);
    }

    #[test]
    fn auto_complete_preserves_every_other_field() {
        let store = InMemorySettingsStore::new();
        let before = Settings {
            accessibility_onboarding_shown: true,
            shortcut: "Cmd+Shift+K".to_string(),
            spellcheck_enabled: false,
            popover_pinned: true,
            active_profile_id: Some("abc".to_string()),
            wayland_restore_token: Some("token-xyz".to_string()),
            input_synthesis_enabled: false,
            auto_copy_result: true,
            ..Settings::default()
        };
        store.save(&before.clone()).unwrap();

        evaluate_onboarding(&store).expect("should succeed");

        let after = store.load().unwrap();
        assert_eq!(
            after,
            Settings {
                onboarding_completed: true,
                ..before
            }
        );
    }

    #[test]
    fn already_completed_is_stable_and_writes_nothing_further() {
        let store = InMemorySettingsStore::new();
        store
            .save(&Settings {
                onboarding_completed: true,
                accessibility_onboarding_shown: true,
                shortcut: "Cmd+Shift+K".to_string(),
                ..Settings::default()
            })
            .unwrap();

        let disposition = evaluate_onboarding(&store).expect("should succeed");

        assert_eq!(disposition, OnboardingDisposition::AlreadyCompleted);
        assert_eq!(store.load().unwrap().shortcut, "Cmd+Shift+K");
    }

    #[test]
    fn complete_onboarding_core_sets_the_flag_and_preserves_other_fields() {
        let store = InMemorySettingsStore::new();
        store
            .save(&Settings {
                shortcut: "Cmd+Shift+K".to_string(),
                spellcheck_enabled: false,
                ..Settings::default()
            })
            .unwrap();

        complete_onboarding_core(&store).expect("should succeed");

        let after = store.load().unwrap();
        assert!(after.onboarding_completed);
        assert_eq!(after.shortcut, "Cmd+Shift+K");
        assert!(!after.spellcheck_enabled);
    }

    #[test]
    fn set_input_synthesis_core_flips_only_that_field() {
        let store = InMemorySettingsStore::new();
        store
            .save(&Settings {
                shortcut: "Cmd+Shift+K".to_string(),
                onboarding_completed: true,
                ..Settings::default()
            })
            .unwrap();

        set_input_synthesis_core(&store, false).expect("should succeed");

        let after = store.load().unwrap();
        assert!(!after.input_synthesis_enabled);
        assert_eq!(after.shortcut, "Cmd+Shift+K");
        assert!(after.onboarding_completed);
    }
}
