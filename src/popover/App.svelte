<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import { captureSelection, hidePopover, openAccessibilitySettings } from "../shared/invoke";
  import type { CaptureFailureReason } from "../shared/types";

  let text = $state("");
  let reason = $state<CaptureFailureReason | null>(null);
  let unlisten: UnlistenFn | undefined;
  let destroyed = false;

  async function refreshCapture() {
    const result = await captureSelection();
    text = result.text;
    reason = result.reason;
  }

  onMount(() => {
    void refreshCapture();

    void listen("capture:done", () => {
      void refreshCapture();
    }).then((fn) => {
      // The component may have unmounted while this promise was pending —
      // in that case there's no `unlisten` to store for `onDestroy` to
      // call, so unlisten immediately here instead of leaking the listener.
      if (destroyed) {
        fn();
      } else {
        unlisten = fn;
      }
    });
  });

  onDestroy(() => {
    destroyed = true;
    unlisten?.();
  });

  function handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      void hidePopover();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<main class="popover">
  {#if reason === "permissionMissing"}
    <div class="permission-banner">
      <p>Kallilex needs the Accessibility permission to capture your selection.</p>
      <button type="button" onclick={() => void openAccessibilitySettings()}>
        Open System Settings
      </button>
    </div>
  {/if}
  <textarea
    class="capture-field"
    placeholder="No text captured — paste or type here."
    bind:value={text}
  ></textarea>
</main>

<style>
  :global(html),
  :global(body) {
    margin: 0;
    padding: 0;
    height: 100%;
    background: transparent;
  }

  .popover {
    box-sizing: border-box;
    width: 100%;
    height: 100vh;
    background-color: var(--color-basalt);
    border: 1px solid color-mix(in srgb, var(--color-marble) 12%, transparent);
    border-radius: 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 10px;
    overflow: hidden;
    font-family:
      -apple-system,
      BlinkMacSystemFont,
      "Segoe UI",
      sans-serif;
  }

  .permission-banner {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 8px 10px;
    border-radius: 8px;
    background-color: color-mix(in srgb, var(--color-electrum) 16%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-electrum) 40%, transparent);
  }

  .permission-banner p {
    margin: 0;
    color: var(--color-marble);
    font-size: 12px;
    line-height: 1.4;
  }

  .permission-banner button {
    align-self: flex-start;
    border: none;
    border-radius: 6px;
    padding: 4px 10px;
    background-color: var(--color-electrum);
    color: var(--color-basalt);
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }

  .capture-field {
    flex: 1;
    box-sizing: border-box;
    width: 100%;
    resize: none;
    border: none;
    outline: none;
    background: transparent;
    color: var(--color-marble);
    font-size: 13px;
    line-height: 1.5;
    font-family: inherit;
  }

  .capture-field::placeholder {
    color: var(--color-ash);
  }
</style>
