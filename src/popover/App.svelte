<script lang="ts">
  import { hidePopover } from "../shared/invoke";

  function handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      void hidePopover();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<main class="popover">
  <p class="placeholder">Kallilex</p>
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
    align-items: center;
    justify-content: center;
    overflow: hidden;
    font-family:
      -apple-system,
      BlinkMacSystemFont,
      "Segoe UI",
      sans-serif;
  }

  .placeholder {
    margin: 0;
    color: var(--color-ash);
    font-size: 13px;
    letter-spacing: 0.02em;
  }
</style>
