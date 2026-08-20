//! Capture orchestration: the platform-agnostic `SelectionBackend` seam and
//! the `capture()` function that tries the Accessibility path first, falls
//! back to a synthetic-copy clipboard read, and otherwise reports why
//! capture produced nothing.

use std::time::Duration;

use crate::core::clipboard::{BackupLifecycle, Clipboard, Keyboard};

/// How long to wait for the fallback's synthetic ⌘C to land on the
/// clipboard before giving up.
const FALLBACK_SETTLE_TIMEOUT: Duration = Duration::from_millis(300);

/// Opaque platform window identifier (X11 window id on Linux). Never sent to
/// the frontend.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlatformWindowId(pub u64);

/// The application the selection was captured from, remembered for
/// replace-back and focus restoration (spec-04).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceApp {
    pub bundle_id: Option<String>,
    pub pid: i32,
    pub name: Option<String>,
    /// Opaque platform window handle (Slice B: Linux window activation).
    /// Never serialized to the frontend; macOS never sets it (activation is
    /// by pid).
    #[serde(skip)]
    pub window: Option<PlatformWindowId>,
}

/// Why `capture()` produced empty text.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptureFailureReason {
    PermissionMissing,
    NoSelection,
}

/// Result of a capture attempt, returned to the frontend as-is.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureResult {
    /// `""` when capture failed.
    pub text: String,
    /// Set when `text` is empty because capture failed.
    pub reason: Option<CaptureFailureReason>,
    pub source_app: Option<SourceApp>,
}

impl CaptureResult {
    pub fn empty() -> Self {
        Self {
            text: String::new(),
            reason: None,
            source_app: None,
        }
    }
}

/// Platform seam for reading the current selection via the macOS
/// Accessibility API. Kept separate from platform/window-manager concerns
/// so other platforms can plug in a different implementation later.
pub trait SelectionBackend: Send + Sync {
    fn permission_granted(&self) -> bool;
    fn frontmost_app(&self) -> Option<SourceApp>;
    /// Reads `AXSelectedText` of the focused UI element. `None` (or a
    /// failure to read it) means the AX path failed and the caller should
    /// fall back to the clipboard.
    fn ax_selected_text(&self) -> Option<String>;
}

/// Orchestrates a single capture: the Accessibility API primary path (on
/// Linux: the primary-selection read), then an automatic clipboard
/// fallback, then an empty result with a reason.
///
/// Always starts by resolving any unresolved backup left pending by a prior
/// capture (`lifecycle.restore_pending`), returning the clipboard to its
/// true original state before this capture takes its own backup. Without
/// this, two captures in a row that both fall back (e.g. the global
/// shortcut pressed twice while the popover is already open) would back up
/// the *first* capture's leftover clipboard text instead of the user's real
/// original content.
///
/// The source app is always recorded on the result (when available),
/// regardless of which path — or neither — produced text.
///
/// If `keyboard.send_copy()` itself fails (e.g. Linux Wayland, where
/// synthetic key events are unavailable), the just-taken backup is restored
/// immediately and the result is `NoSelection` without ever calling
/// `wait_for_change` — there is nothing to wait for a copy that was never
/// sent, and waiting out `FALLBACK_SETTLE_TIMEOUT` anyway would only add a
/// pointless delay. This is what makes the fallback path fully inert on
/// Wayland: no synthetic copy is attempted, and no fallback wait happens.
pub fn capture(
    backend: &dyn SelectionBackend,
    clipboard: &dyn Clipboard,
    keyboard: &dyn Keyboard,
    lifecycle: &BackupLifecycle,
) -> CaptureResult {
    lifecycle.restore_pending(clipboard);

    let source_app = backend.frontmost_app();

    if !backend.permission_granted() {
        // Synthetic key events also require the Accessibility permission,
        // so there is no point attempting the fallback here.
        return CaptureResult {
            text: String::new(),
            reason: Some(CaptureFailureReason::PermissionMissing),
            source_app,
        };
    }

    if let Some(text) = backend.ax_selected_text() {
        if !text.is_empty() {
            return CaptureResult {
                text,
                reason: None,
                source_app,
            };
        }
    }

    // AX path failed (or returned an empty selection): fall back to a
    // synthetic ⌘C. Back up the clipboard immediately before the copy so a
    // clipboard-mutating app causes minimal data loss.
    let backup = clipboard.backup();
    lifecycle.store(backup);
    let prev = clipboard.change_count();

    if keyboard.send_copy().is_err() {
        // No synthetic copy was actually sent (e.g. unavailable on
        // Wayland): resolve the backup immediately instead of waiting out
        // `FALLBACK_SETTLE_TIMEOUT` for a change that can never land.
        lifecycle.restore_pending(clipboard);
        return CaptureResult {
            text: String::new(),
            reason: Some(CaptureFailureReason::NoSelection),
            source_app,
        };
    }

    let changed = clipboard.wait_for_change(prev, FALLBACK_SETTLE_TIMEOUT);

    if changed {
        if let Some(text) = clipboard.read_text() {
            if !text.is_empty() {
                // The backup stays pending: it is restored on cancel or
                // after Replace settles, and discarded on Copy (spec-04).
                return CaptureResult {
                    text,
                    reason: None,
                    source_app,
                };
            }
        }
    }

    // The fallback produced nothing: undo its own side effects immediately.
    lifecycle.restore_pending(clipboard);
    CaptureResult {
        text: String::new(),
        reason: Some(CaptureFailureReason::NoSelection),
        source_app,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::core::clipboard::fakes::{CallLog, FakeClipboard, FakeKeyboard};

    struct FakeSelectionBackend {
        permission_granted: bool,
        frontmost_app: Option<SourceApp>,
        ax_selected_text: Option<String>,
    }

    impl FakeSelectionBackend {
        fn granted(ax_selected_text: Option<&str>) -> Self {
            Self {
                permission_granted: true,
                frontmost_app: Some(sample_source_app()),
                ax_selected_text: ax_selected_text.map(str::to_string),
            }
        }

        fn missing_permission() -> Self {
            Self {
                permission_granted: false,
                frontmost_app: Some(sample_source_app()),
                ax_selected_text: None,
            }
        }
    }

    impl SelectionBackend for FakeSelectionBackend {
        fn permission_granted(&self) -> bool {
            self.permission_granted
        }

        fn frontmost_app(&self) -> Option<SourceApp> {
            self.frontmost_app.clone()
        }

        fn ax_selected_text(&self) -> Option<String> {
            self.ax_selected_text.clone()
        }
    }

    fn sample_source_app() -> SourceApp {
        SourceApp {
            bundle_id: Some("com.example.app".to_string()),
            pid: 123,
            name: Some("Example".to_string()),
            window: None,
        }
    }

    #[test]
    fn ax_success_returns_the_text_without_touching_the_clipboard() {
        let backend = FakeSelectionBackend::granted(Some("selected text"));
        let log = CallLog::new();
        let clipboard = FakeClipboard::new(log.clone());
        let keyboard = FakeKeyboard::succeeding(log.clone());
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, &clipboard, &keyboard, &lifecycle);

        assert_eq!(result.text, "selected text");
        assert_eq!(result.reason, None);
        assert_eq!(result.source_app, Some(sample_source_app()));
        assert!(log.calls().is_empty());
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn ax_failure_falls_back_and_leaves_the_backup_pending() {
        let backend = FakeSelectionBackend::granted(None);
        let log = CallLog::new();
        let clipboard = Arc::new(FakeClipboard::with_text(log.clone(), "original"));
        let keyboard =
            FakeKeyboard::succeeding_with_copy(log.clone(), clipboard.clone(), "fallback text");
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, clipboard.as_ref(), &keyboard, &lifecycle);

        assert_eq!(result.text, "fallback text");
        assert_eq!(result.reason, None);
        assert_eq!(
            log.calls(),
            vec!["backup", "send_copy", "wait_for_change", "read_text"]
        );
        assert!(lifecycle.has_pending());
    }

    #[test]
    fn send_copy_failure_restores_immediately_without_waiting_for_a_change() {
        // Mirrors Linux Wayland: `send_copy` fails outright (key synthesis
        // is unavailable), so there is nothing to wait for — `capture` must
        // resolve the pending backup and report `NoSelection` without ever
        // calling `wait_for_change`.
        let backend = FakeSelectionBackend::granted(None);
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::failing(log.clone());
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, &clipboard, &keyboard, &lifecycle);

        assert_eq!(result.text, "");
        assert_eq!(result.reason, Some(CaptureFailureReason::NoSelection));
        assert_eq!(log.calls(), vec!["backup", "send_copy", "restore"]);
        assert!(!log.calls().contains(&"wait_for_change"));
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn empty_ax_selection_counts_as_ax_failure_and_falls_back() {
        let backend = FakeSelectionBackend::granted(Some(""));
        let log = CallLog::new();
        let clipboard = Arc::new(FakeClipboard::with_text(log.clone(), "original"));
        let keyboard =
            FakeKeyboard::succeeding_with_copy(log.clone(), clipboard.clone(), "fallback text");
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, clipboard.as_ref(), &keyboard, &lifecycle);

        assert_eq!(result.text, "fallback text");
        assert!(log.calls().contains(&"backup"));
    }

    #[test]
    fn missing_permission_returns_empty_result_and_never_calls_the_keyboard() {
        let backend = FakeSelectionBackend::missing_permission();
        let log = CallLog::new();
        let clipboard = FakeClipboard::new(log.clone());
        let keyboard = FakeKeyboard::succeeding(log.clone());
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, &clipboard, &keyboard, &lifecycle);

        assert_eq!(result.text, "");
        assert_eq!(
            result.reason,
            Some(CaptureFailureReason::PermissionMissing)
        );
        assert_eq!(result.source_app, Some(sample_source_app()));
        assert!(!log.calls().contains(&"send_copy"));
    }

    #[test]
    fn a_second_capture_restores_the_first_captures_pending_backup_before_taking_its_own() {
        // Two captures in a row, both falling back, with no cancel/restore
        // in between (mirrors pressing the global shortcut twice while the
        // popover is already open). The clipboard starts at the user's
        // real original text; the first capture's fallback lands
        // "fallback text" and leaves that pending. The second capture must
        // first resolve the first capture's pending backup (restoring
        // "original") before backing up and taking its own attempt — and
        // since its own fallback fails, the clipboard must end up back at
        // "original" with nothing left pending.
        let log = CallLog::new();
        let clipboard = Arc::new(FakeClipboard::with_text(log.clone(), "original"));
        let lifecycle = BackupLifecycle::new();

        let backend = FakeSelectionBackend::granted(None);
        let first_keyboard =
            FakeKeyboard::succeeding_with_copy(log.clone(), clipboard.clone(), "fallback text");
        let first_result = capture(&backend, clipboard.as_ref(), &first_keyboard, &lifecycle);

        assert_eq!(first_result.text, "fallback text");
        assert_eq!(clipboard.current_text(), Some("fallback text".to_string()));
        assert!(lifecycle.has_pending());

        let second_keyboard = FakeKeyboard::failing(log.clone());
        let second_result = capture(&backend, clipboard.as_ref(), &second_keyboard, &lifecycle);

        assert_eq!(second_result.text, "");
        assert_eq!(
            second_result.reason,
            Some(CaptureFailureReason::NoSelection)
        );
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }

    #[test]
    fn both_paths_failing_restores_the_clipboard_and_reports_no_selection() {
        let backend = FakeSelectionBackend::granted(None);
        let log = CallLog::new();
        let clipboard = FakeClipboard::with_text(log.clone(), "original");
        let keyboard = FakeKeyboard::failing(log.clone());
        let lifecycle = BackupLifecycle::new();

        let result = capture(&backend, &clipboard, &keyboard, &lifecycle);

        assert_eq!(result.text, "");
        assert_eq!(result.reason, Some(CaptureFailureReason::NoSelection));
        assert_eq!(clipboard.current_text(), Some("original".to_string()));
        assert!(!lifecycle.has_pending());
    }
}
