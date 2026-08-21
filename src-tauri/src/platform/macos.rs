//! macOS-backed implementations of the `core` seams: Accessibility API
//! selection reading, `NSPasteboard` clipboard access, and a synthetic ⌘C
//! via `CGEvent`.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use accessibility_sys::{
    kAXErrorSuccess, kAXFocusedUIElementAttribute, kAXSelectedTextAttribute, AXIsProcessTrusted,
    AXUIElementCopyAttributeValue, AXUIElementCreateSystemWide, AXUIElementRef,
};
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_app_kit::{
    NSApplicationActivationOptions, NSPasteboard, NSPasteboardItem, NSPasteboardTypeString,
    NSPasteboardWriting, NSRunningApplication, NSSpellChecker, NSWorkspace,
};
use objc2_foundation::{NSArray, NSData, NSOrthography, NSRange, NSString, NSTextCheckingType};
use tauri::AppHandle;

use crate::core::capture::{SelectionBackend, SourceApp};
use crate::core::clipboard::{Clipboard, ClipboardBackup, ClipboardItem, Keyboard};
use crate::core::replace::AppActivator;
use crate::core::spellcheck::{Misspelling, SpellChecker, SpellcheckError, SpellcheckResult};

/// `kVK_ANSI_C`, the physical keycode for the "C" key regardless of
/// keyboard layout — what a real ⌘C keystroke sends.
const KEYCODE_C: u16 = 8;

/// `kVK_ANSI_V`, the physical keycode for the "V" key regardless of
/// keyboard layout — what a real ⌘V keystroke sends.
const KEYCODE_V: u16 = 9;

/// How often to poll the pasteboard's change count while waiting for the
/// synthetic copy to land.
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Wraps a raw, owned Core Foundation reference (obtained from a Copy/Create
/// rule API) so it is released via `CFType`'s `Drop` impl instead of being
/// leaked.
fn own(ptr: CFTypeRef) -> Option<CFType> {
    if ptr.is_null() {
        None
    } else {
        // SAFETY: callers only pass pointers returned by AX "Copy" APIs,
        // which hand over a +1 reference that we now own.
        Some(unsafe { CFType::wrap_under_create_rule(ptr) })
    }
}

/// Copies `attribute` off `element` via the Accessibility API. Returns
/// `None` on any AX failure (unsupported attribute, no value, etc.).
fn copy_ax_attribute(element: AXUIElementRef, attribute: &str) -> Option<CFType> {
    let attribute = CFString::new(attribute);
    let mut value: CFTypeRef = std::ptr::null();
    // SAFETY: `element` is a valid AXUIElementRef for the duration of this
    // call (owned by the caller for at least that long); `value` is an
    // out-param the AX API fills in.
    let result = unsafe {
        AXUIElementCopyAttributeValue(element, attribute.as_concrete_TypeRef(), &mut value)
    };
    if result != kAXErrorSuccess {
        return None;
    }
    own(value)
}

/// Selection capture via the macOS Accessibility API.
pub struct MacosSelectionBackend;

impl SelectionBackend for MacosSelectionBackend {
    fn permission_granted(&self) -> bool {
        // SAFETY: `AXIsProcessTrusted` takes no arguments and has no
        // preconditions.
        unsafe { AXIsProcessTrusted() }
    }

    fn frontmost_app(&self) -> Option<SourceApp> {
        let workspace = NSWorkspace::sharedWorkspace();
        let app = workspace.frontmostApplication()?;
        Some(SourceApp {
            bundle_id: app.bundleIdentifier().map(|s| s.to_string()),
            pid: app.processIdentifier(),
            name: app.localizedName().map(|s| s.to_string()),
            window: None,
        })
    }

    fn ax_selected_text(&self) -> Option<String> {
        // SAFETY: `AXUIElementCreateSystemWide` returns a new, owned
        // reference to the well-known system-wide accessibility element.
        let system_wide_ref = unsafe { AXUIElementCreateSystemWide() };
        let system_wide = own(system_wide_ref as CFTypeRef)?;
        let system_wide_element = system_wide.as_concrete_TypeRef() as AXUIElementRef;

        let focused = copy_ax_attribute(system_wide_element, kAXFocusedUIElementAttribute)?;
        let focused_element = focused.as_concrete_TypeRef() as AXUIElementRef;

        let selected_text = copy_ax_attribute(focused_element, kAXSelectedTextAttribute)?;
        let text_ref = selected_text.as_concrete_TypeRef() as CFStringRef;
        // SAFETY: `AXSelectedText` is documented to be a CFString; this
        // borrows the reference already owned by `selected_text` (which
        // stays alive until the end of this function), so no extra release
        // is needed beyond `selected_text`'s own `Drop`.
        let text = unsafe { CFString::wrap_under_get_rule(text_ref) };
        Some(text.to_string())
    }
}

/// Clipboard access via `NSPasteboard.generalPasteboard()`.
pub struct MacosClipboard;

impl Clipboard for MacosClipboard {
    fn read_text(&self) -> Option<String> {
        let pasteboard = NSPasteboard::generalPasteboard();
        // SAFETY: reading an `extern "C"` static string constant defined by
        // AppKit; it is initialized before any Objective-C code runs.
        let string_type = unsafe { NSPasteboardTypeString };
        pasteboard.stringForType(string_type).map(|s| s.to_string())
    }

    fn write_text(&self, text: &str) {
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.clearContents();
        // SAFETY: reading an `extern "C"` static string constant defined by
        // AppKit; it is initialized before any Objective-C code runs.
        let string_type = unsafe { NSPasteboardTypeString };
        pasteboard.setString_forType(&NSString::from_str(text), string_type);
    }

    fn backup(&self) -> ClipboardBackup {
        let pasteboard = NSPasteboard::generalPasteboard();
        let Some(items) = pasteboard.pasteboardItems() else {
            return ClipboardBackup::default();
        };

        let mut backed_up = Vec::new();
        for item in items.iter() {
            let mut formats = Vec::new();
            for pasteboard_type in item.types().iter() {
                // Best-effort: skip any type whose data can't be read.
                if let Some(data) = item.dataForType(&pasteboard_type) {
                    formats.push((pasteboard_type.to_string(), data.to_vec()));
                }
            }
            backed_up.push(ClipboardItem { formats });
        }
        ClipboardBackup(backed_up)
    }

    fn restore(&self, backup: &ClipboardBackup) {
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.clearContents();

        if backup.0.is_empty() {
            return;
        }

        let items: Vec<Retained<NSPasteboardItem>> = backup
            .0
            .iter()
            .map(|item| {
                let ns_item = NSPasteboardItem::new();
                for (format, bytes) in &item.formats {
                    let ns_type = NSString::from_str(format);
                    let ns_data = NSData::from_vec(bytes.clone());
                    ns_item.setData_forType(&ns_data, &ns_type);
                }
                ns_item
            })
            .collect();

        let writers: Vec<&ProtocolObject<dyn NSPasteboardWriting>> = items
            .iter()
            .map(|item| ProtocolObject::from_ref::<NSPasteboardItem>(item))
            .collect();
        let array = NSArray::from_slice(&writers);
        pasteboard.writeObjects(&array);
    }

    fn change_count(&self) -> u64 {
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.changeCount() as u64
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

/// Synthesizes a ⌘+`keycode` chord via `CGEvent`, posted to the HID event
/// tap. Shared by `send_copy` (⌘C) and `send_paste` (⌘V).
fn send_cmd_key(keycode: u16) -> Result<(), String> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "failed to create a CGEventSource".to_string())?;

    let key_down = CGEvent::new_keyboard_event(source.clone(), keycode, true)
        .map_err(|_| "failed to create the key-down event".to_string())?;
    key_down.set_flags(CGEventFlags::CGEventFlagCommand);

    let key_up = CGEvent::new_keyboard_event(source, keycode, false)
        .map_err(|_| "failed to create the key-up event".to_string())?;
    key_up.set_flags(CGEventFlags::CGEventFlagCommand);

    key_down.post(CGEventTapLocation::HID);
    key_up.post(CGEventTapLocation::HID);
    Ok(())
}

/// Synthesizes ⌘C/⌘V via `CGEvent`, posted to the HID event tap.
pub struct MacosKeyboard;

impl Keyboard for MacosKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        send_cmd_key(KEYCODE_C)
    }

    fn send_paste(&self) -> Result<(), String> {
        send_cmd_key(KEYCODE_V)
    }
}

/// How long to wait for a spell check marshalled onto the main thread to
/// complete before giving up. `NSSpellChecker` is fast (in-process, local
/// dictionaries), so a real timeout here only ever fires if the main thread
/// itself is wedged.
const SPELLCHECK_TIMEOUT: Duration = Duration::from_secs(5);

/// Spell checking via the shared `NSSpellChecker`. All AppKit calls are
/// marshalled onto the main thread (`NSSpellChecker` is not `Send`): `check`
/// blocks the calling thread on a channel while `app.run_on_main_thread`
/// does the actual work.
pub struct MacosSpellChecker {
    app: AppHandle,
}

impl MacosSpellChecker {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl SpellChecker for MacosSpellChecker {
    fn check(&self, text: &str) -> Result<SpellcheckResult, SpellcheckError> {
        let (tx, rx) = mpsc::channel();
        let owned_text = text.to_string();

        self.app
            .run_on_main_thread(move || {
                let result = check_on_main_thread(&owned_text);
                // The receiver may already be gone if `recv_timeout` below
                // gave up first; that's fine, there's nothing left to do.
                let _ = tx.send(result);
            })
            .map_err(|e| {
                SpellcheckError::Backend(format!("failed to schedule on the main thread: {e}"))
            })?;

        rx.recv_timeout(SPELLCHECK_TIMEOUT)
            .map_err(|_| SpellcheckError::Backend("spell check timed out".to_string()))
    }
}

/// Runs the actual `NSSpellChecker` work. Must only ever be called from the
/// main thread — every AppKit object created here is main-thread-affine.
///
/// Two passes, in order:
///
/// 1. The unified `checkString:...:orthography:` API, with no forced
///    language: the shared checker already honors the user's system
///    language preferences (multi-language auto identification), so we
///    never call `setAutomaticallyIdentifiesLanguages` ourselves. This is
///    the API that correctly flags misspellings once a dominant language is
///    identified (validated fixture: "Das ist ein kleinner Test" -> `de` ->
///    finds "kleinner").
/// 2. A fallback that only runs when pass 1's orthography couldn't
///    determine a language (`dominantLanguage` is absent or `"und"` —
///    undetermined). Short, linguistically ambiguous text triggers this: on
///    "und", the unified API silently flags nothing at all (validated
///    fixture: "Her is a smal test" -> `und` -> pass 1 finds nothing, the
///    fallback loop over `checkSpellingOfString:startingAt:language:...`
///    with the checker's currently selected language finds "smal"). This
///    is `NSSpellChecker`'s own behavior around orthography detection, not
///    a binding bug.
fn check_on_main_thread(text: &str) -> SpellcheckResult {
    let checker = NSSpellChecker::sharedSpellChecker();
    let ns_text = NSString::from_str(text);
    // NSSpellChecker's NSRange (like all AppKit/Foundation string APIs)
    // counts UTF-16 code units, so we index into a UTF-16 view of `text`
    // rather than its UTF-8 bytes or `char`s.
    let units: Vec<u16> = text.encode_utf16().collect();
    let total_length = units.len();

    // Pass 1: unified API, respects automatic multi-language identification.
    let mut orthography: Option<Retained<NSOrthography>> = None;
    // SAFETY: `ns_text` and the out-param `orthography` are both valid for
    // the duration of this call; `word_count` is intentionally null (we
    // don't need it).
    let results = unsafe {
        checker.checkString_range_types_options_inSpellDocumentWithTag_orthography_wordCount(
            &ns_text,
            NSRange::new(0, total_length),
            NSTextCheckingType::Spelling.0,
            None,
            0,
            Some(&mut orthography),
            std::ptr::null_mut(),
        )
    };
    let dominant = orthography
        .as_ref()
        .map(|o| o.dominantLanguage().to_string());
    let mut ranges: Vec<NSRange> = results.iter().map(|r| r.range()).collect();

    // Pass 2: only when pass 1 couldn't settle on a language at all — the
    // exact condition under which the unified API flags nothing.
    if matches!(dominant.as_deref(), None | Some("und")) {
        let language = checker.language();
        let mut cursor = 0usize;
        while cursor < total_length {
            // SAFETY: `ns_text` and `language` are valid for the call;
            // `word_count` is intentionally null.
            let range = unsafe {
                checker.checkSpellingOfString_startingAt_language_wrap_inSpellDocumentWithTag_wordCount(
                    &ns_text,
                    cursor as isize,
                    Some(&language),
                    false,
                    0,
                    std::ptr::null_mut(),
                )
            };
            if range.location >= total_length || range.length == 0 {
                break;
            }
            let already_found = ranges
                .iter()
                .any(|r| r.location == range.location && r.length == range.length);
            if !already_found {
                ranges.push(range);
            }
            cursor = range.location + range.length;
        }
    }

    ranges.sort_by_key(|r| r.location);

    let misspellings = ranges
        .into_iter()
        .filter_map(|range| {
            let start = range.location;
            let end = (start + range.length).min(total_length);
            if start >= total_length || end <= start {
                return None;
            }
            let word = String::from_utf16_lossy(&units[start..end]);

            let suggestions = checker
                .guessesForWordRange_inString_language_inSpellDocumentWithTag(
                    range, &ns_text, None, 0,
                )
                .map(|guesses| guesses.iter().map(|s| s.to_string()).collect())
                .unwrap_or_default();

            Some(Misspelling {
                start: start as u32,
                length: (end - start) as u32,
                word,
                suggestions,
            })
        })
        .collect();

    SpellcheckResult { misspellings }
}

/// How long to wait for an app activation marshalled onto the main thread
/// to complete before giving up. `NSRunningApplication` activation is fast
/// (in-process AppKit call), so a real timeout here only ever fires if the
/// main thread itself is wedged.
const ACTIVATE_TIMEOUT: Duration = Duration::from_secs(2);

/// Brings another application to the foreground via `NSRunningApplication`.
/// All AppKit calls are marshalled onto the main thread (`NSRunningApplication`
/// is not `Send`): `activate` blocks the calling thread on a channel while
/// `app.run_on_main_thread` does the actual work — the same pattern
/// `MacosSpellChecker::check` uses for `NSSpellChecker`.
pub struct MacosAppActivator {
    app: AppHandle,
}

impl MacosAppActivator {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

impl AppActivator for MacosAppActivator {
    fn activate(&self, app: &SourceApp) -> Result<(), String> {
        let pid = app.pid;
        let (tx, rx) = mpsc::channel();

        self.app
            .run_on_main_thread(move || {
                let result = activate_on_main_thread(pid);
                // The receiver may already be gone if `recv_timeout` below
                // gave up first; that's fine, there's nothing left to do.
                let _ = tx.send(result);
            })
            .map_err(|e| format!("failed to schedule activation on the main thread: {e}"))?;

        match rx.recv_timeout(ACTIVATE_TIMEOUT) {
            Ok(result) => result,
            Err(_) => Err("activating the source application timed out".to_string()),
        }
    }
}

/// Runs the actual `NSRunningApplication` activation. Must only ever be
/// called from the main thread — `NSRunningApplication` is main-thread-affine.
fn activate_on_main_thread(pid: i32) -> Result<(), String> {
    let Some(app) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid) else {
        return Err("the source application is no longer running".to_string());
    };

    // `ActivateIgnoringOtherApps` is deprecated in macOS 14+ (activation
    // options are being phased out in favor of finer-grained APIs) but
    // remains the correct, functioning choice here: replace-back needs the
    // source app brought forward regardless of what else is currently
    // active.
    #[allow(deprecated)]
    let activated =
        app.activateWithOptions(NSApplicationActivationOptions::ActivateIgnoringOtherApps);

    if activated {
        Ok(())
    } else {
        Err("failed to activate the source application".to_string())
    }
}

/// Opens System Settings directly at Privacy & Security -> Accessibility.
pub fn open_permission_settings() -> Result<(), String> {
    let status = std::process::Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .status()
        .map_err(|e| e.to_string())?;

    if status.success() {
        Ok(())
    } else {
        Err(format!("`open` exited with status {status}"))
    }
}

/// Constructs the macOS `SelectionBackend`: Accessibility API selection
/// reading.
pub fn selection_backend() -> MacosSelectionBackend {
    MacosSelectionBackend
}

/// Constructs the macOS `Clipboard`: `NSPasteboard.generalPasteboard()`.
pub fn clipboard() -> MacosClipboard {
    MacosClipboard
}

/// Constructs the macOS `Keyboard`: synthetic ⌘C/⌘V via `CGEvent`.
/// The `AppHandle` parameter exists only for signature parity with the
/// Linux constructor (spec-12 Slice C, where the Wayland path needs a
/// handle to reach its portal session manager) — `CGEvent` posting has no
/// main-thread affinity or app-handle dependency, so it's unused here.
pub fn keyboard(_app: AppHandle) -> MacosKeyboard {
    MacosKeyboard
}

/// Constructs the macOS `AppActivator`: `NSRunningApplication` activation by
/// pid.
pub fn app_activator(app: AppHandle) -> MacosAppActivator {
    MacosAppActivator::new(app)
}

/// Constructs the macOS `SpellChecker`: the shared `NSSpellChecker`.
pub fn spell_checker(app: AppHandle) -> MacosSpellChecker {
    MacosSpellChecker::new(app)
}

/// Menu-bar-only app: no Dock icon, no app switcher entry.
pub fn setup(app: &mut tauri::App) {
    app.set_activation_policy(tauri::ActivationPolicy::Accessory);
}

/// Positions the popover window under the tray icon.
pub fn position_popover(window: &tauri::WebviewWindow) {
    use tauri_plugin_positioner::{Position, WindowExt};

    let _ = window.move_window(Position::TrayBottomCenter);
}

/// macOS platform metadata: Accessibility is a grantable permission and
/// Replace (write-back into the source app) is available.
pub fn platform_info() -> crate::platform::PlatformInfo {
    crate::platform::PlatformInfo {
        os: "macos",
        session: None,
        replace_back_available: true,
        permission_required: true,
        default_shortcut: crate::core::settings::default_shortcut().to_string(),
        wayland: None,
    }
}

/// No-op: macOS's synthetic ⌘C/⌘V (via `CGEvent`, see `send_cmd_key`) needs
/// no grantable permission at all, so there is nothing on this platform for
/// the spec-13 Slice A opt-out to actually gate. The setting is still
/// persisted (cross-platform, in `Settings`) but never surfaced or
/// consulted here.
pub fn set_input_synthesis_enabled(_enabled: bool) {}

/// macOS's menu bar already reliably delivers tray left-clicks, so no extra
/// "Open Kallilex" menu entry is needed (spec-11 Slice B, Linux-only).
pub fn wants_tray_open_entry() -> bool {
    false
}

/// macOS always has a working Accessibility-backed synthetic-copy fallback,
/// so opening the popover never needs to eagerly trigger a capture
/// (spec-11 Slice B, Linux Wayland-only).
pub fn tray_open_captures() -> bool {
    false
}

/// macOS's global shortcut registration is expected to succeed (or fail for
/// a genuine, worth-reporting reason), unlike Linux Wayland's compositor-
/// dependent support (spec-11 Slice B, Linux-only).
pub fn global_shortcut_failure_expected() -> bool {
    false
}

/// The embedded tray-icon raster. Only the @2x raster is embedded:
/// tray-icon builds a single NSImage scaled to a fixed 18 pt height, so the
/// 44 px source downsamples crisply on both Retina and non-Retina displays.
/// icons/tray.png (@1x) stays committed as an artwork artifact.
pub fn tray_icon_bytes() -> &'static [u8] {
    include_bytes!("../../icons/tray@2x.png")
}

/// The black glyph is a template image: macOS recolors it to match the
/// menu bar (light and dark) automatically.
pub fn tray_icon_as_template() -> bool {
    true
}

/// Portals are a Linux/XDG-desktop-portal concept; macOS has no equivalent,
/// so the tauri global-shortcut plugin registration in `lib.rs` is always
/// used here.
pub fn use_portal_global_shortcut() -> bool {
    false
}

/// Never actually called: `use_portal_global_shortcut` always returns
/// `false` on macOS, so `lib.rs` never takes the portal-shortcut branch that
/// would call this. Kept as a no-op purely so the cross-platform seam
/// surface (`platform::spawn_portal_shortcut`) exists identically on both
/// platforms.
pub fn spawn_portal_shortcut(
    _app: tauri::AppHandle,
    _preferred_shortcut: String,
    _on_activated: fn(&tauri::AppHandle),
) {
}

/// `false`: macOS has no client-side-decoration toolkit, so the GTK
/// frame-extents workaround (see `lib.rs::resync_frame_extents`) does not
/// apply here.
pub fn needs_frame_extents_resync() -> bool {
    false
}
