//! Binding the "capture" shortcut through the `org.freedesktop.portal.GlobalShortcuts`
//! interface, and translating Kallilex's stored shortcut string into the hint
//! that portal accepts.
//!
//! The compositor — not Kallilex — owns everything about how this shortcut
//! is actually presented and remembered: whether/how it's shown to the user
//! for confirmation, which physical keys it ends up bound to, and whether
//! that binding persists across runs (portal-side, keyed by Kallilex's app
//! id). `preferred_trigger` is only ever a hint a well-behaved backend *may*
//! honor; Kallilex never assumes it was actually used and always reads back
//! whatever the bind response reports instead.

use futures_util::StreamExt;
use tauri::Manager;

use ashpd::desktop::global_shortcuts::{
    BindShortcuts, BindShortcutsOptions, GlobalShortcuts, NewShortcut,
};
use ashpd::desktop::CreateSessionOptions;

use crate::platform::PortalShortcutTrigger;

/// Application-provided id for Kallilex's single portal-bound shortcut.
const CAPTURE_SHORTCUT_ID: &str = "capture";

/// User-readable text describing what the shortcut does, shown by the
/// compositor's own shortcut-binding/management UI.
const CAPTURE_SHORTCUT_DESCRIPTION: &str = "Capture the current selection";

/// Canonical XDG "shortcuts" spec trigger modifier order: `CTRL`, `SHIFT`,
/// `ALT`, then `LOGO` (the Super/Cmd/Meta key).
const MODIFIER_ORDER: [&str; 4] = ["CTRL", "SHIFT", "ALT", "LOGO"];

/// Translates a stored tauri-plugin-global-shortcut-style shortcut string
/// (e.g. `"Ctrl+Alt+K"`) into the XDG "shortcuts" spec's trigger format
/// (e.g. `"CTRL+ALT+k"`), for use as the `preferred_trigger` hint when
/// binding a shortcut through the GlobalShortcuts portal.
///
/// Modifier tokens are mapped case-insensitively: `Ctrl`/`Control` -> `CTRL`,
/// `Alt`/`Option` -> `ALT`, `Shift` -> `SHIFT`, `Super`/`Cmd`/`Command`/`Meta`
/// -> `LOGO`; the recognized modifiers present are then re-emitted in that
/// canonical order regardless of the order they appeared in the input. The
/// final token is the key: a single ASCII letter is lowercased (`K` ->
/// `k`), matching the spec's convention for plain letter keys; anything
/// else (digits, multi-character key names like `F5`) passes through
/// unchanged.
///
/// Returns `None` for input that can't be confidently translated — empty
/// input, an empty token (e.g. a trailing `+`), an unrecognized modifier
/// name, or the same modifier appearing twice — rather than guessing. The
/// caller treats `None` exactly like "no preferred trigger": binding still
/// proceeds, just without a hint, and the compositor picks entirely on its
/// own.
pub fn portal_trigger_from_shortcut(shortcut: &str) -> Option<String> {
    let trimmed = shortcut.trim();
    if trimmed.is_empty() {
        return None;
    }

    let tokens: Vec<&str> = trimmed.split('+').map(str::trim).collect();
    if tokens.iter().any(|token| token.is_empty()) {
        return None;
    }

    let (key_token, modifier_tokens) = tokens.split_last()?;

    let mut modifiers: Vec<&'static str> = Vec::with_capacity(modifier_tokens.len());
    for token in modifier_tokens {
        let canonical = match token.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => "CTRL",
            "alt" | "option" => "ALT",
            "shift" => "SHIFT",
            "super" | "cmd" | "command" | "meta" => "LOGO",
            _ => return None,
        };
        if modifiers.contains(&canonical) {
            return None;
        }
        modifiers.push(canonical);
    }

    let is_single_letter = key_token.chars().count() == 1
        && key_token
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic());
    let key = if is_single_letter {
        key_token.to_ascii_lowercase()
    } else {
        (*key_token).to_string()
    };

    let mut parts: Vec<String> = MODIFIER_ORDER
        .iter()
        .filter(|modifier| modifiers.contains(modifier))
        .map(|modifier| modifier.to_string())
        .collect();
    parts.push(key);

    Some(parts.join("+"))
}

/// Runs [`bind_and_listen`] and reports any failure quietly. Intended to be
/// spawned once via `tauri::async_runtime::spawn` from
/// `platform::linux::spawn_portal_shortcut`, for the lifetime of the app.
///
/// Failure honesty: a missing portal, a session-creation failure, or the
/// user declining the bind request are all real, expected outcomes on some
/// compositors/sessions — not Kallilex bugs — so none of them show an error
/// dialog. They're logged to stderr (at most) and leave
/// [`PortalShortcutTrigger`] at `None`, which the Settings window's General
/// tab surfaces as "not currently bound". The tray icon remains the
/// guaranteed-reachable way to open Kallilex either way. The same applies if
/// the bind succeeds but the `Activated` signal stream later ends at
/// runtime (portal daemon restart, D-Bus connection drop): `bind_and_listen`
/// logs that and clears the stored trigger back to `None` before returning,
/// so this function's own error branch never fires for it — there is no
/// reconnect loop, so the shortcut stays unavailable until Kallilex
/// restarts.
pub async fn run_portal_shortcut(
    app: tauri::AppHandle,
    preferred_shortcut: String,
    on_activated: fn(&tauri::AppHandle),
) {
    if let Err(err) = bind_and_listen(&app, &preferred_shortcut, on_activated).await {
        eprintln!("Kallilex: Wayland GlobalShortcuts portal unavailable: {err}");
    }
}

/// Creates a `GlobalShortcuts` session, binds the single "capture" shortcut,
/// stores the compositor-reported trigger description, then listens for
/// `Activated` signals for as long as the returned future is polled — which,
/// per [`run_portal_shortcut`]'s doc comment, is the lifetime of the app.
/// The session (and the bind) stays alive purely because `session` and
/// `global_shortcuts` remain in scope across the whole `while` loop below;
/// there is no separate keep-alive mechanism.
async fn bind_and_listen(
    app: &tauri::AppHandle,
    preferred_shortcut: &str,
    on_activated: fn(&tauri::AppHandle),
) -> Result<(), ashpd::Error> {
    let global_shortcuts = GlobalShortcuts::new().await?;
    let session = global_shortcuts
        .create_session(CreateSessionOptions::default())
        .await?;

    let preferred_trigger = portal_trigger_from_shortcut(preferred_shortcut);
    let new_shortcut = NewShortcut::new(CAPTURE_SHORTCUT_ID, CAPTURE_SHORTCUT_DESCRIPTION)
        .preferred_trigger(preferred_trigger.as_deref());

    let bind_request = global_shortcuts
        .bind_shortcuts(
            &session,
            &[new_shortcut],
            None,
            BindShortcutsOptions::default(),
        )
        .await?;
    let bound = bind_request.response()?;

    store_trigger(app, &bound);

    // `ShortcutsChanged` would let a live rebind (the user re-picking the key
    // combination from the compositor's own settings while Kallilex keeps
    // running) update the stored trigger immediately. That's skipped here:
    // Settings polls the stored trigger (see `App.svelte`'s Wayland polling
    // of `getWaylandShortcutTrigger`) rather than only reading it once, and
    // adding a second concurrent signal stream on the same session for an
    // uncommon mid-run rebind isn't worth the complexity.
    let this_session = session_path(&session);

    let mut activated = global_shortcuts.receive_activated().await?;
    while let Some(event) = activated.next().await {
        // `receive_activated()` is a bus-wide broadcast: every portal
        // client's `Activated` signals arrive on it, not just this
        // session's, so events must be filtered by `session_handle()`
        // before acting on a matching shortcut id — otherwise another
        // app's shortcut happening to share the generic id "capture" would
        // spuriously trigger Kallilex's capture.
        let is_this_session = this_session.as_deref() == Some(event.session_handle().as_str());
        if is_this_session && event.shortcut_id() == CAPTURE_SHORTCUT_ID {
            // `on_activated` (`trigger_capture`) can block on the capture
            // fallback's settle timeout, so it must never run directly on
            // the async executor driving this loop — that would stall every
            // other in-flight async task, including this signal stream
            // itself, for the duration of the wait.
            let app_handle = app.clone();
            let _ = tauri::async_runtime::spawn_blocking(move || on_activated(&app_handle)).await;
        }
    }

    // The stream only ends if the portal daemon restarts or drops the D-Bus
    // connection out from under this session; there is no reconnect loop
    // (out of scope), so the bind is simply gone. Say so and clear the
    // stored trigger — otherwise Settings would keep reporting the shortcut
    // as bound even though it no longer does anything.
    eprintln!(
        "Kallilex: Wayland GlobalShortcuts portal Activated stream ended; the \"capture\" shortcut is unavailable until Kallilex restarts."
    );
    clear_trigger(app);

    Ok(())
}

/// Reads back the D-Bus object path of a portal `Session`, for comparing
/// against the `session_handle` carried by broadcast signals like
/// `Activated`. ashpd 0.13.13 doesn't expose this through any public
/// accessor — `Session::path` is crate-private — only indirectly through its
/// `Serialize` impl, which serializes the session as exactly that path
/// string; `serde_json` (already a direct dependency) is used to read it
/// back out without needing a raw D-Bus wire encoder.
fn session_path<T: ashpd::desktop::SessionPortal>(
    session: &ashpd::desktop::Session<T>,
) -> Option<String> {
    match serde_json::to_value(session).ok()? {
        serde_json::Value::String(path) => Some(path),
        _ => None,
    }
}

/// Stores the compositor-reported trigger description for the "capture"
/// shortcut, or leaves the stored value untouched if the bind response
/// somehow didn't include it (an ill-behaved portal backend, in practice —
/// there is nothing more specific to fall back to).
fn store_trigger(app: &tauri::AppHandle, bound: &BindShortcuts) {
    let Some(state) = app.try_state::<PortalShortcutTrigger>() else {
        return;
    };

    let Some(trigger) = bound
        .shortcuts()
        .iter()
        .find(|shortcut| shortcut.id() == CAPTURE_SHORTCUT_ID)
        .map(|shortcut| shortcut.trigger_description().to_string())
    else {
        return;
    };

    let mut stored = state
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *stored = Some(trigger);
}

/// Clears the stored trigger description for the "capture" shortcut back to
/// `None`, e.g. once the `Activated` signal stream backing the bind has
/// ended and the shortcut is no longer actually functional.
fn clear_trigger(app: &tauri::AppHandle) {
    let Some(state) = app.try_state::<PortalShortcutTrigger>() else {
        return;
    };

    let mut stored = state
        .0
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *stored = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctrl_alt_letter_maps_to_canonical_order_and_lowercase_key() {
        assert_eq!(
            portal_trigger_from_shortcut("Ctrl+Alt+K").as_deref(),
            Some("CTRL+ALT+k")
        );
    }

    #[test]
    fn control_alias_maps_the_same_as_ctrl() {
        assert_eq!(
            portal_trigger_from_shortcut("Control+K").as_deref(),
            Some("CTRL+k")
        );
    }

    #[test]
    fn shift_and_logo_aliases_map_and_reorder_canonically() {
        // Input order is Cmd, Shift — canonical output order is SHIFT, LOGO.
        assert_eq!(
            portal_trigger_from_shortcut("Cmd+Shift+5").as_deref(),
            Some("SHIFT+LOGO+5")
        );
        assert_eq!(
            portal_trigger_from_shortcut("Super+K").as_deref(),
            Some("LOGO+k")
        );
        assert_eq!(
            portal_trigger_from_shortcut("Command+K").as_deref(),
            Some("LOGO+k")
        );
        assert_eq!(
            portal_trigger_from_shortcut("Meta+K").as_deref(),
            Some("LOGO+k")
        );
        assert_eq!(
            portal_trigger_from_shortcut("Option+K").as_deref(),
            Some("ALT+k")
        );
    }

    #[test]
    fn multi_character_key_names_pass_through_unchanged() {
        assert_eq!(
            portal_trigger_from_shortcut("Ctrl+F5").as_deref(),
            Some("CTRL+F5")
        );
    }

    #[test]
    fn single_digit_key_passes_through_unchanged() {
        assert_eq!(
            portal_trigger_from_shortcut("Ctrl+5").as_deref(),
            Some("CTRL+5")
        );
    }

    #[test]
    fn empty_input_is_none() {
        assert_eq!(portal_trigger_from_shortcut(""), None);
        assert_eq!(portal_trigger_from_shortcut("   "), None);
    }

    #[test]
    fn trailing_separator_leaving_an_empty_token_is_none() {
        assert_eq!(portal_trigger_from_shortcut("Ctrl+"), None);
        assert_eq!(portal_trigger_from_shortcut("Ctrl++K"), None);
    }

    #[test]
    fn unrecognized_modifier_name_is_none() {
        assert_eq!(portal_trigger_from_shortcut("Fn+K"), None);
        assert_eq!(portal_trigger_from_shortcut("Hyper+K"), None);
    }

    #[test]
    fn duplicate_modifier_is_none() {
        assert_eq!(portal_trigger_from_shortcut("Ctrl+Control+K"), None);
    }

    #[test]
    fn single_token_with_no_modifiers_is_just_the_key() {
        assert_eq!(portal_trigger_from_shortcut("K").as_deref(), Some("k"));
        assert_eq!(portal_trigger_from_shortcut("F1").as_deref(), Some("F1"));
    }
}
