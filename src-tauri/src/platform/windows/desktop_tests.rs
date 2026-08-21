//! Desktop integration tests for the Windows capture path
//! (`WindowsSelectionBackend`, `WindowsClipboard`, `WindowsKeyboard`).
//!
//! These need an interactive Windows desktop session: they open Notepad and
//! deliberately steal foreground focus away from whatever currently has it,
//! type into it, and drive real `SendInput` key events. That makes them
//! unsuitable for CI (headless/RDP-disconnected session, or a runner shared
//! with other work), so every test here is `#[ignore]`d and must be run
//! explicitly by a maintainer at a real desktop:
//!
//! ```text
//! cargo test -- --ignored --nocapture --test-threads=1
//! # or, scoped to just this module:
//! cargo test desktop_tests -- --ignored --nocapture --test-threads=1
//! ```
//!
//! `--test-threads=1` matters: every test here spawns its own Notepad and
//! drives the one real desktop/clipboard, so running them concurrently would
//! have them fight over focus and the clipboard.
//!
//! There are three tests, each spawning and cleaning up its own Notepad
//! instance (`frontmost_app_reports_a_foreground_window` is the exception —
//! it just reads whatever already has focus):
//!
//! - [`notepad_document_text_reflects_typed_marker`] is the oracle: it proves
//!   the typing helper, focus handoff, and UI Automation plumbing all work,
//!   by reading the whole document back via `DocumentRange()` — independent
//!   of anything under test in the other two.
//! - [`notepad_uia_selection_probe`] exercises the production
//!   `WindowsSelectionBackend::ax_selected_text()` instant-selection path,
//!   but does not assert `Some`: see its doc comment for the Windows 11
//!   Notepad UIA behavior — observed to vary — that makes both `Some` and
//!   `None` acceptable results there.
//! - [`notepad_synthetic_copy_round_trip`] is the strict one: it verifies the
//!   production `WindowsKeyboard::send_copy()` + `WindowsClipboard`
//!   change-count fallback path end to end.
//!
//! Every Notepad-spawning test clears the typed text and closes Notepad via
//! its `Drop`-based [`NotepadGuard`], unconditionally — including when an
//! assertion panics partway through — specifically so Windows 11 Notepad's
//! session-restore feature never resurrects leftover probe text the next
//! time a maintainer (or the next test run) opens Notepad. See
//! [`NotepadGuard`]'s doc comment for why cleanup lives there instead of at
//! the end of each test body.

use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use windows::core::Interface;
use windows::Win32::Foundation::{CloseHandle, RPC_E_CHANGED_MODE, WAIT_OBJECT_0};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationTextPattern, UIA_TextPatternId,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE, VIRTUAL_KEY, VK_A, VK_CONTROL, VK_DELETE, VK_F4, VK_MENU,
};

use super::clipboard::WindowsClipboard;
use super::keyboard::WindowsKeyboard;
use super::selection::WindowsSelectionBackend;
use crate::core::capture::SelectionBackend;
use crate::core::clipboard::{Clipboard, ClipboardBackup, Keyboard};

/// The marker text typed into Notepad and expected back out of the UIA
/// document-text read, the UIA selection probe (when it returns `Some`), and
/// the synthetic-copy clipboard round trip.
const MARKER: &str = "kallilex uia probe";

/// How long to poll `frontmost_app()` for Notepad to become the foreground
/// window, and how often. On Windows 11, `notepad.exe` is often an alias
/// launcher (App Execution Alias) that exits immediately after handing off
/// to the real, separately-hosted Notepad process/window — so the spawned
/// child's own pid and its foreground-window pid are not reliably the same
/// thing, and polling `frontmost_app()` rather than trusting the child
/// handle is the only reliable way to know Notepad is actually up and
/// focused.
const NOTEPAD_POLL_TIMEOUT: Duration = Duration::from_secs(5);
const NOTEPAD_POLL_INTERVAL: Duration = Duration::from_millis(200);

/// Bound on waiting for a gracefully-closed Notepad process to actually exit
/// before [`NotepadGuard`] falls back to `TerminateProcess`.
const NOTEPAD_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);

/// Extra settle time [`spawn_notepad_foreground`] waits after
/// `frontmost_app()` first reports Notepad as focused, before any typing
/// starts. See that function's doc comment for the dropped-first-character
/// failure this exists to prevent.
const NOTEPAD_FOCUS_SETTLE_DELAY: Duration = Duration::from_millis(500);

/// Restores the clipboard to whatever it held before the test, even on a
/// failing assertion (via `Drop`) — these tests must never leave the user's
/// real clipboard contents clobbered.
struct ClipboardRestoreGuard {
    backup: ClipboardBackup,
}

impl Drop for ClipboardRestoreGuard {
    fn drop(&mut self) {
        WindowsClipboard.restore(&self.backup);
    }
}

/// Cleans up the spawned Notepad process, even on a failing assertion (via
/// `Drop`) — these tests must never leave a stray probe-text Notepad window
/// behind on the desktop.
///
/// Cleanup is unconditional and lives entirely here, not as an explicit step
/// at the end of a passing test body: the clear-and-close sequence must run
/// even when an assertion panics partway through — a failing assertion must
/// not leave Notepad holding the typed marker text when `TerminateProcess`
/// runs, because Windows 11 Notepad's session-restore feature would then
/// resurrect leftover probe text the next time Notepad opens. Putting the
/// sequence in `Drop` means it always runs, panic or not.
///
/// The close itself prefers a graceful Alt+F4 (with the document already
/// cleared, no save prompt appears) over an immediate `TerminateProcess`,
/// waiting up to [`NOTEPAD_CLOSE_TIMEOUT`] for the process to actually exit:
/// a clean exit gives Notepad a chance to persist its (now-empty) session
/// state, where a hard kill does not. `TerminateProcess` is still the
/// fallback if the graceful close doesn't complete in time, so this can never
/// hang a test run or leave a zombie Notepad behind.
struct NotepadGuard {
    pid: u32,
}

impl Drop for NotepadGuard {
    fn drop(&mut self) {
        clear_notepad_document();
        thread::sleep(Duration::from_millis(150));
        close_notepad(self.pid);
    }
}

/// Clears whatever text is currently in the focused Notepad document
/// (select-all + Delete). Assumes Notepad still has focus, which holds for
/// every test in this module: nothing else takes focus between typing the
/// marker and the guard's `Drop` running.
fn clear_notepad_document() {
    select_all();
    thread::sleep(Duration::from_millis(100));
    tap_key(VK_DELETE);
}

/// Closes Notepad gracefully via Alt+F4 — `VK_MENU` down, `VK_F4` down/up,
/// `VK_MENU` up — waiting up to [`NOTEPAD_CLOSE_TIMEOUT`] for the process to
/// exit before falling back to `OpenProcess(PROCESS_TERMINATE)` +
/// `TerminateProcess`. See [`NotepadGuard`]'s doc comment for why the
/// graceful path is preferred.
fn close_notepad(pid: u32) {
    send_key(VK_MENU, false);
    send_key(VK_F4, false);
    send_key(VK_F4, true);
    send_key(VK_MENU, true);

    if wait_for_process_exit(pid, NOTEPAD_CLOSE_TIMEOUT) {
        return;
    }

    force_terminate(pid);
}

/// Waits up to `timeout` for the process identified by `pid` to exit.
/// Returns `true` both when it exits within the deadline and when it was
/// already gone (or inaccessible) by the time this opened it — either way,
/// there is nothing left to wait for.
fn wait_for_process_exit(pid: u32, timeout: Duration) -> bool {
    // SAFETY: `pid` is a plain process id; `OpenProcess` returning `Err`
    // (e.g. the process already exited on its own) is tolerated here — that
    // is treated the same as "already exited", since there is nothing left
    // to wait on.
    let Ok(handle) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, pid) }) else {
        return true;
    };
    // SAFETY: `handle` was just successfully opened above with
    // `PROCESS_SYNCHRONIZE` access, which is exactly what `WaitForSingleObject`
    // requires; `timeout` is always a small, fixed duration in this module
    // and fits comfortably in a `u32` millisecond count.
    let result = unsafe { WaitForSingleObject(handle, timeout.as_millis() as u32) };
    // SAFETY: `handle` is not used again after this point.
    let _ = unsafe { CloseHandle(handle) };
    result == WAIT_OBJECT_0
}

/// Unconditionally terminates the process identified by `pid`. The last-
/// resort fallback when a graceful close didn't complete in time.
fn force_terminate(pid: u32) {
    // SAFETY: `OpenProcess` returning `Err` (e.g. the process already exited
    // on its own) is tolerated here: there is nothing left to clean up.
    let Ok(handle) = (unsafe { OpenProcess(PROCESS_TERMINATE, false, pid) }) else {
        return;
    };
    // SAFETY: `handle` was just successfully opened above, with
    // `PROCESS_TERMINATE` access.
    let _ = unsafe { TerminateProcess(handle, 0) };
    // SAFETY: `handle` is not used again after this point.
    let _ = unsafe { CloseHandle(handle) };
}

/// Sends a single synthetic key event for a virtual key via `SendInput`.
/// Test-local rather than reusing `keyboard.rs`'s private `send_key_event`:
/// this file drives keys (`VK_A`, `VK_DELETE`, `VK_MENU`, `VK_F4`) that
/// module has no reason to expose, and asserts delivery with a panic
/// (appropriate for a test) rather than returning a `Result` (appropriate for
/// production code).
fn send_key(vk: VIRTUAL_KEY, key_up: bool) {
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
    assert_eq!(inserted, 1, "SendInput failed to deliver a key event");
}

/// Presses and releases a virtual key.
fn tap_key(vk: VIRTUAL_KEY) {
    send_key(vk, false);
    send_key(vk, true);
}

/// Sends a single synthetic Unicode character via `SendInput`'s
/// `KEYEVENTF_UNICODE` path: `wScan` carries the UTF-16 code unit and `wVk`
/// is `0`, per the documented Unicode-input convention (this bypasses
/// keyboard-layout-dependent virtual-key mapping entirely, which is exactly
/// what's wanted for typing an arbitrary marker string).
fn send_unicode_char(unit: u16, key_up: bool) {
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: if key_up {
                    KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
                } else {
                    KEYEVENTF_UNICODE
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    // SAFETY: `input` is a single, fully-initialized `INPUT` struct valid
    // for the duration of this call.
    let inserted = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    assert_eq!(
        inserted, 1,
        "SendInput failed to deliver a unicode key event"
    );
}

/// Delay held between each typed character's key-up and the next
/// character's key-down. Empirically necessary, not cosmetic: sending
/// `KEYEVENTF_UNICODE` down/up pairs back-to-back with no gap at all was
/// observed to make Windows' keyboard input processing fall behind and treat
/// the still-in-flight prior character as held — the injected text came out
/// as the first word followed by the *last* character repeated for the rest
/// of the string (e.g. typing `"kallilex uia probe"` produced
/// `"kallilex eeeeeeeee"`), which is exactly OS-level key-repeat, just
/// triggered by injection rate rather than a missing key-up. This delay is
/// the fix.
const TYPE_CHAR_DELAY: Duration = Duration::from_millis(50);

/// Types `text` into the focused control via per-character Unicode key
/// events. Each character is a matched key-down immediately followed by its
/// key-up — never a bare key-down — so the target application never sees an
/// unreleased key; [`TYPE_CHAR_DELAY`] between characters is what actually
/// prevents Windows from misreading the injected stream as a held key. See
/// that constant's doc comment for the failure this delay fixes.
fn type_text(text: &str) {
    for unit in text.encode_utf16() {
        send_unicode_char(unit, false);
        send_unicode_char(unit, true);
        thread::sleep(TYPE_CHAR_DELAY);
    }
}

/// Synthesizes Ctrl+A ("select all"): Control down, `A` down, `A` up,
/// Control up.
fn select_all() {
    send_key(VK_CONTROL, false);
    send_key(VK_A, false);
    send_key(VK_A, true);
    send_key(VK_CONTROL, true);
}

/// Polls `frontmost_app()` until it reports a window whose process name is
/// `"notepad"` (case-insensitive), or panics with a diagnostic after
/// [`NOTEPAD_POLL_TIMEOUT`]. See [`NOTEPAD_POLL_TIMEOUT`]'s doc comment for
/// why polling the foreground window, rather than trusting the spawned
/// child's own pid, is necessary on Windows 11.
fn wait_for_notepad_foreground(backend: &WindowsSelectionBackend) -> u32 {
    let deadline = Instant::now() + NOTEPAD_POLL_TIMEOUT;
    loop {
        if let Some(app) = backend.frontmost_app() {
            if app
                .name
                .as_deref()
                .is_some_and(|name| name.eq_ignore_ascii_case("notepad"))
            {
                return app.pid as u32;
            }
        }
        if Instant::now() >= deadline {
            panic!(
                "notepad.exe did not become the foreground window within {:?}; on Windows 11 \
                 the notepad.exe alias launcher can exit immediately without a real Notepad \
                 window ever gaining focus — check that Notepad is installed and not blocked \
                 from launching",
                NOTEPAD_POLL_TIMEOUT
            );
        }
        thread::sleep(NOTEPAD_POLL_INTERVAL);
    }
}

/// Spawns `notepad.exe`, waits for it to become the foreground window, and
/// returns a [`NotepadGuard`] that clears its document and closes it on
/// `Drop`. Shared by every Notepad-spawning test in this module.
fn spawn_notepad_foreground(backend: &WindowsSelectionBackend) -> NotepadGuard {
    // Deliberately not `.wait()`ed: this is a GUI app expected to keep
    // running for the duration of the test, and `wait()` would block until
    // it exits on its own, which never happens here. Cleanup is via
    // `NotepadGuard`'s `Drop`, not `Child::wait`.
    #[allow(clippy::zombie_processes)]
    Command::new("notepad.exe")
        .spawn()
        .expect("failed to spawn notepad.exe");

    let pid = wait_for_notepad_foreground(backend);

    // `frontmost_app()` reporting Notepad as the foreground window does not
    // mean its edit control is actually ready to receive input yet — without
    // this settle delay, the first one or two characters of the very next
    // `type_text()` call were empirically observed to be silently dropped
    // (e.g. `"kallilex uia probe"` arriving as `"llilex uia probe"`), most
    // likely lost during the window's own activation/initial-paint work.
    thread::sleep(NOTEPAD_FOCUS_SETTLE_DELAY);

    NotepadGuard { pid }
}

/// Reads the focused window's *entire document* text via UI Automation's
/// `DocumentRange()` — deliberately not the production `ax_selected_text()`
/// path, which reads the current *selection* and is exactly what's under
/// test in [`notepad_uia_selection_probe`] instead. Runs the COM work on the
/// calling (test) thread with a balanced `CoInitializeEx`/`CoUninitialize`
/// pair, unlike the production `selection.rs` path, which marshals onto a
/// timeout-bounded worker thread — a test is allowed to simply block if UIA
/// misbehaves, so that indirection isn't needed here.
fn read_document_text_via_uia() -> Option<String> {
    // SAFETY: called only from a test thread; test threads in this binary
    // never touch COM before this point, so `COINIT_MULTITHREADED`
    // unconditionally applies for the lifetime of the call below.
    let init_hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };

    // See `selection.rs::ax_selected_text_on_worker`'s doc comment for why
    // both `S_OK` and `S_FALSE` (both covered by `is_ok()`) must be balanced
    // with `CoUninitialize`, while `RPC_E_CHANGED_MODE` must not be.
    let owns_com = init_hr.is_ok();
    assert!(
        owns_com || init_hr == RPC_E_CHANGED_MODE,
        "CoInitializeEx failed on the test thread: {:?}",
        init_hr
    );

    let text = (|| {
        // SAFETY: `CUIAutomation` is a standard, documented in-process COM
        // server; COM was just initialized (or already usable) on this
        // thread.
        let automation: IUIAutomation =
            unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }.ok()?;
        // SAFETY: `automation` is a valid, live COM object for the duration
        // of this call.
        let focused = unsafe { automation.GetFocusedElement() }.ok()?;
        // SAFETY: `focused` is a valid, live COM object for the duration of
        // this call.
        let pattern_unknown = unsafe { focused.GetCurrentPattern(UIA_TextPatternId) }.ok()?;
        let text_pattern: IUIAutomationTextPattern = pattern_unknown.cast().ok()?;
        // SAFETY: `text_pattern` is a valid, live COM object for the
        // duration of this call.
        let document = unsafe { text_pattern.DocumentRange() }.ok()?;
        // SAFETY: `document` is a valid, live COM object for the duration of
        // this call; `-1` requests the range's full text with no truncation.
        let text = unsafe { document.GetText(-1) }.ok()?.to_string();
        Some(text)
    })();

    if owns_com {
        // SAFETY: balances the successful `CoInitializeEx` call above, and
        // is only reached when that call actually owns a usage count.
        unsafe { CoUninitialize() };
    }

    text
}

#[test]
#[ignore]
fn frontmost_app_reports_a_foreground_window() {
    let backend = WindowsSelectionBackend;

    let app = backend
        .frontmost_app()
        .expect("expected a foreground window on an interactive desktop session");

    assert!(
        app.window.is_some(),
        "expected a window handle on the foreground app"
    );
    assert!(app.pid >= 0, "expected a non-negative pid, got {}", app.pid);
}

/// Oracle test: proves typing, focus handoff, and the UI Automation plumbing
/// all work by reading the whole document back via `DocumentRange()`,
/// independent of anything under test in [`notepad_uia_selection_probe`] or
/// [`notepad_synthetic_copy_round_trip`]. If either of those fails, check
/// this one first — a failure here means the problem is upstream of both.
#[test]
#[ignore]
fn notepad_document_text_reflects_typed_marker() {
    let backend = WindowsSelectionBackend;
    let _notepad_guard = spawn_notepad_foreground(&backend);

    type_text(MARKER);
    thread::sleep(Duration::from_millis(300));

    let text = read_document_text_via_uia();
    // Windows 11 Notepad's `TextPattern` implementation has been observed to
    // include a trailing `\r`/`\r\n` on a range's text in some builds;
    // trimming it here is about tolerating that formatting quirk, not about
    // being lenient on the actual marker content.
    let normalized = text.as_deref().map(|s| s.trim_end_matches(['\r', '\n']));
    assert_eq!(
        normalized,
        Some(MARKER),
        "DocumentRange().GetText(-1) returned {:?} after typing the marker; frontmost_app() \
         reported {:?}",
        text,
        backend.frontmost_app()
    );
}

/// Exercises the production `WindowsSelectionBackend::ax_selected_text()`
/// instant-selection path, but deliberately does **not** assert `Some`:
/// Windows 11 Notepad's (`RichEditD2DPT`) `TextPattern::GetSelection()`
/// behavior varies by Notepad build and timing — `GetSelection()` has been
/// observed returning a single, non-degenerate range whose `GetText(-1)` is
/// an empty string even when the same document's `DocumentRange().GetText(-1)`
/// (see [`notepad_document_text_reflects_typed_marker`]) reads back the full
/// text correctly. Under `selection.rs`'s "empty selection text is `None`"
/// contract (see `selection.rs::read_selected_text`), that makes `None` a
/// correct, expected result of this path rather than a bug — and other
/// builds/timings instead return the full marker text as `Some`. Either
/// result is treated as acceptable here, so the probe does not hard-assert
/// either way. If `ax_selected_text()` does return `None` on a given
/// app/build, capture legitimately falls through to the synthetic-Ctrl+C
/// clipboard path exercised by [`notepad_synthetic_copy_round_trip`] instead.
///
/// The probe is still run with `--nocapture` so a maintainer can see at a
/// glance — via the `eprintln!` below — which behavior the UIA instant path
/// exhibits against a given app/build, without that being baked into a hard
/// assertion that would fail this whole module depending on the build.
#[test]
#[ignore]
fn notepad_uia_selection_probe() {
    let backend = WindowsSelectionBackend;
    let _notepad_guard = spawn_notepad_foreground(&backend);

    type_text(MARKER);
    thread::sleep(Duration::from_millis(300));

    select_all();
    thread::sleep(Duration::from_millis(300));

    let selected = backend.ax_selected_text();
    eprintln!(
        "ax_selected_text() returned {:?} (see this test's doc comment: both Some(marker) and \
         None have been observed on Windows 11 Notepad and are treated as acceptable here)",
        selected
    );

    if let Some(text) = selected.as_deref() {
        let normalized = text.trim_end_matches(['\r', '\n']);
        assert_eq!(
            normalized, MARKER,
            "ax_selected_text() returned Some({:?}), which does not match the typed marker",
            text
        );
    }
}

/// Strict round trip through the production `WindowsKeyboard::send_copy()` +
/// `WindowsClipboard` change-count path: this is the real verification that
/// `keyboard.rs`'s synthetic Ctrl+C and `clipboard.rs`'s
/// `GetClipboardSequenceNumber`-backed change counter work end to end against
/// a real application, which is exactly the fallback
/// [`notepad_uia_selection_probe`]'s doc comment says Windows 11 Notepad
/// falls through to.
#[test]
#[ignore]
fn notepad_synthetic_copy_round_trip() {
    let clipboard = WindowsClipboard;
    let _clipboard_guard = ClipboardRestoreGuard {
        backup: clipboard.backup(),
    };

    let backend = WindowsSelectionBackend;
    let _notepad_guard = spawn_notepad_foreground(&backend);

    type_text(MARKER);
    thread::sleep(Duration::from_millis(300));

    select_all();
    thread::sleep(Duration::from_millis(300));

    let keyboard = WindowsKeyboard;
    let prev = clipboard.change_count();
    keyboard.send_copy().expect("send_copy failed");
    assert!(
        clipboard.wait_for_change(prev, Duration::from_secs(2)),
        "clipboard did not change within 2s after send_copy"
    );
    let copied = clipboard.read_text();
    let normalized_copied = copied.as_deref().map(|s| s.trim_end_matches(['\r', '\n']));
    assert_eq!(
        normalized_copied,
        Some(MARKER),
        "clipboard read {:?} after send_copy",
        copied
    );
}
