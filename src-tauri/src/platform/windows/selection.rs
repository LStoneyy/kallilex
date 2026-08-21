//! Windows selection reading (spec-15 Slice B): UI Automation
//! (`IUIAutomation` + `TextPattern`) for instant selection text, and
//! `GetForegroundWindow` + `GetWindowThreadProcessId` +
//! `QueryFullProcessImageNameW` for frontmost-app identity.

use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use windows::core::{Interface, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND, RPC_E_CHANGED_MODE};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationTextPattern, UIA_TextPatternId,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
};

use crate::core::capture::{PlatformWindowId, SelectionBackend, SourceApp};

/// Bound on the UI Automation worker thread's round trip. UIA calls cross
/// process boundaries (they're serviced by the target application, via COM)
/// and can therefore block indefinitely against an unresponsive target;
/// without this bound, one wedged app could hang every future capture
/// attempt. 400ms is long enough for a healthy app's UIA server to respond,
/// short enough that the clipboard + synthetic-Ctrl+C fallback this timeout
/// falls through to still feels instant. A timeout is `None` (fall through
/// to the fallback), not an error — this mirrors how `MacosSpellChecker::
/// check` and `MacosAppActivator::activate` bound their own main-thread
/// round trips with `mpsc::recv_timeout`, except here the direction is
/// reversed: the calling thread marshals work *off* to a worker rather than
/// *onto* AppKit's main thread.
const UIA_TIMEOUT: Duration = Duration::from_millis(400);

/// Selection capture via UI Automation and the foreground window. Unlike
/// macOS's Accessibility-permission model, Windows has no grantable capture
/// permission at all — `permission_granted` always returning `true` is the
/// *final* contract, not a placeholder.
pub struct WindowsSelectionBackend;

impl SelectionBackend for WindowsSelectionBackend {
    fn permission_granted(&self) -> bool {
        true
    }

    fn frontmost_app(&self) -> Option<SourceApp> {
        frontmost_app()
    }

    /// Reads the focused UI element's selected text via `TextPattern`,
    /// bounded by [`UIA_TIMEOUT`]. `None` (whether from an absent pattern, an
    /// empty selection, or a timeout) is exactly what makes `core::capture`
    /// fall through to the clipboard + synthetic-Ctrl+C path.
    ///
    /// UIPI note: against a target running at a higher integrity level,
    /// `GetFocusedElement` returns nothing this process can use, so this
    /// returns `None` here too — and the clipboard fallback then also fails,
    /// because `SendInput` is silently dropped by the OS for the same
    /// reason. The net effect is `CaptureFailureReason::NoSelection`
    /// surfacing through the existing popover UI; no new UI is needed for
    /// this case.
    fn ax_selected_text(&self) -> Option<String> {
        ax_selected_text()
    }
}

/// Reads the frontmost application's identity via `GetForegroundWindow` and
/// friends. Returns `None` when there is no foreground window; a missing pid
/// or name is not fatal — a bare `HWND` is still a usable `SourceApp` (the
/// same contract the X11 implementation documents), since `window` is what
/// replace-back actually needs.
fn frontmost_app() -> Option<SourceApp> {
    // SAFETY: `GetForegroundWindow` takes no arguments and has no
    // preconditions; it returns a null `HWND` (not an error) when there is
    // no foreground window.
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }

    let mut pid = 0u32;
    // SAFETY: `hwnd` was just obtained from `GetForegroundWindow` and is
    // live for the duration of this call; `pid` is a valid out-param.
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };

    let name = process_display_name(pid).or_else(|| window_title(hwnd));

    Some(SourceApp {
        bundle_id: None,
        pid: pid as i32,
        name,
        window: Some(PlatformWindowId(hwnd.0 as usize as u64)),
    })
}

/// Resolves a process's display name from its full image path
/// (`QueryFullProcessImageNameW`). `None` on any failure along the way
/// (invalid pid, `OpenProcess` denied — e.g. an elevated process — or the
/// query itself failing), which callers treat as "fall back to the window
/// title", not as an error.
fn process_display_name(pid: u32) -> Option<String> {
    if pid == 0 {
        return None;
    }

    // SAFETY: `pid` is a plain process id; `OpenProcess` returns an `Err`
    // (rather than an invalid handle) on failure, which the `?` below
    // propagates as `None`.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;

    let mut buf = [0u16; 1024];
    let mut size = buf.len() as u32;
    // SAFETY: `handle` is a live, just-opened process handle; `buf` and
    // `size` are valid in/out buffers for the duration of this call.
    let result = unsafe {
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut size,
        )
    };

    // SAFETY: `handle` was returned by the `OpenProcess` call above and is
    // not used again after this point.
    let _ = unsafe { CloseHandle(handle) };

    result.ok()?;
    let path = String::from_utf16_lossy(&buf[..size as usize]);
    process_name_from_image_path(&path)
}

/// Derives a process's display name from its full image path (e.g.
/// `C:\Windows\notepad.exe` -> `notepad`): the file name with its directory
/// and extension stripped. Pure so it can be unit tested without an actual
/// process handle. Handles both backslash (native Windows) and forward-slash
/// separators, and only strips the *last* dot-delimited segment, so a name
/// with several dots (`Code - Insiders.exe`) or none at all (`explorer`) both
/// come out right. `None` for an empty path (nothing to derive a name from).
fn process_name_from_image_path(path: &str) -> Option<String> {
    let file_name = path.rsplit(['\\', '/']).next().unwrap_or(path);
    if file_name.is_empty() {
        return None;
    }

    let stem = match file_name.rfind('.') {
        // A dot at position 0 (a dotfile-style name) isn't a real
        // extension; keep the whole name in that case.
        Some(dot) if dot > 0 => &file_name[..dot],
        _ => file_name,
    };

    if stem.is_empty() {
        None
    } else {
        Some(stem.to_string())
    }
}

/// Falls back to the window title (`GetWindowTextW`) when the process image
/// name is unavailable — e.g. `OpenProcess` denied against an elevated
/// process. `None` if the window has no title either.
fn window_title(hwnd: HWND) -> Option<String> {
    // SAFETY: `hwnd` is a live window handle for the duration of this call.
    let len = unsafe { GetWindowTextLengthW(hwnd) };
    if len <= 0 {
        return None;
    }

    let mut buf = vec![0u16; len as usize + 1];
    // SAFETY: `hwnd` is live; `buf` is a valid, appropriately-sized output
    // buffer (the +1 above accounts for the trailing NUL `GetWindowTextW`
    // writes).
    let copied = unsafe { GetWindowTextW(hwnd, &mut buf) };
    if copied <= 0 {
        return None;
    }

    let title = String::from_utf16_lossy(&buf[..copied as usize]);
    if title.is_empty() {
        None
    } else {
        Some(title)
    }
}

/// Reads the focused element's selected text via UI Automation, bounded by
/// [`UIA_TIMEOUT`]. Runs on a **fresh worker thread per call**, rather than a
/// long-lived worker, so a UIA call wedged against an unresponsive target can
/// never poison later captures: the calling thread simply stops waiting at
/// the timeout, and the abandoned worker thread quietly finishes (or never
/// does) on its own, with no shared state for it to corrupt.
fn ax_selected_text() -> Option<String> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        // The receiver may already be gone if `recv_timeout` below gave up
        // first; that's fine, there's nothing left to do.
        let _ = tx.send(ax_selected_text_on_worker());
    });

    rx.recv_timeout(UIA_TIMEOUT).ok().flatten()
}

/// Runs the actual UI Automation work. Must only ever be called from the
/// dedicated worker thread [`ax_selected_text`] spawns: it owns COM
/// interface pointers created here for the duration of this call, and those
/// pointers are never sent across threads — only the resulting
/// `Option<String>` is.
fn ax_selected_text_on_worker() -> Option<String> {
    // SAFETY: called only from a freshly spawned worker thread that has not
    // previously touched COM, so `COINIT_MULTITHREADED` unconditionally
    // applies for the lifetime of that thread.
    let init_hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };

    // `HRESULT::is_ok()` is `self.0 >= 0`, which already covers both `S_OK`
    // (fresh init on this thread, incrementing a COM usage count) and
    // `S_FALSE` (already initialized on this thread by something else,
    // which still increments a usage count) — both must be balanced with
    // `CoUninitialize` below. `RPC_E_CHANGED_MODE` means COM was already
    // initialized on this thread in an incompatible apartment mode by
    // something else — practically never on a thread we just spawned, but
    // tolerated defensively; it does not own a usage count to release, so it
    // must not call `CoUninitialize`. Any other failure means COM isn't
    // usable on this thread at all.
    let owns_com = init_hr.is_ok();
    if !owns_com && init_hr != RPC_E_CHANGED_MODE {
        return None;
    }

    let text = read_selected_text();

    if owns_com {
        // SAFETY: balances the successful `CoInitializeEx` call above, and
        // is only reached when that call actually owns a usage count.
        unsafe { CoUninitialize() };
    }

    text
}

/// The actual `IUIAutomation` -> focused element -> `TextPattern` ->
/// selection -> text walk. `TextPattern` only — no `ValuePattern` or legacy
/// `IAccessible` fallback (spec-15 Out of Scope). Empty or absent at any
/// step is `None`.
fn read_selected_text() -> Option<String> {
    // SAFETY: `CUIAutomation` is a standard, documented in-process COM
    // server; COM was just initialized (or already usable) on this thread.
    let automation: IUIAutomation =
        unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }.ok()?;

    // SAFETY: `automation` is a valid, live COM object for the duration of
    // this call.
    let focused = unsafe { automation.GetFocusedElement() }.ok()?;

    // SAFETY: `focused` is a valid, live COM object for the duration of this
    // call.
    let pattern_unknown = unsafe { focused.GetCurrentPattern(UIA_TextPatternId) }.ok()?;
    let text_pattern: IUIAutomationTextPattern = pattern_unknown.cast().ok()?;

    // SAFETY: `text_pattern` is a valid, live COM object for the duration of
    // this call.
    let selection = unsafe { text_pattern.GetSelection() }.ok()?;

    // SAFETY: `selection` is a valid, live COM object for the duration of
    // this call.
    let length = unsafe { selection.Length() }.ok()?;
    if length <= 0 {
        return None;
    }

    // SAFETY: index 0 is valid — `Length()` above just confirmed at least
    // one range is present.
    let range = unsafe { selection.GetElement(0) }.ok()?;

    // SAFETY: `range` is a valid, live COM object for the duration of this
    // call; `-1` requests the range's full text with no truncation.
    let text = unsafe { range.GetText(-1) }.ok()?.to_string();

    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_name_from_image_path_strips_directory_and_extension() {
        assert_eq!(
            process_name_from_image_path(r"C:\Windows\notepad.exe"),
            Some("notepad".to_string())
        );
    }

    #[test]
    fn process_name_from_image_path_handles_forward_slashes() {
        assert_eq!(
            process_name_from_image_path("C:/Program Files/App/thing.exe"),
            Some("thing".to_string())
        );
    }

    #[test]
    fn process_name_from_image_path_handles_no_extension() {
        assert_eq!(
            process_name_from_image_path(r"C:\Windows\explorer"),
            Some("explorer".to_string())
        );
    }

    #[test]
    fn process_name_from_image_path_keeps_multiple_dots() {
        assert_eq!(
            process_name_from_image_path(r"C:\Program Files\Code - Insiders\Code - Insiders.exe"),
            Some("Code - Insiders".to_string())
        );
    }

    #[test]
    fn process_name_from_image_path_returns_none_for_empty() {
        assert_eq!(process_name_from_image_path(""), None);
    }

    #[test]
    fn process_name_from_image_path_returns_none_for_trailing_separator() {
        assert_eq!(process_name_from_image_path(r"C:\Windows\"), None);
    }

    #[test]
    fn process_name_from_image_path_keeps_dotfile_style_name() {
        assert_eq!(
            process_name_from_image_path(r"C:\Users\x\.hidden"),
            Some(".hidden".to_string())
        );
    }

    #[test]
    fn process_name_from_image_path_handles_unicode_name() {
        assert_eq!(
            process_name_from_image_path(r"C:\Apps\café.exe"),
            Some("café".to_string())
        );
    }
}
