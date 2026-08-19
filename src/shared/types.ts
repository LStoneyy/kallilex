/**
 * Mirrors the `Settings` struct defined in `src-tauri/src/core/settings/mod.rs`.
 * Keep in sync with the Rust source of truth.
 */
export interface Settings {
  activeProfileId: string | null;
  shortcut: string;
  spellcheckEnabled: boolean;
  popoverPinned: boolean;
  accessibilityOnboardingShown: boolean;
}

/**
 * Mirrors `SourceApp` in `src-tauri/src/core/capture/mod.rs`: the
 * application a selection was captured from.
 */
export interface SourceApp {
  bundleId: string | null;
  pid: number;
  name: string | null;
}

/**
 * Mirrors `CaptureFailureReason` in `src-tauri/src/core/capture/mod.rs`.
 */
export type CaptureFailureReason = "permissionMissing" | "noSelection";

/**
 * Mirrors `CaptureResult` in `src-tauri/src/core/capture/mod.rs`.
 */
export interface CaptureResult {
  text: string;
  reason: CaptureFailureReason | null;
  sourceApp: SourceApp | null;
}

/**
 * Mirrors `Misspelling` in `src-tauri/src/core/spellcheck/mod.rs`.
 * `start`/`length` are UTF-16 code-unit offsets — the same unit JS strings
 * use internally, so they can be passed straight to `.slice()`.
 */
export interface Misspelling {
  start: number;
  length: number;
  word: string;
  suggestions: string[];
}

/**
 * Mirrors `SpellcheckResult` in `src-tauri/src/core/spellcheck/mod.rs`.
 */
export interface SpellcheckResult {
  misspellings: Misspelling[];
}
