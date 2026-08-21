//! Windows key synthesis: `SendInput` with virtual-key codes for synthetic
//! Ctrl+C/Ctrl+V, including the modifier-hygiene cleanup the default
//! `Ctrl+Alt+K` shortcut requires — see [`send_ctrl_chord`]'s doc comment for
//! the "Modifier hygiene" hazard this exists to handle.

use std::thread;
use std::time::Duration;

use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_C, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT, VK_V,
};

use crate::core::clipboard::Keyboard;

/// How long to wait after releasing any held modifiers before synthesizing
/// the Ctrl chord, so the target app has processed the releases before the
/// chord lands.
const MODIFIER_SETTLE_DELAY: Duration = Duration::from_millis(20);

/// Modifiers whose held state matters for the default `Ctrl+Alt+K`
/// shortcut's modifier hygiene: Alt (almost always still physically down
/// when the handler fires, and — combined with the Ctrl this module is
/// about to send — `Ctrl+Alt` is AltGr on Windows, not a copy/paste chord),
/// plus Shift and both Windows keys for the same reason (any of them held
/// alongside Ctrl+C/Ctrl+V can change or block what the target app sees).
const MODIFIERS_TO_CLEAR: [VIRTUAL_KEY; 4] = [VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN];

/// High bit of `GetAsyncKeyState`'s result: set when the key is currently
/// physically down.
const ASYNC_KEY_STATE_DOWN_BIT: i16 = -0x8000; // 0x8000 as i16

/// Synthesizes Ctrl+C/Ctrl+V via `SendInput`, virtual-key based.
pub struct WindowsKeyboard;

impl Keyboard for WindowsKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        send_ctrl_chord(VK_C)
    }

    fn send_paste(&self) -> Result<(), String> {
        send_ctrl_chord(VK_V)
    }
}

/// Synthesizes a Ctrl+`vk` chord via `SendInput`: modifier cleanup, then
/// Control down, `vk` down, `vk` up, Control up.
///
/// Virtual keys, not scan codes: applications interpret `WM_KEYDOWN` by
/// virtual key, so this is layout-independent in the way that matters here
/// (unlike scan codes, which are physical-position-based and vary with the
/// user's keyboard layout).
///
/// **Modifier hygiene** (the Windows-specific hazard): the
/// default shortcut is `Ctrl+Alt+K`, so Alt is almost always still physically
/// held when this runs — and `Ctrl+Alt` is AltGr on Windows, so an
/// un-cleaned Ctrl+C is not a copy in many apps. Before synthesizing the
/// chord, every currently-held modifier in [`MODIFIERS_TO_CLEAR`] gets a
/// synthetic key-up, followed by a short settle delay so the target has
/// processed the releases.
///
/// Once the Control press has been sent, the Control release is *always*
/// attempted regardless of whether the letter press succeeded — mirroring
/// the Linux implementation's explicit contract — so a failure here can
/// never leave Control logically stuck down.
///
/// **Deliberate deviation from a naive "restore what was held" design**:
/// the released modifiers are not re-pressed afterwards. `GetAsyncKeyState`
/// only reflects the logical async key state, which the synthetic key-ups
/// above already cleared — there is no way to observe "the user is still
/// physically holding this" at that point. Re-pressing anyway would risk
/// leaving a modifier logically stuck down if the user had actually released
/// it in the meantime, which is worse than the alternative: leaving it
/// unpressed is harmless, because when the user does physically release a
/// modifier, the system simply delivers a key-up for a key that's already up.
///
/// UIPI note: `SendInput` into a window belonging to a higher-integrity
/// process is silently dropped by the OS — no error is returned here, the
/// input just never arrives. Capture then reports `NoSelection` and Replace
/// reports failure via their existing paths; this is not a bug in this
/// function.
fn send_ctrl_chord(vk: VIRTUAL_KEY) -> Result<(), String> {
    clear_held_modifiers();
    thread::sleep(MODIFIER_SETTLE_DELAY);

    send_key_event(VK_CONTROL, false)?;

    let press_result = send_key_event(vk, false).and_then(|()| send_key_event(vk, true));

    // Always release Control, regardless of whether the letter press
    // succeeded above — see the doc comment.
    let release_result = send_key_event(VK_CONTROL, true);

    press_result?;
    release_result?;
    Ok(())
}

/// Sends a synthetic key-up for every modifier in [`MODIFIERS_TO_CLEAR`]
/// that `GetAsyncKeyState` reports as currently physically held.
fn clear_held_modifiers() {
    for &vk in &MODIFIERS_TO_CLEAR {
        // SAFETY: `GetAsyncKeyState` takes a virtual-key code and has no
        // further preconditions.
        let state = unsafe { GetAsyncKeyState(vk.0 as i32) };
        if state & ASYNC_KEY_STATE_DOWN_BIT != 0 {
            // Best-effort: if the synthetic key-up itself fails to send, the
            // chord below is sent anyway (nothing else to try), and the
            // settle delay simply does slightly less work.
            let _ = send_key_event(vk, true);
        }
    }
}

/// Sends a single synthetic key event for `vk` via `SendInput`: a key-down
/// when `key_up` is `false`, a key-up when it's `true`.
fn send_key_event(vk: VIRTUAL_KEY, key_up: bool) -> Result<(), String> {
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if key_up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };

    // SAFETY: `input` is a single, fully-initialized `INPUT` struct valid
    // for the duration of this call.
    let inserted = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };

    if inserted < 1 {
        Err(format!(
            "SendInput failed to deliver a key event: {}",
            windows::core::Error::from_thread()
        ))
    } else {
        Ok(())
    }
}
