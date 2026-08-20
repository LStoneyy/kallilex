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
mod wayland;

pub use activation::app_activator;
pub use clipboard::LinuxClipboard;
pub use keyboard::LinuxKeyboard;
pub use selection::selection_backend;
pub use spellcheck::spell_checker;

use session::SessionType;
use wayland::WaylandCapabilities;

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

/// Tray-only behavior is achieved simply by never showing a Dock-equivalent
/// window, with no activation-policy API to call — so on X11 this is still a
/// no-op. On Wayland it also runs the read-only portal capability probe
/// (spec-12 Slice A) once, synchronously, before the rest of startup
/// consults `platform_info()`: this runs on Tauri's main-thread `setup` hook,
/// not inside the tokio runtime, so blocking on the async probe here is
/// safe and doesn't risk a nested-runtime panic.
pub fn setup(_app: &mut tauri::App) {
    if session::current() == SessionType::Wayland {
        let caps = tauri::async_runtime::block_on(wayland::probe());
        wayland::init(caps);
    }
}

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
        Err(_) => (
            min_x + work_area.size.width as i32 - window_size.width as i32,
            min_y,
        ),
    };

    let clamped = PhysicalPosition::new(x.clamp(min_x, max_x), y.clamp(min_y, max_y));
    let _ = window.set_position(clamped);
}

/// Linux platform metadata: session-aware. Replace (write-back into the
/// source app) needs either `_NET_ACTIVE_WINDOW` activation (X11) or the
/// `RemoteDesktop` portal's input-synthesis capability (Wayland, spec-12).
pub fn platform_info() -> crate::platform::PlatformInfo {
    platform_info_for(session::current(), wayland::capabilities())
}

/// Pure session+capabilities → `PlatformInfo` mapping, kept separate from
/// `platform_info` so the X11/Wayland branching can be unit-tested directly
/// against injected values instead of the real session/portal state.
fn platform_info_for(
    session: SessionType,
    caps: WaylandCapabilities,
) -> crate::platform::PlatformInfo {
    match session {
        SessionType::X11 => crate::platform::PlatformInfo {
            os: "linux",
            session: Some("x11".to_string()),
            replace_back_available: true,
            permission_required: false,
            default_shortcut: crate::core::settings::default_shortcut().to_string(),
            wayland: None,
        },
        SessionType::Wayland => crate::platform::PlatformInfo {
            os: "linux",
            session: Some("wayland".to_string()),
            replace_back_available: caps.input_synthesis,
            permission_required: false,
            default_shortcut: crate::core::settings::default_shortcut().to_string(),
            wayland: Some(crate::platform::WaylandCapabilitiesInfo {
                global_shortcut: caps.global_shortcut,
                input_synthesis: caps.input_synthesis,
                can_persist_session: caps.can_persist_session,
            }),
        },
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

/// The embedded tray-icon raster: the same K glyph as macOS, but
/// pre-colored in the logo's verdigris accent (#2faf9b). Linux trays have
/// no template-image recoloring, so the macOS black template glyph would
/// be near-invisible on dark panels (e.g. Ubuntu's top bar); the accent
/// color stays legible on both dark and light panels. The 44 px @2x source
/// scales down cleanly on standard-DPI trays; icons/tray-linux.png (@1x)
/// stays committed as an artwork artifact.
pub fn tray_icon_bytes() -> &'static [u8] {
    include_bytes!("../../../icons/tray-linux@2x.png")
}

/// No template-image concept on Linux trays; the flag is ignored there,
/// passed as `false` for clarity.
pub fn tray_icon_as_template() -> bool {
    false
}

/// Whether the Wayland GlobalShortcuts portal should own the "capture"
/// shortcut instead of the tauri global-shortcut plugin. There must be
/// exactly one owner of that trigger: when the portal is present, `lib.rs`
/// must not also attempt plugin-based registration, since the plugin's
/// underlying key-grab mechanism doesn't work under Wayland anyway and
/// attempting both would either double-fire or race on which one the
/// compositor actually delivers events through.
pub fn use_portal_global_shortcut() -> bool {
    session::current() == SessionType::Wayland && wayland::capabilities().global_shortcut
}

/// Spawns the long-lived async task that binds the "capture" shortcut
/// through the `GlobalShortcuts` portal and routes its `Activated` signal
/// into `on_activated`. Only meaningful (and only ever called) when
/// [`use_portal_global_shortcut`] is `true`. See `wayland::run_portal_shortcut`
/// for the full bind/listen/failure-handling logic.
pub fn spawn_portal_shortcut(
    app: tauri::AppHandle,
    preferred_shortcut: String,
    on_activated: fn(&tauri::AppHandle),
) {
    tauri::async_runtime::spawn(wayland::run_portal_shortcut(
        app,
        preferred_shortcut,
        on_activated,
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn x11_has_replace_back_and_no_wayland_info() {
        let info = platform_info_for(SessionType::X11, WaylandCapabilities::default());

        assert_eq!(info.session.as_deref(), Some("x11"));
        assert!(info.replace_back_available);
        assert!(info.wayland.is_none());
    }

    #[test]
    fn wayland_with_no_capabilities_has_no_replace_back() {
        let info = platform_info_for(SessionType::Wayland, WaylandCapabilities::default());

        assert_eq!(info.session.as_deref(), Some("wayland"));
        assert!(!info.replace_back_available);
        let wayland = info
            .wayland
            .expect("wayland info must be present on a Wayland session");
        assert!(!wayland.global_shortcut);
        assert!(!wayland.input_synthesis);
        assert!(!wayland.can_persist_session);
    }

    #[test]
    fn wayland_with_input_synthesis_enables_replace_back() {
        let caps = WaylandCapabilities {
            global_shortcut: false,
            input_synthesis: true,
            can_persist_session: false,
        };

        let info = platform_info_for(SessionType::Wayland, caps);

        assert!(info.replace_back_available);
        let wayland = info
            .wayland
            .expect("wayland info must be present on a Wayland session");
        assert!(wayland.input_synthesis);
        assert!(!wayland.global_shortcut);
    }

    #[test]
    fn wayland_capabilities_pass_through_can_persist_session() {
        let caps = WaylandCapabilities {
            global_shortcut: true,
            input_synthesis: true,
            can_persist_session: true,
        };

        let info = platform_info_for(SessionType::Wayland, caps);

        let wayland = info
            .wayland
            .expect("wayland info must be present on a Wayland session");
        assert!(wayland.global_shortcut);
        assert!(wayland.input_synthesis);
        assert!(wayland.can_persist_session);
    }
}
