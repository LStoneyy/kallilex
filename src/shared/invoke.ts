import { invoke } from "@tauri-apps/api/core";
import type { Settings } from "./types";

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
