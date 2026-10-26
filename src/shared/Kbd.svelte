<script lang="ts">
  import { formatChord, type Os } from "./shortcuts";

  // `chord` is a stored `[Mod+][Alt+][Shift+]Key` string; rendering is
  // entirely `formatChord`'s call — this component only lays its tokens out
  // as `<kbd>` elements, macOS tight against each other, everywhere else
  // with a `+` between.
  let { chord, os }: { chord: string; os: Os } = $props();

  const tokens = $derived(formatChord(chord, os));
</script>

<span class="kbd-chord">
  {#each tokens as token, index (index)}
    {#if index > 0 && os !== "macos"}<span class="kbd-sep">+</span>{/if}
    <kbd>{token}</kbd>
  {/each}
</span>

<style>
  .kbd-chord {
    display: inline-flex;
    align-items: center;
    gap: 1px;
    line-height: 1;
  }

  kbd {
    font-family: inherit;
    font-size: 9px;
    font-weight: 600;
    line-height: 1;
    padding: 2px 3px;
    border-radius: 3px;
    border: 1px solid color-mix(in srgb, var(--color-marble) 28%, transparent);
    background-color: color-mix(in srgb, var(--color-marble) 12%, transparent);
    color: var(--color-marble);
  }

  .kbd-sep {
    color: var(--color-ash);
    font-size: 9px;
  }
</style>
