import { invoke } from "@tauri-apps/api/core";
import type { CaptureResult, Settings } from "./types";

/**
 * Thin, typed wrappers around the Tauri command surface.
 * UI code should always go through these instead of calling `invoke` directly.
 */

export async function getSettings(): Promise<Settings> {
  return invoke<Settings>("get_settings");
}

export async function setSettings(settings: Settings): Promise<Settings> {
  return invoke<Settings>("set_settings", { settings });
}

export async function hidePopover(): Promise<void> {
  return invoke<void>("hide_popover");
}

export async function captureSelection(): Promise<CaptureResult> {
  return invoke<CaptureResult>("capture_selection");
}

export async function accessibilityStatus(): Promise<boolean> {
  return invoke<boolean>("accessibility_status");
}

export async function openAccessibilitySettings(): Promise<void> {
  return invoke<void>("open_accessibility_settings");
}
