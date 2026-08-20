//! Linux platform implementation (spec-11 Slice B): X11 is the fully
//! supported tier (clipboard, key synthesis, window activation, frontmost-
//! app lookup), Wayland gets an honest degraded mode (primary-selection
//! capture and clipboard still work via `arboard`'s `wayland-data-control`
//! backend; key synthesis and window activation are unavailable and report
//! so explicitly rather than silently failing).

mod activation;
mod clipboard;
mod keyboard;
mod selection;
mod session;
mod spellcheck;

pub use activation::app_activator;
pub use clipboard::LinuxClipboard;
pub use keyboard::LinuxKeyboard;
pub use selection::selection_backend;
pub use spellcheck::spell_checker;

use session::SessionType;

/// Constructs the Linux `Clipboard`.
pub fn clipboard() -> LinuxClipboard {
    LinuxClipboard
}

/// Constructs the Linux `Keyboard`.
pub fn keyboard() -> LinuxKeyboard {
    LinuxKeyboard
}

/// No-op: Linux has no grantable permission to deep-link into.
pub fn open_permission_settings() -> Result<(), String> {
    Ok(())
}

/// No-op on Linux: tray-only behavior is achieved simply by never showing a
/// Dock-equivalent window, with no activation-policy API to call.
pub fn setup(_app: &mut tauri::App) {}

/// Positions the popover at the current cursor position, clamped to the
/// current monitor's work area so it always stays fully on-screen — Linux
/// window managers have no tray-relative positioning API equivalent to
/// macOS's menu-bar geometry, and `tauri_plugin_positioner`'s
/// `TrayBottomCenter` is unreliable across Linux desktop environments (it
/// depends on tray geometry information many Linux tray implementations
/// don't provide). Falls back to the top-right corner of the current (or
/// primary) monitor when the cursor position can't be read.
pub fn position_popover(window: &tauri::WebviewWindow) {
    use tauri::PhysicalPosition;

    let Some(monitor) = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
    else {
        return;
    };

    let window_size = window
        .outer_size()
        .unwrap_or(tauri::PhysicalSize::new(400, 300));
    let work_area = monitor.work_area();

    let min_x = work_area.position.x;
    let min_y = work_area.position.y;
    let max_x = (min_x + work_area.size.width as i32 - window_size.width as i32).max(min_x);
    let max_y = (min_y + work_area.size.height as i32 - window_size.height as i32).max(min_y);

    let (x, y) = match window.cursor_position() {
        Ok(cursor) => (cursor.x as i32, cursor.y as i32),
        // Cursor position unavailable: fall back to the monitor's top-right
        // corner rather than guessing.
        Err(_) => (min_x + work_area.size.width as i32 - window_size.width as i32, min_y),
    };

    let clamped = PhysicalPosition::new(x.clamp(min_x, max_x), y.clamp(min_y, max_y));
    let _ = window.set_position(clamped);
}

/// Linux platform metadata: session-aware. Replace (write-back into the
/// source app) needs `_NET_ACTIVE_WINDOW` activation, which is X11-only.
pub fn platform_info() -> crate::platform::PlatformInfo {
    let session = session::current();
    crate::platform::PlatformInfo {
        os: "linux",
        session: Some(match session {
            SessionType::X11 => "x11".to_string(),
            SessionType::Wayland => "wayland".to_string(),
        }),
        replace_back_available: session == SessionType::X11,
        permission_required: false,
        default_shortcut: crate::core::settings::default_shortcut().to_string(),
    }
}

/// Linux wants an explicit "Open Kallilex" tray-menu entry: SNI
/// (StatusNotifierItem) trays are menu-oriented and may not deliver
/// left-click events at all, so the menu is the only guaranteed-reachable
/// way to open the popover on some desktop environments.
pub fn wants_tray_open_entry() -> bool {
    true
}

/// On Wayland, opening the popover from the tray (left-click toggle or the
/// "Open Kallilex" menu entry) should behave like the global shortcut and
/// immediately capture the primary selection, since Wayland has no
/// synthetic-copy fallback to rely on later and the primary selection is
/// the only capture path available at all.
pub fn tray_open_captures() -> bool {
    session::current() == SessionType::Wayland
}

/// On Wayland, global shortcut registration commonly fails or is
/// unsupported depending on the compositor (no portal-backed global
/// shortcuts wired up yet — spec-12+). Registration is still attempted, but
/// a failure there is expected, not a real error worth an error dialog.
pub fn global_shortcut_failure_expected() -> bool {
    session::current() == SessionType::Wayland
}
