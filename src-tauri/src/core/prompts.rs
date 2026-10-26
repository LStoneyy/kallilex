//! User-managed AI prompts: named instructions rendered as buttons in the
//! popover's action row, seeded with the three prompts Kallilex used to
//! bundle unconditionally (Rewrite, Shorten, Improve clarity) and fully
//! CRUD-editable from the Settings window's Prompts tab. Modeled closely on
//! the provider profile CRUD in [`crate::core::providers`].

use serde::{Deserialize, Serialize};

use crate::core::settings::{SettingsError, SettingsStore};
use crate::core::shortcuts::{self, ShortcutTarget};

/// A single user-manageable prompt: the label shown on its popover button,
/// and the instruction sent to the AI provider as the system prompt (see
/// [`crate::core::providers::assemble_prompt`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomPrompt {
    pub id: String,
    pub label: String,
    pub instruction: String,
    /// This prompt's popover keyboard shortcut, if any — see
    /// `core::shortcuts` for the chord grammar and conflict rules.
    /// `#[serde(default)]` so a prompt persisted before this field existed
    /// deserializes with no shortcut rather than failing to load.
    #[serde(default)]
    pub shortcut: Option<String>,
}

/// The three prompts bundled with Kallilex before prompts became
/// user-editable — seeded into a fresh install's settings and into any
/// pre-existing `settings.json` written before [`crate::core::settings::Settings::prompts`]
/// existed (see that field's doc comment). Ids are stable so a settings
/// round-trip never orphans a prompt's button. The instructions are
/// verbatim what `assemble_prompt` used to hardcode for the old
/// `Action::Rewrite` / `Action::Shorten` / `Action::ImproveClarity`
/// variants — `prompt_seed_reproduces_the_original_rewrite_prompt_byte_for_byte`
/// in `core::providers`'s tests proves this reproduces the exact same
/// prompt text sent to the model before this change.
pub fn default_prompts() -> Vec<CustomPrompt> {
    vec![
        CustomPrompt {
            id: "builtin-rewrite".to_string(),
            label: "Rewrite".to_string(),
            instruction: "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone.".to_string(),
            shortcut: Some("Mod+1".to_string()),
        },
        CustomPrompt {
            id: "builtin-shorten".to_string(),
            label: "Shorten".to_string(),
            instruction: "Make the user's text noticeably shorter while keeping its essential meaning and tone.".to_string(),
            shortcut: Some("Mod+2".to_string()),
        },
        CustomPrompt {
            id: "builtin-improve-clarity".to_string(),
            label: "Improve clarity".to_string(),
            instruction: "Make the user's text clearer and easier to understand without changing its meaning.".to_string(),
            shortcut: Some("Mod+3".to_string()),
        },
    ]
}

/// Errors from the prompt CRUD "core" functions below, which compose
/// [`SettingsStore`].
#[derive(Debug, thiserror::Error)]
pub enum PromptOpError {
    #[error("{0}")]
    Validation(String),
    #[error(transparent)]
    Settings(#[from] SettingsError),
}

/// Validates a prompt before it is saved: both the label and the
/// instruction must be non-blank after trimming.
pub fn validate_prompt(prompt: &CustomPrompt) -> Result<(), String> {
    if prompt.label.trim().is_empty() {
        return Err("Prompt label must not be empty.".to_string());
    }
    if prompt.instruction.trim().is_empty() {
        return Err("Prompt instruction must not be empty.".to_string());
    }
    Ok(())
}

fn upsert_by_id(prompts: &mut Vec<CustomPrompt>, prompt: CustomPrompt) {
    if let Some(existing) = prompts.iter_mut().find(|p| p.id == prompt.id) {
        *existing = prompt;
    } else {
        prompts.push(prompt);
    }
}

/// Creates or updates a prompt. Generates a fresh id when `prompt.id` is
/// empty (same convention as [`crate::core::providers::save_profile_core`]).
/// `prompt.shortcut`, if set, is validated and canonicalized the same way
/// [`shortcuts::assign_shortcut_core`] would for any other target — the
/// duplicate check excludes this very prompt (so re-saving its own shortcut
/// unchanged is never a conflict), and `take_over` clears a conflicting
/// holder in the same write, exactly like that function's popover/prompt
/// branch. Returns the updated prompt list.
///
/// [`shortcuts::assign_shortcut_core`]: crate::core::shortcuts::assign_shortcut_core
pub fn save_prompt_core(
    settings_store: &dyn SettingsStore,
    mut prompt: CustomPrompt,
    take_over_shortcut: bool,
) -> Result<Vec<CustomPrompt>, PromptOpError> {
    validate_prompt(&prompt).map_err(PromptOpError::Validation)?;

    let mut settings = settings_store.load()?;

    if prompt.id.trim().is_empty() {
        prompt.id = uuid::Uuid::new_v4().to_string();
    }

    if let Some(raw) = prompt.shortcut.clone() {
        let target = ShortcutTarget::Prompt {
            id: prompt.id.clone(),
        };
        let canonical = shortcuts::resolve_shortcut_assignment(
            &mut settings,
            &target,
            &raw,
            take_over_shortcut,
        )
        .map_err(PromptOpError::Validation)?;
        prompt.shortcut = Some(canonical);
    }

    upsert_by_id(&mut settings.prompts, prompt);

    settings_store.save(&settings)?;
    Ok(settings.prompts)
}

/// Removes the prompt with `id` — a no-op (not an error) when no prompt has
/// that id. Returns the updated prompt list.
pub fn delete_prompt_core(
    settings_store: &dyn SettingsStore,
    id: &str,
) -> Result<Vec<CustomPrompt>, PromptOpError> {
    let mut settings = settings_store.load()?;
    settings.prompts.retain(|p| p.id != id);
    settings_store.save(&settings)?;
    Ok(settings.prompts)
}

/// Convenience used by the `list_prompts` command.
pub fn list_prompts_core(
    settings_store: &dyn SettingsStore,
) -> Result<Vec<CustomPrompt>, SettingsError> {
    Ok(settings_store.load()?.prompts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::settings::InMemorySettingsStore;

    fn sample_prompt(id: &str) -> CustomPrompt {
        CustomPrompt {
            id: id.to_string(),
            label: format!("Prompt {id}"),
            instruction: "Do something with the text.".to_string(),
            shortcut: None,
        }
    }

    #[test]
    fn a_fresh_store_lists_the_seeded_defaults() {
        let settings_store = InMemorySettingsStore::new();

        let prompts = list_prompts_core(&settings_store).unwrap();

        assert_eq!(prompts, default_prompts());
    }

    #[test]
    fn saving_a_prompt_with_an_empty_id_generates_one() {
        let settings_store = InMemorySettingsStore::new();
        let mut prompt = sample_prompt("");
        prompt.id = "".to_string();

        let prompts = save_prompt_core(&settings_store, prompt, false).unwrap();

        // The three seeds plus the newly saved prompt.
        assert_eq!(prompts.len(), default_prompts().len() + 1);
        let saved = prompts.last().unwrap();
        assert!(!saved.id.is_empty());
    }

    #[test]
    fn saving_an_existing_id_upserts_in_place() {
        let settings_store = InMemorySettingsStore::new();
        save_prompt_core(&settings_store, sample_prompt("a"), false).unwrap();

        let mut updated = sample_prompt("a");
        updated.label = "Renamed".to_string();
        let prompts = save_prompt_core(&settings_store, updated, false).unwrap();

        let matching: Vec<_> = prompts.iter().filter(|p| p.id == "a").collect();
        assert_eq!(matching.len(), 1);
        assert_eq!(matching[0].label, "Renamed");
    }

    #[test]
    fn blank_label_fails_validation() {
        let mut prompt = sample_prompt("a");
        prompt.label = "   ".to_string();
        assert!(validate_prompt(&prompt).is_err());
    }

    #[test]
    fn blank_instruction_fails_validation() {
        let mut prompt = sample_prompt("a");
        prompt.instruction = "   ".to_string();
        assert!(validate_prompt(&prompt).is_err());
    }

    #[test]
    fn saving_a_prompt_with_a_blank_label_never_touches_the_store() {
        let settings_store = InMemorySettingsStore::new();
        let mut prompt = sample_prompt("a");
        prompt.label = "".to_string();

        let result = save_prompt_core(&settings_store, prompt, false);

        assert!(matches!(result, Err(PromptOpError::Validation(_))));
        assert_eq!(settings_store.load().unwrap().prompts, default_prompts());
    }

    #[test]
    fn deleting_a_prompt_removes_it_and_preserves_the_rest() {
        let settings_store = InMemorySettingsStore::new();
        save_prompt_core(&settings_store, sample_prompt("a"), false).unwrap();
        save_prompt_core(&settings_store, sample_prompt("b"), false).unwrap();

        let prompts = delete_prompt_core(&settings_store, "a").unwrap();

        assert!(!prompts.iter().any(|p| p.id == "a"));
        assert!(prompts.iter().any(|p| p.id == "b"));
    }

    #[test]
    fn deleting_an_unknown_id_is_a_no_op() {
        let settings_store = InMemorySettingsStore::new();
        let before = list_prompts_core(&settings_store).unwrap();

        let after = delete_prompt_core(&settings_store, "missing").unwrap();

        assert_eq!(before, after);
    }

    #[test]
    fn saving_a_prompt_preserves_other_settings_fields() {
        let settings_store = InMemorySettingsStore::new();
        let mut settings = settings_store.load().unwrap();
        settings.spellcheck_enabled = false;
        settings.shortcut = "Ctrl+Alt+K".to_string();
        settings_store.save(&settings).unwrap();

        save_prompt_core(&settings_store, sample_prompt("a"), false).unwrap();

        let after = settings_store.load().unwrap();
        assert!(!after.spellcheck_enabled);
        assert_eq!(after.shortcut, "Ctrl+Alt+K");
    }

    #[test]
    fn saving_a_prompt_canonicalizes_its_shortcut() {
        let settings_store = InMemorySettingsStore::new();
        let mut prompt = sample_prompt("a");
        prompt.shortcut = Some("shift+mod+l".to_string());

        save_prompt_core(&settings_store, prompt, false).unwrap();

        let after = settings_store.load().unwrap();
        let saved = after.prompts.iter().find(|p| p.id == "a").unwrap();
        assert_eq!(saved.shortcut.as_deref(), Some("Mod+Shift+L"));
    }

    #[test]
    fn saving_a_prompt_with_a_reserved_shortcut_fails_and_saves_nothing() {
        let settings_store = InMemorySettingsStore::new();
        let mut prompt = sample_prompt("a");
        prompt.shortcut = Some("Mod+C".to_string());

        let result = save_prompt_core(&settings_store, prompt, false);

        assert!(matches!(result, Err(PromptOpError::Validation(_))));
        assert!(!settings_store
            .load()
            .unwrap()
            .prompts
            .iter()
            .any(|p| p.id == "a"));
    }

    #[test]
    fn saving_a_prompt_with_a_shortcut_already_used_by_another_prompt_fails_without_take_over() {
        let settings_store = InMemorySettingsStore::new();
        let mut first = sample_prompt("a");
        first.shortcut = Some("Mod+9".to_string());
        save_prompt_core(&settings_store, first, false).unwrap();

        let mut second = sample_prompt("b");
        second.shortcut = Some("Mod+9".to_string());
        let result = save_prompt_core(&settings_store, second, false);

        assert!(matches!(result, Err(PromptOpError::Validation(_))));
        let after = settings_store.load().unwrap();
        assert!(!after.prompts.iter().any(|p| p.id == "b"));
        assert_eq!(
            after
                .prompts
                .iter()
                .find(|p| p.id == "a")
                .unwrap()
                .shortcut
                .as_deref(),
            Some("Mod+9")
        );
    }

    #[test]
    fn take_over_clears_the_shortcut_from_the_prompt_that_held_it() {
        let settings_store = InMemorySettingsStore::new();
        let mut first = sample_prompt("a");
        first.shortcut = Some("Mod+9".to_string());
        save_prompt_core(&settings_store, first, false).unwrap();

        let mut second = sample_prompt("b");
        second.shortcut = Some("Mod+9".to_string());
        save_prompt_core(&settings_store, second, true).unwrap();

        let after = settings_store.load().unwrap();
        assert_eq!(
            after.prompts.iter().find(|p| p.id == "a").unwrap().shortcut,
            None
        );
        assert_eq!(
            after
                .prompts
                .iter()
                .find(|p| p.id == "b")
                .unwrap()
                .shortcut
                .as_deref(),
            Some("Mod+9")
        );
    }

    #[test]
    fn resaving_a_prompts_own_shortcut_unchanged_is_not_a_conflict() {
        let settings_store = InMemorySettingsStore::new();
        let mut prompt = sample_prompt("a");
        prompt.shortcut = Some("Mod+9".to_string());
        save_prompt_core(&settings_store, prompt.clone(), false).unwrap();

        // Saving the very same prompt/shortcut again (e.g. editing only the
        // label) must not be treated as a conflict with itself.
        prompt.label = "Renamed".to_string();
        let prompts = save_prompt_core(&settings_store, prompt, false).unwrap();

        let saved = prompts.iter().find(|p| p.id == "a").unwrap();
        assert_eq!(saved.label, "Renamed");
        assert_eq!(saved.shortcut.as_deref(), Some("Mod+9"));
    }

    #[test]
    fn a_prompt_shortcut_equal_to_the_global_shortcut_is_always_rejected() {
        let settings_store = InMemorySettingsStore::new();
        let mut settings = settings_store.load().unwrap();
        settings.shortcut = if cfg!(target_os = "macos") {
            "Alt+Cmd+K".to_string()
        } else {
            "Ctrl+Alt+K".to_string()
        };
        settings_store.save(&settings).unwrap();

        let mut prompt = sample_prompt("a");
        prompt.shortcut = Some("Mod+Alt+K".to_string());

        // Even with `take_over: true` — the global shortcut can never be
        // taken over by a popover/prompt shortcut.
        let result = save_prompt_core(&settings_store, prompt, true);

        assert!(matches!(result, Err(PromptOpError::Validation(_))));
    }
}
