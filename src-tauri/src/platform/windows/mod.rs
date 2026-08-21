//! Windows platform implementation. Slice A got the crate building, testing,
//! and running on Windows with a tray icon, popover, Settings, a registered
//! global shortcut, and clipboard-fallback capture. Slice B (this state)
//! adds the native capture/replace loop: `selection_backend()` reads the
//! current selection instantly via UI Automation (`IUIAutomation` +
//! `TextPattern`), falling back through `core::capture`'s existing
//! clipboard + synthetic-Ctrl+C path — `keyboard()`'s `SendInput`-based
//! `send_copy`/`send_paste` — when UI Automation finds nothing usable;
//! `app_activator()` brings the source application back to the foreground
//! via `SetForegroundWindow` (plus the documented `AttachThreadInput`
//! fallback) for Replace. Native spell check (the Windows Spell Checking
//! API) is still a Slice C stub — see `spell_checker()`.

mod activation;
mod clipboard;
#[cfg(test)]
mod desktop_tests;
mod keyboard;
mod selection;
mod spellcheck;

pub use activation::WindowsAppActivator;
pub use clipboard::WindowsClipboard;
pub use keyboard::WindowsKeyboard;
pub use selection::WindowsSelectionBackend;
pub use spellcheck::WindowsSpellChecker;

/// Constructs the Windows `Clipboard`: `arboard`, text-only (same as
/// Linux), with a real `change_count()` backed by
/// `GetClipboardSequenceNumber`.
pub fn clipboard() -> WindowsClipboard {
    WindowsClipboard
}

/// Constructs the Windows `Keyboard`: synthetic Ctrl+C/Ctrl+V via
/// `SendInput`. Takes an `AppHandle` only for signature parity with the
/// Linux constructor (spec-12 Slice C) — `SendInput` has no main-thread
/// affinity or app-handle dependency, so it's unused here (unlike Linux's
/// Wayland portal path, which needs a handle to reach its portal session
/// manager).
pub fn keyboard(_app: tauri::AppHandle) -> WindowsKeyboard {
    WindowsKeyboard
}

/// Constructs the Windows `SelectionBackend`: UI Automation `TextPattern`
/// selection reading plus `GetForegroundWindow`-based frontmost-app
/// identity.
pub fn selection_backend() -> WindowsSelectionBackend {
    WindowsSelectionBackend
}

/// Constructs the Windows `AppActivator`: `SetForegroundWindow` activation
/// by remembered `HWND`. Stores the `AppHandle` because `activate` marshals
/// the actual `SetForegroundWindow` call onto the main (message-loop) thread
/// the same way `MacosAppActivator`/`MacosSpellChecker` marshal onto AppKit's
/// main thread, and that marshalling needs the handle.
pub fn app_activator(app: tauri::AppHandle) -> WindowsAppActivator {
    WindowsAppActivator::new(app)
}

/// Constructs the Windows `SpellChecker`. Slice A stub — see the module doc
/// comment; the `AppHandle` parameter exists for signature parity with the
/// macOS/Linux constructors, which do need one (marshalling onto a
/// main/worker thread).
pub fn spell_checker(_app: tauri::AppHandle) -> WindowsSpellChecker {
    WindowsSpellChecker
}

/// No-op: Windows has no grantable capture permission to deep-link into.
pub fn open_permission_settings() -> Result<(), String> {
    Ok(())
}

/// No-op: tray-only behavior is achieved by `skipTaskbar: true` on both
/// windows (already set in `tauri.conf.json`) plus never showing a taskbar
/// window; Windows has no activation-policy API equivalent to call.
pub fn setup(_app: &mut tauri::App) {}

/// Positions the popover at the current cursor position, clamped to the
/// current monitor's work area (which excludes the taskbar), falling back
/// to the work area's bottom-right corner (nearest the notification area)
/// when the cursor position can't be read. `tauri_plugin_positioner`'s
/// tray-relative positions are deliberately not used: the taskbar can live
/// on any edge and be auto-hidden, and the cursor is always where the user
/// just triggered from — the same reasoning `platform::linux::position_popover`
/// documents, shared via `platform::positioning`.
pub fn position_popover(window: &tauri::WebviewWindow) {
    super::positioning::position_popover(window, super::positioning::FallbackCorner::BottomRight);
}

/// Windows platform metadata: no session concept, no grantable permission,
/// and `replace_back_available: true` — backed, as of Slice B, by
/// `WindowsSelectionBackend::frontmost_app`'s real `GetForegroundWindow`-based
/// identity and `WindowsAppActivator`'s `SetForegroundWindow` activation, so
/// the frontend's `canReplace` gating now reflects an actually-working
/// Replace button whenever a source app was recorded.
pub fn platform_info() -> crate::platform::PlatformInfo {
    crate::platform::PlatformInfo {
        os: "windows",
        session: None,
        replace_back_available: true,
        permission_required: false,
        default_shortcut: crate::core::settings::default_shortcut().to_string(),
        wayland: None,
    }
}

/// No-op, like macOS: `SendInput` needs no grantable permission, so there is
/// nothing on this platform for the spec-13 Slice A opt-out to actually
/// gate. The setting is still persisted (cross-platform, in `Settings`) but
/// never surfaced or consulted here.
pub fn set_input_synthesis_enabled(_enabled: bool) {}

/// The Windows notification area delivers left-click reliably, and
/// `show_menu_on_left_click(false)` (set in `lib.rs`) already gives the
/// conventional left-opens / right-menus behavior, so no extra "Open
/// Kallilex" tray-menu entry is needed. If the Slice D manual matrix finds
/// click-delivery problems in the notification-area overflow flyout,
/// flipping this to `true` is a one-line follow-up.
pub fn wants_tray_open_entry() -> bool {
    false
}

/// `false`: Windows always has the synthetic-copy clipboard fallback
/// (manual Ctrl+C in Slice A, `SendInput` Ctrl+C in Slice B), so opening the
/// popover from the tray never needs to eagerly trigger a capture the way
/// Linux Wayland's tray-open path does.
pub fn tray_open_captures() -> bool {
    false
}

/// `false`: `RegisterHotKey` failure is a real, reportable error (usually a
/// conflicting registration by another app), unlike Linux Wayland's
/// compositor-dependent global-shortcut support — the existing error dialog
/// is the right response here.
pub fn global_shortcut_failure_expected() -> bool {
    false
}

/// `false`: portals are a Linux/XDG-desktop-portal concept with no Windows
/// equivalent, so the tauri global-shortcut plugin registration in `lib.rs`
/// is always used here.
pub fn use_portal_global_shortcut() -> bool {
    false
}

/// Never actually called: `use_portal_global_shortcut` always returns
/// `false` on Windows, so `lib.rs` never takes the portal-shortcut branch
/// that would call this. Kept as a no-op purely so the cross-platform seam
/// surface (`platform::spawn_portal_shortcut`) exists identically on every
/// platform.
pub fn spawn_portal_shortcut(
    _app: tauri::AppHandle,
    _preferred_shortcut: String,
    _on_activated: fn(&tauri::AppHandle),
) {
}

/// No template-image concept on the Windows notification area; the flag is
/// ignored there, passed as `false` for clarity.
pub fn tray_icon_as_template() -> bool {
    false
}

/// The embedded tray-icon raster: the same verdigris (#2faf9b) K glyph as
/// the Linux tray icon, its own 32x32 artwork file rather than
/// `include_bytes!`-ing the Linux raster across module boundaries. The
/// notification area scales this down to 16px logical, and the accent color
/// stays legible on both the light and dark taskbar.
pub fn tray_icon_bytes() -> &'static [u8] {
    include_bytes!("../../../icons/tray-windows@2x.png")
}

/// `false`: this is the one shared-code behavior edit in spec-15 Slice A —
/// the Settings-window maximise/restore workaround (see
/// `lib.rs::resync_frame_extents`) fixes a GTK client-side-decoration
/// defect that Windows's native title bar doesn't have; running it here
/// would just produce a visible, wrong flicker on every Settings open.
pub fn needs_frame_extents_resync() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_info_reports_windows_with_no_permission_and_no_session() {
        let info = platform_info();

        assert_eq!(info.os, "windows");
        assert!(info.session.is_none());
        assert!(info.replace_back_available);
        assert!(!info.permission_required);
        assert!(info.wayland.is_none());
    }
}
