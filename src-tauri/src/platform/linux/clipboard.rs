//! Linux clipboard access via `arboard` (X11 selections plus Wayland's
//! `wlr-data-control` protocol through the `wayland-data-control` feature).

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::{Duration, Instant};

use arboard::{Clipboard as ArboardClipboard, GetExtLinux, LinuxClipboardKind};

use crate::core::clipboard::{Clipboard, ClipboardBackup, ClipboardItem};

/// The MIME type used for the single format this backup/restore
/// implementation preserves. Not meant to match macOS's
/// `public.utf8-plain-text` — only this module's own `backup`/`restore` pair
/// ever reads it back.
const TEXT_FORMAT: &str = "text/plain;charset=utf-8";

/// How often to poll the emulated change count while waiting for a
/// synthetic copy to land — matches macOS's `POLL_INTERVAL`.
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Clipboard access via `arboard`. Every method opens its own short-lived
/// `arboard::Clipboard` handle rather than holding one: the handle is not
/// `Sync`, and arboard's Linux backends keep whatever was last `set` alive
/// via a background thread/connection even after the handle is dropped, so
/// there is no lifetime reason to keep it open either.
pub struct LinuxClipboard;

impl LinuxClipboard {
    /// Reads the X11/Wayland **primary selection** (the "select text to
    /// copy it" clipboard, pasted with a middle click) rather than the
    /// regular clipboard. `LinuxSelectionBackend::ax_selected_text` uses
    /// this as the capture-order "primary selection first" path — see that
    /// impl's doc comment for how this maps onto the capture orchestration.
    /// `None` when the primary selection is empty or unreadable (no arboard
    /// handle, no owner, or — on some Wayland compositors — no primary
    /// selection support at all).
    pub fn read_primary() -> Option<String> {
        let mut clipboard = ArboardClipboard::new().ok()?;
        let text = clipboard
            .get()
            .clipboard(LinuxClipboardKind::Primary)
            .text()
            .ok()?;
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
}

impl Clipboard for LinuxClipboard {
    fn read_text(&self) -> Option<String> {
        let mut clipboard = ArboardClipboard::new().ok()?;
        clipboard.get_text().ok().filter(|text| !text.is_empty())
    }

    fn write_text(&self, text: &str) {
        if let Ok(mut clipboard) = ArboardClipboard::new() {
            let _ = clipboard.set_text(text.to_string());
        }
    }

    /// **Documented Linux limitation: text-only.** arboard has no
    /// cross-backend API for enumerating/reading arbitrary clipboard MIME
    /// types (unlike `NSPasteboard`'s `pasteboardItems`/`dataForType`), so
    /// only the plain-text contents are backed up. Non-text clipboard
    /// contents (images, rich text, files) are silently not restored by
    /// [`Self::restore`] on Linux.
    fn backup(&self) -> ClipboardBackup {
        match self.read_text() {
            Some(text) => ClipboardBackup(vec![ClipboardItem {
                formats: vec![(TEXT_FORMAT.to_string(), text.into_bytes())],
            }]),
            None => ClipboardBackup::default(),
        }
    }

    fn restore(&self, backup: &ClipboardBackup) {
        let Some(text) = backup.0.first().and_then(|item| {
            item.formats
                .iter()
                .find(|(format, _)| format == TEXT_FORMAT)
                .map(|(_, bytes)| String::from_utf8_lossy(bytes).into_owned())
        }) else {
            // Empty backup: a no-op, not a clear — mirrors the macOS
            // contract (nothing was backed up, so nothing should change).
            return;
        };
        self.write_text(&text);
    }

    /// **Documented Linux limitation: emulated, not a real counter.** X11
    /// and Wayland have no equivalent of `NSPasteboard.changeCount`, so this
    /// hashes the current clipboard text instead. A consequence: copying
    /// identical content twice in a row is indistinguishable from no change
    /// at all. The fallback capture path only cares whether *some* change
    /// landed after the synthetic Ctrl+C.
    fn change_count(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.read_text().hash(&mut hasher);
        hasher.finish()
    }

    fn wait_for_change(&self, prev: u64, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.change_count() != prev {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(POLL_INTERVAL);
        }
    }
}
