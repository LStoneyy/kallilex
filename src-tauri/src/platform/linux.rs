//! Linux platform stubs (spec-11 Slice A): compile-only placeholders that
//! implement every seam trait so the crate builds and its tests pass on
//! Linux. Real implementations (arboard/enigo/x11rb/spellbook-backed) land
//! in spec-11 Slice B.

use std::time::Duration;

use tauri::AppHandle;

use crate::core::capture::{SelectionBackend, SourceApp};
use crate::core::clipboard::{Clipboard, ClipboardBackup, Keyboard};
use crate::core::replace::AppActivator;
use crate::core::spellcheck::{SpellChecker, SpellcheckError, SpellcheckResult};

/// Slice A placeholder for Linux selection capture — replaced by spec-11
/// Slice B. Linux has no equivalent of macOS's Accessibility permission, so
/// `permission_granted` always returning `true` is the *final* contract, not
/// a stub.
pub struct LinuxSelectionBackend;

impl SelectionBackend for LinuxSelectionBackend {
    fn permission_granted(&self) -> bool {
        true
    }

    fn frontmost_app(&self) -> Option<SourceApp> {
        None
    }

    fn ax_selected_text(&self) -> Option<String> {
        None
    }
}

/// Slice A placeholder for Linux clipboard access — replaced by spec-11
/// Slice B.
pub struct LinuxClipboard;

impl Clipboard for LinuxClipboard {
    fn read_text(&self) -> Option<String> {
        None
    }

    fn write_text(&self, _text: &str) {}

    fn backup(&self) -> ClipboardBackup {
        ClipboardBackup::default()
    }

    fn restore(&self, _backup: &ClipboardBackup) {}

    fn change_count(&self) -> u64 {
        0
    }

    fn wait_for_change(&self, _prev: u64, _timeout: Duration) -> bool {
        false
    }
}

/// Slice A placeholder for Linux key synthesis — replaced by spec-11 Slice B.
pub struct LinuxKeyboard;

impl Keyboard for LinuxKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        Err("key synthesis not yet implemented on Linux".into())
    }

    fn send_paste(&self) -> Result<(), String> {
        Err("key synthesis not yet implemented on Linux".into())
    }
}

/// Slice A placeholder for Linux window activation — replaced by spec-11
/// Slice B.
pub struct LinuxAppActivator;

impl AppActivator for LinuxAppActivator {
    fn activate(&self, _app: &SourceApp) -> Result<(), String> {
        Err("window activation not yet implemented on Linux".into())
    }
}

/// Slice A placeholder for Linux spell checking — replaced by spec-11 Slice
/// B.
pub struct LinuxSpellChecker;

impl SpellChecker for LinuxSpellChecker {
    fn check(&self, _text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        Ok(SpellcheckResult::default())
    }
}

/// Constructs the Linux `SelectionBackend` (Slice A placeholder).
pub fn selection_backend() -> LinuxSelectionBackend {
    LinuxSelectionBackend
}

/// Constructs the Linux `Clipboard` (Slice A placeholder).
pub fn clipboard() -> LinuxClipboard {
    LinuxClipboard
}

/// Constructs the Linux `Keyboard` (Slice A placeholder).
pub fn keyboard() -> LinuxKeyboard {
    LinuxKeyboard
}

/// Constructs the Linux `AppActivator` (Slice A placeholder). The
/// `AppHandle` is unused for now; Slice B's X11 implementation is expected
/// to need it (main-thread marshalling, mirroring the macOS activator).
pub fn app_activator(_app: AppHandle) -> LinuxAppActivator {
    LinuxAppActivator
}

/// Constructs the Linux `SpellChecker` (Slice A placeholder). Ignores the
/// handle — unlike `NSSpellChecker`, a Slice B `spellbook`-backed checker
/// won't need main-thread marshalling.
pub fn spell_checker(_app: AppHandle) -> LinuxSpellChecker {
    LinuxSpellChecker
}

/// No-op: Linux has no grantable permission to deep-link into.
pub fn open_permission_settings() -> Result<(), String> {
    Ok(())
}

/// No-op on Linux: tray-only behavior is achieved simply by never showing a
/// Dock-equivalent window, with no activation-policy API to call.
pub fn setup(_app: &mut tauri::App) {}

/// Slice A placeholder: same tray-relative positioning as macOS. Slice B
/// replaces this with cursor-based positioning appropriate for X11/Wayland.
pub fn position_popover(window: &tauri::WebviewWindow) {
    use tauri_plugin_positioner::{Position, WindowExt};

    let _ = window.move_window(Position::TrayBottomCenter);
}

/// Linux platform metadata (Slice A): no grantable permission, and Replace
/// is not yet available (Slice B adds window activation).
pub fn platform_info() -> crate::platform::PlatformInfo {
    crate::platform::PlatformInfo {
        os: "linux",
        session: None,
        replace_back_available: false,
        permission_required: false,
        default_shortcut: crate::core::settings::default_shortcut().to_string(),
    }
}
