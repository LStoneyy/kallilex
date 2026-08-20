//! Spell checking via `spellbook` (a pure-Rust Hunspell-compatible engine),
//! backed by system Hunspell/MySpell dictionaries when present and by a
//! small set of bundled dictionaries otherwise.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;

use spellbook::Dictionary;
use tauri::{AppHandle, Manager};
use unicode_segmentation::UnicodeSegmentation;

use crate::core::spellcheck::{Misspelling, SpellChecker, SpellcheckError, SpellcheckResult};

/// System dictionary directories, scanned before the bundled fallback so a
/// user/distro-provided dictionary always wins over the one Kallilex ships.
const SYSTEM_DICTIONARY_DIRS: &[&str] = &["/usr/share/hunspell", "/usr/share/myspell"];

/// The bundled dictionaries' location relative to the Tauri resource
/// directory (see `tauri.conf.json`'s `bundle.resources`).
const BUNDLED_DICTIONARIES_SUBDIR: &str = "resources/dictionaries";

/// A resolved `<lang>.aff`+`<lang>.dic` pair.
type ResolvedDictionary = (String, PathBuf, PathBuf);

/// Scans `search_dirs` in order for `<lang>.aff`/`<lang>.dic` pairs, keeping
/// only the *first* occurrence of each language code — callers are expected
/// to pass higher-precedence directories (system dictionaries) before
/// lower-precedence ones (the bundled fallback). A language whose `.aff` or
/// `.dic` half is missing from a given directory is skipped entirely for
/// that directory: pair completeness is required.
///
/// Pure and side-effect-free beyond reading directory listings, so it is
/// unit-tested directly with temp directories rather than through a full
/// `LinuxSpellChecker`.
pub fn resolve_dictionaries(search_dirs: &[PathBuf]) -> Vec<ResolvedDictionary> {
    let mut seen = HashSet::new();
    let mut resolved = Vec::new();

    for dir in search_dirs {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };

        let mut aff_by_lang: HashMap<String, PathBuf> = HashMap::new();
        let mut dic_by_lang: HashMap<String, PathBuf> = HashMap::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            match path.extension().and_then(|e| e.to_str()) {
                Some("aff") => {
                    aff_by_lang.insert(stem.to_string(), path);
                }
                Some("dic") => {
                    dic_by_lang.insert(stem.to_string(), path);
                }
                _ => {}
            }
        }

        let mut langs: Vec<&String> = aff_by_lang.keys().collect();
        langs.sort();
        for lang in langs {
            if seen.contains(lang) {
                continue;
            }
            if let Some(dic) = dic_by_lang.get(lang) {
                resolved.push((lang.clone(), aff_by_lang[lang].clone(), dic.clone()));
                seen.insert(lang.clone());
            }
        }
    }

    resolved
}

/// Loads every dictionary `resolve_dictionaries` can find across
/// `search_dirs`. Dictionaries that fail to read or parse are skipped
/// individually; only when *none* could be loaded at all does this return
/// `SpellcheckError::Backend`.
fn load_dictionaries(search_dirs: &[PathBuf]) -> Result<Vec<(String, Dictionary)>, String> {
    let mut loaded = Vec::new();
    for (lang, aff_path, dic_path) in resolve_dictionaries(search_dirs) {
        let Ok(aff) = std::fs::read_to_string(&aff_path) else {
            continue;
        };
        let Ok(dic) = std::fs::read_to_string(&dic_path) else {
            continue;
        };
        if let Ok(dictionary) = Dictionary::new(&aff, &dic) {
            loaded.push((lang, dictionary));
        }
    }

    if loaded.is_empty() {
        Err("no dictionary could be loaded from any resolved location".to_string())
    } else {
        Ok(loaded)
    }
}

/// Whether `word` should be spell-checked at all: it must contain at least
/// one alphabetic character and no digits (numbers, measurements, version
/// strings, etc. are never real "words" to flag).
fn should_check(word: &str) -> bool {
    word.chars().any(char::is_alphabetic) && !word.chars().any(char::is_numeric)
}

/// Spell checking via `spellbook`, loading system and/or bundled
/// dictionaries lazily on first use.
pub struct LinuxSpellChecker {
    search_dirs: Vec<PathBuf>,
    dictionaries: OnceLock<Result<Vec<(String, Dictionary)>, String>>,
}

impl LinuxSpellChecker {
    /// `app` is finally used here (Slice A's placeholder ignored it):
    /// resolving the bundled dictionaries' location requires
    /// `app.path().resource_dir()`.
    pub fn new(app: AppHandle) -> Self {
        let mut search_dirs: Vec<PathBuf> =
            SYSTEM_DICTIONARY_DIRS.iter().map(PathBuf::from).collect();
        if let Ok(resource_dir) = app.path().resource_dir() {
            search_dirs.push(resource_dir.join(BUNDLED_DICTIONARIES_SUBDIR));
        }
        Self {
            search_dirs,
            dictionaries: OnceLock::new(),
        }
    }

    #[cfg(test)]
    fn with_search_dirs(search_dirs: Vec<PathBuf>) -> Self {
        Self {
            search_dirs,
            dictionaries: OnceLock::new(),
        }
    }
}

impl SpellChecker for LinuxSpellChecker {
    fn check(&self, text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        let dictionaries = self
            .dictionaries
            .get_or_init(|| load_dictionaries(&self.search_dirs));
        let dictionaries = match dictionaries {
            Ok(dictionaries) => dictionaries,
            Err(message) => return Err(SpellcheckError::Backend(message.clone())),
        };

        let mut misspellings = Vec::new();
        // UTF-16 code-unit offset, matching `Misspelling`'s documented
        // units (see `core::spellcheck`'s module doc). `split_word_bound_indices`
        // partitions the *entire* string, including whitespace/punctuation
        // runs as their own tokens, so accumulating each token's UTF-16
        // length in order — with no gaps to account for — reconstructs the
        // right offset.
        let mut utf16_offset: u32 = 0;
        for (_, word) in text.split_word_bound_indices() {
            let word_utf16_len: u32 = word.chars().map(|c| c.len_utf16() as u32).sum();

            if should_check(word) {
                let correct = dictionaries.iter().any(|(_, dict)| dict.check(word));
                if !correct {
                    let mut suggestions = Vec::new();
                    for (_, dict) in dictionaries {
                        let mut candidate = Vec::new();
                        dict.suggest(word, &mut candidate);
                        if !candidate.is_empty() {
                            suggestions = candidate;
                            break;
                        }
                    }
                    misspellings.push(Misspelling {
                        start: utf16_offset,
                        length: word_utf16_len,
                        word: word.to_string(),
                        suggestions,
                    });
                }
            }

            utf16_offset += word_utf16_len;
        }

        Ok(SpellcheckResult { misspellings })
    }
}

/// Constructs the Linux `SpellChecker`.
pub fn spell_checker(app: AppHandle) -> LinuxSpellChecker {
    LinuxSpellChecker::new(app)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn fixture_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("src/platform/linux/testdata")
    }

    fn fixture_checker() -> LinuxSpellChecker {
        LinuxSpellChecker::with_search_dirs(vec![fixture_dir()])
    }

    fn write_pair(dir: &Path, lang: &str, aff: &str, dic: &str) {
        std::fs::write(dir.join(format!("{lang}.aff")), aff).unwrap();
        std::fs::write(dir.join(format!("{lang}.dic")), dic).unwrap();
    }

    #[test]
    fn misspelling_after_a_non_bmp_char_and_an_umlaut_word_has_correct_utf16_offsets() {
        let checker = fixture_checker();

        // "😀" is a non-BMP char (2 UTF-16 units), "grüße" is a correctly
        // spelled word containing an umlaut, and "helo" is a misspelling of
        // "hello" from the fixture dictionary.
        let result = checker.check("😀 grüße helo").unwrap();

        assert_eq!(result.misspellings.len(), 1);
        let misspelling = &result.misspellings[0];
        assert_eq!(misspelling.word, "helo");
        // "😀"(2) + " "(1) + "grüße"(5) + " "(1) = 9
        assert_eq!(misspelling.start, 9);
        assert_eq!(misspelling.length, 4);
    }

    #[test]
    fn correctly_spelled_words_are_not_flagged() {
        let checker = fixture_checker();

        let result = checker.check("hello world grüße").unwrap();

        assert!(result.misspellings.is_empty());
    }

    #[test]
    fn a_near_miss_gets_non_empty_suggestions() {
        let checker = fixture_checker();

        let result = checker.check("helo").unwrap();

        assert_eq!(result.misspellings.len(), 1);
        assert!(
            !result.misspellings[0].suggestions.is_empty(),
            "expected at least one suggestion for a near-miss of a dictionary word"
        );
    }

    #[test]
    fn tokens_containing_digits_are_skipped() {
        let checker = fixture_checker();

        // "helo2" contains a digit, so it must not be flagged even though
        // it isn't a dictionary word.
        let result = checker.check("helo2").unwrap();

        assert!(result.misspellings.is_empty());
    }

    /// Guards against a bundled dictionary silently failing to load (e.g. a
    /// truncated download or a wrong text encoding, both of which
    /// `load_dictionaries` would otherwise swallow via its "skip
    /// individually" behavior): both bundled dictionaries must actually be
    /// present, `resolve_dictionaries`-resolvable, and `Dictionary::new`-
    /// parseable, and the English one must correctly check a real sentence.
    #[test]
    fn bundled_dictionaries_are_present_and_parse_successfully() {
        let bundled_dir =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources/dictionaries");

        let resolved = resolve_dictionaries(std::slice::from_ref(&bundled_dir));
        let langs: HashSet<&str> = resolved.iter().map(|(lang, _, _)| lang.as_str()).collect();
        assert!(langs.contains("en_US"), "en_US.aff/.dic must be bundled");
        assert!(
            langs.contains("de_DE_frami"),
            "de_DE_frami.aff/.dic must be bundled"
        );

        for (lang, aff_path, dic_path) in &resolved {
            let aff = std::fs::read_to_string(aff_path)
                .unwrap_or_else(|e| panic!("{lang}.aff must be valid UTF-8 text: {e}"));
            let dic = std::fs::read_to_string(dic_path)
                .unwrap_or_else(|e| panic!("{lang}.dic must be valid UTF-8 text: {e}"));
            Dictionary::new(&aff, &dic)
                .unwrap_or_else(|e| panic!("{lang} must parse as a valid dictionary: {e}"));
        }

        let checker = LinuxSpellChecker::with_search_dirs(vec![bundled_dir]);
        let result = checker.check("This is a simple test sentence.").unwrap();
        assert!(
            result.misspellings.is_empty(),
            "expected no misspellings from the bundled en_US dictionary, got {:?}",
            result.misspellings
        );
    }

    #[test]
    fn resolve_dictionaries_prefers_system_over_bundled_for_the_same_language() {
        let system_dir = tempfile_dir();
        let bundled_dir = tempfile_dir();
        write_pair(&system_dir, "en_US", "", "1\nsystem\n");
        write_pair(&bundled_dir, "en_US", "", "1\nbundled\n");

        let resolved = resolve_dictionaries(&[
            system_dir.path().to_path_buf(),
            bundled_dir.path().to_path_buf(),
        ]);

        assert_eq!(resolved.len(), 1);
        assert_eq!(resolved[0].0, "en_US");
        assert_eq!(resolved[0].1, system_dir.join("en_US.aff"));
    }

    #[test]
    fn resolve_dictionaries_skips_an_aff_with_no_matching_dic() {
        let dir = tempfile_dir();
        std::fs::write(dir.join("en_US.aff"), "").unwrap();
        // No en_US.dic written.

        let resolved = resolve_dictionaries(&[dir.path().to_path_buf()]);

        assert!(resolved.is_empty());
    }

    #[test]
    fn resolve_dictionaries_collects_distinct_languages_from_multiple_dirs() {
        let system_dir = tempfile_dir();
        let bundled_dir = tempfile_dir();
        write_pair(&system_dir, "en_US", "", "1\nhello\n");
        write_pair(&bundled_dir, "de_DE_frami", "", "1\nhallo\n");

        let resolved = resolve_dictionaries(&[
            system_dir.path().to_path_buf(),
            bundled_dir.path().to_path_buf(),
        ]);

        let langs: Vec<&str> = resolved.iter().map(|(lang, _, _)| lang.as_str()).collect();
        assert_eq!(langs, vec!["en_US", "de_DE_frami"]);
    }

    /// An RAII guard around a fresh temp directory for `resolve_dictionaries`
    /// tests: `Drop` removes the directory (and everything written into it)
    /// so these tests don't leak uuid-named directories under the OS temp
    /// dir across runs. Derefs to `Path` so it can be used wherever a
    /// directory path is expected; `.path()` gives an explicit `&Path` for
    /// call sites that need to build an owned `PathBuf`.
    struct TempTestDir(PathBuf);

    impl TempTestDir {
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl std::ops::Deref for TempTestDir {
        type Target = Path;

        fn deref(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempTestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn tempfile_dir() -> TempTestDir {
        let dir = std::env::temp_dir().join(format!(
            "kallilex-spellcheck-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        TempTestDir(dir)
    }
}
