//! Spell-check seam: the platform-agnostic `SpellChecker` trait and the
//! `run_spellcheck()` orchestration function the command wraps thinly.
//!
//! All offsets in [`Misspelling`] are UTF-16 code-unit offsets, not byte
//! offsets and not Unicode scalar counts: `NSSpellChecker`'s `NSRange` counts
//! UTF-16 code units, and JavaScript strings are UTF-16 internally, so the
//! frontend can slice `text` directly with these offsets — no conversion
//! happens anywhere in this pipeline.

#[cfg(test)]
pub mod fakes;

/// A single misspelling found in the checked text.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Misspelling {
    /// UTF-16 code-unit offset of the first code unit of the misspelled
    /// word.
    pub start: u32,
    /// Length, in UTF-16 code units, of the misspelled word.
    pub length: u32,
    pub word: String,
    pub suggestions: Vec<String>,
}

/// Result of a spell-check pass over some text.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpellcheckResult {
    pub misspellings: Vec<Misspelling>,
}

impl SpellcheckResult {
    pub fn empty() -> Self {
        Self::default()
    }
}

/// Errors surfaced by a [`SpellChecker`] implementation.
#[derive(Debug, thiserror::Error)]
pub enum SpellcheckError {
    #[error("spell-check backend failed: {0}")]
    Backend(String),
}

/// Platform seam for checking spelling. Implementations may be backed by
/// `NSSpellChecker` (macOS) or an in-memory fake (tests).
pub trait SpellChecker: Send + Sync {
    fn check(&self, text: &str) -> Result<SpellcheckResult, SpellcheckError>;
}

/// Orchestrates a single spell-check pass: empty or whitespace-only text
/// short-circuits to an empty result without calling `checker` at all
/// (nothing to check, and no reason to pay the `NSSpellChecker` main-thread
/// round trip); otherwise delegates to `checker.check(text)` unchanged.
pub fn run_spellcheck(
    checker: &dyn SpellChecker,
    text: &str,
) -> Result<SpellcheckResult, SpellcheckError> {
    if text.trim().is_empty() {
        return Ok(SpellcheckResult::empty());
    }
    checker.check(text)
}

#[cfg(test)]
mod tests {
    use super::fakes::FakeSpellChecker;
    use super::*;

    fn sample_misspelling() -> Misspelling {
        Misspelling {
            start: 5,
            length: 4,
            word: "teh".to_string(),
            suggestions: vec!["the".to_string(), "tech".to_string()],
        }
    }

    #[test]
    fn clean_text_returns_no_misspellings() {
        let checker = FakeSpellChecker::returning(SpellcheckResult::empty());

        let result = run_spellcheck(&checker, "All correct words here.").unwrap();

        assert!(result.misspellings.is_empty());
        assert_eq!(checker.checked_texts(), vec!["All correct words here."]);
    }

    #[test]
    fn misspelled_fixture_passes_ranges_and_suggestions_through_unchanged() {
        let canned = SpellcheckResult {
            misspellings: vec![sample_misspelling()],
        };
        let checker = FakeSpellChecker::returning(canned.clone());

        let result = run_spellcheck(&checker, "Some teh text.").unwrap();

        assert_eq!(result, canned);
    }

    #[test]
    fn empty_string_returns_empty_result_without_calling_the_checker() {
        let checker = FakeSpellChecker::returning(SpellcheckResult {
            misspellings: vec![sample_misspelling()],
        });

        let result = run_spellcheck(&checker, "").unwrap();

        assert!(result.misspellings.is_empty());
        assert!(checker.checked_texts().is_empty());
    }

    #[test]
    fn whitespace_only_string_returns_empty_result_without_calling_the_checker() {
        let checker = FakeSpellChecker::returning(SpellcheckResult {
            misspellings: vec![sample_misspelling()],
        });

        let result = run_spellcheck(&checker, "   \n\t  ").unwrap();

        assert!(result.misspellings.is_empty());
        assert!(checker.checked_texts().is_empty());
    }

    #[test]
    fn checker_error_is_propagated() {
        let checker = FakeSpellChecker::failing("backend exploded");

        let result = run_spellcheck(&checker, "some text");

        assert!(matches!(result, Err(SpellcheckError::Backend(message)) if message == "backend exploded"));
    }
}
