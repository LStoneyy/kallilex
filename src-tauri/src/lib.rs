//! Kallilex application entry point: builds the Tauri app, wires the tray
//! icon, popover/settings windows, and registers plugins/commands.

mod commands;
mod core;
mod platform;

use std::str::FromStr;
use std::sync::Mutex;

use tauri::menu::{AboutMetadataBuilder, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{ActivationPolicy, Emitter, Manager, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_positioner::{Position, WindowExt};

use crate::core::capture::CaptureResult;
use crate::core::clipboard::BackupLifecycle;
use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::core::{POPOVER_WINDOW_LABEL, SETTINGS_WINDOW_LABEL};

const SETTINGS_MENU_ID: &str = "settings";
const QUIT_MENU_ID: &str = "quit";

/// Holds the most recent capture result: stored by the global-shortcut
/// trigger flow, read (without clearing) by the `capture_selection` command,
/// and cleared on cancel (`cancel_capture`) or when the popover is hidden.
#[derive(Default)]
pub(crate) struct CaptureState(pub(crate) Mutex<Option<CaptureResult>>);

/// True while a replace-back is writing into the source app. Checked by the
/// global-shortcut trigger so a capture can never run concurrently with an
/// in-flight replace: activating the source app during replace hides the
/// popover, which defeats `trigger_capture`'s usual "popover already
/// visible" guard, but a concurrent capture would still share the
/// clipboard, keyboard, and `BackupLifecycle` with the still-running
/// replace and could corrupt the clipboard (backing up the in-flight result
/// text as if it were the user's original).
#[derive(Default)]
pub(crate) struct ReplaceInFlight(pub(crate) std::sync::atomic::AtomicBool);

/// Shows the popover window under the tray icon, positions it, and gives it
/// keyboard focus.
fn show_popover(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) else {
        return;
    };
    let _ = window.move_window(Position::TrayBottomCenter);
    let _ = window.show();
    let _ = window.set_focus();
}

/// Hides the popover and cancels any in-flight capture: a pending clipboard
/// backup (from the fallback path) is restored immediately, and the stored
/// capture result is cleared. Safe to call whether or not a capture is
/// currently pending — both operations are no-ops in that case.
pub(crate) fn hide_popover(app: &tauri::AppHandle) {
    cancel_capture(app);
    if let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        let _ = window.hide();
    }
}

fn toggle_popover(app: &tauri::AppHandle) {
    match app.get_webview_window(POPOVER_WINDOW_LABEL) {
        Some(window) if window.is_visible().unwrap_or(false) => hide_popover(app),
        _ => show_popover(app),
    }
}

fn show_settings(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window(SETTINGS_WINDOW_LABEL) {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Restores any pending clipboard backup and clears the stored capture
/// result. Called on cancel (Escape / focus loss / closing without an
/// action, all of which route through [`hide_popover`]).
pub(crate) fn cancel_capture(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let lifecycle = app.state::<BackupLifecycle>();
        let clipboard = crate::platform::MacosClipboard;
        lifecycle.restore_pending(&clipboard);
    }

    if let Some(state) = app.try_state::<CaptureState>() {
        let mut captured = state
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *captured = None;
    }
}

/// Runs the capture flow (Accessibility primary path -> clipboard fallback)
/// and stores the result, then marshals only the UI tail — showing the
/// popover and notifying it that a fresh capture is ready — onto the main
/// thread.
///
/// Capture itself deliberately does *not* run on the main thread: the
/// fallback path can block for up to `FALLBACK_SETTLE_TIMEOUT` waiting for
/// the synthetic ⌘C to land, and the global-shortcut handler already runs
/// off the main thread, so running capture there keeps that wait off the
/// main thread too. The AppKit/CoreGraphics/Accessibility calls capture
/// makes are not main-thread-affine. `show_popover` and the `capture:done`
/// emit, which touch window focus, must still run on the main thread — and
/// only after capture has fully completed, so the popover never shows stale
/// or partial state.
///
/// If the popover is already visible — a re-press of the shortcut while
/// Kallilex is already frontmost — capture is skipped entirely: it must not
/// capture from Kallilex itself or clear the user's in-progress edits. The
/// popover is simply left shown, and no `capture:done` is emitted.
fn trigger_capture(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
        if window.is_visible().unwrap_or(false) {
            return;
        }
    }

    // A replace-back may currently have the popover hidden (it activates the
    // source app, stealing focus) while it's still mid-flight — see
    // `ReplaceInFlight`'s doc comment. Treat that exactly like the
    // popover-visible case above: do nothing.
    if let Some(state) = app.try_state::<ReplaceInFlight>() {
        if state.0.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
    }

    #[cfg(target_os = "macos")]
    {
        use crate::core::capture;
        use crate::platform::{MacosClipboard, MacosKeyboard, MacosSelectionBackend};

        let backend = MacosSelectionBackend;
        let clipboard = MacosClipboard;
        let keyboard = MacosKeyboard;
        let lifecycle = app.state::<BackupLifecycle>();

        let result = capture::capture(&backend, &clipboard, &keyboard, &lifecycle);
        if let Some(state) = app.try_state::<CaptureState>() {
            let mut captured = state
                .0
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *captured = Some(result);
        }
    }

    let app_handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        show_popover(&app_handle);

        if let Some(window) = app_handle.get_webview_window(POPOVER_WINDOW_LABEL) {
            let _ = window.emit("capture:done", ());
        }
    });
}

/// Shows a non-fatal error dialog. Used for shortcut parse/registration
/// failures, and for replace-back errors that occur after the popover has
/// already been hidden, so they never fail silently.
pub(crate) fn show_error_dialog(app: &tauri::AppHandle, message: impl Into<String>) {
    app.dialog()
        .message(message.into())
        .title("Kallilex")
        .kind(MessageDialogKind::Error)
        .show(|_| {});
}

/// Loads the persisted shortcut, falling back to the default (and warning
/// the user) if it fails to parse.
fn resolve_shortcut(app: &tauri::AppHandle, settings: &Settings) -> Shortcut {
    match Shortcut::from_str(&settings.shortcut) {
        Ok(shortcut) => shortcut,
        Err(_) => {
            show_error_dialog(
                app,
                format!(
                    "Kallilex couldn't understand the saved shortcut \"{}\" and will use the default ⌥⌘K instead.",
                    settings.shortcut
                ),
            );
            Shortcut::from_str(&Settings::default().shortcut)
                .expect("the default shortcut string must always parse")
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // A second launch focuses the already-running instance's popover
            // instead of starting a new process.
            show_popover(app);
        }))
        .plugin(tauri_plugin_positioner::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        // Runs on the shortcut handler's own (non-main)
                        // thread: capture's blocking fallback wait must not
                        // stall the main thread. `trigger_capture` marshals
                        // only its UI tail (show_popover + capture:done)
                        // onto the main thread itself.
                        trigger_capture(app);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::set_settings,
            commands::hide_popover,
            commands::capture_selection,
            commands::accessibility_status,
            commands::open_accessibility_settings,
            commands::spellcheck,
            commands::replace_back,
            commands::copy_result,
        ])
        .setup(|app| {
            // Menu-bar-only app: no Dock icon, no app switcher entry.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(ActivationPolicy::Accessory);

            app.manage(CaptureState::default());
            app.manage(BackupLifecycle::new());
            app.manage(ReplaceInFlight::default());

            let settings_store = TauriStoreSettings::new(app.handle().clone());
            let current_settings = settings::get_settings(&settings_store).unwrap_or_default();

            let shortcut = resolve_shortcut(app.handle(), &current_settings);
            if let Err(err) = app.global_shortcut().register(shortcut) {
                show_error_dialog(
                    app.handle(),
                    format!(
                        "Kallilex couldn't register the global shortcut ({err}). \
                         You can still open Kallilex from the tray icon."
                    ),
                );
            }

            // First-run Accessibility onboarding: if permission is missing
            // and we haven't shown the panel before, open Settings once.
            #[cfg(target_os = "macos")]
            {
                use crate::core::capture::SelectionBackend;

                let permission_granted = crate::platform::MacosSelectionBackend.permission_granted();
                if !permission_granted && !current_settings.accessibility_onboarding_shown {
                    show_settings(app.handle());
                    let updated_settings = Settings {
                        accessibility_onboarding_shown: true,
                        ..current_settings.clone()
                    };
                    let _ = settings::set_settings(&settings_store, updated_settings);
                }
            }

            let settings_item =
                MenuItem::with_id(app, SETTINGS_MENU_ID, "Settings", true, None::<&str>)?;
            let about_metadata = AboutMetadataBuilder::new()
                .name(Some("Kallilex"))
                .version(Some(app.package_info().version.to_string()))
                .license(Some("Apache-2.0"))
                .icon(app.default_window_icon().cloned())
                .build();
            let about_item = PredefinedMenuItem::about(app, Some("About Kallilex"), Some(about_metadata))?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit_item = MenuItem::with_id(app, QUIT_MENU_ID, "Quit", true, None::<&str>)?;

            let tray_menu = Menu::with_items(app, &[&settings_item, &about_item, &separator, &quit_item])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().cloned().expect("default window icon"))
                .menu(&tray_menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    SETTINGS_MENU_ID => show_settings(app),
                    QUIT_MENU_ID => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    let app = tray.app_handle();
                    tauri_plugin_positioner::on_tray_event(app, &event);

                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_popover(app);
                    }
                })
                .build(app)?;

            if let Some(popover) = app.get_webview_window(POPOVER_WINDOW_LABEL) {
                popover.on_window_event({
                    let app_handle = app.handle().clone();
                    move |event| {
                        if let WindowEvent::Focused(false) = event {
                            hide_popover(&app_handle);
                        }
                    }
                });
            }

            // The settings window is a reusable shell: closing it (red traffic
            // light) should hide it, not destroy it, so it can be shown again
            // from the tray menu without recreating the webview.
            if let Some(settings) = app.get_webview_window(SETTINGS_WINDOW_LABEL) {
                let settings_handle = settings.clone();
                settings.on_window_event(move |event| {
                    if let WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = settings_handle.hide();
                    }
                });
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
