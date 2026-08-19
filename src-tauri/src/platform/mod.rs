//! Real, OS-backed implementations of the `core` seams
//! (`SelectionBackend`, `Clipboard`, `Keyboard`) plus small platform
//! utilities (opening System Settings) that don't fit any trait.

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::{open_accessibility_settings, MacosClipboard, MacosKeyboard, MacosSelectionBackend};
