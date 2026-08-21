//! Window activation: the EWMH `_NET_ACTIVE_WINDOW` client message on X11,
//! and a Wayland "focus-return" activation built on hiding the popover —
//! see [`LinuxAppActivator::activate`]'s doc comment for why that's the
//! correct (and only possible) Wayland equivalent.

use tauri::{AppHandle, Manager};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    ClientMessageData, ClientMessageEvent, ConnectionExt, EventMask, CLIENT_MESSAGE_EVENT,
};

use crate::core::capture::SourceApp;
use crate::core::replace::AppActivator;
use crate::core::POPOVER_WINDOW_LABEL;
use crate::platform::linux::session::{self, SessionType};
use crate::platform::linux::wayland;

/// EWMH source indication for "pager or other tool", as opposed to `1`
/// ("normal application"). Kallilex is acting on behalf of the user like a
/// pager/taskbar would, not as the target application itself.
const SOURCE_INDICATION_PAGER: u32 = 2;

/// Brings another application's window to the foreground: on X11, by
/// sending it a `_NET_ACTIVE_WINDOW` client message, exactly like a pager
/// or taskbar would; on Wayland, by hiding the popover (see
/// [`Self::activate`]).
pub struct LinuxAppActivator {
    app: AppHandle,
}

impl LinuxAppActivator {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl AppActivator for LinuxAppActivator {
    /// X11: the `app` field is unused — sending an X11 client message is a
    /// plain, thread-safe socket write over a fresh connection, no
    /// AppKit-style main-thread affinity applies, so no marshalling is
    /// needed. `app.window` (the remembered X11 window handle) is required
    /// and this fails without one.
    ///
    /// Wayland: there is no cross-client activation protocol at all — a
    /// Wayland compositor deliberately gives no client the ability to
    /// raise/focus *another* client's window, unlike X11's EWMH pager
    /// convention. The only activation Kallilex itself can perform is
    /// negative: hide its own popover window and let the compositor's
    /// normal focus-follows-visibility behavior return focus to whatever
    /// surface previously had it — which, in the shortcut/tray capture
    /// flow, is exactly the app the user captured from. `app` itself (the
    /// [`SourceApp`] parameter) carries no usable identity on this path —
    /// see [`SourceApp::focus_return`] — this is intentional: there is
    /// nothing more specific to activate by. This whole path is only
    /// reached when `wayland::input_synthesis_live()` is true — the
    /// RemoteDesktop portal's input-synthesis capability being available is
    /// not enough on its own: the user may also have switched input
    /// synthesis off in Settings, in which case this returns the same `Err`
    /// as a compositor without the portal at all, by choice rather than by
    /// limitation.
    ///
    /// Hiding runs via `run_on_main_thread` and is not waited on: the hide
    /// request is simply queued, and `core::replace::replace_back`'s
    /// `FOCUS_SETTLE_DELAY` (150ms) after this call returns already exists
    /// to give the newly-focused app time to actually take focus, so it
    /// also comfortably covers the latency of the queued hide actually
    /// running. Hiding the popover triggers the same focus-loss ->
    /// `cancel_capture` -> `restore_pending` path a manual Escape/click-away
    /// would; that's already a harmless no-op mid-replace thanks to
    /// `BackupLifecycle::take_pending` (the race guard replace_back
    /// applies before ever calling into this activator) — no core changes
    /// needed here. Plain `window.hide()` is used rather than the crate's
    /// `hide_popover` helper, which also eagerly clears capture state; that
    /// would be premature here, since replace-back's own cleanup already
    /// owns clearing state through its normal flow.
    fn activate(&self, app: &SourceApp) -> Result<(), String> {
        match session::current() {
            SessionType::X11 => activate_x11(app),
            SessionType::Wayland => {
                if wayland::input_synthesis_live() {
                    hide_popover_for_focus_return(&self.app)
                } else {
                    Err("window activation is unavailable on Wayland".to_string())
                }
            }
        }
    }
}

fn activate_x11(app: &SourceApp) -> Result<(), String> {
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

/// Queues hiding the popover window on the main thread. Missing window is
/// an error (nothing to hide, so no meaningful "activation" happened at
/// all); scheduling failure is also surfaced rather than swallowed.
fn hide_popover_for_focus_return(app: &AppHandle) -> Result<(), String> {
    let window = app
        .get_webview_window(POPOVER_WINDOW_LABEL)
        .ok_or_else(|| "the popover window does not exist".to_string())?;

    app.run_on_main_thread(move || {
        let _ = window.hide();
    })
    .map_err(|e| format!("failed to schedule hiding the popover on the main thread: {e}"))
}

/// Constructs the Linux `AppActivator`.
pub fn app_activator(app: AppHandle) -> LinuxAppActivator {
    LinuxAppActivator::new(app)
}
