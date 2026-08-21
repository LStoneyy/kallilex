//! Windows spell checking (spec-15 Slice A stub). Slice C replaces this
//! with the Windows Spell Checking API (`ISpellCheckerFactory`/
//! `ISpellChecker`), whose `ISpellingError` offsets are UTF-16 code units —
//! exactly the unit `core::spellcheck::Misspelling` already documents, so no
//! re-indexing is needed there.

use crate::core::spellcheck::{SpellChecker, SpellcheckError, SpellcheckResult};

/// Honest stub: no spell-checking backend is implemented yet. Returns a
/// handled [`SpellcheckError::Backend`] — the `spellcheck` command rejects
/// rather than fabricating an empty result. (The popover does not currently
/// distinguish a backend error from a clean "no misspellings" result — a
/// pre-existing frontend limitation on every platform, not something
/// changed here.)
pub struct WindowsSpellChecker;

impl SpellChecker for WindowsSpellChecker {
    fn check(&self, _text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        Err(SpellcheckError::Backend(
            "spell check is not yet available on Windows".to_string(),
        ))
    }
}
