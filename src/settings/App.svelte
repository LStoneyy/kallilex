<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import { accessibilityStatus, openAccessibilitySettings } from "../shared/invoke";

  const POLL_INTERVAL_MS = 1000;

  let granted = $state(false);
  let intervalId: ReturnType<typeof setInterval> | undefined;

  async function refreshStatus() {
    granted = await accessibilityStatus();
  }

  onMount(() => {
    void refreshStatus();
    intervalId = setInterval(() => {
      void refreshStatus();
    }, POLL_INTERVAL_MS);
  });

  onDestroy(() => {
    if (intervalId !== undefined) {
      clearInterval(intervalId);
    }
  });
</script>

<main class="settings">
  <h1>Settings</h1>

  <section class="accessibility">
    <h2>Accessibility permission</h2>
    <p>
      Kallilex reads the text you've selected in whatever app you're writing in, so pressing the
      shortcut captures it instantly instead of asking you to copy it first. Capture happens
      entirely on this Mac — nothing leaves your machine until you choose to process it.
    </p>

    <p class="status" class:granted class:not-granted={!granted}>
      {granted ? "Granted" : "Not granted"}
    </p>

    <button type="button" onclick={() => void openAccessibilitySettings()}>
      Open System Settings
    </button>

    <p class="hint">
      If macOS doesn't pick up the change right away, quit and reopen Kallilex.
    </p>
  </section>
</main>

<style>
  :global(html),
  :global(body) {
    margin: 0;
    padding: 0;
    height: 100%;
  }

  .settings {
    box-sizing: border-box;
    width: 100%;
    height: 100vh;
    background-color: var(--color-basalt);
    color: var(--color-marble);
    padding: 24px;
    font-family:
      -apple-system,
      BlinkMacSystemFont,
      "Segoe UI",
      sans-serif;
  }

  h1 {
    margin: 0 0 20px;
    font-size: 18px;
    font-weight: 600;
    color: var(--color-marble);
  }

  .accessibility h2 {
    margin: 0 0 8px;
    font-size: 14px;
    font-weight: 600;
    color: var(--color-marble);
  }

  .accessibility p {
    margin: 0 0 12px;
    font-size: 13px;
    line-height: 1.5;
    color: var(--color-ash);
    max-width: 480px;
  }

  .status {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
  }

  .status.granted {
    color: var(--color-verdigris);
    background-color: color-mix(in srgb, var(--color-verdigris) 18%, transparent);
  }

  .status.not-granted {
    color: var(--color-electrum);
    background-color: color-mix(in srgb, var(--color-electrum) 18%, transparent);
  }

  button {
    display: block;
    margin: 14px 0 8px;
    border: none;
    border-radius: 6px;
    padding: 6px 14px;
    background-color: var(--color-attic-clay);
    color: var(--color-marble);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
  }

  .hint {
    font-size: 12px;
    color: var(--color-ash);
  }
</style>
