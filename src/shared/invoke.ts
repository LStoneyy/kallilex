import { invoke } from "@tauri-apps/api/core";
import {
  disable as autostartDisable,
  enable as autostartEnable,
  isEnabled as autostartIsEnabled,
} from "@tauri-apps/plugin-autostart";
import type {
  Action,
  ActionContext,
  CaptureResult,
  PlatformInfo,
  Preset,
  ProviderProfile,
  RunActionOutcome,
  Settings,
  SpellcheckResult,
} from "./types";

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

export async function spellcheck(text: string): Promise<SpellcheckResult> {
  return invoke<SpellcheckResult>("spellcheck", { text });
}

export async function replaceBack(text: string): Promise<void> {
  return invoke<void>("replace_back", { text });
}

export async function copyResult(text: string): Promise<void> {
  return invoke<void>("copy_result", { text });
}

export async function runAction(text: string, action: Action): Promise<RunActionOutcome> {
  return invoke<RunActionOutcome>("run_action", { text, action });
}

export async function cancelAction(): Promise<void> {
  return invoke<void>("cancel_action");
}

export async function getActionContext(): Promise<ActionContext> {
  return invoke<ActionContext>("get_action_context");
}

export async function listProfiles(): Promise<ProviderProfile[]> {
  return invoke<ProviderProfile[]>("list_profiles");
}

export async function saveProfile(
  profile: ProviderProfile,
  apiKey?: string | null,
): Promise<ProviderProfile[]> {
  return invoke<ProviderProfile[]>("save_profile", { profile, apiKey: apiKey ?? null });
}

export async function deleteProfile(id: string): Promise<ProviderProfile[]> {
  return invoke<ProviderProfile[]>("delete_profile", { id });
}

export async function setActiveProfile(id: string | null): Promise<void> {
  return invoke<void>("set_active_profile", { id });
}

export async function getPresets(): Promise<Preset[]> {
  return invoke<Preset[]>("get_presets");
}

export async function testConnection(id: string): Promise<number> {
  return invoke<number>("test_connection", { id });
}

export async function openSettings(): Promise<void> {
  return invoke<void>("open_settings");
}

export async function getPlatformInfo(): Promise<PlatformInfo> {
  return invoke<PlatformInfo>("get_platform_info");
}

/**
 * The Wayland GlobalShortcuts portal's reported trigger for the "capture"
 * shortcut (spec-12 Slice B), or `null` when unbound. Only meaningful on
 * sessions where `PlatformInfo.wayland?.globalShortcut` is true.
 */
export async function getWaylandShortcutTrigger(): Promise<string | null> {
  return invoke<string | null>("get_wayland_shortcut_trigger");
}

/**
 * Thin wrappers around `@tauri-apps/plugin-autostart`'s JS API, kept here so
 * components never import the plugin directly — tests can mock these like
 * every other invoke wrapper.
 */
export async function isAutostartEnabled(): Promise<boolean> {
  return autostartIsEnabled();
}

export async function enableAutostart(): Promise<void> {
  return autostartEnable();
}

export async function disableAutostart(): Promise<void> {
  return autostartDisable();
}

/**
 * Persists `onboardingCompleted = true` and closes the onboarding window
 * (Rust-side, via `complete_onboarding_core` + `window.close()`) — see
 * `src/onboarding/App.svelte`'s "Done" handler for why a lost IPC response
 * during that close is expected and harmless.
 */
export async function completeOnboarding(): Promise<void> {
  return invoke<void>("complete_onboarding");
}

/**
 * Persists `inputSynthesisEnabled` and pushes it live (spec-13 Slice A),
 * mirroring what `setSettings` does for the same field — the onboarding
 * window's Wayland paste-back toggle calls this instead of `setSettings` so
 * it never clobbers the (hidden but live) Settings window's in-memory state.
 */
export async function setInputSynthesis(enabled: boolean): Promise<void> {
  return invoke<void>("set_input_synthesis", { enabled });
}
