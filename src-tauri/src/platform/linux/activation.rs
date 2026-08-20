//! Window activation via the EWMH `_NET_ACTIVE_WINDOW` client message,
//! sent directly over an X11 connection.

use tauri::AppHandle;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    ClientMessageData, ClientMessageEvent, ConnectionExt, EventMask, CLIENT_MESSAGE_EVENT,
};

use crate::core::capture::SourceApp;
use crate::core::replace::AppActivator;
use crate::platform::linux::session::{self, SessionType};

/// EWMH source indication for "pager or other tool", as opposed to `1`
/// ("normal application"). Kallilex is acting on behalf of the user like a
/// pager/taskbar would, not as the target application itself.
const SOURCE_INDICATION_PAGER: u32 = 2;

/// Brings another application's window to the foreground by sending it a
/// `_NET_ACTIVE_WINDOW` client message, exactly like a pager or taskbar
/// would. X11 only — Wayland has no equivalent cross-client activation
/// protocol.
pub struct LinuxAppActivator;

impl AppActivator for LinuxAppActivator {
    /// The `AppHandle` parameter is unused, unlike macOS's
    /// `MacosAppActivator`: sending an X11 client message is a plain,
    /// thread-safe socket write over a fresh connection — no AppKit-style
    /// main-thread affinity applies, so no marshalling is needed here.
    fn activate(&self, app: &SourceApp) -> Result<(), String> {
        if session::current() == SessionType::Wayland {
            return Err("window activation is unavailable on Wayland".to_string());
        }

        let window = app
            .window
            .ok_or_else(|| "no window handle recorded for the source application".to_string())?;

        let (conn, screen_num) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let root = conn.setup().roots[screen_num].root;

        let atom = conn
            .intern_atom(false, b"_NET_ACTIVE_WINDOW")
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom;

        let event = ClientMessageEvent {
            response_type: CLIENT_MESSAGE_EVENT,
            format: 32,
            sequence: 0,
            window: window.0 as u32,
            type_: atom,
            // [source indication, timestamp, requestor's active window, 0, 0]
            // — timestamp 0 means CurrentTime; requestor is 0 as specified.
            data: ClientMessageData::from([SOURCE_INDICATION_PAGER, 0, 0, 0, 0]),
        };

        let event_mask = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
        conn.send_event(false, root, event_mask, event)
            .map_err(|e| e.to_string())?;
        conn.flush().map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// Constructs the Linux `AppActivator`.
pub fn app_activator(_app: AppHandle) -> LinuxAppActivator {
    LinuxAppActivator
}
