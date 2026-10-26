//! Keyboard shortcuts for the popover's actions and for user-managed
//! prompts: the `[Mod+][Alt+][Shift+]Key` chord grammar ([`Chord`]), the
//! rules every chord must satisfy ([`validate`]), and the load-validate-save
//! "core" functions the `assign_shortcut`/`reset_popover_shortcuts` commands
//! wrap thinly. `Mod` is platform-neutral — ⌘ on macOS, Ctrl elsewhere — so
//! a stored chord string means the same thing on every machine, the same
//! way [`crate::core::settings::default_shortcut`] already is for the
//! global shortcut.
//!
//! [`save_prompt_core`](crate::core::prompts::save_prompt_core) and
//! `set_settings`'s integrity check both go through
//! [`resolve_shortcut_assignment`] / [`validate_shortcut_changes`] below
//! rather than duplicating the conflict rules.

use serde::{Deserialize, Serialize};

use crate::core::settings::{Settings, SettingsError, SettingsStore};

/// One bindable key: a letter, a digit, a function key, Enter, or a single
/// printable punctuation character. Arrows, Space, Tab, Escape, Backspace
/// and Delete are deliberately not representable — [`parse_key`] simply has
/// no case that produces them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Letter(char),
    Digit(char),
    Function(u8),
    Enter,
    Punct(char),
}

impl std::fmt::Display for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Key::Letter(c) | Key::Digit(c) | Key::Punct(c) => write!(f, "{c}"),
            Key::Function(n) => write!(f, "F{n}"),
            Key::Enter => write!(f, "Enter"),
        }
    }
}

/// A parsed shortcut: `Mod` is ⌘ on macOS and Ctrl elsewhere (see the module
/// doc comment); `alt`/`shift` are literal. `Display` always renders the
/// canonical `[Mod+][Alt+][Shift+]Key` form, regardless of the order the
/// string was parsed from — every write path through this module stores
/// that canonical form, never the one the caller happened to pass in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    pub mod_: bool,
    pub alt: bool,
    pub shift: bool,
    pub key: Key,
}

impl std::fmt::Display for Chord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut parts = Vec::new();
        if self.mod_ {
            parts.push("Mod".to_string());
        }
        if self.alt {
            parts.push("Alt".to_string());
        }
        if self.shift {
            parts.push("Shift".to_string());
        }
        parts.push(self.key.to_string());
        write!(f, "{}", parts.join("+"))
    }
}

impl Chord {
    /// Parses a stored shortcut string. Modifier tokens (`Mod`/`Alt`/`Shift`)
    /// are accepted case-insensitively and in any order — only [`Display`]
    /// is canonical — but exactly one key token is required, and every
    /// other token must be a modifier.
    pub fn parse(raw: &str) -> Result<Chord, String> {
        if raw.trim().is_empty() {
            return Err("A shortcut can't be empty.".to_string());
        }

        let mut mod_ = false;
        let mut alt = false;
        let mut shift = false;
        let mut key: Option<Key> = None;

        for part in raw.split('+') {
            if part.is_empty() {
                return Err(format!("\"{raw}\" isn't a valid shortcut."));
            }
            match part.to_ascii_lowercase().as_str() {
                "mod" => mod_ = true,
                "alt" => alt = true,
                "shift" => shift = true,
                _ => {
                    if key.is_some() {
                        return Err("A shortcut can only have one key.".to_string());
                    }
                    key = Some(parse_key(part)?);
                }
            }
        }

        let key = key.ok_or_else(|| "A shortcut needs a key.".to_string())?;
        Ok(Chord {
            mod_,
            alt,
            shift,
            key,
        })
    }
}

/// Punctuation characters a shortcut may bind to as a key — the same set
/// [`parse_global_key`] already recognizes by name, plus `#` and `<`, which
/// sit unshifted on a German keyboard. Deliberately a closed set rather
/// than every ASCII punctuation character: a shifted glyph (`!`, `@`, `(`,
/// `?`, …) must never be its own key, because `Shift` is already a
/// separate flag in the chord grammar — accepting one would let, say,
/// `Mod+!` and `Mod+Shift+1` name the exact same physical keypress without
/// the duplicate-shortcut check ever noticing they collide.
fn is_bindable_punctuation(c: char) -> bool {
    matches!(
        c,
        ',' | '.' | '-' | '=' | ';' | '\'' | '/' | '\\' | '[' | ']' | '`' | '#' | '<'
    )
}

/// Parses a single key token: `A`-`Z`, `0`-`9`, `F1`-`F12`, `Enter`, or one
/// of the punctuation characters [`is_bindable_punctuation`] allows.
fn parse_key(token: &str) -> Result<Key, String> {
    let mut chars = token.chars();
    let first = chars
        .next()
        .ok_or_else(|| "A shortcut needs a key.".to_string())?;

    if chars.next().is_none() {
        if first.is_ascii_alphabetic() {
            return Ok(Key::Letter(first.to_ascii_uppercase()));
        }
        if first.is_ascii_digit() {
            return Ok(Key::Digit(first));
        }
        if is_bindable_punctuation(first) {
            return Ok(Key::Punct(first));
        }
        return Err(format!("\"{token}\" isn't a bindable key."));
    }

    if token.eq_ignore_ascii_case("enter") {
        return Ok(Key::Enter);
    }

    if token.len() >= 2 && (token.starts_with('F') || token.starts_with('f')) {
        if let Ok(n) = token[1..].parse::<u8>() {
            if (1..=12).contains(&n) {
                return Ok(Key::Function(n));
            }
        }
    }

    Err(format!("\"{token}\" isn't a bindable key."))
}

/// The platform's `Mod` symbol, used in error messages: "⌘" on macOS, "Ctrl"
/// elsewhere.
fn mod_symbol() -> &'static str {
    if cfg!(target_os = "macos") {
        "⌘"
    } else {
        "Ctrl"
    }
}

/// Renders `chord` the way this OS would show it: macOS joins `⌘⌥⇧` directly
/// against the key (with `↩` for Enter); elsewhere each token is spelled out
/// and joined with `+`.
pub fn format_for_display(chord: &Chord) -> String {
    if cfg!(target_os = "macos") {
        let mut s = String::new();
        if chord.mod_ {
            s.push('⌘');
        }
        if chord.alt {
            s.push('⌥');
        }
        if chord.shift {
            s.push('⇧');
        }
        s.push_str(&if chord.key == Key::Enter {
            "↩".to_string()
        } else {
            chord.key.to_string()
        });
        s
    } else {
        let mut parts = Vec::new();
        if chord.mod_ {
            parts.push("Ctrl".to_string());
        }
        if chord.alt {
            parts.push("Alt".to_string());
        }
        if chord.shift {
            parts.push("Shift".to_string());
        }
        parts.push(chord.key.to_string());
        parts.join("+")
    }
}

/// Validates `chord` against the fixed rule set: it must carry `Mod` unless
/// the key is a bare F-key, and it must not be one of the chords reserved
/// on every platform so a stored setting stays portable across machines.
pub fn validate(chord: &Chord) -> Result<(), String> {
    if !chord.mod_ && !matches!(chord.key, Key::Function(_)) {
        return Err(format!(
            "Add {} — plain keys would get in the way of typing.",
            mod_symbol()
        ));
    }

    if let Some(reason) = reserved_reason(chord) {
        return Err(format!("{} {reason}", format_for_display(chord)));
    }

    Ok(())
}

/// Reasons every reserved chord is rejected, after normalization: text
/// editing (copy/paste/cut/select-all/undo/redo), macOS system shortcuts
/// (quit/close/hide/minimize), and webview accelerators (reload/print/find/
/// dev tools) stay off-limits on every platform so a stored setting is
/// portable across machines. Checked as exact [`Chord`] equality, not
/// string comparison, so `Shift+Mod+C` and `Mod+Shift+C` are caught the
/// same way.
fn reserved_reason(chord: &Chord) -> Option<&'static str> {
    let plain = |key: Key| Chord {
        mod_: true,
        alt: false,
        shift: false,
        key,
    };
    let plain_shift = |key: Key| Chord {
        mod_: true,
        alt: false,
        shift: true,
        key,
    };
    let bare_function = |n: u8| Chord {
        mod_: false,
        alt: false,
        shift: false,
        key: Key::Function(n),
    };

    if *chord == plain(Key::Letter('C')) {
        return Some("is reserved for copying text.");
    }
    if *chord == plain(Key::Letter('V')) {
        return Some("is reserved for pasting text.");
    }
    if *chord == plain(Key::Letter('X')) {
        return Some("is reserved for cutting text.");
    }
    if *chord == plain(Key::Letter('A')) {
        return Some("is reserved for select all.");
    }
    if *chord == plain(Key::Letter('Z')) {
        return Some("is reserved for undo.");
    }
    if *chord == plain_shift(Key::Letter('Z')) {
        return Some("is reserved for redo.");
    }
    if *chord == plain(Key::Letter('Y')) {
        return Some("is reserved for redo.");
    }
    if *chord == plain(Key::Letter('Q')) {
        return Some("is reserved for quitting.");
    }
    if *chord == plain(Key::Letter('W')) {
        return Some("is reserved for closing the window.");
    }
    if *chord == plain(Key::Letter('H')) {
        return Some("is reserved for hiding the app.");
    }
    if *chord == plain(Key::Letter('M')) {
        return Some("is reserved for minimizing the window.");
    }
    if *chord == plain(Key::Letter('R')) {
        return Some("is reserved for reloading.");
    }
    if *chord == plain(Key::Letter('P')) {
        return Some("is reserved for printing.");
    }
    if *chord == plain(Key::Letter('F')) {
        return Some("is reserved for find.");
    }
    if *chord == plain(Key::Letter('G')) {
        return Some("is reserved for find next.");
    }
    if *chord == bare_function(5) {
        return Some("is reserved for reloading.");
    }
    if *chord == bare_function(7) {
        return Some("is reserved for spell-check.");
    }
    if *chord == bare_function(12) {
        return Some("is reserved for developer tools.");
    }

    None
}

/// Parses and validates a stored shortcut string in one step — the gate
/// every write path (assignment, prompt save, settings integrity) runs a
/// candidate value through before it's allowed to reach disk.
fn parse_and_validate(raw: &str) -> Result<Chord, String> {
    let chord = Chord::parse(raw)?;
    validate(&chord)?;
    Ok(chord)
}

/// Maps a Tauri global-shortcut accelerator string (`Alt+Cmd+K`,
/// `CommandOrControl+K`, …) onto the same chord space `Chord` occupies for
/// the current OS, so "does the global shortcut equal this popover chord"
/// is a value comparison rather than a string comparison. Returns `None`
/// when the accelerator uses a modifier with no popover equivalent on this
/// OS (macOS `Ctrl`, or `Super`/`Meta`/`Cmd` elsewhere) — such an
/// accelerator can never equal a popover chord, by construction.
pub fn chord_for_global(accelerator: &str) -> Option<Chord> {
    let macos = cfg!(target_os = "macos");

    let mut mod_ = false;
    let mut alt = false;
    let mut shift = false;
    let mut key: Option<Key> = None;

    for token in accelerator.split('+') {
        match token.to_ascii_lowercase().as_str() {
            "cmdorctrl" | "commandorcontrol" => mod_ = true,
            "cmd" | "command" | "super" | "meta" => {
                if macos {
                    mod_ = true;
                } else {
                    return None;
                }
            }
            "ctrl" | "control" => {
                if macos {
                    return None;
                }
                mod_ = true;
            }
            "alt" | "option" => alt = true,
            "shift" => shift = true,
            _ => {
                if key.is_some() {
                    return None;
                }
                key = Some(parse_global_key(token)?);
            }
        }
    }

    Some(Chord {
        mod_,
        alt,
        shift,
        key: key?,
    })
}

/// Parses one non-modifier accelerator token (`K`, `KeyK`, `1`, `Digit1`,
/// `F6`, `Comma`, `Enter`/`Return`, …) into the [`Key`] it names.
fn parse_global_key(token: &str) -> Option<Key> {
    let lower = token.to_ascii_lowercase();

    if lower == "enter" || lower == "return" {
        return Some(Key::Enter);
    }
    if let Some(rest) = strip_ci_prefix(token, "Key") {
        let mut chars = rest.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            if c.is_ascii_alphabetic() {
                return Some(Key::Letter(c.to_ascii_uppercase()));
            }
        }
    }
    if let Some(rest) = strip_ci_prefix(token, "Digit") {
        let mut chars = rest.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            if c.is_ascii_digit() {
                return Some(Key::Digit(c));
            }
        }
    }
    if let Some(rest) = strip_ci_prefix(token, "F") {
        if let Ok(n) = rest.parse::<u8>() {
            if (1..=12).contains(&n) {
                return Some(Key::Function(n));
            }
        }
    }
    if token.chars().count() == 1 {
        let c = token.chars().next().expect("checked count == 1 above");
        if c.is_ascii_alphabetic() {
            return Some(Key::Letter(c.to_ascii_uppercase()));
        }
        if c.is_ascii_digit() {
            return Some(Key::Digit(c));
        }
    }

    match lower.as_str() {
        "comma" => Some(Key::Punct(',')),
        "period" => Some(Key::Punct('.')),
        "minus" => Some(Key::Punct('-')),
        "equal" => Some(Key::Punct('=')),
        "semicolon" => Some(Key::Punct(';')),
        "quote" => Some(Key::Punct('\'')),
        "slash" => Some(Key::Punct('/')),
        "backslash" => Some(Key::Punct('\\')),
        "bracketleft" => Some(Key::Punct('[')),
        "bracketright" => Some(Key::Punct(']')),
        "backquote" => Some(Key::Punct('`')),
        _ => None,
    }
}

/// Case-insensitively strips `prefix` from the front of `token`, but only
/// when something is left afterwards — `strip_ci_prefix("F", "F")` is
/// `None`, not `Some("")`, so a bare `"F"` still falls through to the
/// single-letter-key case in [`parse_global_key`] instead of being treated
/// as a truncated function key.
fn strip_ci_prefix<'a>(token: &'a str, prefix: &str) -> Option<&'a str> {
    if token.len() > prefix.len()
        && token.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
    {
        Some(&token[prefix.len()..])
    } else {
        None
    }
}

/// What a chord is bound to: a popover action, a prompt (by id), or the
/// global "open Kallilex" shortcut. Serialized as a tagged union so the
/// frontend can pass one straight through to [`assign_shortcut`] without a
/// separate "kind" parameter.
///
/// [`assign_shortcut`]: crate::commands::assign_shortcut
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ShortcutTarget {
    Action { action: PopoverAction },
    Prompt { id: String },
    Global,
}

/// A popover action with a configurable shortcut. Pin is never bound to a
/// key, so it isn't a variant here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PopoverAction {
    Replace,
    Copy,
    CustomPrompt,
    OpenSettings,
    CheckSpelling,
}

const ALL_ACTIONS: [PopoverAction; 5] = [
    PopoverAction::Replace,
    PopoverAction::Copy,
    PopoverAction::CustomPrompt,
    PopoverAction::OpenSettings,
    PopoverAction::CheckSpelling,
];

fn action_label(action: PopoverAction) -> &'static str {
    match action {
        PopoverAction::Replace => "Replace",
        PopoverAction::Copy => "Copy",
        PopoverAction::CustomPrompt => "Custom prompt",
        PopoverAction::OpenSettings => "Open Settings",
        PopoverAction::CheckSpelling => "Check spelling",
    }
}

/// The popover's per-action shortcuts. Missing fields (an older
/// `settings.json`, or a field added later) fall back to
/// [`PopoverShortcuts::default`]'s table via the struct-level
/// `#[serde(default)]` below, while a field explicitly written as `null`
/// (the user removed that shortcut) deserializes straight to `None` and
/// stays removed — the two cases need different outcomes, which is exactly
/// what a container-level default (rather than one `#[serde(default = ..)]`
/// per field) gives for free: serde fills in whichever fields are *absent*
/// from `Self::default()`, and only those.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PopoverShortcuts {
    pub replace: Option<String>,
    pub copy: Option<String>,
    pub custom_prompt: Option<String>,
    pub open_settings: Option<String>,
    pub check_spelling: Option<String>,
}

impl Default for PopoverShortcuts {
    fn default() -> Self {
        Self {
            replace: Some("Mod+Enter".to_string()),
            copy: Some("Mod+Shift+C".to_string()),
            custom_prompt: Some("Mod+L".to_string()),
            open_settings: Some("Mod+,".to_string()),
            check_spelling: None,
        }
    }
}

fn action_slot(settings: &Settings, action: PopoverAction) -> Option<String> {
    match action {
        PopoverAction::Replace => settings.popover_shortcuts.replace.clone(),
        PopoverAction::Copy => settings.popover_shortcuts.copy.clone(),
        PopoverAction::CustomPrompt => settings.popover_shortcuts.custom_prompt.clone(),
        PopoverAction::OpenSettings => settings.popover_shortcuts.open_settings.clone(),
        PopoverAction::CheckSpelling => settings.popover_shortcuts.check_spelling.clone(),
    }
}

fn set_action_slot(settings: &mut Settings, action: PopoverAction, value: Option<String>) {
    let slot = match action {
        PopoverAction::Replace => &mut settings.popover_shortcuts.replace,
        PopoverAction::Copy => &mut settings.popover_shortcuts.copy,
        PopoverAction::CustomPrompt => &mut settings.popover_shortcuts.custom_prompt,
        PopoverAction::OpenSettings => &mut settings.popover_shortcuts.open_settings,
        PopoverAction::CheckSpelling => &mut settings.popover_shortcuts.check_spelling,
    };
    *slot = value;
}

/// Writes `value` into whatever `target` points at. Every caller reaches
/// this with a `target` that was already established to be a popover
/// action or a prompt — the global shortcut is always assigned directly by
/// [`assign_shortcut_core`]'s own `global` branch, never through this path
/// — but since `target` ultimately comes from parsed user input (a
/// conflict's reported holder, or the command parameter itself), the
/// `Global` case returns an error here rather than panicking if that
/// invariant is ever wrong.
fn set_target_shortcut(
    settings: &mut Settings,
    target: &ShortcutTarget,
    value: Option<String>,
) -> Result<(), String> {
    match target {
        ShortcutTarget::Action { action } => set_action_slot(settings, *action, value),
        ShortcutTarget::Prompt { id } => {
            if let Some(prompt) = settings.prompts.iter_mut().find(|p| &p.id == id) {
                prompt.shortcut = value;
            }
        }
        ShortcutTarget::Global => {
            return Err("The global shortcut can't be assigned this way.".to_string());
        }
    }
    Ok(())
}

fn clear_holder(settings: &mut Settings, holder: &ShortcutTarget) -> Result<(), String> {
    set_target_shortcut(settings, holder, None)
}

fn describe_target(settings: &Settings, target: &ShortcutTarget) -> String {
    match target {
        ShortcutTarget::Action { action } => action_label(*action).to_string(),
        ShortcutTarget::Prompt { id } => settings
            .prompts
            .iter()
            .find(|p| &p.id == id)
            .map(|p| p.label.clone())
            .unwrap_or_else(|| "a prompt".to_string()),
        ShortcutTarget::Global => "opening Kallilex".to_string(),
    }
}

fn conflict_message(settings: &Settings, chord: &Chord, holder: &ShortcutTarget) -> String {
    format!(
        "{} is used by \"{}\".",
        format_for_display(chord),
        describe_target(settings, holder)
    )
}

/// Finds whichever popover action or prompt currently holds `chord`, not
/// counting the global shortcut.
fn holder_in_popover_or_prompts(settings: &Settings, chord: &Chord) -> Option<ShortcutTarget> {
    for action in ALL_ACTIONS {
        if let Some(raw) = action_slot(settings, action) {
            if Chord::parse(&raw).ok().as_ref() == Some(chord) {
                return Some(ShortcutTarget::Action { action });
            }
        }
    }
    for prompt in &settings.prompts {
        if let Some(raw) = &prompt.shortcut {
            if Chord::parse(raw).ok().as_ref() == Some(chord) {
                return Some(ShortcutTarget::Prompt {
                    id: prompt.id.clone(),
                });
            }
        }
    }
    None
}

/// Finds whatever currently holds `chord` — a popover action, a prompt, or
/// the global shortcut (compared as a chord via [`chord_for_global`], not as
/// a string).
pub fn holder_of(settings: &Settings, chord: &Chord) -> Option<ShortcutTarget> {
    holder_in_popover_or_prompts(settings, chord).or_else(|| {
        (chord_for_global(&settings.shortcut) == Some(*chord)).then_some(ShortcutTarget::Global)
    })
}

/// Errors from the shortcut "core" functions below, modeled on
/// [`crate::core::prompts::PromptOpError`].
#[derive(Debug, thiserror::Error)]
pub enum ShortcutOpError {
    #[error("{0}")]
    Validation(String),
    #[error(transparent)]
    Settings(#[from] SettingsError),
}

/// Validates `raw`, resolves any conflict against `target`'s current
/// holder, and returns the canonical string to store — the shared logic
/// behind both [`assign_shortcut_core`]'s popover/prompt branch and
/// [`crate::core::prompts::save_prompt_core`]'s shortcut handling. A target
/// that already holds `raw` itself (re-saving the same value) is not a
/// conflict. The global shortcut can never be taken over, regardless of
/// `take_over`.
pub fn resolve_shortcut_assignment(
    settings: &mut Settings,
    target: &ShortcutTarget,
    raw: &str,
    take_over: bool,
) -> Result<String, String> {
    let chord = parse_and_validate(raw)?;

    if let Some(holder) = holder_of(settings, &chord) {
        if &holder == target {
            // Already held by this very target — nothing to resolve.
        } else if holder == ShortcutTarget::Global {
            return Err("Already used to open Kallilex.".to_string());
        } else if take_over {
            clear_holder(settings, &holder)?;
        } else {
            return Err(conflict_message(settings, &chord, &holder));
        }
    }

    Ok(chord.to_string())
}

/// Assigns (or, with `shortcut: None`, clears) the shortcut for `target`:
/// one load, mutate, save. See [`resolve_shortcut_assignment`] for the
/// conflict/take-over rules applied to popover and prompt targets.
///
/// The `global` target is handled separately: `shortcut` is required (the
/// global shortcut always has a value), it is *not* run through [`Chord`]
/// parsing — it's a Tauri accelerator string, not popover-chord grammar —
/// and it can take over a conflicting popover/prompt chord but can never
/// itself be taken over. Syntactic validation of the accelerator and its
/// (un)registration with the OS happen in the `assign_shortcut` command, not
/// here.
pub fn assign_shortcut_core(
    store: &dyn SettingsStore,
    target: ShortcutTarget,
    shortcut: Option<String>,
    take_over: bool,
) -> Result<Settings, ShortcutOpError> {
    let mut settings = store.load()?;

    if target == ShortcutTarget::Global {
        let accelerator = shortcut.ok_or_else(|| {
            ShortcutOpError::Validation("The global shortcut can't be removed.".to_string())
        })?;

        if let Some(chord) = chord_for_global(&accelerator) {
            if let Some(holder) = holder_in_popover_or_prompts(&settings, &chord) {
                if take_over {
                    clear_holder(&mut settings, &holder).map_err(ShortcutOpError::Validation)?;
                } else {
                    return Err(ShortcutOpError::Validation(conflict_message(
                        &settings, &chord, &holder,
                    )));
                }
            }
        }

        settings.shortcut = accelerator;
        store.save(&settings)?;
        return Ok(settings);
    }

    if let ShortcutTarget::Prompt { id } = &target {
        if !settings.prompts.iter().any(|p| &p.id == id) {
            return Err(ShortcutOpError::Validation(format!(
                "No prompt with id \"{id}\"."
            )));
        }
    }

    let canonical = match shortcut {
        Some(raw) => Some(
            resolve_shortcut_assignment(&mut settings, &target, &raw, take_over)
                .map_err(ShortcutOpError::Validation)?,
        ),
        None => None,
    };

    set_target_shortcut(&mut settings, &target, canonical).map_err(ShortcutOpError::Validation)?;

    store.save(&settings)?;
    Ok(settings)
}

/// Resets every popover shortcut to [`PopoverShortcuts::default`] and
/// re-seeds the first nine prompts with `Mod+1`…`Mod+9` after clearing
/// every prompt's shortcut — unconditionally, since the defaults and
/// `Mod+1`…`Mod+9` never collide with each other. The global shortcut is
/// untouched.
pub fn reset_popover_shortcuts_core(store: &dyn SettingsStore) -> Result<Settings, SettingsError> {
    let mut settings = store.load()?;

    settings.popover_shortcuts = PopoverShortcuts::default();
    for prompt in &mut settings.prompts {
        prompt.shortcut = None;
    }
    for (index, prompt) in settings.prompts.iter_mut().take(9).enumerate() {
        prompt.shortcut = Some(format!("Mod+{}", index + 1));
    }

    store.save(&settings)?;
    Ok(settings)
}

/// One-time migration from a pre-shortcuts `settings.json`: walks the first
/// nine prompts in list order and gives prompt *i* `Mod+i` if it has no
/// shortcut of its own and `Mod+i` isn't already used by a popover action
/// (checked fresh on every iteration, so an earlier prompt this same run
/// just claimed `Mod+1` can never collide with `Mod+1` again — there's
/// nothing left in the first-nine range that would). Idempotent: once
/// `prompt_shortcuts_seeded` is set it short-circuits immediately, so a
/// shortcut the user later removes stays removed.
pub fn seed_prompt_shortcuts(store: &dyn SettingsStore) -> Result<(), SettingsError> {
    let mut settings = store.load()?;
    if settings.prompt_shortcuts_seeded {
        return Ok(());
    }

    let candidate_count = settings.prompts.len().min(9);
    for index in 0..candidate_count {
        if settings.prompts[index].shortcut.is_some() {
            continue;
        }
        let candidate = format!("Mod+{}", index + 1);
        let chord = Chord::parse(&candidate).expect("Mod+<digit> is always a valid chord");
        if holder_of(&settings, &chord).is_some() {
            continue;
        }
        settings.prompts[index].shortcut = Some(candidate);
    }

    settings.prompt_shortcuts_seeded = true;
    store.save(&settings)
}

/// Popover actions whose stored value differs between `previous` and `next`.
fn changed_popover_actions(previous: &Settings, next: &Settings) -> Vec<PopoverAction> {
    ALL_ACTIONS
        .into_iter()
        .filter(|&action| action_slot(previous, action) != action_slot(next, action))
        .collect()
}

/// Ids of prompts in `next` whose shortcut differs from what that same id
/// had in `previous` — a prompt that only changed position, label or
/// instruction doesn't count, and neither does a prompt that simply isn't
/// in `previous` at all unless the new entry itself carries a shortcut.
fn changed_prompt_ids(previous: &Settings, next: &Settings) -> Vec<String> {
    next.prompts
        .iter()
        .filter(|p| match previous.prompts.iter().find(|pp| pp.id == p.id) {
            Some(prev) => prev.shortcut != p.shortcut,
            None => p.shortcut.is_some(),
        })
        .map(|p| p.id.clone())
        .collect()
}

/// Every popover action and prompt shortcut currently in `settings` that
/// parses to a valid [`Chord`], paired with the target it belongs to.
/// Deliberately silent about anything that fails to parse — an invalid
/// stored value (hand-edited, or left over from before a key was reserved)
/// has nothing to collide with, and must not be forced into this list just
/// to report it as broken.
fn all_current_bindings(settings: &Settings) -> Vec<(ShortcutTarget, Chord)> {
    let mut bindings = Vec::new();

    for action in ALL_ACTIONS {
        if let Some(raw) = action_slot(settings, action) {
            if let Ok(chord) = Chord::parse(&raw) {
                bindings.push((ShortcutTarget::Action { action }, chord));
            }
        }
    }
    for prompt in &settings.prompts {
        if let Some(raw) = &prompt.shortcut {
            if let Ok(chord) = Chord::parse(raw) {
                bindings.push((
                    ShortcutTarget::Prompt {
                        id: prompt.id.clone(),
                    },
                    chord,
                ));
            }
        }
    }

    bindings
}

/// Validates (and canonicalizes) the popover/prompt shortcuts that actually
/// changed between `previous` and `next`, for the `set_settings` command.
/// Item-grained on purpose: a save that didn't touch a given action or
/// prompt's shortcut must go through untouched, however it was left on
/// disk — reordering the prompt list, removing a prompt, or an unrelated
/// field changing elsewhere must never trip on some other window's (or a
/// hand-edited `settings.json`'s) already-invalid value.
///
/// Each changed item is checked against the chord grammar, the reserved
/// list, the global shortcut, and every other *current* binding in `next` —
/// changed or not — so a newly-typed duplicate of an untouched shortcut is
/// still caught. When the global shortcut itself changed, it's additionally
/// checked against every current popover/prompt chord (a popover shortcut
/// can never equal the global one, mirroring [`assign_shortcut_core`]'s
/// rule in the other direction).
pub fn validate_shortcut_changes(previous: &Settings, next: &mut Settings) -> Result<(), String> {
    let changed_actions = changed_popover_actions(previous, next);
    let changed_prompt_ids = changed_prompt_ids(previous, next);

    if !changed_actions.is_empty() || !changed_prompt_ids.is_empty() {
        let global_chord = chord_for_global(&next.shortcut);
        let existing_bindings = all_current_bindings(next);

        for action in changed_actions {
            if let Some(raw) = action_slot(next, action) {
                let target = ShortcutTarget::Action { action };
                let chord =
                    check_changed_item(&raw, &target, next, global_chord, &existing_bindings)?;
                set_action_slot(next, action, Some(chord.to_string()));
            }
        }

        for id in changed_prompt_ids {
            let Some(index) = next.prompts.iter().position(|p| p.id == id) else {
                continue;
            };
            let Some(raw) = next.prompts[index].shortcut.clone() else {
                continue;
            };
            let target = ShortcutTarget::Prompt { id };
            let chord = check_changed_item(&raw, &target, next, global_chord, &existing_bindings)?;
            next.prompts[index].shortcut = Some(chord.to_string());
        }
    }

    if next.shortcut != previous.shortcut {
        if let Some(chord) = chord_for_global(&next.shortcut) {
            if let Some(holder) = holder_in_popover_or_prompts(next, &chord) {
                return Err(conflict_message(next, &chord, &holder));
            }
        }
    }

    Ok(())
}

/// Validates one changed item's raw value against the chord grammar, the
/// global shortcut, and `existing_bindings` (every other current binding,
/// itself excluded by target) — the per-item check
/// [`validate_shortcut_changes`] runs for each changed action/prompt.
fn check_changed_item(
    raw: &str,
    target: &ShortcutTarget,
    settings: &Settings,
    global_chord: Option<Chord>,
    existing_bindings: &[(ShortcutTarget, Chord)],
) -> Result<Chord, String> {
    let chord = parse_and_validate(raw)?;

    if Some(chord) == global_chord {
        return Err(format!(
            "{} can't also be the global shortcut.",
            describe_target(settings, target)
        ));
    }

    if let Some((other_target, _)) = existing_bindings
        .iter()
        .find(|(other_target, other_chord)| other_target != target && *other_chord == chord)
    {
        return Err(format!(
            "{} and {} can't share the same shortcut.",
            describe_target(settings, target),
            describe_target(settings, other_target)
        ));
    }

    Ok(chord)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::prompts::CustomPrompt;
    use crate::core::settings::InMemorySettingsStore;

    fn prompt(id: &str, shortcut: Option<&str>) -> CustomPrompt {
        CustomPrompt {
            id: id.to_string(),
            label: format!("Prompt {id}"),
            instruction: "Do something.".to_string(),
            shortcut: shortcut.map(|s| s.to_string()),
        }
    }

    // ---- Chord parse/format -------------------------------------------

    #[test]
    fn parses_and_formats_a_simple_letter_chord() {
        let chord = Chord::parse("Mod+L").unwrap();
        assert_eq!(chord.to_string(), "Mod+L");
    }

    #[test]
    fn parsing_is_case_insensitive_and_order_independent_but_display_is_canonical() {
        let chord = Chord::parse("shift+mod+c").unwrap();
        assert_eq!(chord.to_string(), "Mod+Shift+C");

        let same_order_different_case = Chord::parse("SHIFT+MOD+C").unwrap();
        assert_eq!(chord, same_order_different_case);
    }

    #[test]
    fn lowercase_letters_are_canonicalized_to_uppercase() {
        assert_eq!(Chord::parse("Mod+l").unwrap().to_string(), "Mod+L");
    }

    #[test]
    fn digits_round_trip() {
        assert_eq!(Chord::parse("Mod+1").unwrap().to_string(), "Mod+1");
    }

    #[test]
    fn function_keys_round_trip_without_mod() {
        assert_eq!(Chord::parse("F6").unwrap().to_string(), "F6");
    }

    #[test]
    fn function_keys_allow_shift_and_alt_without_mod() {
        assert!(Chord::parse("Shift+F6").is_ok());
        assert!(Chord::parse("Alt+F6").is_ok());
        assert!(Chord::parse("Alt+Shift+F6").is_ok());
    }

    #[test]
    fn enter_round_trips() {
        assert_eq!(Chord::parse("Mod+Enter").unwrap().to_string(), "Mod+Enter");
    }

    #[test]
    fn punctuation_round_trips() {
        assert_eq!(Chord::parse("Mod+,").unwrap().to_string(), "Mod+,");
    }

    #[test]
    fn every_bindable_punctuation_character_is_accepted() {
        for c in [
            ',', '.', '-', '=', ';', '\'', '/', '\\', '[', ']', '`', '#', '<',
        ] {
            let raw = format!("Mod+{c}");
            assert!(Chord::parse(&raw).is_ok(), "{raw} should be accepted");
        }
    }

    #[test]
    fn shifted_glyphs_are_rejected_as_keys_rather_than_aliasing_shift_plus_the_base_key() {
        // `!` and `@` are what Shift+1/Shift+2 type on a US layout — if they
        // were accepted as keys in their own right, `Mod+!` and
        // `Mod+Shift+1` could both end up meaning the same physical
        // keypress without the duplicate-shortcut check ever catching it.
        assert!(Chord::parse("Mod+!").is_err());
        assert!(Chord::parse("Mod+@").is_err());
    }

    #[test]
    fn plus_cannot_be_used_as_a_key() {
        assert!(Chord::parse("Mod++").is_err());
    }

    #[test]
    fn unknown_keys_are_rejected() {
        for raw in [
            "Mod+Space",
            "Mod+Tab",
            "Mod+Escape",
            "Mod+Backspace",
            "Mod+Delete",
            "Mod+Up",
        ] {
            assert!(Chord::parse(raw).is_err(), "{raw} should be rejected");
        }
    }

    #[test]
    fn a_key_with_no_modifier_is_rejected_unless_it_is_a_bare_function_key() {
        assert!(validate(&Chord::parse("L").unwrap()).is_err());
        assert!(validate(&Chord::parse("Shift+L").unwrap()).is_err());
        assert!(validate(&Chord::parse("Alt+L").unwrap()).is_err());
        assert!(validate(&Chord::parse("F6").unwrap()).is_ok());
    }

    #[test]
    fn every_reserved_chord_is_rejected() {
        let reserved = [
            "Mod+C",
            "Mod+V",
            "Mod+X",
            "Mod+A",
            "Mod+Z",
            "Mod+Shift+Z",
            "Mod+Y",
            "Mod+Q",
            "Mod+W",
            "Mod+H",
            "Mod+M",
            "Mod+R",
            "Mod+P",
            "Mod+F",
            "Mod+G",
            "F5",
            "F7",
            "F12",
        ];
        for raw in reserved {
            let chord = Chord::parse(raw).unwrap();
            assert!(validate(&chord).is_err(), "{raw} should be reserved");
        }
    }

    #[test]
    fn a_non_reserved_chord_validates() {
        assert!(validate(&Chord::parse("Mod+9").unwrap()).is_ok());
    }

    // ---- chord_for_global -----------------------------------------------

    #[test]
    fn chord_for_global_maps_the_platform_default_to_mod_alt_k() {
        let accelerator = if cfg!(target_os = "macos") {
            "Alt+Cmd+K"
        } else {
            "Ctrl+Alt+K"
        };
        assert_eq!(
            chord_for_global(accelerator),
            Some(Chord {
                mod_: true,
                alt: true,
                shift: false,
                key: Key::Letter('K'),
            })
        );
    }

    #[test]
    fn chord_for_global_recognizes_key_and_digit_tokens() {
        assert_eq!(
            chord_for_global("CmdOrCtrl+KeyK").unwrap().key,
            Key::Letter('K')
        );
        assert_eq!(
            chord_for_global("CmdOrCtrl+Digit1").unwrap().key,
            Key::Digit('1')
        );
        assert_eq!(
            chord_for_global("CmdOrCtrl+Comma").unwrap().key,
            Key::Punct(',')
        );
        assert_eq!(chord_for_global("CmdOrCtrl+Enter").unwrap().key, Key::Enter);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn chord_for_global_treats_macos_ctrl_as_having_no_popover_equivalent() {
        assert_eq!(chord_for_global("Ctrl+K"), None);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn chord_for_global_treats_non_macos_super_as_having_no_popover_equivalent() {
        assert_eq!(chord_for_global("Super+K"), None);
    }

    // ---- holder_of --------------------------------------------------------

    #[test]
    fn holder_of_finds_a_popover_action() {
        let settings = Settings::default();
        let chord = Chord::parse("Mod+Enter").unwrap();
        assert_eq!(
            holder_of(&settings, &chord),
            Some(ShortcutTarget::Action {
                action: PopoverAction::Replace
            })
        );
    }

    #[test]
    fn holder_of_finds_a_prompt() {
        let settings = Settings {
            prompts: vec![prompt("a", Some("Mod+9"))],
            ..Settings::default()
        };
        let chord = Chord::parse("Mod+9").unwrap();
        assert_eq!(
            holder_of(&settings, &chord),
            Some(ShortcutTarget::Prompt {
                id: "a".to_string()
            })
        );
    }

    #[test]
    fn holder_of_finds_the_global_shortcut() {
        let settings = Settings::default();
        let global_chord = chord_for_global(&settings.shortcut).unwrap();
        assert_eq!(
            holder_of(&settings, &global_chord),
            Some(ShortcutTarget::Global)
        );
    }

    #[test]
    fn holder_of_returns_none_for_a_free_chord() {
        let settings = Settings::default();
        let chord = Chord::parse("Mod+9").unwrap();
        assert_eq!(holder_of(&settings, &chord), None);
    }

    // ---- assign_shortcut_core ----------------------------------------------

    #[test]
    fn assigns_a_free_shortcut_to_a_popover_action() {
        let store = InMemorySettingsStore::new();
        let target = ShortcutTarget::Action {
            action: PopoverAction::CheckSpelling,
        };

        let settings = assign_shortcut_core(&store, target, Some("mod+shift+s".to_string()), false)
            .expect("should succeed");

        assert_eq!(
            settings.popover_shortcuts.check_spelling.as_deref(),
            Some("Mod+Shift+S")
        );
    }

    #[test]
    fn assigning_a_conflicting_shortcut_without_take_over_fails_and_writes_nothing() {
        let store = InMemorySettingsStore::new();
        let target = ShortcutTarget::Action {
            action: PopoverAction::CheckSpelling,
        };

        let result = assign_shortcut_core(&store, target, Some("Mod+L".to_string()), false);

        assert!(matches!(result, Err(ShortcutOpError::Validation(_))));
        let after = store.load().unwrap();
        assert_eq!(after, Settings::default());
    }

    #[test]
    fn assigning_a_conflicting_shortcut_with_take_over_clears_the_other_holder() {
        let store = InMemorySettingsStore::new();
        let target = ShortcutTarget::Action {
            action: PopoverAction::CheckSpelling,
        };

        let settings = assign_shortcut_core(&store, target, Some("Mod+L".to_string()), true)
            .expect("should succeed");

        assert_eq!(
            settings.popover_shortcuts.check_spelling.as_deref(),
            Some("Mod+L")
        );
        assert_eq!(settings.popover_shortcuts.custom_prompt, None);
    }

    #[test]
    fn assigning_none_clears_a_popover_shortcut() {
        let store = InMemorySettingsStore::new();
        let target = ShortcutTarget::Action {
            action: PopoverAction::Replace,
        };

        let settings = assign_shortcut_core(&store, target, None, false).expect("should succeed");

        assert_eq!(settings.popover_shortcuts.replace, None);
    }

    #[test]
    fn assigning_a_shortcut_to_an_unknown_prompt_fails() {
        let store = InMemorySettingsStore::new();
        let target = ShortcutTarget::Prompt {
            id: "missing".to_string(),
        };

        let result = assign_shortcut_core(&store, target, Some("Mod+9".to_string()), false);

        assert!(matches!(result, Err(ShortcutOpError::Validation(_))));
    }

    #[test]
    fn assigning_none_to_the_global_target_fails() {
        let store = InMemorySettingsStore::new();

        let result = assign_shortcut_core(&store, ShortcutTarget::Global, None, false);

        assert!(matches!(result, Err(ShortcutOpError::Validation(_))));
    }

    #[test]
    fn a_popover_chord_cannot_take_over_the_global_shortcut() {
        let store = InMemorySettingsStore::new();
        let global_accelerator = Settings::default().shortcut;
        let global_chord = chord_for_global(&global_accelerator).unwrap();
        let target = ShortcutTarget::Action {
            action: PopoverAction::CheckSpelling,
        };

        let result = assign_shortcut_core(&store, target, Some(global_chord.to_string()), true);

        assert!(matches!(result, Err(ShortcutOpError::Validation(_))));
    }

    #[test]
    fn assigning_the_global_target_can_take_over_a_popover_chord() {
        let store = InMemorySettingsStore::new();
        // `Mod+L` is the default Custom-prompt shortcut; map it onto a
        // global accelerator string in the same chord space.
        let accelerator = if cfg!(target_os = "macos") {
            "Cmd+L".to_string()
        } else {
            "Ctrl+L".to_string()
        };

        let settings = assign_shortcut_core(
            &store,
            ShortcutTarget::Global,
            Some(accelerator.clone()),
            true,
        )
        .expect("should succeed");

        assert_eq!(settings.shortcut, accelerator);
        assert_eq!(settings.popover_shortcuts.custom_prompt, None);
    }

    #[test]
    fn assigning_the_global_target_without_take_over_fails_on_conflict() {
        let store = InMemorySettingsStore::new();
        let accelerator = if cfg!(target_os = "macos") {
            "Cmd+L".to_string()
        } else {
            "Ctrl+L".to_string()
        };

        let result = assign_shortcut_core(&store, ShortcutTarget::Global, Some(accelerator), false);

        assert!(matches!(result, Err(ShortcutOpError::Validation(_))));
        assert_eq!(store.load().unwrap(), Settings::default());
    }

    // ---- reset_popover_shortcuts_core ---------------------------------------

    #[test]
    fn reset_restores_defaults_and_reseeds_prompts_in_order_without_touching_the_global_shortcut() {
        let store = InMemorySettingsStore::new();
        let settings = Settings {
            shortcut: "Ctrl+Alt+K".to_string(),
            popover_shortcuts: PopoverShortcuts {
                replace: None,
                check_spelling: Some("Mod+Shift+S".to_string()),
                ..PopoverShortcuts::default()
            },
            prompts: vec![
                prompt("a", None),
                prompt("b", Some("Mod+5")),
                prompt("c", None),
            ],
            ..Settings::default()
        };
        store.save(&settings).unwrap();

        let after = reset_popover_shortcuts_core(&store).expect("should succeed");

        assert_eq!(after.popover_shortcuts, PopoverShortcuts::default());
        assert_eq!(after.shortcut, "Ctrl+Alt+K");
        assert_eq!(after.prompts[0].shortcut.as_deref(), Some("Mod+1"));
        assert_eq!(after.prompts[1].shortcut.as_deref(), Some("Mod+2"));
        assert_eq!(after.prompts[2].shortcut.as_deref(), Some("Mod+3"));
    }

    // ---- seed_prompt_shortcuts (migration) ----------------------------------

    #[test]
    fn migration_seeds_mod_1_through_3_for_an_old_settings_json_without_shortcuts() {
        let store = InMemorySettingsStore::new();
        let settings = Settings {
            prompt_shortcuts_seeded: false,
            prompts: vec![prompt("a", None), prompt("b", None), prompt("c", None)],
            ..Settings::default()
        };
        store.save(&settings).unwrap();

        seed_prompt_shortcuts(&store).expect("should succeed");

        let after = store.load().unwrap();
        assert_eq!(after.prompts[0].shortcut.as_deref(), Some("Mod+1"));
        assert_eq!(after.prompts[1].shortcut.as_deref(), Some("Mod+2"));
        assert_eq!(after.prompts[2].shortcut.as_deref(), Some("Mod+3"));
        assert!(after.prompt_shortcuts_seeded);
    }

    #[test]
    fn migration_is_idempotent() {
        let store = InMemorySettingsStore::new();
        let settings = Settings {
            prompt_shortcuts_seeded: false,
            prompts: vec![prompt("a", None)],
            ..Settings::default()
        };
        store.save(&settings).unwrap();

        seed_prompt_shortcuts(&store).unwrap();
        // The user removes the shortcut the migration just seeded...
        let mut after_first_run = store.load().unwrap();
        after_first_run.prompts[0].shortcut = None;
        store.save(&after_first_run).unwrap();

        // ...a second run must not bring it back, because the flag is set.
        seed_prompt_shortcuts(&store).unwrap();

        assert_eq!(store.load().unwrap().prompts[0].shortcut, None);
    }

    #[test]
    fn migration_skips_a_slot_already_taken_by_a_popover_action() {
        let store = InMemorySettingsStore::new();
        let settings = Settings {
            prompt_shortcuts_seeded: false,
            popover_shortcuts: PopoverShortcuts {
                check_spelling: Some("Mod+2".to_string()),
                ..PopoverShortcuts::default()
            },
            prompts: vec![prompt("a", None), prompt("b", None), prompt("c", None)],
            ..Settings::default()
        };
        store.save(&settings).unwrap();

        seed_prompt_shortcuts(&store).unwrap();

        let after = store.load().unwrap();
        assert_eq!(after.prompts[0].shortcut.as_deref(), Some("Mod+1"));
        assert_eq!(after.prompts[1].shortcut, None);
        assert_eq!(after.prompts[2].shortcut.as_deref(), Some("Mod+3"));
    }

    #[test]
    fn migration_never_touches_prompts_past_the_ninth() {
        let store = InMemorySettingsStore::new();
        let settings = Settings {
            prompt_shortcuts_seeded: false,
            prompts: (1..=10).map(|n| prompt(&n.to_string(), None)).collect(),
            ..Settings::default()
        };
        store.save(&settings).unwrap();

        seed_prompt_shortcuts(&store).unwrap();

        let after = store.load().unwrap();
        assert_eq!(after.prompts[9].shortcut, None);
    }

    #[test]
    fn migration_on_a_fresh_store_changes_nothing() {
        // A fresh install's `Settings::default()` already has
        // `prompt_shortcuts_seeded: true` and pre-seeded prompts — the
        // migration has nothing left to do and must leave it byte-for-byte
        // identical, not just functionally equivalent.
        let store = InMemorySettingsStore::new();
        let before = store.load().unwrap();

        seed_prompt_shortcuts(&store).unwrap();

        assert_eq!(store.load().unwrap(), before);
    }

    // ---- validate_shortcut_changes (set_settings integrity) -----------------

    #[test]
    fn unchanged_invalid_stored_shortcuts_do_not_block_an_unrelated_save() {
        let previous = Settings {
            prompts: vec![prompt("a", Some("totally not a shortcut"))],
            ..Settings::default()
        };
        let mut next = previous.clone();
        next.spellcheck_enabled = !previous.spellcheck_enabled;

        assert!(validate_shortcut_changes(&previous, &mut next).is_ok());
    }

    #[test]
    fn a_changed_duplicate_shortcut_is_rejected() {
        let previous = Settings::default();
        let mut next = previous.clone();
        next.popover_shortcuts.check_spelling = Some("Mod+L".to_string());

        let result = validate_shortcut_changes(&previous, &mut next);

        assert!(result.is_err());
    }

    #[test]
    fn a_changed_shortcut_is_canonicalized() {
        let previous = Settings::default();
        let mut next = previous.clone();
        next.popover_shortcuts.check_spelling = Some("shift+mod+s".to_string());

        validate_shortcut_changes(&previous, &mut next).expect("should succeed");

        assert_eq!(
            next.popover_shortcuts.check_spelling.as_deref(),
            Some("Mod+Shift+S")
        );
    }

    #[test]
    fn a_changed_global_shortcut_equal_to_a_popover_chord_is_rejected() {
        let previous = Settings::default();
        let mut next = previous.clone();
        next.shortcut = if cfg!(target_os = "macos") {
            "Cmd+L".to_string()
        } else {
            "Ctrl+L".to_string()
        };

        let result = validate_shortcut_changes(&previous, &mut next);

        assert!(result.is_err());
    }

    #[test]
    fn a_changed_prompt_succeeds_even_while_another_untouched_prompt_holds_an_invalid_value() {
        let previous = Settings {
            prompts: vec![
                prompt("a", Some("totally not a shortcut")),
                prompt("b", None),
            ],
            ..Settings::default()
        };
        let mut next = previous.clone();
        next.prompts[1].shortcut = Some("Mod+9".to_string());

        assert!(validate_shortcut_changes(&previous, &mut next).is_ok());
        // The untouched invalid value is left exactly as stored.
        assert_eq!(
            next.prompts[0].shortcut.as_deref(),
            Some("totally not a shortcut")
        );
        assert_eq!(next.prompts[1].shortcut.as_deref(), Some("Mod+9"));
    }

    #[test]
    fn reordering_prompts_with_no_other_change_succeeds() {
        let previous = Settings {
            prompts: vec![prompt("a", Some("Mod+9")), prompt("b", Some("Mod+8"))],
            ..Settings::default()
        };
        let mut next = previous.clone();
        next.prompts.reverse();

        assert!(validate_shortcut_changes(&previous, &mut next).is_ok());
    }

    #[test]
    fn a_changed_value_duplicating_an_unchanged_one_is_rejected() {
        let previous = Settings {
            prompts: vec![prompt("a", Some("Mod+9"))],
            ..Settings::default()
        };
        let mut next = previous.clone();
        // `Replace` changes to the same chord prompt "a" already holds
        // (untouched) — must be caught even though "a" itself never moved.
        next.popover_shortcuts.replace = Some("Mod+9".to_string());

        let result = validate_shortcut_changes(&previous, &mut next);

        assert!(result.is_err());
    }
}
