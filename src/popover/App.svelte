<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import {
    captureSelection,
    hidePopover,
    openAccessibilitySettings,
    spellcheck as spellcheckInvoke,
  } from "../shared/invoke";
  import type { CaptureFailureReason, Misspelling } from "../shared/types";

  type Segment = {
    key: string;
    text: string;
    misspelling: Misspelling | null;
  };

  type SuggestionPopup = {
    misspelling: Misspelling;
    top: number;
    left: number;
  };

  let text = $state("");
  let reason = $state<CaptureFailureReason | null>(null);
  let misspellings = $state<Misspelling[]>([]);
  let popup = $state<SuggestionPopup | null>(null);
  let customOpen = $state(false);
  let customValue = $state("");

  let unlisten: UnlistenFn | undefined;
  let destroyed = false;

  let editorEl: HTMLDivElement | undefined;
  let textareaEl: HTMLTextAreaElement | undefined;
  let backdropEl: HTMLDivElement | undefined;

  // Guards a spellcheck response that resolves after the text it was
  // computed for has been superseded (a fresh capture, a newer on-demand
  // check, or the user typing while a check was in flight): the offsets in
  // a stale response no longer match `text`, so they must never be applied.
  let pendingCheckText: string | null = null;

  function buildSegments(value: string, marks: Misspelling[]): Segment[] {
    const sorted = [...marks].sort((a, b) => a.start - b.start);
    const segments: Segment[] = [];
    let cursor = 0;

    for (const mark of sorted) {
      const start = Math.max(mark.start, cursor);
      const end = Math.max(mark.start + mark.length, start);
      if (start > cursor) {
        segments.push({ key: `plain-${cursor}`, text: value.slice(cursor, start), misspelling: null });
      }
      if (end > start) {
        segments.push({ key: `mark-${start}`, text: value.slice(start, end), misspelling: mark });
      }
      cursor = Math.max(cursor, end);
    }
    if (cursor < value.length) {
      segments.push({ key: `plain-${cursor}`, text: value.slice(cursor), misspelling: null });
    }
    return segments;
  }

  const segments = $derived(buildSegments(text, misspellings));

  async function runSpellcheck(target: string) {
    if (target.trim() === "") {
      misspellings = [];
      return;
    }
    pendingCheckText = target;
    try {
      const result = await spellcheckInvoke(target);
      if (pendingCheckText !== target || text !== target) {
        // Superseded by a newer request, or the text has since changed.
        return;
      }
      misspellings = result.misspellings;
    } catch (error) {
      console.error("spellcheck failed", error);
      if (pendingCheckText === target) {
        pendingCheckText = null;
      }
      if (text === target) {
        misspellings = [];
      }
    }
  }

  async function refreshCapture() {
    const result = await captureSelection();
    text = result.text;
    reason = result.reason;
    misspellings = [];
    popup = null;
    void runSpellcheck(text);
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

  function handleInput() {
    // The moment the text changes, every stored offset is stale.
    misspellings = [];
    popup = null;
  }

  function handleScroll() {
    if (backdropEl && textareaEl) {
      backdropEl.scrollTop = textareaEl.scrollTop;
      backdropEl.scrollLeft = textareaEl.scrollLeft;
    }
  }

  function handleCheckSpellingClick() {
    void runSpellcheck(text);
  }

  function openSuggestionsFor(target: HTMLElement, misspelling: Misspelling) {
    if (!editorEl) return;
    const markRect = target.getBoundingClientRect();
    const containerRect = editorEl.getBoundingClientRect();
    popup = {
      misspelling,
      top: markRect.bottom - containerRect.top + 4,
      left: markRect.left - containerRect.left,
    };
  }

  function handleMarkClick(event: MouseEvent, misspelling: Misspelling) {
    // Stop this click from also reaching the window-level "close the
    // popup" listener below — a mark click should open/replace the popup,
    // never open-then-immediately-close it.
    event.stopPropagation();
    openSuggestionsFor(event.currentTarget as HTMLElement, misspelling);
  }

  function applySuggestion(suggestion: string) {
    if (!popup) return;
    const { start, length } = popup.misspelling;
    const corrected = text.slice(0, start) + suggestion + text.slice(start + length);
    popup = null;
    // The moment the text changes, every stored offset is stale — clear
    // marks before assigning the corrected text so a stale mark is never
    // rendered against the new text while the follow-up check is in flight.
    misspellings = [];
    text = corrected;
    void runSpellcheck(corrected);
  }

  function handleWindowClick() {
    // Any click that reaches the window (i.e. wasn't stopped by a mark
    // click) closes an open popup — "clicking anywhere else".
    if (popup) {
      popup = null;
    }
  }

  function toggleCustom() {
    customOpen = !customOpen;
    if (!customOpen) {
      customValue = "";
    }
  }

  function handleWindowKeydown(event: KeyboardEvent) {
    if (event.key !== "Escape") return;
    if (popup) {
      popup = null;
      return;
    }
    if (customOpen) {
      customOpen = false;
      customValue = "";
      return;
    }
    void hidePopover();
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} onclick={handleWindowClick} />

<main class="popover">
  {#if reason === "permissionMissing"}
    <div class="permission-banner">
      <p>Kallilex needs the Accessibility permission to capture your selection.</p>
      <button type="button" onclick={() => void openAccessibilitySettings()}>
        Open System Settings
      </button>
    </div>
  {/if}

  <div class="toolbar">
    <button type="button" class="check-spelling" onclick={handleCheckSpellingClick}>
      Check spelling
    </button>
  </div>

  <div class="editor" bind:this={editorEl}>
    <div class="editor-backdrop" bind:this={backdropEl} aria-hidden="true">
      {#each segments as segment (segment.key)}
        {#if segment.misspelling}
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <span
            class="mark"
            onclick={(event) => handleMarkClick(event, segment.misspelling as Misspelling)}
          >{segment.text}</span>
        {:else}{segment.text}{/if}
      {/each}
    </div>
    <textarea
      class="capture-field"
      placeholder="No text captured — paste or type here."
      spellcheck="false"
      autocapitalize="off"
      {...{ autocorrect: "off" }}
      bind:this={textareaEl}
      bind:value={text}
      oninput={handleInput}
      onscroll={handleScroll}
    ></textarea>

    {#if popup}
      <div class="suggestion-popup" style={`top: ${popup.top}px; left: ${popup.left}px;`}>
        {#if popup.misspelling.suggestions.length > 0}
          <ul>
            {#each popup.misspelling.suggestions as suggestion (suggestion)}
              <li>
                <button type="button" onclick={() => applySuggestion(suggestion)}>
                  {suggestion}
                </button>
              </li>
            {/each}
          </ul>
        {:else}
          <p class="no-suggestions">No suggestions</p>
        {/if}
      </div>
    {/if}
  </div>

  <div class="action-row">
    <button type="button" class="action-button">Rewrite</button>
    <button type="button" class="action-button">Shorten</button>
    <button type="button" class="action-button">Improve clarity</button>
    <button type="button" class="action-button" class:active={customOpen} onclick={toggleCustom}>
      Custom
    </button>
  </div>

  {#if customOpen}
    <input
      class="custom-prompt"
      type="text"
      placeholder="Describe what to do…"
      bind:value={customValue}
    />
  {/if}

  <div class="result-row">
    <button type="button" class="result-button" disabled>Replace</button>
    <button type="button" class="result-button" disabled>Copy</button>
    <span class="badge-placeholder"></span>
  </div>
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
    position: relative;
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

  .toolbar {
    display: flex;
    justify-content: flex-end;
  }

  .check-spelling {
    border: none;
    background: transparent;
    color: var(--color-ash);
    font-size: 11px;
    padding: 2px 4px;
    cursor: pointer;
  }

  .check-spelling:hover {
    color: var(--color-marble);
    text-decoration: underline;
  }

  .editor {
    position: relative;
    flex: 1;
    min-height: 0;
  }

  .editor-backdrop,
  .capture-field {
    position: absolute;
    inset: 0;
    box-sizing: border-box;
    width: 100%;
    height: 100%;
    margin: 0;
    padding: 0;
    border: none;
    font-size: 13px;
    line-height: 1.5;
    font-family: inherit;
    white-space: pre-wrap;
    word-break: break-word;
    overflow-wrap: anywhere;
  }

  .editor-backdrop {
    color: transparent;
    overflow: hidden;
    /* Stacked above the textarea so `.mark` spans can be hit-tested;
       everything else passes through to the textarea. */
    z-index: 1;
    pointer-events: none;
  }

  .mark {
    pointer-events: auto;
    cursor: pointer;
    /* Longhands, not the `text-decoration` shorthand: WKWebView drops the
       shorthand entirely when it carries a style/color. */
    text-decoration-line: underline;
    text-decoration-style: wavy;
    text-decoration-color: var(--color-electrum);
    text-decoration-skip-ink: none;
    text-underline-offset: 2px;
  }

  .capture-field {
    resize: none;
    outline: none;
    background: transparent;
    color: var(--color-marble);
  }

  .capture-field::placeholder {
    color: var(--color-ash);
  }

  .suggestion-popup {
    position: absolute;
    z-index: 20;
    min-width: 120px;
    max-width: 220px;
    background-color: var(--color-basalt);
    border: 1px solid color-mix(in srgb, var(--color-marble) 18%, transparent);
    border-radius: 8px;
    padding: 4px;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.45);
  }

  .suggestion-popup ul {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
  }

  .suggestion-popup li button {
    width: 100%;
    text-align: left;
    border: none;
    background: transparent;
    color: var(--color-marble);
    font-size: 12px;
    padding: 5px 8px;
    border-radius: 5px;
    cursor: pointer;
  }

  .suggestion-popup li button:hover {
    background-color: color-mix(in srgb, var(--color-marble) 10%, transparent);
  }

  .no-suggestions {
    margin: 0;
    padding: 5px 8px;
    color: var(--color-ash);
    font-size: 12px;
  }

  .action-row {
    display: flex;
    gap: 6px;
  }

  .action-button {
    flex: 1;
    border: 1px solid color-mix(in srgb, var(--color-attic-clay) 35%, transparent);
    background-color: color-mix(in srgb, var(--color-attic-clay) 14%, transparent);
    color: var(--color-marble);
    border-radius: 6px;
    padding: 5px 6px;
    font-size: 12px;
    cursor: pointer;
  }

  .action-button:hover {
    background-color: color-mix(in srgb, var(--color-attic-clay) 22%, transparent);
  }

  .action-button.active {
    border-color: color-mix(in srgb, var(--color-verdigris) 60%, transparent);
    background-color: color-mix(in srgb, var(--color-verdigris) 18%, transparent);
  }

  .custom-prompt {
    box-sizing: border-box;
    width: 100%;
    border: 1px solid color-mix(in srgb, var(--color-marble) 15%, transparent);
    border-radius: 6px;
    background-color: transparent;
    color: var(--color-marble);
    font-size: 12px;
    padding: 5px 8px;
    outline: none;
    font-family: inherit;
  }

  .custom-prompt::placeholder {
    color: var(--color-ash);
  }

  .result-row {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .result-button {
    border: 1px solid color-mix(in srgb, var(--color-ash) 30%, transparent);
    background-color: transparent;
    color: var(--color-ash);
    border-radius: 6px;
    padding: 5px 10px;
    font-size: 12px;
    cursor: not-allowed;
  }

  .badge-placeholder {
    flex: 1;
  }
</style>
