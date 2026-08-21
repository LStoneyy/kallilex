//! Windows clipboard access via `arboard`, mirroring the Linux text-only
//! implementation (`platform::linux::clipboard`) exactly, with one
//! improvement: `change_count()` uses the real `GetClipboardSequenceNumber`
//! counter instead of a content hash.

use std::time::{Duration, Instant};

use arboard::Clipboard as ArboardClipboard;
use windows::Win32::System::DataExchange::GetClipboardSequenceNumber;

use crate::core::clipboard::{Clipboard, ClipboardBackup, ClipboardItem};

/// The MIME type used for the single format this backup/restore
/// implementation preserves. Not meant to match macOS's
/// `public.utf8-plain-text` — only this module's own `backup`/`restore` pair
/// ever reads it back. Matches Linux's `TEXT_FORMAT` constant in spirit
/// (not shared: each platform module owns its own copy).
const TEXT_FORMAT: &str = "text/plain;charset=utf-8";

/// How often to poll the change count while waiting for the synthetic copy
/// to land — matches macOS's and Linux's `POLL_INTERVAL`.
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Clipboard access via `arboard`. Every method opens its own short-lived
/// `arboard::Clipboard` handle rather than holding one, matching the Linux
/// implementation's rationale: the handle is not `Sync`, and there is no
/// lifetime reason to keep it open.
pub struct WindowsClipboard;

impl Clipboard for WindowsClipboard {
    fn read_text(&self) -> Option<String> {
        let mut clipboard = ArboardClipboard::new().ok()?;
        clipboard.get_text().ok().filter(|text| !text.is_empty())
    }

    fn write_text(&self, text: &str) {
        if let Ok(mut clipboard) = ArboardClipboard::new() {
            let _ = clipboard.set_text(text.to_string());
        }
    }

    /// **Documented Windows limitation: text-only**, matching Linux (spec-15
    /// Out of Scope: multi-format clipboard backup via `EnumClipboardFormats`
    /// over HGLOBAL formats). `arboard` has no cross-backend API for
    /// enumerating/reading arbitrary clipboard formats on Windows either, so
    /// only the plain-text contents are backed up. Non-text clipboard
    /// contents (images, rich text, files) are silently not restored by
    /// [`Self::restore`].
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
            // Empty backup: a no-op, not a clear — mirrors the macOS/Linux
            // contract (nothing was backed up, so nothing should change).
            return;
        };
        self.write_text(&text);
    }

    /// Unlike Linux's content hash, this is a real, monotonically
    /// increasing counter maintained by the OS: `GetClipboardSequenceNumber`
    /// increments on every clipboard content change, so identical
    /// consecutive copies are distinguishable here (Linux's hash-based
    /// emulation cannot tell them apart). A clipboard locked by another
    /// process (rare, but possible mid-write) degrades to the trait's
    /// existing best-effort contract rather than surfacing an error: the
    /// sequence number is simply read again on the next poll, and
    /// `write_text`/`read_text` already swallow/absorb that kind of
    /// failure elsewhere in this impl.
    fn change_count(&self) -> u64 {
        // SAFETY: `GetClipboardSequenceNumber` takes no arguments and has no
        // preconditions beyond an initialized process; it is safe to call
        // from any thread at any time. The `windows` crate marks it `unsafe`
        // only because it's a raw FFI binding, not because of any actual
        // precondition callers must uphold.
        unsafe { GetClipboardSequenceNumber() as u64 }
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
