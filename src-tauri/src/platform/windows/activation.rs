//! Windows window activation (spec-15 Slice A stub). Slice B replaces this
//! with `SetForegroundWindow` on the remembered `HWND` (plus the documented
//! `AttachThreadInput` fallback), marshalled onto the main (message-loop)
//! thread the same way `MacosAppActivator` marshals onto AppKit's main
//! thread.

use tauri::AppHandle;

use crate::core::capture::SourceApp;
use crate::core::replace::AppActivator;

/// Honest stub: no window activation is implemented yet.
pub struct WindowsAppActivator {
    /// Unused in Slice A's stub; Slice B marshals `SetForegroundWindow`
    /// calls onto the main thread via `app.run_on_main_thread`, which needs
    /// this handle. Stored now so the constructor's signature (and the
    /// stored-state shape) doesn't have to change between slices.
    #[allow(dead_code)]
    app: AppHandle,
}

impl WindowsAppActivator {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl AppActivator for WindowsAppActivator {
    fn activate(&self, _app: &SourceApp) -> Result<(), String> {
        Err("window activation is not yet implemented on Windows".to_string())
    }
}
