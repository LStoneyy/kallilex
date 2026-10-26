<script lang="ts">
  /**
   * A generic, reusable shortcut-recording control: idle, it shows the
   * current value (or "Not set"); activated (click, Enter or Space), it
   * captures the next `keydown` itself and turns it into a candidate value
   * via `chordFromEvent`/`acceleratorFromEvent` depending on `mode` — the
   * same functions the popover and the global shortcut actually match
   * against, so recording and matching can never disagree. It never talks
   * to the backend itself: `validate`, `findConflict` and `onCommit` are the
   * caller's own rules (popover-chord or global-accelerator), so the same
   * component drives the popover rows, the prompt rows, the prompt form and
   * the global row.
   *
   * A take-over-able conflict is its own state (`pendingConflict`), separate
   * from `recording`: the Take over/Cancel buttons live outside the main
   * button, so the moment focus moves to them the main button blurs — if
   * that blur still meant "cancel", both a mouse take-over (mousedown blurs
   * before the click lands) and a keyboard one (Tab away from the main
   * button) would wipe the very conflict they were trying to resolve. Once
   * `recording` is false the stray blur is inert, and focus is moved to Take
   * over itself so a keyboard user never has to Tab there at all.
   */
  import { onDestroy, tick } from "svelte";
  import Kbd from "./Kbd.svelte";
  import {
    acceleratorFromEvent,
    chordFromEvent,
    formatAccelerator,
    formatChord,
    type Os,
  } from "./shortcuts";

  type Mode = "chord" | "accelerator";

  interface Conflict {
    holder: string;
    canTakeOver: boolean;
    /** Verbatim wording to show instead of this component's own generic
     * sentence — e.g. "Already used to open Kallilex." for the global
     * shortcut, which isn't "held" by a describable target the same way a
     * popover action or prompt is. */
    message?: string;
  }

  interface PendingConflict {
    candidate: string;
    line: string;
  }

  let {
    value,
    os,
    mode,
    label,
    clearable = true,
    defaultValue = null,
    validate,
    findConflict,
    warn,
    onCommit,
    confirmOnCommit = true,
  }: {
    value: string | null;
    os: Os;
    mode: Mode;
    label: string;
    clearable?: boolean;
    defaultValue?: string | null;
    validate: (candidate: string) => string | null;
    findConflict: (candidate: string) => Conflict | null;
    warn?: (candidate: string) => string | null;
    onCommit: (value: string | null, takeOver: boolean) => Promise<void> | void;
    confirmOnCommit?: boolean;
  } = $props();

  let recording = $state(false);
  let committing = $state(false);
  let heldModifierTokens = $state<string[]>([]);
  let error = $state<string | null>(null);
  let hint = $state<string | null>(null);
  let confirming = $state(false);
  let pendingConflict = $state<PendingConflict | null>(null);

  let rootEl: HTMLDivElement | undefined = $state();
  let mainButtonEl: HTMLButtonElement | undefined = $state();
  let takeOverButtonEl: HTMLButtonElement | undefined = $state();

  let confirmTimeoutId: ReturnType<typeof setTimeout> | undefined;

  onDestroy(() => {
    if (confirmTimeoutId !== undefined) clearTimeout(confirmTimeoutId);
  });

  // Renders `v` the way this control's `mode` and `os` would show it —
  // used both for the idle label and inline in error/conflict text, so a
  // message like "⌘2 is used by…" always matches what the button itself
  // would go on to display.
  function formatValueText(v: string): string {
    const tokens = mode === "chord" ? formatChord(v, os) : formatAccelerator(v, os);
    return os === "macos" ? tokens.join("") : tokens.join("+");
  }

  const idleDisplayText = $derived(value === null ? "not set" : formatValueText(value));
  const idleAriaLabel = $derived(
    `Shortcut for ${label}: ${idleDisplayText}. Press Enter to record a new one.`,
  );
  const mainAriaLabel = $derived.by(() => {
    if (pendingConflict) return `Shortcut conflict for ${label}: ${pendingConflict.line}`;
    if (committing) return `Saving the shortcut for ${label}…`;
    if (recording) {
      return `Recording a shortcut for ${label}. Press the keys, or Escape to cancel.`;
    }
    return idleAriaLabel;
  });
  const recordingHint = $derived(clearable ? "Esc to cancel, ⌫ to clear" : "Esc to cancel");
  const showClear = $derived(clearable && value !== null);
  const showReset = $derived(defaultValue !== null && defaultValue !== value);

  function currentModifierTokens(event: KeyboardEvent): string[] {
    const tokens: string[] = [];
    if (os === "macos") {
      if (event.ctrlKey) tokens.push("⌃");
      if (event.altKey) tokens.push("⌥");
      if (event.shiftKey) tokens.push("⇧");
      if (event.metaKey) tokens.push("⌘");
    } else {
      if (event.ctrlKey) tokens.push("Ctrl");
      if (event.altKey) tokens.push("Alt");
      if (event.shiftKey) tokens.push("Shift");
      if (event.metaKey) tokens.push("Super");
    }
    return tokens;
  }

  function isFocusInside(): boolean {
    return rootEl !== undefined && rootEl.contains(document.activeElement);
  }

  async function restoreFocusIfNeeded(wasInside: boolean) {
    if (!wasInside) return;
    await tick();
    mainButtonEl?.focus();
  }

  function startRecording() {
    recording = true;
    error = null;
    hint = null;
    confirming = false;
    pendingConflict = null;
    heldModifierTokens = [];
  }

  function cancelRecording() {
    recording = false;
    error = null;
    pendingConflict = null;
    heldModifierTokens = [];
  }

  async function focusTakeOverAfterRender() {
    await tick();
    takeOverButtonEl?.focus();
  }

  // Evaluates a just-recorded (or proposed-default) candidate against the
  // caller's rules: an invalid or blocked-conflict candidate shows an
  // inline reason and leaves the current state untouched (recording stays
  // open for another try; idle stays idle for a rejected ↺); a
  // take-over-able conflict leaves `recording` and moves into its own
  // `pendingConflict` state (see the module doc comment for why); anything
  // else commits outright.
  function evaluateCandidate(candidate: string) {
    const validationError = validate(candidate);
    if (validationError) {
      error = validationError;
      return;
    }

    const conflict = findConflict(candidate);
    if (conflict) {
      if (!conflict.canTakeOver) {
        error =
          conflict.message ??
          `${formatValueText(candidate)} is already used by ${conflict.holder} and can't be taken over.`;
        return;
      }
      error = null;
      recording = false;
      pendingConflict = {
        candidate,
        line: conflict.message ?? `${formatValueText(candidate)} is used by "${conflict.holder}".`,
      };
      void focusTakeOverAfterRender();
      return;
    }

    error = null;
    void commit(candidate, false);
  }

  async function commit(newValue: string | null, takeOver: boolean) {
    const wasInside = isFocusInside();
    const warningText = newValue !== null ? (warn?.(newValue) ?? null) : null;
    pendingConflict = null;
    recording = false;
    committing = true;

    try {
      await onCommit(newValue, takeOver);
      error = null;
      hint = warningText;
      if (confirmTimeoutId !== undefined) clearTimeout(confirmTimeoutId);
      if (confirmOnCommit) {
        confirming = true;
        confirmTimeoutId = setTimeout(() => {
          confirming = false;
        }, 1500);
      } else {
        confirming = false;
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      hint = null;
      confirming = false;
    } finally {
      committing = false;
      await restoreFocusIfNeeded(wasInside);
    }
  }

  function handleClick() {
    if (committing || recording || pendingConflict) return;
    startRecording();
  }

  function handleKeydown(event: KeyboardEvent) {
    if (committing) return;

    if (!recording) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        startRecording();
      }
      return;
    }

    if (event.key === "Tab") {
      // Let focus move on as normal — only our own state resets.
      cancelRecording();
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    if (event.key === "Escape") {
      cancelRecording();
      return;
    }

    if (event.key === "Backspace" || event.key === "Delete") {
      const bare = !event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey;
      if (bare && clearable) void commit(null, false);
      return;
    }

    heldModifierTokens = currentModifierTokens(event);

    const candidate = mode === "chord" ? chordFromEvent(event, os) : acceleratorFromEvent(event, os);
    if (candidate === null) return; // modifier-only, repeat, AltGraph, … — keep recording

    evaluateCandidate(candidate);
  }

  function handleKeyup(event: KeyboardEvent) {
    if (!recording) return;
    heldModifierTokens = currentModifierTokens(event);
  }

  function handleBlur() {
    if (recording) cancelRecording();
  }

  function handleClear() {
    if (committing) return;
    void commit(null, false);
  }

  function handleReset() {
    if (committing || defaultValue === null) return;
    evaluateCandidate(defaultValue);
  }

  function handleTakeOver() {
    if (committing || !pendingConflict) return;
    void commit(pendingConflict.candidate, true);
  }

  async function handleCancelConflict() {
    if (committing) return;
    const wasInside = isFocusInside();
    pendingConflict = null;
    await restoreFocusIfNeeded(wasInside);
  }

  // Escape cancels the pending conflict no matter whether Take over or
  // Cancel itself has focus — neither carries any other `keydown` handler,
  // so this is attached to both directly rather than relying on bubbling
  // through a non-interactive wrapper.
  function handleConflictKeydown(event: KeyboardEvent) {
    if (event.key !== "Escape" || committing) return;
    event.preventDefault();
    event.stopPropagation();
    void handleCancelConflict();
  }

  // A pending conflict must not outlive the user simply walking away from
  // it — a click elsewhere, or tabbing past Take over/Cancel onto whatever
  // comes next — or it would sit there forever since nothing else ever
  // clears it. A real outside click is caught here rather than through
  // `focusout`: WKWebView (macOS's system webview) doesn't focus a button
  // on click, so clicking Cancel itself can blur Take over with
  // `relatedTarget: null` *before* the click lands — treating a null
  // `relatedTarget` as "left" would cancel the very click meant to resolve
  // the conflict.
  function handleDocumentPointerDown(event: PointerEvent) {
    if (!pendingConflict) return;
    if (event.target instanceof Node && rootEl?.contains(event.target)) return;
    void handleCancelConflict();
  }

  // Tab out of the component (a real `relatedTarget`, pointing somewhere
  // else) abandons the conflict the same way; a null `relatedTarget` is
  // left alone for the WKWebView reason above — `handleDocumentPointerDown`
  // covers that case instead.
  function handleContainerFocusOut(event: FocusEvent) {
    if (!pendingConflict) return;
    const related = event.relatedTarget;
    if (related === null) return;
    if (related instanceof Node && rootEl?.contains(related)) return;
    void handleCancelConflict();
  }
</script>

<svelte:document onpointerdown={handleDocumentPointerDown} />

<div class="shortcut-recorder-container" bind:this={rootEl} onfocusout={handleContainerFocusOut}>
  <div class="recorder-row">
    <button
      type="button"
      class="shortcut-recorder"
      class:is-recording={recording}
      bind:this={mainButtonEl}
      aria-label={mainAriaLabel}
      onclick={handleClick}
      onkeydown={handleKeydown}
      onkeyup={handleKeyup}
      onblur={handleBlur}
    >
      {#if committing}
        <span class="placeholder">Saving…</span>
      {:else if pendingConflict}
        {#if mode === "chord"}
          <Kbd chord={pendingConflict.candidate} {os} />
        {:else}
          <Kbd tokens={formatAccelerator(pendingConflict.candidate, os)} {os} />
        {/if}
      {:else if recording}
        <span class="placeholder">Press a shortcut…</span>
        {#if heldModifierTokens.length > 0}
          <span class="held-preview">
            {#each heldModifierTokens as token, index (index)}<kbd>{token}</kbd>{/each}
          </span>
        {/if}
      {:else if value !== null}
        {#if mode === "chord"}
          <Kbd chord={value} {os} />
        {:else}
          <Kbd tokens={formatAccelerator(value, os)} {os} />
        {/if}
      {:else}
        <span class="not-set">Not set</span>
      {/if}
    </button>

    {#if !recording && !pendingConflict && !committing}
      {#if showClear}
        <button
          type="button"
          class="icon-button"
          aria-label={`Clear shortcut for ${label}`}
          onclick={handleClear}
        >
          ✕
        </button>
      {/if}
      {#if showReset}
        <button
          type="button"
          class="icon-button"
          aria-label={`Reset shortcut for ${label} to its default`}
          onclick={handleReset}
        >
          ↺
        </button>
      {/if}
    {/if}
  </div>

  <div class="recorder-status" aria-live="polite">
    {#if pendingConflict}
      <span class="hint conflict-line">{pendingConflict.line}</span>
      <button
        type="button"
        class="link-button"
        bind:this={takeOverButtonEl}
        onclick={handleTakeOver}
        onkeydown={handleConflictKeydown}
      >
        Take over
      </button>
      <button
        type="button"
        class="link-button"
        onclick={() => void handleCancelConflict()}
        onkeydown={handleConflictKeydown}
      >
        Cancel
      </button>
    {:else if recording}
      <span class="hint">{recordingHint}</span>
      {#if error}<span class="error">{error}</span>{/if}
    {:else if error}
      <span class="error">{error}</span>
    {:else}
      {#if confirming}<span class="confirm">Saved</span>{/if}
      {#if hint}<span class="hint">{hint}</span>{/if}
    {/if}
  </div>
</div>

<style>
  .shortcut-recorder-container {
    display: flex;
    flex-direction: column;
  }

  .recorder-row {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .shortcut-recorder {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 64px;
    min-height: 24px;
    padding: 3px 10px;
    border-radius: 6px;
    border: 1px solid color-mix(in srgb, var(--color-marble) 18%, transparent);
    background-color: transparent;
    color: var(--color-marble);
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }

  .shortcut-recorder.is-recording {
    border-color: var(--color-verdigris);
    color: var(--color-verdigris);
  }

  .shortcut-recorder .not-set {
    color: var(--color-ash);
    font-weight: 400;
  }

  .shortcut-recorder .placeholder {
    font-weight: 400;
  }

  .held-preview {
    display: inline-flex;
    gap: 2px;
  }

  .held-preview kbd {
    font-family: inherit;
    font-size: 9px;
    font-weight: 600;
    padding: 1px 3px;
    border-radius: 3px;
    border: 1px solid color-mix(in srgb, var(--color-verdigris) 40%, transparent);
    color: var(--color-verdigris);
  }

  .icon-button {
    border: none;
    background: none;
    color: var(--color-ash);
    font-size: 12px;
    padding: 2px 4px;
    cursor: pointer;
    flex: none;
  }

  .icon-button:hover {
    color: var(--color-marble);
  }

  .recorder-status {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: 16px;
    margin-top: 2px;
  }

  .recorder-status .hint {
    font-size: 11px;
    color: var(--color-ash);
  }

  .recorder-status .error {
    font-size: 11px;
    color: var(--color-attic-clay);
  }

  .recorder-status .confirm {
    font-size: 11px;
    color: var(--color-verdigris);
  }

  .link-button {
    border: none;
    background: none;
    padding: 0;
    font-size: 11px;
    font-weight: 600;
    text-decoration: underline;
    color: var(--color-marble);
    cursor: pointer;
    flex: none;
  }
</style>
