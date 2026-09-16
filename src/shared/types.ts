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
  waylandRestoreToken: string | null;
  /** Wayland-only opt-out from RemoteDesktop-portal input synthesis. */
  inputSynthesisEnabled: boolean;
  /** Auto-copy results to the clipboard, cross-platform. */
  autoCopyResult: boolean;
  /** Whether the first-run onboarding window has been completed (or
   * auto-completed for an already-set-up install). */
  onboardingCompleted: boolean;
  /** The popover's user-dragged position (physical pixels), or `null` for
   * automatic (cursor-anchored) positioning. See `Settings::popover_position`'s
   * doc comment in the Rust source for why this is machine-local, like
   * `waylandRestoreToken` above. */
  popoverPosition: { x: number; y: number } | null;
  /** User-managed AI prompts offered as buttons in the popover's action
   * row. Defaults to the three bundled prompts (Rewrite / Shorten / Improve
   * clarity) both for a fresh install and for settings persisted before
   * this field existed — see `Settings::prompts`'s doc comment in the Rust
   * source. */
  prompts: CustomPrompt[];
  /** Which GitHub release channel to check for updates against. Defaults
   * to `"preview"` for a build whose own version carries a semver
   * pre-release suffix, `"stable"` otherwise — see `Settings::update_channel`'s
   * doc comment in the Rust source. */
  updateChannel: "stable" | "preview";
  /** How often Kallilex looks for updates. */
  updateCheckFrequency: "never" | "onLaunch" | "daily" | "weekly";
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
 * Mirrors `CustomPrompt` in `src-tauri/src/core/prompts.rs`: a single
 * user-manageable prompt — the label shown on its popover button, and the
 * instruction sent to the AI provider.
 */
export interface CustomPrompt {
  id: string;
  label: string;
  instruction: string;
}

/**
 * Mirrors `Action` in `src-tauri/src/core/providers/mod.rs`: a saved
 * prompt's instruction, or a free-form custom instruction.
 */
export type Action =
  | { kind: "prompt"; instruction: string }
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

/**
 * Mirrors `WaylandCapabilitiesInfo` in `src-tauri/src/platform/mod.rs`:
 * XDG-portal capabilities detected for the current Wayland compositor.
 */
export interface WaylandCapabilities {
  globalShortcut: boolean;
  inputSynthesis: boolean;
  canPersistSession: boolean;
}

/**
 * Mirrors `PlatformInfo` in `src-tauri/src/platform/mod.rs`: platform
 * metadata surfaced to the frontend by the `get_platform_info` command.
 */
export interface PlatformInfo {
  os: "macos" | "linux" | "windows";
  session: string | null;
  replaceBackAvailable: boolean;
  permissionRequired: boolean;
  defaultShortcut: string;
  wayland: WaylandCapabilities | null;
}
