//! The read-only D-Bus probe itself, kept separate from the cache/module
//! surface in `super` so the "how do we ask the portal what it supports"
//! logic doesn't get tangled up with the "how is the answer stored and
//! reused" concern.

use std::time::Duration;

use ashpd::desktop::global_shortcuts::GlobalShortcuts;
use ashpd::desktop::remote_desktop::RemoteDesktop;
use ashpd::zbus;

use super::WaylandCapabilities;

/// `RemoteDesktop` interface version at which session-restore tokens
/// (`persist_mode`/`restore_token`) were introduced.
const REMOTE_DESKTOP_PERSIST_MIN_VERSION: u32 = 2;

/// How long the whole probe is allowed to take before giving up and
/// reporting no capabilities. A well-behaved portal backend answers a
/// property read near-instantly; a compositor with a hung or absent portal
/// service must never be allowed to delay app startup.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Well-known bus name of the XDG desktop portal service that hosts every
/// portal interface we probe (`GlobalShortcuts`, `RemoteDesktop`, ...).
const PORTAL_SERVICE: &str = "org.freedesktop.portal.Desktop";

/// Probes the running XDG desktop portal for the Wayland-relevant
/// capabilities Kallilex depends on. Read-only: checking bus presence and
/// reading a portal's `version` property never triggers a permission
/// dialog, unlike creating a session or calling any of the portals' action
/// methods (later slices only do that in direct response to explicit user
/// action).
///
/// This is a two-step probe:
///
/// 1. Confirm `org.freedesktop.portal.Desktop` is actually present on the
///    session bus (owned, or D-Bus-activatable) before touching ashpd at
///    all. This step exists because `ashpd::proxy::Proxy::with_connection`
///    treats *any* error from reading the interface's `version` property
///    other than an `InvalidArgs` naming that interface — including the
///    portal service not existing on the bus at all — as "version 1,
///    interface present". Without this check, a machine with no
///    `xdg-desktop-portal` daemon installed would be reported as
///    supporting every portal.
/// 2. Once the service is known to exist, create each ashpd proxy and read
///    its `version` property as usual. A running portal whose backend
///    genuinely lacks an interface still yields `Err(PortalNotFound)` here,
///    which correctly degrades that one capability to `false`.
///
/// Any error at either step — the interface isn't implemented, the portal
/// service isn't present at all, D-Bus is unreachable, or the probe simply
/// takes too long — degrades the corresponding capability to `false` rather
/// than failing startup. A compositor that doesn't support a portal isn't a
/// Kallilex error; it's a real, expected environment to run in with fewer
/// features.
pub async fn probe() -> WaylandCapabilities {
    tokio::time::timeout(PROBE_TIMEOUT, probe_uncapped())
        .await
        .unwrap_or_default()
}

async fn probe_uncapped() -> WaylandCapabilities {
    if !portal_service_present().await {
        return WaylandCapabilities::default();
    }

    let global_shortcut = GlobalShortcuts::new().await.is_ok();

    let (input_synthesis, can_persist_session) = match RemoteDesktop::new().await {
        Ok(remote_desktop) => (
            true,
            remote_desktop.version() >= REMOTE_DESKTOP_PERSIST_MIN_VERSION,
        ),
        Err(_) => (false, false),
    };

    WaylandCapabilities {
        global_shortcut,
        input_synthesis,
        can_persist_session,
    }
}

/// Checks whether `org.freedesktop.portal.Desktop` is present on the
/// session bus, either because something already owns the name or because
/// it's registered as D-Bus-activatable (in which case the subsequent
/// property read on a portal interface will auto-start it). Any failure
/// along the way — no session bus, no `org.freedesktop.DBus` proxy, a
/// malformed bus name — is treated as "not present".
async fn portal_service_present() -> bool {
    let Ok(connection) = zbus::Connection::session().await else {
        return false;
    };

    let Ok(dbus) = zbus::fdo::DBusProxy::new(&connection).await else {
        return false;
    };

    let Ok(name) = zbus::names::BusName::try_from(PORTAL_SERVICE) else {
        return false;
    };

    if dbus.name_has_owner(name).await.unwrap_or(false) {
        return true;
    }

    dbus.list_activatable_names()
        .await
        .map(|names| names.iter().any(|name| name.as_str() == PORTAL_SERVICE))
        .unwrap_or(false)
}
