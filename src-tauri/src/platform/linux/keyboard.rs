//! Synthetic Ctrl+C/Ctrl+V key synthesis: `enigo`'s X11 (XTest) backend on
//! X11, and the RemoteDesktop portal's `NotifyKeyboardKeycode` (spec-12
//! Slice C, [`wayland::send_chord`]) on Wayland sessions where the portal's
//! input-synthesis capability is live. Wayland sessions without that
//! capability keep reporting the unconditional `Err` from spec-11 — there
//! is no synthetic-input mechanism to fall back to on those compositors.

use enigo::{Direction, Enigo, Key, Keyboard as EnigoKeyboard, Settings};
use tauri::AppHandle;

use crate::core::clipboard::Keyboard;
use crate::platform::linux::session::{self, SessionType};
use crate::platform::linux::wayland::{self, Chord};

/// Synthesizes Ctrl+C/Ctrl+V: `enigo`'s XTest-based X11 backend on X11, the
/// RemoteDesktop portal on Wayland (when available).
pub struct LinuxKeyboard {
    app: AppHandle,
}

impl LinuxKeyboard {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }

    /// Sends a Ctrl+`chord` chord, dispatching per session type.
    fn send_ctrl_chord(&self, unicode_key: char, chord: Chord) -> Result<(), String> {
        match session::current() {
            SessionType::X11 => send_ctrl_chord_x11(unicode_key),
            SessionType::Wayland => {
                if wayland::capabilities().input_synthesis {
                    wayland::send_chord(&self.app, chord)
                } else {
                    Err("key synthesis is unavailable on Wayland".to_string())
                }
            }
        }
    }
}

/// Sends a Ctrl+`unicode_key` chord via `enigo`: Control press,
/// `unicode_key` click, Control release. `Key::Unicode` is layout-
/// independent — enigo maps the character to a keysym and, if it isn't
/// already bound to a keycode on the current layout, temporarily remaps a
/// free keycode to it for the duration of the click, so this works
/// regardless of the user's keyboard layout. Once the Control press has
/// succeeded, the Control release is always attempted regardless of
/// whether the click succeeds, so a failed click can never leave Control
/// logically held down system-wide.
fn send_ctrl_chord_x11(unicode_key: char) -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;

    enigo
        .key(Key::Control, Direction::Press)
        .map_err(|e| e.to_string())?;

    let click_result = enigo
        .key(Key::Unicode(unicode_key), Direction::Click)
        .map_err(|e| e.to_string());
    let release_result = enigo
        .key(Key::Control, Direction::Release)
        .map_err(|e| e.to_string());

    click_result?;
    release_result?;
    Ok(())
}

impl Keyboard for LinuxKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        self.send_ctrl_chord('c', Chord::Copy)
    }

    fn send_paste(&self) -> Result<(), String> {
        self.send_ctrl_chord('v', Chord::Paste)
    }
}
