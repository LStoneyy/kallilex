//! Kallilex application entry point: builds the Tauri app, wires the tray
//! icon, popover/settings windows, and registers plugins/commands.

mod commands;
mod core;
mod platform;

use std::str::FromStr;
use std::sync::Mutex;

use tauri::menu::{AboutMetadataBuilder, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Emitter, Manager, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

use crate::core::capture::CaptureResult;
use crate::core::clipboard::BackupLifecycle;
use crate::core::settings::{self, Settings, TauriStoreSettings};
use crate::core::{POPOVER_WINDOW_LABEL, SETTINGS_WINDOW_LABEL};

const OPEN_MENU_ID: &str = "open";
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

/// Cancel handle for the (at most one) in-flight AI action request
/// (spec-05's `run_action` command).
///
/// Only one action can be in flight at a time: starting a new one replaces
/// whatever `Sender` was previously stored here. Dropping a
/// `oneshot::Sender` fires its `Receiver`, so replacing the slot
/// automatically cancels the request that owned the old sender — the same
/// outcome an explicit `cancel_action` call produces by sending on it
/// directly.
///
/// Each stored sender is tagged with a generation counter so that when a
/// request finishes (cancelled or not), it only clears the slot if it
/// still holds *that* request's generation — i.e. no newer request has
/// since replaced it. Without this guard, an unconditional clear after
/// `select!` could race a newer request's `begin()` and erase its sender
/// out from under it, leaving that newer request permanently
/// uncancellable.
pub(crate) struct ActionInFlight {
    slot: Mutex<Option<(u64, tokio::sync::oneshot::Sender<()>)>>,
    next_generation: std::sync::atomic::AtomicU64,
}

impl ActionInFlight {
    pub(crate) fn new() -> Self {
        Self {
            slot: Mutex::new(None),
            next_generation: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// Registers a new in-flight request, implicitly cancelling any
    /// previous one (see the struct doc comment). Returns the receiver to
    /// race against in `tokio::select!` and the generation token to pass
    /// back to `clear`.
    pub(crate) fn begin(&self) -> (tokio::sync::oneshot::Receiver<()>, u64) {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let generation = self
            .next_generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let mut slot = self.slot.lock().unwrap_or_else(|p| p.into_inner());
        *slot = Some((generation, tx));
        (rx, generation)
    }

    /// Clears the slot after a request completes, but only if it still
    /// holds `generation` (see the struct doc comment).
    pub(crate) fn clear(&self, generation: u64) {
        let mut slot = self.slot.lock().unwrap_or_else(|p| p.into_inner());
        if matches!(&*slot, Some((g, _)) if *g == generation) {
            *slot = None;
        }
    }

    /// Cancels the current in-flight request, if any. A no-op when nothing
    /// is in flight or the request just finished on its own — the `send`
    /// failing in that race is expected and ignored.
    pub(crate) fn cancel(&self) {
        let mut slot = self.slot.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((_, tx)) = slot.take() {
            let _ = tx.send(());
        }
    }
}

/// Shows the popover window under the tray icon, positions it, and gives it
/// keyboard focus.
fn show_popover(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window(POPOVER_WINDOW_LABEL) else {
        return;
    };
    platform::position_popover(&window);
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

/// Opens the popover the way a tray interaction should: on platforms/
/// sessions where `platform::tray_open_captures()` is true (Linux Wayland,
/// which has no synthetic-copy fallback to fall back on later), this
/// immediately runs the capture flow instead of just showing an empty
/// popover — mirroring what the global shortcut does. Elsewhere, it's a
/// plain `show_popover`. Shared by the tray left-click toggle (when
/// toggling *open*) and the "Open Kallilex" tray-menu entry.
fn open_popover_from_tray(app: &tauri::AppHandle) {
    if platform::tray_open_captures() {
        trigger_capture(app);
    } else {
        show_popover(app);
    }
}

fn toggle_popover(app: &tauri::AppHandle) {
    match app.get_webview_window(POPOVER_WINDOW_LABEL) {
        Some(window) if window.is_visible().unwrap_or(false) => hide_popover(app),
        _ => open_popover_from_tray(app),
    }
}

pub(crate) fn show_settings(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window(SETTINGS_WINDOW_LABEL) {
        let _ = window.show();
        let _ = window.set_focus();
        if platform::needs_frame_extents_resync() {
            resync_frame_extents(&window);
        }
    }
}

/// Works around a GTK client-side-decoration bug that leaves the Settings
/// window's title-bar buttons unclickable on GNOME Wayland.
///
/// The window is created hidden and shown on demand. On its first map, GTK
/// reports the shadow-inclusive rectangle (652x499 for a 600x400 window,
/// i.e. 26px of invisible CSD shadow per side and 23px on top) while the
/// visible frame is drawn inset by exactly that margin. The result is that
/// the title bar's input regions sit ~26px off from where the buttons are
/// painted: clicking Minimise or Close lands on the draggable strip instead
/// and does nothing, while a *double* click still hits that strip and
/// maximises. Only a real allocation change re-syncs the two — measured on
/// GNOME 50 / Ubuntu, where the window then reports 600x447 (shadows gone)
/// and every button responds.
///
/// So this reproduces, deliberately and briefly, the one sequence proven to
/// fix it: maximise, then restore. The 60ms lead-in lets the initial map
/// settle first; without it the cycle races the mapping and has no effect.
/// It is a workaround for a toolkit-level defect, not a design choice — if a
/// future GTK/tao release fixes the frame-extents handling, this whole
/// function should go.
///
/// Skipped when the window is already maximised: there are no CSD shadows in
/// that state (so nothing to re-sync), and cycling would throw away a
/// maximised window the user chose.
fn resync_frame_extents(window: &tauri::WebviewWindow) {
    if window.is_maximized().unwrap_or(false) {
        return;
    }
    let window = window.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(60));
        let _ = window.maximize();
        std::thread::sleep(std::time::Duration::from_millis(120));
        let _ = window.unmaximize();
    });
}

/// Restores any pending clipboard backup and clears the stored capture
/// result. Called on cancel (Escape / focus loss / closing without an
/// action, all of which route through [`hide_popover`]).
pub(crate) fn cancel_capture(app: &tauri::AppHandle) {
    let lifecycle = app.state::<BackupLifecycle>();
    lifecycle.restore_pending(&platform::clipboard());

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

    {
        use crate::core::capture;

        let backend = platform::selection_backend();
        let clipboard = platform::clipboard();
        let keyboard = platform::keyboard(app.clone());
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
                    "Kallilex couldn't understand the saved shortcut \"{}\" and will use the default {} instead.",
                    settings.shortcut,
                    Settings::default().shortcut
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
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
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
            commands::get_platform_info,
            commands::run_action,
            commands::cancel_action,
            commands::get_action_context,
            commands::list_profiles,
            commands::save_profile,
            commands::delete_profile,
            commands::set_active_profile,
            commands::get_presets,
            commands::test_connection,
            commands::open_settings,
            commands::get_wayland_shortcut_trigger,
        ])
        // Registered on the builder, not inside `.setup()`: the windows
        // declared in `tauri.conf.json` are created while `Builder::build`
        // is still running, before `setup` gets a chance to run. On
        // Windows, WebView2 initialisation of the second (settings) window
        // pumps the main thread's message loop, which can let the
        // already-loaded popover webview dispatch its first IPC command
        // (e.g. `capture_selection`) before `setup` would have called
        // `app.manage(...)`, panicking on `state() called before
        // manage()`. `Builder::manage` registers state before any window
        // exists, on every platform, so moving it here is safe everywhere;
        // behavior on macOS/Linux is unchanged since nothing there reads
        // this state earlier than `setup` did.
        .manage(CaptureState::default())
        .manage(BackupLifecycle::new())
        .manage(ReplaceInFlight::default())
        .manage(ActionInFlight::new())
        .manage(platform::PortalShortcutTrigger::default())
        .setup(|app| {
            // Menu-bar-only app: no Dock icon, no app switcher entry.
            platform::setup(app);

            let settings_store = TauriStoreSettings::new(app.handle().clone());
            let current_settings = settings::get_settings(&settings_store).unwrap_or_default();

            // spec-13 Slice A: apply the persisted input-synthesis opt-out
            // before anything below consults `platform::platform_info()` (or
            // any other reader of `wayland::input_synthesis_live()`), so the
            // very first capability report already reflects the user's
            // choice instead of the all-permissive process-wide default.
            platform::set_input_synthesis_enabled(current_settings.input_synthesis_enabled);

            if platform::use_portal_global_shortcut() {
                // The GlobalShortcuts portal is the sole owner of the
                // "capture" trigger on this session: the tauri
                // global-shortcut plugin registration below is skipped
                // entirely rather than attempted and ignored, since its
                // underlying key-grab mechanism doesn't work under Wayland
                // anyway.
                platform::spawn_portal_shortcut(
                    app.handle().clone(),
                    current_settings.shortcut.clone(),
                    trigger_capture,
                );
            } else {
                let shortcut = resolve_shortcut(app.handle(), &current_settings);
                if let Err(err) = app.global_shortcut().register(shortcut) {
                    // Registration is still attempted above regardless; on
                    // platforms/sessions where failure is expected (Linux
                    // Wayland has no portal-backed global shortcuts wired up
                    // yet), skip the dialog — the frontend surfaces a one-line
                    // notice instead, so this isn't silent, just not a popup.
                    if !platform::global_shortcut_failure_expected() {
                        show_error_dialog(
                            app.handle(),
                            format!(
                                "Kallilex couldn't register the global shortcut ({err}). \
                                 You can still open Kallilex from the tray icon."
                            ),
                        );
                    }
                }
            }

            // First-run permission onboarding: if the platform requires a
            // grantable capture permission (macOS Accessibility; none on
            // Linux) and it's currently missing, and we haven't shown the
            // panel before, open Settings once.
            {
                use crate::core::capture::SelectionBackend;

                let permission_required = platform::platform_info().permission_required;
                let permission_granted = platform::selection_backend().permission_granted();
                if permission_required
                    && !permission_granted
                    && !current_settings.accessibility_onboarding_shown
                {
                    show_settings(app.handle());
                    let updated_settings = Settings {
                        accessibility_onboarding_shown: true,
                        ..current_settings.clone()
                    };
                    let _ = settings::set_settings(&settings_store, updated_settings);
                }
            }

            // SNI trays are menu-oriented and may not deliver left-click
            // events at all, so platforms that want it (Linux) get an
            // explicit "Open Kallilex" entry as the first item, guaranteeing
            // the popover is always reachable from the tray menu.
            let open_item = platform::wants_tray_open_entry()
                .then(|| MenuItem::with_id(app, OPEN_MENU_ID, "Open Kallilex", true, None::<&str>))
                .transpose()?;
            let settings_item =
                MenuItem::with_id(app, SETTINGS_MENU_ID, "Settings", true, None::<&str>)?;
            let about_metadata = AboutMetadataBuilder::new()
                .name(Some("Kallilex"))
                .version(Some(app.package_info().version.to_string()))
                .license(Some("Apache-2.0"))
                .icon(app.default_window_icon().cloned())
                .build();
            let about_item =
                PredefinedMenuItem::about(app, Some("About Kallilex"), Some(about_metadata))?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit_item = MenuItem::with_id(app, QUIT_MENU_ID, "Quit", true, None::<&str>)?;

            let mut menu_items: Vec<&dyn tauri::menu::IsMenuItem<_>> = Vec::new();
            if let Some(open_item) = open_item.as_ref() {
                menu_items.push(open_item);
            }
            menu_items.push(&settings_item);
            menu_items.push(&about_item);
            menu_items.push(&separator);
            menu_items.push(&quit_item);

            let tray_menu = Menu::with_items(app, &menu_items)?;

            TrayIconBuilder::new()
                .icon(tauri::image::Image::from_bytes(platform::tray_icon_bytes())?)
                .icon_as_template(platform::tray_icon_as_template())
                .menu(&tray_menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    OPEN_MENU_ID => open_popover_from_tray(app),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancel_fires_the_receiver_returned_by_begin() {
        let in_flight = ActionInFlight::new();
        let (rx, _generation) = in_flight.begin();

        in_flight.cancel();

        assert!(rx.await.is_ok());
    }

    #[tokio::test]
    async fn a_second_begin_implicitly_cancels_the_first() {
        let in_flight = ActionInFlight::new();
        let (rx1, _g1) = in_flight.begin();

        // Replaces the slot, dropping the first sender — which fires rx1
        // (with an Err, since nothing was ever sent on it). That the await
        // completes at all is what matters: it's what `select!`'s
        // `_ = &mut cancel_rx` branch in `run_action` relies on to notice
        // it's been superseded.
        let (_rx2, _g2) = in_flight.begin();

        assert!(rx1.await.is_err());
    }

    #[tokio::test]
    async fn clear_with_a_stale_generation_leaves_a_newer_request_cancellable() {
        let in_flight = ActionInFlight::new();
        let (_rx1, g1) = in_flight.begin();
        let (rx2, _g2) = in_flight.begin();

        // Stale: g1 no longer matches what's in the slot (g2 does), so this
        // must not clear the newer request's sender.
        in_flight.clear(g1);
        in_flight.cancel();

        assert!(rx2.await.is_ok());
    }

    #[tokio::test]
    async fn clear_with_the_current_generation_clears_the_slot() {
        let in_flight = ActionInFlight::new();
        let (rx, g) = in_flight.begin();

        in_flight.clear(g);
        // The slot is now empty, so this is a no-op — the receiver still
        // resolves, but only because `clear` dropped the sender above, not
        // because `cancel` sent anything.
        in_flight.cancel();

        assert!(rx.await.is_err());
    }
}
