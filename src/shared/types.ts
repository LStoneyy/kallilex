/**
 * Mirrors the `Settings` struct defined in `src-tauri/src/core/settings/mod.rs`.
 * Keep in sync with the Rust source of truth.
 */
export interface Settings {
  activeProfileId: string | null;
  shortcut: string;
  spellcheckEnabled: boolean;
  popoverPinned: boolean;
}
