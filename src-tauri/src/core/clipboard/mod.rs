//! Clipboard seam: abstracts pasteboard access plus a synthetic-copy
//! keyboard trigger, and owns the single source of truth for the pending
//! fallback backup (shared between capture's cancel path here and the
//! Copy/Replace actions added in spec-04).

#[cfg(test)]
pub mod fakes;

use std::sync::Mutex;
use std::time::Duration;

/// A single clipboard pasteboard item: every readable (type, raw bytes)
/// pair. Unreadable types are skipped on a best-effort basis.
#[derive(Debug, Clone)]
pub struct ClipboardItem {
    pub formats: Vec<(String, Vec<u8>)>,
}

/// Opaque best-effort snapshot of clipboard contents (all items, all
/// formats' raw data). Callers only ever pass this back to
/// [`Clipboard::restore`] or [`BackupLifecycle`] — the contents are not
/// meant to be inspected outside this module and the `platform` backend.
#[derive(Debug, Clone, Default)]
pub struct ClipboardBackup(pub Vec<ClipboardItem>);

/// Platform seam for reading/writing the system clipboard.
pub trait Clipboard: Send + Sync {
    fn read_text(&self) -> Option<String>;
    /// Best-effort snapshot of all pasteboard items/formats.
    fn backup(&self) -> ClipboardBackup;
    /// Best-effort restore of a previously captured snapshot.
    fn restore(&self, backup: &ClipboardBackup);
    fn change_count(&self) -> u64;
    /// Blocks until `change_count()` differs from `prev` or `timeout`
    /// elapses. Returns `true` if the clipboard changed.
    fn wait_for_change(&self, prev: u64, timeout: Duration) -> bool;
}

/// Platform seam for synthesizing the ⌘C fallback keystroke.
pub trait Keyboard: Send + Sync {
    /// Sends a synthetic Cmd+C to the frontmost app.
    fn send_copy(&self) -> Result<(), String>;
}

/// Single source of truth for the pending clipboard backup produced by the
/// fallback copy path. There is never more than one pending backup: a new
/// [`Self::store`] call replaces whatever was pending before.
#[derive(Default)]
pub struct BackupLifecycle {
    pending: Mutex<Option<ClipboardBackup>>,
}

impl BackupLifecycle {
    pub fn new() -> Self {
        Self {
            pending: Mutex::new(None),
        }
    }

    /// Stores `backup` as the pending backup, replacing any prior one.
    pub fn store(&self, backup: ClipboardBackup) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *pending = Some(backup);
    }

    /// Restores the pending backup to `clipboard` (if any) and clears it.
    /// A no-op, idempotent, when nothing is pending — this is what makes
    /// cancel (Escape, focus loss, closing without an action) safe to call
    /// repeatedly.
    pub fn restore_pending(&self, clipboard: &dyn Clipboard) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(backup) = pending.take() {
            clipboard.restore(&backup);
        }
    }

    /// Clears the pending backup without restoring it (the Copy action:
    /// the fallback's result intentionally stays on the clipboard). Not
    /// wired to a command yet — the Copy action lands in spec-04.
    #[allow(dead_code)]
    pub fn discard_pending(&self) {
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *pending = None;
    }

    /// Not read by production code yet — exposed for spec-04's Copy/Replace
    /// wiring; exercised directly by this module's tests today.
    #[allow(dead_code)]
    pub fn has_pending(&self) -> bool {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::fakes::{CallLog, FakeClipboard};
    use super::*;

    #[test]
    fn restore_pending_writes_the_backup_back_and_clears_pending() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let lifecycle = BackupLifecycle::new();

        let backup = clipboard.backup();
        lifecycle.store(backup);
        clipboard.set_external_text("intermediate");

        lifecycle.restore_pending(&clipboard);

        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn discard_pending_prevents_a_later_restore_from_touching_the_clipboard() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let lifecycle = BackupLifecycle::new();

        lifecycle.store(clipboard.backup());
        clipboard.set_external_text("result-to-keep");
        lifecycle.discard_pending();

        lifecycle.restore_pending(&clipboard);

        assert_eq!(clipboard.current_text(), Some("result-to-keep".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn restore_pending_with_nothing_pending_is_a_no_op() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log, "untouched");
        let lifecycle = BackupLifecycle::new();

        lifecycle.restore_pending(&clipboard);
        lifecycle.restore_pending(&clipboard); // idempotent

        assert_eq!(clipboard.current_text(), Some("untouched".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn store_replaces_a_prior_pending_backup() {
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "first");
        let lifecycle = BackupLifecycle::new();

        lifecycle.store(clipboard.backup());
        clipboard.set_external_text("second");
        lifecycle.store(clipboard.backup());
        clipboard.set_external_text("third");

        lifecycle.restore_pending(&clipboard);

        assert_eq!(clipboard.current_text(), Some("second".to_string()));
        assert!(!lifecycle.has_pending());
    }
}
