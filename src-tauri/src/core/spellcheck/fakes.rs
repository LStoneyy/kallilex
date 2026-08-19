//! In-memory `SpellChecker` fake used by unit tests in this module.

use std::sync::Mutex;

use super::{SpellChecker, SpellcheckError, SpellcheckResult};

enum Outcome {
    Result(SpellcheckResult),
    Error(String),
}

/// Configurable `SpellChecker` fake: returns a canned [`SpellcheckResult`]
/// (or a canned error) and records every text it was asked to check, in
/// order.
pub struct FakeSpellChecker {
    outcome: Outcome,
    checked_texts: Mutex<Vec<String>>,
}

impl FakeSpellChecker {
    pub fn returning(result: SpellcheckResult) -> Self {
        Self {
            outcome: Outcome::Result(result),
            checked_texts: Mutex::new(Vec::new()),
        }
    }

    pub fn failing(message: impl Into<String>) -> Self {
        Self {
            outcome: Outcome::Error(message.into()),
            checked_texts: Mutex::new(Vec::new()),
        }
    }

    /// Every text passed to [`SpellChecker::check`], in call order.
    pub fn checked_texts(&self) -> Vec<String> {
        self.checked_texts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

impl SpellChecker for FakeSpellChecker {
    fn check(&self, text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        self.checked_texts
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(text.to_string());
        match &self.outcome {
            Outcome::Result(result) => Ok(result.clone()),
            Outcome::Error(message) => Err(SpellcheckError::Backend(message.clone())),
        }
    }
}
