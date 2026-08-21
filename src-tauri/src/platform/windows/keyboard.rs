//! Windows key synthesis (spec-15 Slice A stub). Slice B replaces this with
//! `SendInput`-based Ctrl+C/Ctrl+V, including the modifier-hygiene cleanup
//! `Ctrl+Alt+K` (the default Windows shortcut) requires — see the spec's
//! "Modifier hygiene" hazard.

use crate::core::clipboard::Keyboard;

/// Honest stub: no key synthesis is implemented yet. `core::capture`'s
/// fallback path treats a `send_copy` failure as "nothing to wait for" and
/// resolves immediately without ever calling `wait_for_change` (see that
/// module's doc comment) — so on Windows in Slice A, capture never finds a
/// selection automatically, and the popover opens empty for the user to
/// paste into.
pub struct WindowsKeyboard;

impl Keyboard for WindowsKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        Err("key synthesis is not yet implemented on Windows".to_string())
    }

    fn send_paste(&self) -> Result<(), String> {
        Err("key synthesis is not yet implemented on Windows".to_string())
    }
}
