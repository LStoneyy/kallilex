//! Kallilex application entry point: builds the Tauri app, wires the tray
//! icon, popover/settings windows, and registers plugins/commands.

mod commands;
mod core;

use tauri::menu::{AboutMetadataBuilder, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{ActivationPolicy, Manager, WindowEvent};
use tauri_plugin_positioner::{Position, WindowExt};

use crate::core::{POPOVER_WINDOW_LABEL, SETTINGS_WINDOW_LABEL};

const SETTINGS_MENU_ID: &str = "settings";
const QUIT_MENU_ID: &str = "quit";

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

fn hide_popover(app: &tauri::AppHandle) {
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
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::set_settings,
            commands::hide_popover,
        ])
        .setup(|app| {
            // Menu-bar-only app: no Dock icon, no app switcher entry.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(ActivationPolicy::Accessory);

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
