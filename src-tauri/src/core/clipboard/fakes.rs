//! In-memory `Clipboard`/`Keyboard` fakes used by unit tests in this crate
//! (`core::clipboard` and `core::capture`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::{Clipboard, ClipboardBackup, ClipboardItem, Keyboard};

const TEXT_FORMAT: &str = "public.utf8-plain-text";

/// Shared, ordered log of fake method calls, used to assert call ordering
/// across a `FakeClipboard`/`FakeKeyboard` pair (e.g. backup -> send_copy ->
/// read_text).
#[derive(Clone, Default)]
pub struct CallLog(Arc<Mutex<Vec<&'static str>>>);

impl CallLog {
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends `name` to the log. `pub` so fakes defined outside this
    /// module (e.g. `core::replace`'s `FakeActivator`/`FakeSleeper`) can
    /// share one ordered log with a `FakeClipboard`/`FakeKeyboard` pair.
    pub fn record(&self, name: &'static str) {
        self.0.lock().expect("call log mutex poisoned").push(name);
    }

    pub fn calls(&self) -> Vec<&'static str> {
        self.0.lock().expect("call log mutex poisoned").clone()
    }
}

/// In-memory `Clipboard` fake. Stores a single text value, bumps a change
/// counter on every write (including restores and external mutation via
/// [`Self::set_external_text`]), and records calls to `log`.
pub struct FakeClipboard {
    text: Mutex<Option<String>>,
    change_count: Mutex<u64>,
    log: CallLog,
}

impl FakeClipboard {
    pub fn new(log: CallLog) -> Self {
        Self {
            text: Mutex::new(None),
            change_count: Mutex::new(0),
            log,
        }
    }

    pub fn with_text(log: CallLog, text: impl Into<String>) -> Self {
        let clipboard = Self::new(log);
        *clipboard.text.lock().unwrap() = Some(text.into());
        clipboard
    }

    /// Simulates an external app writing to the clipboard, e.g. what the
    /// real synthetic ⌘C does. Used by tests to wire a `FakeKeyboard`'s
    /// `send_copy` to "land" a copy.
    pub fn set_external_text(&self, text: impl Into<String>) {
        *self.text.lock().unwrap() = Some(text.into());
        *self.change_count.lock().unwrap() += 1;
    }

    pub fn current_text(&self) -> Option<String> {
        self.text.lock().unwrap().clone()
    }
}

impl Clipboard for FakeClipboard {
    fn read_text(&self) -> Option<String> {
        self.log.record("read_text");
        self.text.lock().unwrap().clone()
    }

    fn write_text(&self, text: &str) {
        self.log.record("write_text");
        *self.text.lock().unwrap() = Some(text.to_string());
        *self.change_count.lock().unwrap() += 1;
    }

    fn backup(&self) -> ClipboardBackup {
        self.log.record("backup");
        let text = self.text.lock().unwrap().clone();
        match text {
            Some(text) => ClipboardBackup(vec![ClipboardItem {
                formats: vec![(TEXT_FORMAT.to_string(), text.into_bytes())],
            }]),
            None => ClipboardBackup::default(),
        }
    }

    fn restore(&self, backup: &ClipboardBackup) {
        self.log.record("restore");
        let text = backup
            .0
            .first()
            .and_then(|item| item.formats.iter().find(|(kind, _)| kind == TEXT_FORMAT))
            .map(|(_, bytes)| String::from_utf8_lossy(bytes).into_owned());
        *self.text.lock().unwrap() = text;
        *self.change_count.lock().unwrap() += 1;
    }

    fn change_count(&self) -> u64 {
        *self.change_count.lock().unwrap()
    }

    fn wait_for_change(&self, prev: u64, _timeout: Duration) -> bool {
        self.log.record("wait_for_change");
        // The fake is fully synchronous: by the time capture() calls this,
        // a landed FakeKeyboard::send_copy() has already bumped the count.
        self.change_count() != prev
    }
}

enum KeyboardAction {
    Fail,
    Succeed,
    SucceedAndWrite {
        clipboard: Arc<FakeClipboard>,
        text: String,
    },
}

/// The `send_paste` half of a `FakeKeyboard`, kept separate from
/// `KeyboardAction` since replace-back (spec-04) only ever needs paste to
/// fail or succeed as a no-op — never the "lands external text" variant
/// `send_copy` needs for the capture fallback.
enum PasteAction {
    Fail,
    Succeed,
}

/// In-memory `Keyboard` fake. Configurable to fail, succeed as a no-op, or
/// succeed while "landing" a copy by mutating a paired `FakeClipboard`;
/// `send_paste` independently succeeds unless configured to fail via
/// [`FakeKeyboard::failing_paste`].
pub struct FakeKeyboard {
    log: CallLog,
    action: KeyboardAction,
    paste_action: PasteAction,
}

impl FakeKeyboard {
    pub fn failing(log: CallLog) -> Self {
        Self {
            log,
            action: KeyboardAction::Fail,
            paste_action: PasteAction::Succeed,
        }
    }

    pub fn succeeding(log: CallLog) -> Self {
        Self {
            log,
            action: KeyboardAction::Succeed,
            paste_action: PasteAction::Succeed,
        }
    }

    /// Succeeds and, as a side effect (mirroring a real app reacting to
    /// ⌘C), writes `text` to `clipboard`.
    pub fn succeeding_with_copy(
        log: CallLog,
        clipboard: Arc<FakeClipboard>,
        text: impl Into<String>,
    ) -> Self {
        Self {
            log,
            action: KeyboardAction::SucceedAndWrite {
                clipboard,
                text: text.into(),
            },
            paste_action: PasteAction::Succeed,
        }
    }

    /// Succeeds at `send_copy` but fails `send_paste` (replace-back's paste
    /// failure path).
    pub fn failing_paste(log: CallLog) -> Self {
        Self {
            log,
            action: KeyboardAction::Succeed,
            paste_action: PasteAction::Fail,
        }
    }
}

impl Keyboard for FakeKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        self.log.record("send_copy");
        match &self.action {
            KeyboardAction::Fail => Err("synthetic copy failed".to_string()),
            KeyboardAction::Succeed => Ok(()),
            KeyboardAction::SucceedAndWrite { clipboard, text } => {
                clipboard.set_external_text(text.clone());
                Ok(())
            }
        }
    }

    fn send_paste(&self) -> Result<(), String> {
        self.log.record("send_paste");
        match self.paste_action {
            PasteAction::Fail => Err("synthetic paste failed".to_string()),
            PasteAction::Succeed => Ok(()),
        }
    }
}
