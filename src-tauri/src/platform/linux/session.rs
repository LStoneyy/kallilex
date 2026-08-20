//! Display-server session detection. A handful of Linux-specific behaviors
//! (key synthesis, window activation, tray-open capture, global-shortcut
//! failure dialogs) differ between X11 and Wayland, so the rest of the
//! Linux platform code branches on [`current`] rather than re-deriving this
//! itself.

use std::sync::OnceLock;

/// The detected display-server session. XWayland (an X11 app running under
/// a Wayland compositor) counts as [`Wayland`](SessionType::Wayland): global
/// key/window-manager operations that go through the X11 protocol can't see
/// or affect native Wayland clients, so treating XWayland as X11 would be
/// misleading about what's actually reachable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionType {
    X11,
    Wayland,
}

/// Pure classification function, unit-tested with injected environment
/// values (see the `tests` module below) rather than real env vars.
///
/// A non-empty `WAYLAND_DISPLAY`, or `XDG_SESSION_TYPE == "wayland"`, means
/// Wayland; everything else (including both being absent, which is the
/// classic X11 case) means X11.
pub fn detect(xdg_session_type: Option<&str>, wayland_display: Option<&str>) -> SessionType {
    let wayland_display_present = wayland_display.is_some_and(|value| !value.is_empty());
    let xdg_session_is_wayland = xdg_session_type == Some("wayland");

    if wayland_display_present || xdg_session_is_wayland {
        SessionType::Wayland
    } else {
        SessionType::X11
    }
}

static SESSION: OnceLock<SessionType> = OnceLock::new();

/// The session detected once at startup from the real `XDG_SESSION_TYPE`/
/// `WAYLAND_DISPLAY` environment variables, cached for the process lifetime
/// (the session type cannot change while Kallilex is running).
pub fn current() -> SessionType {
    *SESSION.get_or_init(|| {
        let xdg_session_type = std::env::var("XDG_SESSION_TYPE").ok();
        let wayland_display = std::env::var("WAYLAND_DISPLAY").ok();
        detect(xdg_session_type.as_deref(), wayland_display.as_deref())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_x11_session_is_x11() {
        assert_eq!(detect(Some("x11"), None), SessionType::X11);
    }

    #[test]
    fn wayland_session_type_is_wayland() {
        assert_eq!(
            detect(Some("wayland"), Some("wayland-0")),
            SessionType::Wayland
        );
    }

    #[test]
    fn xwayland_counts_as_wayland() {
        // XDG_SESSION_TYPE=wayland with WAYLAND_DISPLAY set is also what an
        // X11 app sees when it's actually running under XWayland: global X11
        // grabs can't see native Wayland keystrokes, so this must resolve to
        // Wayland, not X11.
        assert_eq!(
            detect(Some("wayland"), Some("wayland-1")),
            SessionType::Wayland
        );
    }

    #[test]
    fn wayland_display_alone_is_wayland_even_without_xdg_session_type() {
        assert_eq!(detect(None, Some("wayland-0")), SessionType::Wayland);
    }

    #[test]
    fn empty_wayland_display_does_not_count_as_present() {
        assert_eq!(detect(Some("x11"), Some("")), SessionType::X11);
    }

    #[test]
    fn both_absent_defaults_to_x11() {
        assert_eq!(detect(None, None), SessionType::X11);
    }
}
