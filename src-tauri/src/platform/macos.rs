//! macOS-backed implementations of the `core` seams: Accessibility API
//! selection reading, `NSPasteboard` clipboard access, and a synthetic ⌘C
//! via `CGEvent`.

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
    NSPasteboard, NSPasteboardItem, NSPasteboardTypeString, NSPasteboardWriting, NSWorkspace,
};
use objc2_foundation::{NSArray, NSData, NSString};

use crate::core::capture::{SelectionBackend, SourceApp};
use crate::core::clipboard::{Clipboard, ClipboardBackup, ClipboardItem, Keyboard};

/// `kVK_ANSI_C`, the physical keycode for the "C" key regardless of
/// keyboard layout — what a real ⌘C keystroke sends.
const KEYCODE_C: u16 = 8;

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
            pid: app.processIdentifier() as i32,
            name: app.localizedName().map(|s| s.to_string()),
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

/// Synthesizes ⌘C via `CGEvent`, posted to the HID event tap.
pub struct MacosKeyboard;

impl Keyboard for MacosKeyboard {
    fn send_copy(&self) -> Result<(), String> {
        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|_| "failed to create a CGEventSource".to_string())?;

        let key_down = CGEvent::new_keyboard_event(source.clone(), KEYCODE_C, true)
            .map_err(|_| "failed to create the key-down event".to_string())?;
        key_down.set_flags(CGEventFlags::CGEventFlagCommand);

        let key_up = CGEvent::new_keyboard_event(source, KEYCODE_C, false)
            .map_err(|_| "failed to create the key-up event".to_string())?;
        key_up.set_flags(CGEventFlags::CGEventFlagCommand);

        key_down.post(CGEventTapLocation::HID);
        key_up.post(CGEventTapLocation::HID);
        Ok(())
    }
}

/// Opens System Settings directly at Privacy & Security -> Accessibility.
pub fn open_accessibility_settings() -> Result<(), String> {
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
