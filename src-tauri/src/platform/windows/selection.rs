//! Windows selection reading (spec-15 Slice A stub). Slice B replaces this
//! with UI Automation (`IUIAutomation` + `TextPattern`), marshalled onto a
//! dedicated worker thread with a bounded `mpsc::recv_timeout`.

use crate::core::capture::{SelectionBackend, SourceApp};

/// Honest stub: no selection reading is implemented yet.
pub struct WindowsSelectionBackend;

impl SelectionBackend for WindowsSelectionBackend {
    /// `true` — final answer, not a placeholder. Windows has no grantable
    /// capture permission (unlike macOS's Accessibility permission): UI
    /// Automation and `SendInput` work without the user granting anything,
    /// so this always reports granted.
    fn permission_granted(&self) -> bool {
        true
    }

    /// `None` in Slice A: no foreground-window/process lookup is
    /// implemented yet (Slice B adds `GetForegroundWindow` +
    /// `GetWindowThreadProcessId` + `QueryFullProcessImageNameW`). This
    /// means `SourceApp` is never recorded on Windows in Slice A, which is
    /// what keeps the popover's Replace button visible-but-disabled the
    /// whole slice (`canReplace` requires a non-null source app).
    fn frontmost_app(&self) -> Option<SourceApp> {
        None
    }

    /// `None` in Slice A: no UI Automation `TextPattern` reading is
    /// implemented yet. `None` is exactly what makes `core::capture` fall
    /// through to the clipboard + synthetic-Ctrl+C path, which in Slice A
    /// (see `keyboard.rs`) means the popover simply opens empty for a
    /// manual paste.
    fn ax_selected_text(&self) -> Option<String> {
        None
    }
}
