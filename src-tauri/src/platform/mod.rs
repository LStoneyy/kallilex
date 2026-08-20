//! Platform seam: the single place `#[cfg(target_os)]` branching lives.
//! `lib.rs` and `commands.rs` never branch on the target OS themselves —
//! they only call the functions re-exported here, which each platform
//! submodule implements under its own name. Adding a new platform means
//! adding a new submodule that implements this same function surface and
//! wiring it into the `#[cfg]` blocks below; nothing else in the crate
//! changes.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
pub use macos::{
    app_activator, clipboard, keyboard, open_permission_settings, platform_info,
    position_popover, selection_backend, setup, spell_checker,
};
#[cfg(target_os = "linux")]
pub use linux::{
    app_activator, clipboard, keyboard, open_permission_settings, platform_info,
    position_popover, selection_backend, setup, spell_checker,
};

/// Platform metadata surfaced to the frontend via the `get_platform_info`
/// command: what capture/replace features this platform supports and what
/// its default shortcut/session look like.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformInfo {
    /// "macos" | "linux"
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
}
