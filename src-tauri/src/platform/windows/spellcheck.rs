//! Windows spell checking (spec-15 Slice C): the Windows Spell Checking API
//! (`ISpellCheckerFactory`/`ISpellChecker`, Windows 8+), which already ships
//! with every Windows install and already knows the user's installed display
//! languages.
//!
//! **Rejected alternative**: reusing `spellbook` (the pure-Rust engine the
//! Linux backend uses) plus bundled `en_US`/`de_DE` dictionaries. It would
//! work and would be less code, but it would ship ~10 MB of dictionaries
//! Windows already has, ignore the user's actual installed display
//! languages, and duplicate a solved problem. If `ISpellChecker` ever proves
//! unusable in practice, the spec-11 crate-choice rule applies: escalate to
//! the orchestrator rather than swapping unilaterally.
//!
//! **The offset contract lines up exactly**: `ISpellingError::StartIndex`/
//! `Length` are UTF-16 code-unit offsets, which is precisely what
//! `core::spellcheck::Misspelling` documents (`start`/`length` are UTF-16
//! units, so the frontend can `.slice()` them directly) — no re-indexing, no
//! tokenizer, no bundled dictionaries.
//!
//! **Threading**: the spell checker objects (`ISpellCheckerFactory`,
//! `ISpellChecker`) are apartment-affine, so they are created once and owned
//! for the lifetime of the process on one dedicated worker thread, spawned
//! lazily on the first `check` call ([`WORKER`]). The worker initializes COM
//! (`COINIT_MULTITHREADED`) once and never uninitializes it — the thread
//! never exits while the process is alive, so there is no matching
//! `CoUninitialize` call to make. Every `check` call sends a request over an
//! `mpsc` channel and blocks on the reply, bounded by [`SPELLCHECK_TIMEOUT`]
//! — the same 5-second value and "only fires if the worker is wedged"
//! rationale `MacosSpellChecker::check` uses for its own main-thread round
//! trip: this API is in-process and fast, so a real timeout here only ever
//! fires if the worker thread itself is wedged. If the worker fails to start
//! (COM/factory failure, or no supported language), the failure is cached
//! and returned from every subsequent `check` — the worker is never retried.
//!
//! **Language rule**: mirrors `LinuxSpellChecker`'s multi-dictionary
//! semantics exactly — a word counts as correct if *any* selected checker
//! accepts it, and suggestions come from the first checker that returns a
//! non-empty list. This is the same forgiving behavior multilingual users
//! get on Linux, now on Windows too.

use std::ffi::c_void;
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{mpsc, OnceLock};
use std::thread;
use std::time::Duration;

use windows::core::{HSTRING, PWSTR};
use windows::Win32::Foundation::{RPC_E_CHANGED_MODE, S_OK};
use windows::Win32::Globalization::{
    GetUserDefaultLocaleName, GetUserPreferredUILanguages, ISpellChecker, ISpellCheckerFactory,
    ISpellingError, SpellCheckerFactory, CORRECTIVE_ACTION_GET_SUGGESTIONS,
    CORRECTIVE_ACTION_REPLACE, MUI_LANGUAGE_NAME,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};

use crate::core::spellcheck::{Misspelling, SpellChecker, SpellcheckError, SpellcheckResult};

/// How long to wait for a spell check served by the dedicated worker thread
/// to complete before giving up. The Windows Spell Checking API is
/// in-process and fast, so a real timeout here only ever fires if the worker
/// thread itself is wedged — the same rationale (and value) as
/// `MacosSpellChecker::SPELLCHECK_TIMEOUT`. If the reply channel instead
/// disconnects before that (the worker thread panicked or otherwise exited
/// mid-request, dropping the reply sender), that's reported immediately as
/// its own distinct error rather than waiting out the rest of the timeout.
const SPELLCHECK_TIMEOUT: Duration = Duration::from_secs(5);

/// The documented maximum length (in `WCHAR`s, including the NUL terminator)
/// of a locale name buffer for `GetUserDefaultLocaleName`. Not exposed as a
/// named constant by the `windows` crate's `Globalization` module, so it's
/// declared here.
const LOCALE_NAME_MAX_LENGTH: usize = 85;

/// A single spell-check request sent to the worker thread: the text to
/// check, and where to send the result back.
type Request = (
    String,
    mpsc::Sender<Result<SpellcheckResult, SpellcheckError>>,
);

/// What a successfully started worker thread hands back: the channel to send
/// it future requests on, and the language tags it ended up selecting.
struct WorkerHandle {
    sender: mpsc::Sender<Request>,
    /// Only read by the `#[ignore]`d real-backend test (`WORKER.get()`),
    /// which prints it via `eprintln!` for manual verification on a real
    /// Windows machine — never consulted by production code, hence the
    /// `dead_code` allowance on non-test builds.
    #[cfg_attr(not(test), allow(dead_code))]
    languages: Vec<String>,
}

/// The single, lazily-started, long-lived spell-check worker for the whole
/// process. `Err` (worker startup failed) is cached permanently — the worker
/// is never retried, matching the "store the error and return it from every
/// `check`" contract.
static WORKER: OnceLock<Result<WorkerHandle, String>> = OnceLock::new();

/// Spell checking via the Windows Spell Checking API. Holds no state of its
/// own: all backend state lives on the shared [`WORKER`] thread.
pub struct WindowsSpellChecker;

impl SpellChecker for WindowsSpellChecker {
    fn check(&self, text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        let handle = WORKER.get_or_init(spawn_worker);
        let sender = match handle {
            Ok(handle) => handle.sender.clone(),
            Err(message) => return Err(SpellcheckError::Backend(message.clone())),
        };

        let (reply_tx, reply_rx) = mpsc::channel();
        sender.send((text.to_string(), reply_tx)).map_err(|_| {
            SpellcheckError::Backend("spell-check worker is no longer running".to_string())
        })?;

        match reply_rx.recv_timeout(SPELLCHECK_TIMEOUT) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => Err(SpellcheckError::Backend(
                "spell check timed out".to_string(),
            )),
            Err(RecvTimeoutError::Disconnected) => Err(SpellcheckError::Backend(
                "the spell-check worker stopped unexpectedly".to_string(),
            )),
        }
    }
}

/// Starts the dedicated worker thread and blocks (on the *calling* thread,
/// only ever `OnceLock`'s first caller) until it reports back either a ready
/// [`WorkerHandle`] or a startup failure message. The COM objects themselves
/// are created *on* the worker thread ([`worker_loop`]), never here — they're
/// apartment-affine and must never be sent across threads.
fn spawn_worker() -> Result<WorkerHandle, String> {
    let (init_tx, init_rx) = mpsc::channel::<Result<Vec<String>, String>>();
    let (req_tx, req_rx) = mpsc::channel::<Request>();

    thread::spawn(move || worker_loop(req_rx, init_tx));

    match init_rx.recv() {
        Ok(Ok(languages)) => Ok(WorkerHandle {
            sender: req_tx,
            languages,
        }),
        Ok(Err(message)) => Err(message),
        Err(_) => Err("the spell-check worker thread failed to start".to_string()),
    }
}

/// Runs on the dedicated worker thread for the lifetime of the process.
/// Initializes COM once, creates one `ISpellChecker` per selected language,
/// reports the outcome back via `init_tx`, and — only on success — serves
/// `check` requests off `req_rx` forever. On any startup failure, reports the
/// failure and returns without entering the request loop; the caller never
/// retries, so this thread simply ends.
fn worker_loop(
    req_rx: mpsc::Receiver<Request>,
    init_tx: mpsc::Sender<Result<Vec<String>, String>>,
) {
    // SAFETY: this is a freshly spawned, dedicated thread that has not
    // previously touched COM. `S_OK` (fresh init) and `S_FALSE` (already
    // initialized on this thread, e.g. by another `windows` crate call) both
    // leave COM usable; `RPC_E_CHANGED_MODE` (incompatible apartment already
    // set on this thread) is tolerated defensively per the same reasoning
    // `platform::windows::selection`'s worker uses, though it's practically
    // unreachable on a thread we just spawned. This thread never exits for
    // the lifetime of the process, so there is no matching `CoUninitialize`
    // call to make — the apartment simply lives until the process does.
    let init_hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    if init_hr.is_err() && init_hr != RPC_E_CHANGED_MODE {
        let _ = init_tx.send(Err(format!("failed to initialize COM: {init_hr:?}")));
        return;
    }

    // SAFETY: `SpellCheckerFactory` is a standard, documented in-process COM
    // server; COM was just confirmed usable on this thread above.
    let factory: ISpellCheckerFactory =
        match unsafe { CoCreateInstance(&SpellCheckerFactory, None, CLSCTX_INPROC_SERVER) } {
            Ok(factory) => factory,
            Err(e) => {
                let _ = init_tx.send(Err(format!(
                    "failed to create the Windows spell-checking factory: {e}"
                )));
                return;
            }
        };

    let preferred = preferred_languages();
    let is_supported = |tag: &str| -> bool {
        let tag = HSTRING::from(tag);
        // SAFETY: `factory` is a valid, live COM object for the duration of
        // this call.
        unsafe { factory.IsSupported(&tag) }
            .map(|supported| supported.as_bool())
            .unwrap_or(false)
    };
    let selected = select_languages(&preferred, &is_supported);

    let mut checkers = Vec::new();
    for tag in &selected {
        let htag = HSTRING::from(tag.as_str());
        // SAFETY: `factory` is a valid, live COM object; `tag` was just
        // confirmed supported by `is_supported` above.
        if let Ok(checker) = unsafe { factory.CreateSpellChecker(&htag) } {
            checkers.push(checker);
        }
    }

    if checkers.is_empty() {
        let _ = init_tx.send(Err(
            "no Windows spell-checking language is installed for your display languages"
                .to_string(),
        ));
        return;
    }

    if init_tx.send(Ok(selected)).is_err() {
        // The caller gave up (timed out) before we finished starting up.
        // There is no one left to serve, so there is nothing left to do.
        return;
    }

    for (text, reply_tx) in req_rx {
        let result = check_with_checkers(&checkers, &text);
        // The receiver may already be gone if the caller's `recv_timeout`
        // gave up first; that's fine, there's nothing left to do.
        let _ = reply_tx.send(result);
    }
}

/// Builds the candidate list of display-language tags to try, in priority
/// order: the user's preferred UI languages
/// (`GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, ...)`, which returns
/// BCP-47 tags like `"en-US"`), falling back to the single default locale
/// name (`GetUserDefaultLocaleName`) only when that call yields nothing
/// (e.g. an unusual configuration with no UI language list at all).
fn preferred_languages() -> Vec<String> {
    let mut count = 0u32;
    let mut buf_len = 0u32;
    // SAFETY: the first call, with a `None` buffer, only queries the
    // required buffer size; `count`/`buf_len` are valid out-params.
    let sized =
        unsafe { GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &mut count, None, &mut buf_len) };
    if sized.is_ok() && buf_len > 0 {
        let mut buf = vec![0u16; buf_len as usize];
        // SAFETY: `buf` is sized exactly to what the query call above
        // reported; `count`/`buf_len` are valid out-params (reused as
        // in/out, per the documented two-call pattern).
        let filled = unsafe {
            GetUserPreferredUILanguages(
                MUI_LANGUAGE_NAME,
                &mut count,
                Some(PWSTR(buf.as_mut_ptr())),
                &mut buf_len,
            )
        };
        if filled.is_ok() {
            let tags = parse_multi_sz(&buf);
            if !tags.is_empty() {
                return tags;
            }
        }
    }

    let mut locale_buf = [0u16; LOCALE_NAME_MAX_LENGTH];
    // SAFETY: `locale_buf` is a valid, appropriately-sized output buffer.
    let len = unsafe { GetUserDefaultLocaleName(&mut locale_buf) };
    if len > 1 {
        // `len` includes the trailing NUL; trim it before decoding.
        let name = String::from_utf16_lossy(&locale_buf[..(len as usize - 1)]);
        if !name.is_empty() {
            return vec![name];
        }
    }

    Vec::new()
}

/// Parses a double-NUL-terminated `MULTI_SZ`-style buffer — the format
/// `GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, ...)` fills its buffer
/// with — into an ordered list of non-empty language tags. Pure and
/// side-effect-free, so it's unit-tested directly without any COM/Win32
/// call.
fn parse_multi_sz(units: &[u16]) -> Vec<String> {
    units
        .split(|&unit| unit == 0)
        .map(String::from_utf16_lossy)
        .filter(|tag| !tag.is_empty())
        .collect()
}

/// Reduces a list of preferred language tags (in priority order) to the tags
/// Windows actually has a spell-checking provider for, per `is_supported`.
/// For each preferred tag, in order: keep it as-is if directly supported;
/// otherwise try its primary subtag once (`"de-DE"` -> `"de"`) and keep that
/// if *it's* supported. Duplicates (e.g. two region variants both falling
/// back to the same primary subtag) are collapsed, keeping the first
/// occurrence's position. Pure and side-effect-free beyond calling the
/// injected `is_supported` closure, so it's unit-tested with fake closures
/// instead of a real `ISpellCheckerFactory`.
fn select_languages(preferred: &[String], is_supported: &dyn Fn(&str) -> bool) -> Vec<String> {
    let mut selected = Vec::new();

    for tag in preferred {
        let candidate = if is_supported(tag) {
            Some(tag.clone())
        } else {
            tag.split('-').next().and_then(|primary| {
                if primary != tag && is_supported(primary) {
                    Some(primary.to_string())
                } else {
                    None
                }
            })
        };

        if let Some(candidate) = candidate {
            if !selected.contains(&candidate) {
                selected.push(candidate);
            }
        }
    }

    selected
}

/// Runs a single spell-check pass over `text` using `checkers[0]` as the
/// primary source of misspellings, applying the "any dictionary accepts it"
/// rule against the remaining checkers, and filling in suggestions. Must
/// only ever be called from the worker thread — every `ISpellChecker` in
/// `checkers` is apartment-affine.
fn check_with_checkers(
    checkers: &[ISpellChecker],
    text: &str,
) -> Result<SpellcheckResult, SpellcheckError> {
    let units: Vec<u16> = text.encode_utf16().collect();
    let total_len = units.len();
    let htext = HSTRING::from(text);

    // SAFETY: `checkers[0]` is a valid, live COM object for the duration of
    // this call.
    let errors = unsafe { checkers[0].Check(&htext) }
        .map_err(|e| SpellcheckError::Backend(format!("spell check failed: {e}")))?;

    let mut misspellings = Vec::new();
    loop {
        let mut current: Option<ISpellingError> = None;
        // SAFETY: `errors` is a valid, live COM object for the duration of
        // this call; `current` is a valid out-param.
        let hr = unsafe { errors.Next(&mut current) };
        if hr != S_OK {
            // Either `S_FALSE` (enumeration exhausted) or a genuine failure;
            // either way, there is nothing more to fetch.
            break;
        }
        let Some(error) = current else { break };

        // SAFETY: `error` is a valid, live COM object for the duration of
        // these calls.
        let (Ok(start_index), Ok(length), Ok(action)) = (
            unsafe { error.StartIndex() },
            unsafe { error.Length() },
            unsafe { error.CorrectiveAction() },
        ) else {
            // A COM call on this particular error failed; skip just this
            // item rather than aborting the whole check.
            continue;
        };

        if action != CORRECTIVE_ACTION_GET_SUGGESTIONS && action != CORRECTIVE_ACTION_REPLACE {
            // `NONE` (not a misspelling) and `DELETE` (the doubled-word
            // case — a grammar-ish correction, out of this spec's scope)
            // are both not misspellings.
            continue;
        }

        let start = start_index as usize;
        let length = length as usize;
        if start >= total_len || length == 0 {
            continue;
        }
        let end = (start + length).min(total_len);
        if end <= start {
            continue;
        }
        let word = String::from_utf16_lossy(&units[start..end]);

        // Multi-dictionary rule: drop this misspelling if any *other*
        // selected checker accepts the word outright.
        let accepted_elsewhere = checkers
            .iter()
            .skip(1)
            .any(|other| matches!(word_is_flagged(other, &word), Ok(false)));
        if accepted_elsewhere {
            continue;
        }

        let replacement = if action == CORRECTIVE_ACTION_REPLACE {
            // SAFETY: `error` is a valid, live COM object.
            unsafe { error.Replacement() }.ok().and_then(|pwstr| {
                let value = pwstr_to_string(pwstr);
                free_pwstr(pwstr);
                if value.is_empty() {
                    None
                } else {
                    Some(value)
                }
            })
        } else {
            None
        };

        let suggestions = collect_suggestions(checkers, &word, replacement.as_deref());

        misspellings.push(Misspelling {
            start: start as u32,
            length: (end - start) as u32,
            word,
            suggestions,
        });
    }

    misspellings.sort_by_key(|m| m.start);
    Ok(SpellcheckResult { misspellings })
}

/// Whether `checker` considers `word` misspelled: `Check(word)` yields at
/// least one error whose `CorrectiveAction` is `GET_SUGGESTIONS` or
/// `REPLACE`. A COM failure is reported as an error rather than silently
/// treated as "not flagged" — callers that use this for the "any dictionary
/// accepts it" rule treat an `Err` as "couldn't confirm acceptance", which
/// conservatively keeps the misspelling rather than dropping it on a backend
/// hiccup.
fn word_is_flagged(checker: &ISpellChecker, word: &str) -> Result<bool, SpellcheckError> {
    let hword = HSTRING::from(word);
    // SAFETY: `checker` is a valid, live COM object for the duration of this
    // call.
    let errors = unsafe { checker.Check(&hword) }
        .map_err(|e| SpellcheckError::Backend(format!("spell check failed: {e}")))?;

    loop {
        let mut current: Option<ISpellingError> = None;
        // SAFETY: `errors` is a valid, live COM object for the duration of
        // this call; `current` is a valid out-param.
        let hr = unsafe { errors.Next(&mut current) };
        if hr != S_OK {
            break;
        }
        let Some(error) = current else { break };

        // SAFETY: `error` is a valid, live COM object.
        if let Ok(action) = unsafe { error.CorrectiveAction() } {
            if action == CORRECTIVE_ACTION_GET_SUGGESTIONS || action == CORRECTIVE_ACTION_REPLACE {
                return Ok(true);
            }
        }
    }

    Ok(false)
}

/// Builds the suggestion list for a misspelled `word`: `replacement` (from a
/// `CORRECTIVE_ACTION_REPLACE` error's `Replacement()`) goes first if
/// present, then `Suggest(word)` is tried on each checker in order, taking
/// the first non-empty result and appending it without duplicating
/// `replacement`.
fn collect_suggestions(
    checkers: &[ISpellChecker],
    word: &str,
    replacement: Option<&str>,
) -> Vec<String> {
    let mut suggestions = Vec::new();
    if let Some(replacement) = replacement {
        suggestions.push(replacement.to_string());
    }

    for checker in checkers {
        let candidates = suggest_words(checker, word);
        if candidates.is_empty() {
            continue;
        }
        for candidate in candidates {
            if Some(candidate.as_str()) != replacement {
                suggestions.push(candidate);
            }
        }
        break;
    }

    suggestions
}

/// Reads every string out of `checker.Suggest(word)`'s `IEnumString`,
/// freeing each `PWSTR` via `CoTaskMemFree` as it's read. Best-effort: any
/// COM failure (either the initial `Suggest` call or a later `Next`) yields
/// whatever was collected so far rather than propagating an error — a
/// missing suggestion list is not worth failing the whole check over.
fn suggest_words(checker: &ISpellChecker, word: &str) -> Vec<String> {
    let hword = HSTRING::from(word);
    // SAFETY: `checker` is a valid, live COM object for the duration of this
    // call.
    let Ok(enum_strings) = (unsafe { checker.Suggest(&hword) }) else {
        return Vec::new();
    };

    let mut results = Vec::new();
    loop {
        let mut buf = [PWSTR::null()];
        let mut fetched = 0u32;
        // SAFETY: `enum_strings` is a valid, live COM object for the
        // duration of this call; `buf` is a valid one-element out array and
        // `fetched` a valid out-param.
        let hr = unsafe { enum_strings.Next(&mut buf, Some(&mut fetched)) };
        if hr != S_OK || fetched == 0 {
            break;
        }

        let pwstr = buf[0];
        results.push(pwstr_to_string(pwstr));
        free_pwstr(pwstr);
    }

    results
}

/// Decodes a COM-owned `PWSTR` into an owned `String`, lossily — the caller
/// is still responsible for freeing `pwstr` via [`free_pwstr`] afterwards.
/// `None`/null is decoded as an empty string.
fn pwstr_to_string(pwstr: PWSTR) -> String {
    if pwstr.is_null() {
        return String::new();
    }
    // SAFETY: `pwstr` was just returned by a Spell Checking API COM call
    // (`Replacement()` or `IEnumString::Next`) and is guaranteed valid for
    // reads up to its next NUL terminator until freed.
    let wide = unsafe { pwstr.as_wide() };
    String::from_utf16_lossy(wide)
}

/// Frees a `PWSTR` allocated by the Spell Checking API. Both `Replacement()`
/// and `IEnumString::Next` document that the caller owns the returned string
/// and must free it via `CoTaskMemFree`.
fn free_pwstr(pwstr: PWSTR) {
    if pwstr.is_null() {
        return;
    }
    // SAFETY: `pwstr` was allocated by a Spell Checking API COM call that
    // documents `CoTaskMemFree` as the correct way to release it, and is
    // freed here exactly once.
    unsafe { CoTaskMemFree(Some(pwstr.0 as *const c_void)) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn parse_multi_sz_handles_a_buffer_missing_the_trailing_double_nul() {
        // Not the real `MULTI_SZ` shape (no final extra NUL marking the end
        // of the whole list) — `split` still yields both entries correctly.
        let mut units: Vec<u16> = "de-DE".encode_utf16().collect();
        units.push(0);
        units.extend("en-US".encode_utf16());

        let tags = parse_multi_sz(&units);

        assert_eq!(tags, vec!["de-DE".to_string(), "en-US".to_string()]);
    }

    #[test]
    fn select_languages_skips_a_hyphen_less_unsupported_tag_and_asks_once() {
        let preferred = vec!["en".to_string()];
        let calls = Cell::new(0);
        let is_supported = |_tag: &str| -> bool {
            calls.set(calls.get() + 1);
            false
        };

        let selected = select_languages(&preferred, &is_supported);

        assert!(selected.is_empty());
        assert_eq!(
            calls.get(),
            1,
            "a hyphen-less tag has no distinct primary subtag to try again"
        );
    }

    #[test]
    fn parse_multi_sz_splits_on_embedded_nuls_and_drops_the_trailing_terminator() {
        // The real `MULTI_SZ` shape: each entry NUL-terminated, with a final
        // extra NUL marking the end of the whole list.
        let mut units: Vec<u16> = "en-US".encode_utf16().collect();
        units.push(0);
        units.extend("de-DE".encode_utf16());
        units.push(0);
        units.push(0);

        let tags = parse_multi_sz(&units);

        assert_eq!(tags, vec!["en-US".to_string(), "de-DE".to_string()]);
    }

    #[test]
    fn parse_multi_sz_handles_a_single_language() {
        let mut units: Vec<u16> = "fr-FR".encode_utf16().collect();
        units.push(0);
        units.push(0);

        let tags = parse_multi_sz(&units);

        assert_eq!(tags, vec!["fr-FR".to_string()]);
    }

    #[test]
    fn parse_multi_sz_handles_an_empty_buffer() {
        assert!(parse_multi_sz(&[]).is_empty());
        assert!(parse_multi_sz(&[0, 0]).is_empty());
    }

    #[test]
    fn select_languages_keeps_every_directly_supported_tag() {
        let preferred = vec!["en-US".to_string(), "fr-FR".to_string()];
        let selected = select_languages(&preferred, &|_tag| true);

        assert_eq!(selected, vec!["en-US".to_string(), "fr-FR".to_string()]);
    }

    #[test]
    fn select_languages_skips_a_tag_with_no_support_at_all() {
        let preferred = vec!["en-US".to_string(), "zz-ZZ".to_string()];
        let selected = select_languages(&preferred, &|tag| tag == "en-US");

        assert_eq!(selected, vec!["en-US".to_string()]);
    }

    #[test]
    fn select_languages_falls_back_to_the_primary_subtag() {
        let preferred = vec!["de-DE".to_string()];
        let selected = select_languages(&preferred, &|tag| tag == "de");

        assert_eq!(selected, vec!["de".to_string()]);
    }

    #[test]
    fn select_languages_collapses_duplicate_fallbacks() {
        let preferred = vec!["de-DE".to_string(), "de-AT".to_string()];
        let selected = select_languages(&preferred, &|tag| tag == "de");

        assert_eq!(selected, vec!["de".to_string()]);
    }

    #[test]
    fn select_languages_returns_empty_for_empty_input() {
        let selected = select_languages(&[], &|_tag| true);

        assert!(selected.is_empty());
    }

    /// Exercises the real Windows Spell Checking API end-to-end. Needs at
    /// least one Windows spell-checking language actually installed for the
    /// current user's display languages (a stock Windows 10/11 install ships
    /// English, so this should normally pass) — run explicitly with
    /// `cargo test real_windows -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn real_windows_spell_checker_flags_misspellings() {
        let checker = WindowsSpellChecker;
        let text = "Ths is a tset of the speling checker";

        let result = checker.check(text);

        match WORKER.get() {
            Some(Ok(handle)) => eprintln!("selected languages: {:?}", handle.languages),
            Some(Err(message)) => eprintln!("worker init failed: {message}"),
            None => eprintln!("worker was never initialized"),
        }
        eprintln!("result: {result:?}");

        let result = result.expect("the real Windows spell checker should succeed");

        let flagged: Vec<&str> = result
            .misspellings
            .iter()
            .map(|m| m.word.as_str())
            .collect();
        assert!(
            flagged
                .iter()
                .any(|w| ["Ths", "tset", "speling"].contains(w)),
            "expected at least one of Ths/tset/speling to be flagged, got {flagged:?}"
        );

        let units: Vec<u16> = text.encode_utf16().collect();
        for misspelling in &result.misspellings {
            let start = misspelling.start as usize;
            let end = start + misspelling.length as usize;
            let sliced = String::from_utf16_lossy(&units[start..end]);
            assert_eq!(
                sliced, misspelling.word,
                "start/length must slice `text` back to `word`"
            );
        }

        assert!(
            result
                .misspellings
                .iter()
                .any(|m| !m.suggestions.is_empty()),
            "expected at least one suggestion among the flagged words, got {:?}",
            result.misspellings
        );

        if let Some(Ok(handle)) = WORKER.get() {
            if handle.languages.iter().any(|tag| tag.starts_with("de")) {
                let german_result = checker.check("Das ist ein kleinner Test");
                eprintln!("German fixture result: {german_result:?}");
            }
        }
    }
}
