//! Replace-back orchestration (spec-04): writes the popover's result text
//! into the remembered source application via clipboard + synthetic ⌘V, and
//! the plain "copy to clipboard" alternative.
//!
//! `replace_back` deliberately *takes* the pending fallback backup
//! (`BackupLifecycle::take_pending`) rather than reading it. Focusing the
//! source app (`AppActivator::activate`) necessarily makes the popover lose
//! focus — which is exactly what the frontend's own cancel path
//! (`hide_popover` -> `cancel_capture` -> `restore_pending`) reacts to.
//! Without this race guard, that focus-loss cancel could fire mid-replace
//! and restore the clipboard out from under an in-flight paste. Taking the
//! backup up front makes the popover losing focus during replace harmless:
//! once taken, there is nothing left pending for `restore_pending` to act
//! on, so a concurrent cancel becomes a no-op.
//!
//! Fallback coordination: when a fallback backup from capture (spec-02) is
//! still pending, it *is* the restore target for replace — at that moment
//! the clipboard holds the intermediate captured selection (from capture's
//! own synthetic ⌘C), not the user's original clipboard content, so it must
//! not be backed up again. A fresh backup is only taken when nothing is
//! pending, i.e. the Accessibility capture path was used and never touched
//! the clipboard.

use std::time::Duration;

use crate::core::capture::SourceApp;
use crate::core::clipboard::{BackupLifecycle, Clipboard, Keyboard};

/// Platform seam for bringing another application to the foreground by pid.
pub trait AppActivator: Send + Sync {
    /// Brings the app with the given pid to the foreground.
    fn activate(&self, pid: i32) -> Result<(), String>;
}

/// Platform seam for blocking the current thread for the replace-back
/// settle delays, abstracted so tests can assert on the wait without
/// actually sleeping.
pub trait Sleeper: Send + Sync {
    fn sleep(&self, duration: Duration);
}

/// Real sleeper: blocks the calling thread via `std::thread::sleep`.
pub struct StdSleeper;

impl Sleeper for StdSleeper {
    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// How long to wait after focusing the source app before sending the
/// synthetic ⌘V, so the app has a chance to actually take focus.
const FOCUS_SETTLE_DELAY: Duration = Duration::from_millis(150);

/// How long to wait after the synthetic ⌘V before restoring the clipboard,
/// so the paste has time to land before the restore can clobber it.
const PASTE_SETTLE_DELAY: Duration = Duration::from_millis(300);

/// Writes `text` back into `source_app`: backup -> write -> focus -> settle
/// -> paste -> settle -> restore (see the module docs for the race guard
/// and fallback-coordination rules governing the backup step).
///
/// `source_app` must be `Some` — there is nowhere to focus or paste into
/// otherwise — and nothing is touched at all (no backup, no clipboard
/// write) when it is `None`.
///
/// On any failure to focus the source app or to send the synthetic paste,
/// the clipboard is restored immediately and the error is returned; the
/// paste is never attempted into an unknown frontmost app.
pub fn replace_back(
    text: &str,
    source_app: Option<&SourceApp>,
    clipboard: &dyn Clipboard,
    keyboard: &dyn Keyboard,
    activator: &dyn AppActivator,
    lifecycle: &BackupLifecycle,
    sleeper: &dyn Sleeper,
) -> Result<(), String> {
    let source_app =
        source_app.ok_or_else(|| "no source application remembered".to_string())?;

    let backup = lifecycle
        .take_pending()
        .unwrap_or_else(|| clipboard.backup());
    clipboard.write_text(text);

    if let Err(err) = activator.activate(source_app.pid) {
        clipboard.restore(&backup);
        return Err(err);
    }

    sleeper.sleep(FOCUS_SETTLE_DELAY);

    if let Err(err) = keyboard.send_paste() {
        clipboard.restore(&backup);
        return Err(err);
    }

    sleeper.sleep(PASTE_SETTLE_DELAY);
    clipboard.restore(&backup);
    Ok(())
}

/// Copies `text` to the clipboard for the user to paste themselves, and
/// closes the loop on any pending fallback backup: it is discarded (not
/// restored) so the result stays on the clipboard even after the popover's
/// close/cancel path (`restore_pending`) runs.
pub fn copy_result(
    text: &str,
    clipboard: &dyn Clipboard,
    lifecycle: &BackupLifecycle,
) -> Result<(), String> {
    lifecycle.discard_pending();
    clipboard.write_text(text);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::clipboard::fakes::{CallLog, FakeClipboard, FakeKeyboard};
    use crate::core::clipboard::{ClipboardBackup, ClipboardItem};

    /// Fake `AppActivator`: records "activate" in the shared `CallLog` and
    /// is configurable to succeed or fail.
    struct FakeActivator {
        log: CallLog,
        should_fail: bool,
    }

    impl FakeActivator {
        fn succeeding(log: CallLog) -> Self {
            Self {
                log,
                should_fail: false,
            }
        }

        fn failing(log: CallLog) -> Self {
            Self {
                log,
                should_fail: true,
            }
        }
    }

    impl AppActivator for FakeActivator {
        fn activate(&self, _pid: i32) -> Result<(), String> {
            self.log.record("activate");
            if self.should_fail {
                Err("activation failed".to_string())
            } else {
                Ok(())
            }
        }
    }

    /// Fake `Sleeper`: records "sleep" in the shared `CallLog` instead of
    /// actually blocking the thread.
    struct FakeSleeper {
        log: CallLog,
    }

    impl FakeSleeper {
        fn new(log: CallLog) -> Self {
            Self { log }
        }
    }

    impl Sleeper for FakeSleeper {
        fn sleep(&self, _duration: Duration) {
            self.log.record("sleep");
        }
    }

    fn sample_source_app() -> SourceApp {
        SourceApp {
            bundle_id: Some("com.example.app".to_string()),
            pid: 123,
            name: Some("Example".to_string()),
        }
    }

    #[test]
    fn ax_path_replace_runs_backup_write_focus_paste_and_restore_in_order() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::succeeding(log.clone());
        let activator = FakeActivator::succeeding(log.clone());
        let sleeper = FakeSleeper::new(log.clone());
        let lifecycle = BackupLifecycle::new();
        let source_app = sample_source_app();

        let result = replace_back(
            "corrected text",
            Some(&source_app),
            &clipboard,
            &keyboard,
            &activator,
            &lifecycle,
            &sleeper,
        );

        assert!(result.is_ok());
        assert_eq!(
            log.calls(),
            vec![
                "backup",
                "write_text",
                "activate",
                "sleep",
                "send_paste",
                "sleep",
                "restore",
            ]
        );
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn a_pending_fallback_backup_is_the_restore_target_and_is_not_re_backed_up() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let lifecycle = BackupLifecycle::new();

        // Simulate spec-02's fallback: the pending backup holds the user's
        // real original clipboard content, taken before the intermediate
        // captured selection landed.
        lifecycle.store(clipboard.backup());
        clipboard.set_external_text("intermediate captured selection");
        let calls_before_replace = log.calls().len();

        let keyboard = FakeKeyboard::succeeding(log.clone());
        let activator = FakeActivator::succeeding(log.clone());
        let sleeper = FakeSleeper::new(log.clone());
        let source_app = sample_source_app();

        let result = replace_back(
            "corrected text",
            Some(&source_app),
            &clipboard,
            &keyboard,
            &activator,
            &lifecycle,
            &sleeper,
        );

        assert!(result.is_ok());
        let calls_during_replace = &log.calls()[calls_before_replace..];
        assert!(
            !calls_during_replace.contains(&"backup"),
            "replace must not re-back-up the clipboard when a fallback backup is pending"
        );
        // The restore target is the pending backup ("original"), not the
        // intermediate captured selection.
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn activation_failure_restores_the_clipboard_and_never_sends_the_paste() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::succeeding(log.clone());
        let activator = FakeActivator::failing(log.clone());
        let sleeper = FakeSleeper::new(log.clone());
        let lifecycle = BackupLifecycle::new();
        let source_app = sample_source_app();

        let result = replace_back(
            "corrected text",
            Some(&source_app),
            &clipboard,
            &keyboard,
            &activator,
            &lifecycle,
            &sleeper,
        );

        assert_eq!(result, Err("activation failed".to_string()));
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!log.calls().contains(&"send_paste"));
    }

    #[test]
    fn paste_failure_restores_the_clipboard() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::failing_paste(log.clone());
        let activator = FakeActivator::succeeding(log.clone());
        let sleeper = FakeSleeper::new(log.clone());
        let lifecycle = BackupLifecycle::new();
        let source_app = sample_source_app();

        let result = replace_back(
            "corrected text",
            Some(&source_app),
            &clipboard,
            &keyboard,
            &activator,
            &lifecycle,
            &sleeper,
        );

        assert!(result.is_err());
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
    }

    #[test]
    fn no_source_app_is_an_error_and_touches_nothing() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::succeeding(log.clone());
        let activator = FakeActivator::succeeding(log.clone());
        let sleeper = FakeSleeper::new(log.clone());
        let lifecycle = BackupLifecycle::new();

        // A pending backup, built directly so storing it doesn't itself
        // touch the clipboard/log — it must stay pending and untouched.
        lifecycle.store(ClipboardBackup(vec![ClipboardItem {
            formats: vec![("public.utf8-plain-text".to_string(), b"pre-existing".to_vec())],
        }]));

        let result = replace_back(
            "corrected text",
            None,
            &clipboard,
            &keyboard,
            &activator,
            &lifecycle,
            &sleeper,
        );

        assert_eq!(result, Err("no source application remembered".to_string()));
        assert!(log.calls().is_empty());
        assert!(lifecycle.has_pending());
    }

    #[test]
    fn copy_result_discards_the_pending_backup_and_writes_the_text() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let lifecycle = BackupLifecycle::new();
        lifecycle.store(clipboard.backup());
        clipboard.set_external_text("intermediate captured selection");

        let result = copy_result("final result", &clipboard, &lifecycle);

        assert!(result.is_ok());
        assert_eq!(clipboard.current_text(), Some("final result".to_string()));
        assert!(!lifecycle.has_pending());

        // A subsequent cancel-path restore must not clobber the copied
        // result: the pending backup was discarded, not left to restore.
        lifecycle.restore_pending(&clipboard);
        assert_eq!(clipboard.current_text(), Some("final result".to_string()));
    }
}
