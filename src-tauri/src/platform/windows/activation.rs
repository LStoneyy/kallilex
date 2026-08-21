//! Windows window activation (spec-15 Slice B): `SetForegroundWindow` on the
//! remembered `HWND`, plus the documented `AttachThreadInput` fallback,
//! marshalled onto the main (message-loop) thread the same way
//! `MacosAppActivator` marshals onto AppKit's main thread.

use std::ffi::c_void;
use std::sync::mpsc;
use std::time::Duration;

use tauri::{AppHandle, Manager};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowThreadProcessId, IsIconic, IsWindow, SetForegroundWindow, ShowWindow, SW_RESTORE,
};

use crate::core::capture::SourceApp;
use crate::core::replace::AppActivator;
use crate::core::POPOVER_WINDOW_LABEL;

/// How long to wait for activation marshalled onto the main thread to
/// complete before giving up. `SetForegroundWindow` and friends are fast
/// (in-process `user32` calls), so a real timeout here only ever fires if
/// the main thread itself is wedged — the same rationale, and the same
/// value, `MacosAppActivator::ACTIVATE_TIMEOUT` uses for `NSRunningApplication`
/// activation.
const ACTIVATE_TIMEOUT: Duration = Duration::from_secs(2);

/// Brings another application's window to the foreground via
/// `SetForegroundWindow`.
pub struct WindowsAppActivator {
    app: AppHandle,
}

impl WindowsAppActivator {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl AppActivator for WindowsAppActivator {
    /// Marshals the actual activation onto the main (message-loop) thread
    /// via `app.run_on_main_thread`, blocking the calling thread on a
    /// channel bounded by [`ACTIVATE_TIMEOUT`] — the same shape
    /// `MacosAppActivator::activate` uses for `NSRunningApplication`
    /// activation.
    ///
    /// `HWND` is a raw-pointer newtype and is not `Send`, so only the
    /// underlying `u64` handle crosses the channel/closure boundary; the
    /// `HWND` itself is rebuilt from it on the main thread inside
    /// [`activate_on_main_thread`].
    fn activate(&self, app: &SourceApp) -> Result<(), String> {
        let Some(window) = app.window else {
            return Err("no window handle recorded for the source application".to_string());
        };
        let hwnd_value = window.0;

        let (tx, rx) = mpsc::channel();
        let app_handle = self.app.clone();

        self.app
            .run_on_main_thread(move || {
                let result = activate_on_main_thread(&app_handle, hwnd_value);
                // The receiver may already be gone if `recv_timeout` below
                // gave up first; that's fine, there's nothing left to do.
                let _ = tx.send(result);
            })
            .map_err(|e| format!("failed to schedule activation on the main thread: {e}"))?;

        match rx.recv_timeout(ACTIVATE_TIMEOUT) {
            Ok(result) => result,
            Err(_) => Err("activating the source application timed out".to_string()),
        }
    }
}

/// Runs the actual `SetForegroundWindow` activation. Must only ever be
/// called from the main (message-loop) thread — this mirrors
/// `MacosAppActivator`'s AppKit main-thread affinity, though the actual
/// Win32 calls here have no such requirement themselves; the requirement is
/// that this only runs *after* the popover-hide step below has a chance to
/// take effect on the same thread that owns the window.
fn activate_on_main_thread(app: &AppHandle, hwnd_value: u64) -> Result<(), String> {
    let hwnd = HWND(hwnd_value as usize as *mut c_void);

    // SAFETY: `IsWindow` tolerates an invalid or stale handle by returning
    // `false`; it has no further precondition.
    if !unsafe { IsWindow(Some(hwnd)) }.as_bool() {
        return Err("the source application is no longer running".to_string());
    }

    // Hide the popover before touching the target window at all: Windows
    // hands foreground rights to the next window more reliably when the
    // *current* foreground window (the popover, at this point) gives them
    // up, rather than fighting it for `SetForegroundWindow`'s cooperative
    // foreground-lock rules. Plain `window.hide()` is used rather than the
    // crate's `hide_popover` helper, for exactly the reason
    // `platform/linux/activation.rs` documents: replace-back owns its own
    // state cleanup, and `hide_popover` also eagerly clears capture state,
    // which would be premature here. Hiding does trigger the same
    // focus-loss -> `cancel_capture` -> `restore_pending` path a manual
    // Escape/click-away would, but that's already a harmless no-op
    // mid-replace thanks to `BackupLifecycle::take_pending` (the race guard
    // `replace_back` applies before ever calling into this activator).
    if let Some(popover) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        let _ = popover.hide();
    }

    // SAFETY: `hwnd` was just validated by `IsWindow` above.
    if unsafe { IsIconic(hwnd) }.as_bool() {
        // SAFETY: `hwnd` is valid; `SW_RESTORE` has no further precondition.
        let _ = unsafe { ShowWindow(hwnd, SW_RESTORE) };
    }

    // SAFETY: `hwnd` is valid.
    if unsafe { SetForegroundWindow(hwnd) }.as_bool() {
        return Ok(());
    }

    // `SetForegroundWindow` failed outright — almost always because this
    // process doesn't currently hold the foreground lock. The documented
    // workaround is to temporarily attach this thread's input queue to the
    // target window's owning thread, which makes Windows treat the two as
    // cooperating for the purposes of the foreground-lock rules, then retry.
    //
    // SAFETY: `hwnd` is valid; `None` for the pid out-param is fine, only
    // the owning thread id is needed here.
    let target_thread = unsafe { GetWindowThreadProcessId(hwnd, None) };
    // SAFETY: no precondition.
    let current_thread = unsafe { GetCurrentThreadId() };

    let mut retried = false;
    if target_thread != current_thread {
        // SAFETY: both thread ids are live: `current_thread` always is, and
        // `target_thread` was just read off the still-valid `hwnd` above.
        let _ = unsafe { AttachThreadInput(current_thread, target_thread, true) };

        // SAFETY: `hwnd` is still valid.
        retried = unsafe { SetForegroundWindow(hwnd) }.as_bool();

        // Always detach, even if the retry above failed — an unpaired or
        // failed attach's matching detach call is harmless, and leaving the
        // input queues attached would be a lasting side effect no failure
        // path should leave behind.
        // SAFETY: matches the attach call above.
        let _ = unsafe { AttachThreadInput(current_thread, target_thread, false) };
    }

    if retried {
        Ok(())
    } else {
        Err("failed to bring the source application to the foreground".to_string())
    }
}
