//! Selection capture: the primary-selection read (X11 + Wayland) and the
//! X11-only frontmost-window query.

use x11rb::connection::Connection;
use x11rb::properties::WmClass;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};

use crate::core::capture::{PlatformWindowId, SelectionBackend, SourceApp};
use crate::platform::linux::clipboard::LinuxClipboard;
use crate::platform::linux::session::{self, SessionType};

/// Linux selection capture. Unlike macOS's Accessibility-permission model,
/// Linux has no grantable capture permission at all — `permission_granted`
/// always returning `true` is the *final* contract, not a placeholder.
pub struct LinuxSelectionBackend;

impl SelectionBackend for LinuxSelectionBackend {
    fn permission_granted(&self) -> bool {
        true
    }

    /// X11 only: reads `_NET_ACTIVE_WINDOW` off the root window and the
    /// standard EWMH/ICCCM properties of that window. `None` on Wayland
    /// (no cross-client window query protocol) or on any X11 protocol
    /// error.
    fn frontmost_app(&self) -> Option<SourceApp> {
        if session::current() == SessionType::Wayland {
            return None;
        }
        frontmost_app_x11().ok().flatten()
    }

    /// Maps onto the spec's "capture order: primary selection first,
    /// clipboard + synthetic Ctrl+C as fallback" by treating the X11/
    /// Wayland **primary selection** (the "select to copy" clipboard) as
    /// this platform's instant path — the same role macOS's Accessibility
    /// `AXSelectedText` plays: read it directly, and if it's empty or
    /// unreadable, `core::capture::capture` falls back to the regular
    /// clipboard plus a synthetic Ctrl+C, unchanged. This works on both
    /// X11 and Wayland (arboard's `wayland-data-control` backend supports
    /// the primary selection on compositors that implement it).
    fn ax_selected_text(&self) -> Option<String> {
        LinuxClipboard::read_primary()
    }
}

/// Reads the frontmost application's identity via `_NET_ACTIVE_WINDOW` and
/// friends. Returns `Ok(None)` when there is no active window (or its pid/
/// name can't be determined at all — a bare `window` handle with no other
/// identity is still returned, since `window` is what replace-back actually
/// needs) and `Err` only on connection/protocol failures, which
/// `frontmost_app` collapses to `None` either way.
fn frontmost_app_x11() -> Result<Option<SourceApp>, Box<dyn std::error::Error>> {
    let (conn, screen_num) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen_num].root;

    let net_active_window = conn.intern_atom(false, b"_NET_ACTIVE_WINDOW")?.reply()?.atom;
    let active_window_reply = conn
        .get_property(
            false,
            root,
            net_active_window,
            AtomEnum::WINDOW,
            0,
            1,
        )?
        .reply()?;

    let Some(window) = active_window_reply.value32().and_then(|mut v| v.next()) else {
        return Ok(None);
    };
    if window == 0 {
        return Ok(None);
    }

    let pid = read_wm_pid(&conn, window).unwrap_or(0);
    let name = read_wm_name(&conn, window).or_else(|| read_wm_class_instance(&conn, window));

    Ok(Some(SourceApp {
        bundle_id: None,
        pid: pid as i32,
        name,
        window: Some(PlatformWindowId(window as u64)),
    }))
}

fn read_wm_pid(
    conn: &x11rb::rust_connection::RustConnection,
    window: u32,
) -> Option<u32> {
    let atom = conn.intern_atom(false, b"_NET_WM_PID").ok()?.reply().ok()?.atom;
    let reply = conn
        .get_property(false, window, atom, AtomEnum::CARDINAL, 0, 1)
        .ok()?
        .reply()
        .ok()?;
    reply.value32().and_then(|mut v| v.next())
}

fn read_wm_name(
    conn: &x11rb::rust_connection::RustConnection,
    window: u32,
) -> Option<String> {
    let net_wm_name = conn.intern_atom(false, b"_NET_WM_NAME").ok()?.reply().ok()?.atom;
    let utf8_string = conn.intern_atom(false, b"UTF8_STRING").ok()?.reply().ok()?.atom;
    let reply = conn
        .get_property(false, window, net_wm_name, utf8_string, 0, u32::MAX)
        .ok()?
        .reply()
        .ok()?;
    let bytes: Vec<u8> = reply.value8()?.collect();
    if bytes.is_empty() {
        None
    } else {
        String::from_utf8(bytes).ok()
    }
}

fn read_wm_class_instance(
    conn: &x11rb::rust_connection::RustConnection,
    window: u32,
) -> Option<String> {
    let reply = WmClass::get(conn, window).ok()?.reply().ok()??;
    let instance = reply.instance();
    if instance.is_empty() {
        None
    } else {
        String::from_utf8(instance.to_vec()).ok()
    }
}

/// Constructs the Linux `SelectionBackend`.
pub fn selection_backend() -> LinuxSelectionBackend {
    LinuxSelectionBackend
}
