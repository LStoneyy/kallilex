//! Synthetic Ctrl+C/Ctrl+V key synthesis via `enigo`'s X11 (XTest) backend.

use enigo::{Direction, Enigo, Key, Keyboard as EnigoKeyboard, Settings};

use crate::core::clipboard::Keyboard;
use crate::platform::linux::session::{self, SessionType};

/// Synthesizes Ctrl+C/Ctrl+V via `enigo`'s XTest-based X11 backend.
pub struct LinuxKeyboard;

/// Sends a Ctrl+`unicode_key` chord: Control press, `unicode_key` click,
/// Control release. `Key::Unicode` is layout-independent — enigo maps the
/// character to a keysym and, if it isn't already bound to a keycode on the
/// current layout, temporarily remaps a free keycode to it for the
/// duration of the click, so this works regardless of the user's keyboard
/// layout. Once the Control press has succeeded, the Control release is
/// always attempted regardless of whether the click succeeds, so a failed
/// click can never leave Control logically held down system-wide.
fn send_ctrl_chord(unicode_key: char) -> Result<(), String> {
    if session::current() == SessionType::Wayland {
        return Err("key synthesis is unavailable on Wayland".to_string());
    }

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
        send_ctrl_chord('c')
    }

    fn send_paste(&self) -> Result<(), String> {
        send_ctrl_chord('v')
    }
}
