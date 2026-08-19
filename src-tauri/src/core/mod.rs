//! Platform-agnostic application core: pure logic and persistence seams
//! that Tauri commands wrap thinly.

pub mod capture;
pub mod clipboard;
pub mod settings;
pub mod spellcheck;

/// Label of the popover window, shared between the tray/window wiring in
/// `lib.rs` and the Tauri commands in `commands.rs`.
pub const POPOVER_WINDOW_LABEL: &str = "popover";

/// Label of the settings window shell.
pub const SETTINGS_WINDOW_LABEL: &str = "settings";
