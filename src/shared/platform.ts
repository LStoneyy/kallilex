import { getPlatformInfo } from "./invoke";
import type { PlatformInfo } from "./types";

/**
 * Cached platform-info loader: the value never changes for the lifetime of
 * a window, so every caller shares the same in-flight/resolved promise
 * instead of round-tripping to the backend more than once.
 */
let cached: Promise<PlatformInfo> | null = null;

export function loadPlatformInfo(): Promise<PlatformInfo> {
  cached ??= getPlatformInfo();
  return cached;
}

/** Test-only: clears the cache so the next `loadPlatformInfo()` re-fetches. */
export function resetPlatformInfoForTests(): void {
  cached = null;
}

/**
 * Adds a `platform-${info.os}` class to the document root, so CSS can scope
 * platform-specific overrides (e.g. `html.platform-linux`) without any
 * runtime branching in components.
 */
export function applyPlatformClass(info: PlatformInfo): void {
  document.documentElement.classList.add(`platform-${info.os}`);
}
