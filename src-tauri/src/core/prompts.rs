//! User-managed AI prompts: named instructions rendered as buttons in the
//! popover's action row, seeded with the three prompts Kallilex used to
//! bundle unconditionally (Rewrite, Shorten, Improve clarity) and fully
//! CRUD-editable from the Settings window's Prompts tab. Modeled closely on
//! the provider profile CRUD in [`crate::core::providers`].

use serde::{Deserialize, Serialize};

use crate::core::settings::{SettingsError, SettingsStore};

/// A single user-manageable prompt: the label shown on its popover button,
/// and the instruction sent to the AI provider as the system prompt (see
/// [`crate::core::providers::assemble_prompt`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomPrompt {
    pub id: String,
    pub label: String,
    pub instruction: String,
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
        },
        CustomPrompt {
            id: "builtin-shorten".to_string(),
            label: "Shorten".to_string(),
            instruction: "Make the user's text noticeably shorter while keeping its essential meaning and tone.".to_string(),
        },
        CustomPrompt {
            id: "builtin-improve-clarity".to_string(),
            label: "Improve clarity".to_string(),
            instruction: "Make the user's text clearer and easier to understand without changing its meaning.".to_string(),
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
/// Returns the updated prompt list.
pub fn save_prompt_core(
    settings_store: &dyn SettingsStore,
    mut prompt: CustomPrompt,
) -> Result<Vec<CustomPrompt>, PromptOpError> {
    validate_prompt(&prompt).map_err(PromptOpError::Validation)?;

    let mut settings = settings_store.load()?;

    if prompt.id.trim().is_empty() {
        prompt.id = uuid::Uuid::new_v4().to_string();
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

        let prompts = save_prompt_core(&settings_store, prompt).unwrap();

        // The three seeds plus the newly saved prompt.
        assert_eq!(prompts.len(), default_prompts().len() + 1);
        let saved = prompts.last().unwrap();
        assert!(!saved.id.is_empty());
    }

    #[test]
    fn saving_an_existing_id_upserts_in_place() {
        let settings_store = InMemorySettingsStore::new();
        save_prompt_core(&settings_store, sample_prompt("a")).unwrap();

        let mut updated = sample_prompt("a");
        updated.label = "Renamed".to_string();
        let prompts = save_prompt_core(&settings_store, updated).unwrap();

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

        let result = save_prompt_core(&settings_store, prompt);

        assert!(matches!(result, Err(PromptOpError::Validation(_))));
        assert_eq!(settings_store.load().unwrap().prompts, default_prompts());
    }

    #[test]
    fn deleting_a_prompt_removes_it_and_preserves_the_rest() {
        let settings_store = InMemorySettingsStore::new();
        save_prompt_core(&settings_store, sample_prompt("a")).unwrap();
        save_prompt_core(&settings_store, sample_prompt("b")).unwrap();

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

        save_prompt_core(&settings_store, sample_prompt("a")).unwrap();

        let after = settings_store.load().unwrap();
        assert!(!after.spellcheck_enabled);
        assert_eq!(after.shortcut, "Ctrl+Alt+K");
    }
}
