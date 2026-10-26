<script lang="ts">
  import { formatChord, type Os } from "./shortcuts";

  // `chord` is a stored `[Mod+][Alt+][Shift+]Key` string, formatted via
  // `formatChord`; this component only lays the resulting tokens out as
  // `<kbd>` elements, macOS tight against each other, everywhere else with a
  // `+` between. `tokens` lets a caller pass already-formatted display
  // tokens instead (the global shortcut's accelerator grammar has no chord
  // string to format, so `ShortcutRecorder` resolves it with
  // `formatAccelerator` itself) — exactly one of `chord`/`tokens` is given.
  let { chord, tokens, os }: { chord?: string; tokens?: string[]; os: Os } = $props();

  const resolvedTokens = $derived(tokens ?? (chord !== undefined ? formatChord(chord, os) : []));
</script>

<span class="kbd-chord">
  {#each resolvedTokens as token, index (index)}
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
