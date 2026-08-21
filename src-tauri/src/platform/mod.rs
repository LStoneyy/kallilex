//! Platform seam: the single place `#[cfg(target_os)]` branching lives.
//! `lib.rs` and `commands.rs` never branch on the target OS themselves —
//! they only call the functions re-exported here, which each platform
//! submodule implements under its own name. Adding a new platform means
//! adding a new submodule that implements this same function surface and
//! wiring it into the `#[cfg]` blocks below; nothing else in the crate
//! changes. Three platforms are supported: macOS, Linux, and Windows.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

// Shared, pure popover-clamping helper (Linux and Windows only — macOS
// positions relative to the menu bar instead, so an unused module there
// would trip `-D warnings`). See `positioning.rs` for details.
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod positioning;

#[cfg(target_os = "linux")]
pub use linux::{
    app_activator, clipboard, global_shortcut_failure_expected, keyboard,
    needs_frame_extents_resync, open_permission_settings, platform_info, position_popover,
    selection_backend, set_input_synthesis_enabled, setup, spawn_portal_shortcut, spell_checker,
    tray_icon_as_template, tray_icon_bytes, tray_open_captures, use_portal_global_shortcut,
    wants_tray_open_entry,
};
#[cfg(target_os = "macos")]
pub use macos::{
    app_activator, clipboard, global_shortcut_failure_expected, keyboard,
    needs_frame_extents_resync, open_permission_settings, platform_info, position_popover,
    selection_backend, set_input_synthesis_enabled, setup, spawn_portal_shortcut, spell_checker,
    tray_icon_as_template, tray_icon_bytes, tray_open_captures, use_portal_global_shortcut,
    wants_tray_open_entry,
};
#[cfg(target_os = "windows")]
pub use windows::{
    app_activator, clipboard, global_shortcut_failure_expected, keyboard,
    needs_frame_extents_resync, open_permission_settings, platform_info, position_popover,
    selection_backend, set_input_synthesis_enabled, setup, spawn_portal_shortcut, spell_checker,
    tray_icon_as_template, tray_icon_bytes, tray_open_captures, use_portal_global_shortcut,
    wants_tray_open_entry,
};

/// Platform metadata surfaced to the frontend via the `get_platform_info`
/// command: what capture/replace features this platform supports and what
/// its default shortcut/session look like.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformInfo {
    /// "macos" | "linux" | "windows"
    pub os: &'static str,
    /// Display-server session: `None` on macOS; Slice B fills in
    /// "x11"/"wayland" on Linux.
    pub session: Option<String>,
    /// Whether Replace (write-back into the source app) is available.
    pub replace_back_available: bool,
    /// Whether this platform has a grantable capture permission (macOS
    /// Accessibility).
    pub permission_required: bool,
    /// The platform's default global shortcut, for UI labels/placeholders.
    pub default_shortcut: String,
    /// XDG-portal capability probe results (spec-12). `None` on macOS and on
    /// X11 sessions, where portals aren't consulted at all; `Some` on
    /// Wayland sessions, reflecting whatever the running compositor's
    /// desktop portal backend actually implements.
    pub wayland: Option<WaylandCapabilitiesInfo>,
}

/// Wayland-portal-backed capabilities surfaced to the frontend, mirroring
/// `platform::linux::wayland::WaylandCapabilities` for the parts the UI
/// needs to know about (see that type for what each flag means and how it's
/// probed).
#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WaylandCapabilitiesInfo {
    pub global_shortcut: bool,
    pub input_synthesis: bool,
    pub can_persist_session: bool,
}

/// The portal-reported, human-readable trigger description for the single
/// "capture" shortcut bound through the Wayland GlobalShortcuts portal
/// (spec-12 Slice B) — e.g. what the compositor's own shortcut-binding UI
/// showed the user, not necessarily the `preferred_trigger` hint Kallilex
/// requested. `None` until a successful bind stores a value: before the
/// portal task has run, when the bind failed or was declined, or on any
/// platform/session where `use_portal_global_shortcut()` is false (the
/// state is still `manage`d there, just never written to).
#[derive(Default)]
pub struct PortalShortcutTrigger(pub std::sync::Mutex<Option<String>>);
