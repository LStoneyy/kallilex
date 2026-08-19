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
  profiles: ProviderProfile[];
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

/**
 * Mirrors `HeaderEntry` in `src-tauri/src/core/providers/mod.rs`: a single
 * custom HTTP header sent with every request for a profile.
 */
export interface HeaderEntry {
  name: string;
  value: string;
}

/**
 * Mirrors `ProviderProfile` in `src-tauri/src/core/providers/mod.rs`. The
 * API key itself never lives here — see `hasApiKey` — it is looked up
 * separately through the backend's `SecretStore`, keyed by `id`.
 */
export interface ProviderProfile {
  id: string;
  name: string;
  baseUrl: string;
  model: string;
  timeoutSecs: number;
  customHeaders: HeaderEntry[];
  enabled: boolean;
  hasApiKey: boolean;
}

/**
 * Mirrors `Action` in `src-tauri/src/core/providers/mod.rs`: a bundled AI
 * action, or a free-form custom instruction.
 */
export type Action =
  | { kind: "rewrite" }
  | { kind: "shorten" }
  | { kind: "improveClarity" }
  | { kind: "custom"; instruction: string };

/**
 * Mirrors `RunActionOutcome` in `src-tauri/src/core/providers/mod.rs`.
 * `kind` on the `error` variant is a stable machine-readable discriminant;
 * `message` is the ready-to-display, actionable text.
 */
export type RunActionOutcome =
  | { status: "ok"; text: string }
  | { status: "notConfigured" }
  | { status: "cancelled" }
  | {
      status: "error";
      kind:
        | "unreachable"
        | "timeout"
        | "http"
        | "missingModel"
        | "invalidBaseUrl"
        | "invalidResponse";
      message: string;
    };

/**
 * Mirrors `PrivacyClass` in `src-tauri/src/core/providers/mod.rs`: a coarse
 * privacy classification of a provider endpoint's host.
 */
export type PrivacyClass = "local" | "lan" | "cloud";

/**
 * Mirrors `ActionContext` in `src-tauri/src/core/providers/mod.rs`: summary
 * of the active profile (if any) for the popover's AI actions panel.
 */
export interface ActionContext {
  configured: boolean;
  profileName: string | null;
  privacy: PrivacyClass | null;
}

/**
 * Mirrors `Preset` in `src-tauri/src/core/providers/mod.rs`: a bundled
 * preset offered when creating a new profile.
 */
export interface Preset {
  id: string;
  label: string;
  baseUrl: string;
  needsApiKey: boolean;
}
