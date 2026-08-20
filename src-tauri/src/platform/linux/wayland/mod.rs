//! Wayland XDG-portal capability probing (spec-12 Slice A) and the
//! GlobalShortcuts portal binding built on top of it (spec-12 Slice B).
//!
//! Wayland has no single API surface for global shortcuts or input
//! synthesis the way X11 does; instead, compositors *optionally* implement
//! the `org.freedesktop.portal.GlobalShortcuts` and
//! `org.freedesktop.portal.RemoteDesktop` interfaces of the XDG desktop
//! portal. Whether either is present — and, for `RemoteDesktop`, which
//! version — varies per compositor and per distro, so Kallilex probes for
//! them once at startup and degrades each dependent feature independently
//! rather than assuming "Wayland" implies a fixed capability set.
//!
//! The probe itself ([`probe::probe`]) is read-only: it only creates portal
//! proxies and reads their `version` D-Bus property, which never shows a
//! permission dialog. Actually *using* a capability — binding a shortcut
//! ([`shortcut::run_portal_shortcut`]), starting a remote-desktop session
//! ([`remote_desktop::send_chord`]) — is the only place a dialog can
//! appear, and even then only in direct response to a user-initiated
//! action (the first fallback-copy or Replace), never at startup.
//!
//! [`remote_desktop`] (spec-12 Slice C) layers input synthesis (synthetic
//! Ctrl+C/Ctrl+V via `NotifyKeyboardKeycode`) and the restore-token session
//! lifecycle on top of the `RemoteDesktop` capability probed here.

mod probe;
mod remote_desktop;
mod shortcut;

use std::sync::OnceLock;

/// Wayland-portal-backed capabilities detected for the current compositor.
/// All fields default to `false`: on X11, or before the probe has run, no
/// capability should be assumed available.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WaylandCapabilities {
    /// `org.freedesktop.portal.GlobalShortcuts` is implemented by the
    /// running desktop portal backend.
    pub global_shortcut: bool,
    /// `org.freedesktop.portal.RemoteDesktop` is implemented by the running
    /// desktop portal backend.
    pub input_synthesis: bool,
    /// The `RemoteDesktop` interface is at version 2 or newer, i.e. it
    /// supports `restore_token`-based session persistence so the user isn't
    /// re-prompted for input-synthesis permission on every run.
    pub can_persist_session: bool,
}

/// Process-wide cache for the probed capabilities, populated once from
/// `linux::setup` on Wayland sessions. Reading it before `setup` has run (or
/// on X11, where it's never populated) returns [`WaylandCapabilities::default`]
/// — all `false` — which is the correct, honest "nothing available" answer.
static CAPABILITIES: OnceLock<WaylandCapabilities> = OnceLock::new();

/// Returns the cached capabilities, or all-`false` defaults if the probe
/// hasn't run (X11 sessions, or before startup has completed it).
pub fn capabilities() -> WaylandCapabilities {
    CAPABILITIES.get().copied().unwrap_or_default()
}

/// Runs the portal capability probe and stores the result in the process-wide
/// cache. Intended to be called exactly once, from `linux::setup`, on
/// Wayland sessions only. Safe to call from a non-async context via a
/// caller-provided async runtime entry point (`tauri::async_runtime::block_on`
/// in `setup`); the probe itself has an internal timeout so this can never
/// hang startup indefinitely.
pub fn init(caps: WaylandCapabilities) {
    let _ = CAPABILITIES.set(caps);
}

/// Registers this (non-sandboxed) process as the owner of `app_id` with
/// the portal's host Registry (`org.freedesktop.host.portal.Registry`),
/// so portals that key permissions and persistence off the app id see a
/// stable identity: GlobalShortcuts refuses to bind without one (the
/// portal answers `NotAllowed: An app id is required`), and RemoteDesktop
/// restore tokens are stored per app id. Only processes started through a
/// desktop entry get an id for free — the launcher wraps them in a
/// systemd scope that encodes it — so a terminal launch, an autostart
/// run, or `pnpm tauri dev` has none without this call.
///
/// Must run before any other portal call: the portal resolves and caches
/// a peer's app id on first contact.
///
/// Registration only succeeds when the desktop database actually holds an
/// entry for `app_id` — the portal looks up `<app_id>.desktop` and rejects
/// the request with `App info not found` otherwise (verified against
/// xdg-desktop-portal 1.21). It therefore requires the installed package
/// to ship a desktop entry whose basename matches the bundle identifier,
/// and it is normal for this to fail in an uninstalled dev run.
///
/// Failure is deliberately non-fatal and silent: portal versions before
/// 1.20 have no Registry interface at all, ashpd no-ops when actually
/// sandboxed, and a run that already has an app id needs nothing here.
/// The user-visible consequence of genuinely having no app id is reported
/// where it becomes real — the shortcut bind logs why it failed and the
/// in-app notice names the missing capability — not from this seam.
pub async fn register_app_id(app_id: &str) {
    const REGISTER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

    let Ok(app_id) = ashpd::AppID::try_from(app_id.to_string()) else {
        return;
    };
    let _ = tokio::time::timeout(REGISTER_TIMEOUT, ashpd::register_host_app(app_id)).await;
}

pub use probe::probe;
pub use remote_desktop::{send_chord, Chord};
pub use shortcut::run_portal_shortcut;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_default_to_all_false_before_init() {
        // `CAPABILITIES` is process-wide, so this only asserts the "unset"
        // fallback behavior via a fresh default value rather than the real
        // static (which other tests in the same binary may have already
        // populated).
        assert_eq!(
            WaylandCapabilities::default(),
            WaylandCapabilities {
                global_shortcut: false,
                input_synthesis: false,
                can_persist_session: false,
            }
        );
    }
}
