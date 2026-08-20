<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import {
    cancelAction as cancelActionInvoke,
    captureSelection,
    copyResult,
    getActionContext,
    getSettings,
    hidePopover,
    openAccessibilitySettings,
    openSettings as openSettingsInvoke,
    replaceBack,
    runAction as runActionInvoke,
    spellcheck as spellcheckInvoke,
  } from "../shared/invoke";
  import { loadPlatformInfo } from "../shared/platform";
  import type {
    Action,
    ActionContext,
    CaptureFailureReason,
    Misspelling,
    PlatformInfo,
    SourceApp,
  } from "../shared/types";

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
  let sourceApp = $state<SourceApp | null>(null);
  // `null` until `loadPlatformInfo()` resolves — treated as "assume the
  // macOS-default look" (Replace shown) so nothing flashes/disappears once
  // it resolves on platforms where it's actually available.
  let platformInfo = $state<PlatformInfo | null>(null);
  let misspellings = $state<Misspelling[]>([]);
  let popup = $state<SuggestionPopup | null>(null);
  let customOpen = $state(false);
  let customValue = $state("");
  // Shared across Replace/Copy and the AI actions: only one can be in
  // flight at a time, and all of Replace/Copy/action buttons are disabled
  // while any of them runs.
  let busy = $state(false);
  let actionError = $state<string | null>(null);
  let actionContext = $state<ActionContext | null>(null);
  let spellcheckEnabled = $state(true);
  // The user's spec-13 Slice A opt-out from Wayland input synthesis.
  // Defaults to `true` (permissive) so nothing flashes away before the
  // first `refreshContext()` resolves, matching `spellcheckEnabled`'s
  // convention above.
  let inputSynthesisEnabled = $state(true);
  // The user's spec-13 Slice B auto-copy preference. Defaults to `false`
  // (permissive-in-the-other-direction: no clipboard write happens until
  // this loads), matching the setting's own default.
  let autoCopyResult = $state(false);
  // True only while an AI action (`run_action`) is specifically in flight —
  // as opposed to `busy`, which is also true during Replace/Copy. Gates the
  // Cancel affordance and the Escape-cancels-first-then-closes behavior.
  let aiRunning = $state(false);
  let showConfiguredHint = $state(false);
  // True briefly after a successful Copy, to confirm the action without
  // relying on the popover closing (it no longer does).
  let copied = $state(false);
  let copiedTimeoutId: ReturnType<typeof setTimeout> | undefined;
  // Whether the editor's content overflows above/below the visible area —
  // drives the top/bottom scroll-shadow pseudo-elements.
  let canScrollUp = $state(false);
  let canScrollDown = $state(false);

  let unlisten: UnlistenFn | undefined;
  let unlistenFocus: UnlistenFn | undefined;
  let destroyed = false;

  let editorEl: HTMLDivElement | undefined;
  let textareaEl: HTMLTextAreaElement | undefined;
  let backdropEl: HTMLDivElement | undefined;

  // Guards a spellcheck response that resolves after the text it was
  // computed for has been superseded (a fresh capture, a newer on-demand
  // check, or the user typing while a check was in flight): the offsets in
  // a stale response no longer match `text`, so they must never be applied.
  let pendingCheckText: string | null = null;

  // Monotonically increasing generation counter, bumped on every fresh
  // capture. Guards an in-flight `runAiAction` the same way `pendingCheckText`
  // guards spellcheck: if the generation changes while a request is
  // outstanding, that request's outcome — and its `finally` state reset —
  // belongs to a session that no longer exists and must be discarded. Not
  // `$state` since nothing renders it directly.
  let captureGeneration = 0;

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

  /**
   * Puts `value` on the clipboard when the user has asked for results to be
   * copied automatically (spec-13 Slice B). Called only where *Kallilex
   * itself* changed the text — a successful AI action, or an applied
   * spellcheck suggestion — never per keystroke while the user types:
   * firing on every edit would clobber the clipboard mid-edit, and a rule
   * the user cannot predict is worse than one extra Copy click. The last
   * such change wins.
   *
   * Deliberately NOT called on the Replace path: `replace_back` owns the
   * clipboard for its whole backup -> write -> paste -> restore sequence,
   * and a copy landing inside that window would defeat the restore. The two
   * settings are usable together, so this is an ordering rule, not a mutual
   * exclusion.
   */
  async function autoCopyIfEnabled(value: string) {
    if (!autoCopyResult) return;
    // Both call sites fire this synchronously right after changing `text`,
    // so reading the generation here is equivalent to capturing it at the
    // call site — and it keeps the staleness rule in one place.
    const generation = captureGeneration;
    try {
      await copyResult(value);
    } catch (error) {
      console.error("auto-copy failed", error);
      if (generation !== captureGeneration) {
        // A fresh capture superseded this session while the copy was in
        // flight. `refreshCapture` already cleared `actionError` for the new
        // session; surfacing this one now would pin a failure that belongs
        // to an abandoned capture onto text the user is only just looking
        // at. Logged above either way, matching `runSpellcheck`'s
        // console-only failure handling.
        return;
      }
      actionError = "The result couldn't be copied automatically — use Copy.";
    }
  }

  /**
   * Fetches the AI-action context (whether a provider is configured, which
   * one, and its privacy class) and the spellcheck-enabled flag. Both can
   * change while the user was away in Settings, so this runs on mount, on
   * every fresh capture, and on window focus gain — without touching the
   * captured text itself.
   */
  async function refreshContext() {
    const [settings, context] = await Promise.all([getSettings(), getActionContext()]);
    spellcheckEnabled = settings.spellcheckEnabled;
    inputSynthesisEnabled = settings.inputSynthesisEnabled;
    autoCopyResult = settings.autoCopyResult;
    actionContext = context;
    if (context.configured) {
      showConfiguredHint = false;
    }
  }

  function updateScrollShadows() {
    if (!textareaEl) return;
    const { scrollTop, scrollHeight, clientHeight } = textareaEl;
    canScrollUp = scrollTop > 0;
    canScrollDown = scrollTop + clientHeight < scrollHeight - 1;
  }

  // Clears the "Copied ✓" confirmation and its pending timeout — used both
  // where a fresh capture/edit already resets other state, and standalone
  // whenever `text` changes underneath a stale confirmation that no longer
  // matches what's on the clipboard.
  function clearCopied() {
    if (copiedTimeoutId !== undefined) {
      clearTimeout(copiedTimeoutId);
      copiedTimeoutId = undefined;
    }
    copied = false;
  }

  async function refreshCapture() {
    // Bumps the session forward, invalidating any `runAiAction` still in
    // flight from the previous session — see `captureGeneration`'s comment.
    captureGeneration += 1;
    clearCopied();
    if (aiRunning) {
      // The in-flight request is about to become irrelevant; ask the
      // backend to abort it instead of letting it run to completion for no
      // reason. Fire-and-forget: whether or not this succeeds, the
      // generation bump above already ensures its outcome gets discarded.
      cancelActionInvoke().catch((error) => console.error("cancel_action failed", error));
    }
    // Started concurrently with the capture itself, but deliberately not
    // awaited before assigning `text` below — `refreshContext` takes an
    // extra network/store round trip, and letting it gate the text
    // assignment would leave a window where a user's in-progress edit (or a
    // manual spellcheck) races a still-pending capture and gets clobbered
    // once it finally resolves. It's only awaited below, right before the
    // decision that actually needs it: whether to auto-run spellcheck.
    const contextPromise = refreshContext();
    const result = await captureSelection();
    text = result.text;
    reason = result.reason;
    sourceApp = result.sourceApp;
    misspellings = [];
    popup = null;
    actionError = null;
    showConfiguredHint = false;
    busy = false;
    aiRunning = false;
    await contextPromise;
    if (spellcheckEnabled) {
      void runSpellcheck(text);
    }
    // Wait for the DOM to reflect the new `text` before measuring scroll
    // extents, otherwise this would read the previous capture's layout.
    await tick();
    updateScrollShadows();
  }

  onMount(() => {
    void refreshCapture();
    void loadPlatformInfo().then((info) => {
      platformInfo = info;
    });

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

    // A reopen that doesn't go through `capture:done` (e.g. a tray click)
    // never runs `refreshCapture`, so a stale `actionError` — set while the
    // popover was hidden (a replace error surfaced via dialog instead), or
    // simply left over from a previous session — must not resurface out of
    // context. Clearing it on every focus gain covers both cases.
    void getCurrentWindow()
      .onFocusChanged(({ payload: focused }) => {
        if (focused) {
          actionError = null;
          void refreshContext();
        }
      })
      .then((fn) => {
        if (destroyed) {
          fn();
        } else {
          unlistenFocus = fn;
        }
      });
  });

  onDestroy(() => {
    destroyed = true;
    unlisten?.();
    unlistenFocus?.();
    if (copiedTimeoutId !== undefined) {
      clearTimeout(copiedTimeoutId);
    }
  });

  function handleInput() {
    // The moment the text changes, every stored offset is stale.
    misspellings = [];
    popup = null;
    clearCopied();
    updateScrollShadows();
  }

  function handleScroll() {
    if (backdropEl && textareaEl) {
      backdropEl.scrollTop = textareaEl.scrollTop;
      backdropEl.scrollLeft = textareaEl.scrollLeft;
    }
    updateScrollShadows();
  }

  function handleCheckSpellingClick() {
    void runSpellcheck(text);
  }

  const canReplace = $derived(text.trim() !== "" && sourceApp !== null && !busy);
  // True when the user has switched input synthesis off (spec-13 Slice A)
  // on a Wayland session — the only session type the setting is honored on.
  // Needed on top of `platformInfo.replaceBackAvailable` because
  // `loadPlatformInfo()` caches its result per window, so a toggle in
  // Settings while the popover is already open wouldn't otherwise be
  // reflected until the next reload.
  const inputSynthesisOffByChoice = $derived(
    platformInfo?.session === "wayland" && !inputSynthesisEnabled,
  );
  // Hidden entirely (not disabled) when the platform doesn't support
  // Replace at all, or the user switched it off — defaults to shown while
  // `platformInfo` is still loading, so nothing flashes away on platforms
  // where it ends up available (macOS today).
  const showReplace = $derived(
    platformInfo === null || (platformInfo.replaceBackAvailable && !inputSynthesisOffByChoice),
  );
  // Wayland's global shortcut and automatic replace-back availability
  // depend on which XDG portals the running compositor implements (spec-12)
  // — this is a plain factual notice about what's missing, not an error
  // state, so it renders unconditionally (when anything is missing) rather
  // than behind any dismiss/error affordance. Replace being off is a
  // separate case: when it's off because the *user* switched input
  // synthesis off, that's a deliberate choice, not something wrong with the
  // session, so it is never reported here at all — only the shortcut
  // dimension still matters in that case (spec-13 Slice A).
  const waylandNoticeText = $derived.by(() => {
    if (platformInfo?.session !== "wayland") return null;
    const wayland = platformInfo.wayland;
    const hasGlobalShortcut = wayland?.globalShortcut ?? false;
    const hasInputSynthesis = wayland?.inputSynthesis ?? false;

    if (!inputSynthesisEnabled) {
      return hasGlobalShortcut
        ? null
        : "Wayland session: your compositor doesn't offer the GlobalShortcuts portal — open Kallilex from the tray to capture your selection.";
    }

    if (hasGlobalShortcut && hasInputSynthesis) return null;
    if (!hasGlobalShortcut && !hasInputSynthesis) {
      return "Wayland session: your compositor doesn't offer the GlobalShortcuts or RemoteDesktop portals — open Kallilex from the tray to capture, and copy results manually.";
    }
    if (!hasGlobalShortcut) {
      return "Wayland session: your compositor doesn't offer the GlobalShortcuts portal — open Kallilex from the tray to capture your selection.";
    }
    return "Wayland session: your compositor doesn't offer the RemoteDesktop portal — automatic replace is unavailable; copy the result instead.";
  });
  const canCopy = $derived(text.trim() !== "" && !busy);
  const canRunAction = $derived(text.trim() !== "" && !busy && actionContext !== null);

  type PrivacyBadge = { text: string; class: string };

  function privacyBadge(context: ActionContext | null): PrivacyBadge | null {
    if (!context || !context.configured) return null;
    switch (context.privacy) {
      case "local":
        return { text: "Local", class: "local" };
      case "lan":
        return { text: `${context.profileName} · LAN`, class: "local" };
      case "cloud":
        return { text: `${context.profileName} · Cloud`, class: "cloud" };
      default:
        // Unparseable base URL — still configured, just an unknown class.
        return { text: context.profileName ?? "", class: "unknown" };
    }
  }

  const badge = $derived(privacyBadge(actionContext));

  /**
   * Runs an AI action (a bundled one or a custom instruction) against `text`.
   * No-ops when there's nothing to act on or another action/Replace/Copy is
   * already running — the shared guard both the buttons' `disabled` state
   * and this function itself enforce, so a stray keyboard-triggered call
   * can never sneak past it.
   */
  async function runAiAction(action: Action) {
    if (text.trim() === "" || busy) return;
    if (actionContext === null) {
      // The initial `getActionContext()` fetch is still pending — too soon
      // to know whether a provider is configured, so this isn't (yet) a
      // "go configure one" situation. `canRunAction` already keeps the
      // buttons disabled in this state; this guard only protects against a
      // stray keyboard-triggered call slipping through in the same window.
      return;
    }
    if (!actionContext.configured) {
      showConfiguredHint = true;
      return;
    }
    showConfiguredHint = false;
    actionError = null;
    busy = true;
    aiRunning = true;
    const generation = captureGeneration;
    try {
      const outcome = await runActionInvoke(text, action);
      if (generation !== captureGeneration) {
        // A fresh capture superseded this session while the request was in
        // flight — `refreshCapture` already reset `text`/`busy`/`aiRunning`
        // for the new session, and `cancelActionInvoke` was already fired.
        // The outcome no longer applies to anything on screen: applying it
        // (or even surfacing its error) would clobber state that belongs to
        // a newer capture.
        return;
      }
      if (outcome.status === "ok") {
        text = outcome.text;
        misspellings = [];
        popup = null;
        clearCopied();
        // Fire-and-forget: does not extend the `busy`/`aiRunning` window the
        // `finally` block below controls.
        void autoCopyIfEnabled(outcome.text);
        if (spellcheckEnabled) {
          void runSpellcheck(outcome.text);
        }
        // Deliberately not re-checking `generation` after this await:
        // `updateScrollShadows` only reads the currently rendered DOM, so
        // even if a newer capture raced in during `tick()`, the recompute
        // is correct for whatever is on screen.
        await tick();
        updateScrollShadows();
      } else if (outcome.status === "notConfigured") {
        showConfiguredHint = true;
      } else if (outcome.status === "error") {
        actionError = outcome.message;
      }
      // "cancelled": nothing further to do — just clear the busy state below.
    } catch (error) {
      if (generation !== captureGeneration) return;
      actionError = error instanceof Error ? error.message : String(error);
    } finally {
      if (generation === captureGeneration) {
        busy = false;
        aiRunning = false;
      }
    }
  }

  function runCustomAction() {
    const instruction = customValue.trim();
    if (instruction === "" || !canRunAction) return;
    void runAiAction({ kind: "custom", instruction });
  }

  function handleCustomKeydown(event: KeyboardEvent) {
    if (event.key !== "Enter") return;
    runCustomAction();
  }

  async function handleCancelClick() {
    try {
      await cancelActionInvoke();
    } catch (error) {
      console.error("cancel_action failed", error);
    }
  }

  async function handleOpenSettingsClick() {
    try {
      await openSettingsInvoke();
    } catch (error) {
      console.error("open_settings failed", error);
    }
  }

  async function handleReplaceClick() {
    actionError = null;
    busy = true;
    try {
      await replaceBack(text);
      void hidePopover();
    } catch (error) {
      actionError = error instanceof Error ? error.message : String(error);
    } finally {
      busy = false;
    }
  }

  async function handleCopyClick() {
    actionError = null;
    busy = true;
    clearCopied();
    try {
      await copyResult(text);
      // Deliberately no `hidePopover()` here — the popover stays open so
      // the user can see the confirmation below.
      copied = true;
      copiedTimeoutId = setTimeout(() => {
        copied = false;
        copiedTimeoutId = undefined;
      }, 1500);
    } catch (error) {
      actionError = error instanceof Error ? error.message : String(error);
    } finally {
      busy = false;
    }
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
    clearCopied();
    void autoCopyIfEnabled(corrected);
    void runSpellcheck(corrected);
    void tick().then(updateScrollShadows);
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
    if (aiRunning) {
      // First Escape while an AI action is in flight cancels it instead of
      // closing the popover; a second Escape then falls through to the
      // normal behavior below.
      void handleCancelClick();
      return;
    }
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
    {#if text.length > 0}
      <span class="char-count">{text.length} chars</span>
    {:else}
      <span class="char-count-placeholder"></span>
    {/if}
    <button type="button" class="check-spelling" onclick={handleCheckSpellingClick}>
      Check spelling
    </button>
  </div>

  <div
    class="editor"
    class:can-scroll-up={canScrollUp}
    class:can-scroll-down={canScrollDown}
    bind:this={editorEl}
  >
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
      disabled={aiRunning}
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
    <button
      type="button"
      class="action-button"
      disabled={!canRunAction}
      onclick={() => void runAiAction({ kind: "rewrite" })}
    >
      Rewrite
    </button>
    <button
      type="button"
      class="action-button"
      disabled={!canRunAction}
      onclick={() => void runAiAction({ kind: "shorten" })}
    >
      Shorten
    </button>
    <button
      type="button"
      class="action-button"
      disabled={!canRunAction}
      onclick={() => void runAiAction({ kind: "improveClarity" })}
    >
      Improve clarity
    </button>
    <button
      type="button"
      class="action-button"
      class:active={customOpen}
      disabled={busy}
      onclick={toggleCustom}
    >
      Custom
    </button>
  </div>

  {#if customOpen}
    <div class="custom-row">
      <input
        class="custom-prompt"
        type="text"
        placeholder="Describe what to do…"
        bind:value={customValue}
        onkeydown={handleCustomKeydown}
        disabled={busy}
      />
      <button
        type="button"
        class="custom-run"
        disabled={!canRunAction || customValue.trim() === ""}
        onclick={runCustomAction}
      >
        Run
      </button>
    </div>
  {/if}

  {#if showConfiguredHint}
    <div class="ai-hint">
      <span>No AI provider set up yet — open Settings to add one.</span>
      <button type="button" onclick={() => void handleOpenSettingsClick()}>
        Open Settings
      </button>
    </div>
  {/if}

  {#if aiRunning}
    <div class="ai-progress">
      <span class="ai-progress-label" role="status" aria-label="Working…">Working</span>
      <button type="button" class="ai-cancel" onclick={() => void handleCancelClick()}>
        Cancel
      </button>
    </div>
  {/if}

  {#if waylandNoticeText}
    <p class="wayland-notice">{waylandNoticeText}</p>
  {/if}

  <div class="result-row">
    {#if showReplace}
      <button
        type="button"
        class="result-button"
        disabled={!canReplace}
        onclick={() => void handleReplaceClick()}
      >
        Replace
      </button>
    {/if}
    <button
      type="button"
      class="result-button"
      disabled={!canCopy}
      onclick={() => void handleCopyClick()}
    >
      {copied ? "Copied ✓" : "Copy"}
    </button>
    {#if actionError}
      <span class="action-error">{actionError}</span>
    {:else if badge}
      <span class="privacy-badge {badge.class}">{badge.text}</span>
    {:else}
      <span class="badge-placeholder"></span>
    {/if}
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
    background-color: color-mix(in srgb, var(--color-basalt) 80%, transparent);
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

  /* X11 has no compositor by default, so the semi-transparent surface color
     above renders as garbage instead of a blur/blend. Linux gets a fully
     opaque surface; macOS is untouched. */
  :global(html.platform-linux) .popover {
    background-color: var(--color-basalt);
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
    justify-content: space-between;
    align-items: center;
  }

  .char-count,
  .char-count-placeholder {
    color: var(--color-ash);
    font-size: 11px;
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

  .editor::before,
  .editor::after {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    height: 12px;
    pointer-events: none;
    z-index: 2;
    opacity: 0;
    transition: opacity 120ms ease;
  }

  .editor::before {
    top: 0;
    background: linear-gradient(to bottom, var(--color-basalt), transparent);
  }

  .editor::after {
    bottom: 0;
    background: linear-gradient(to top, var(--color-basalt), transparent);
  }

  .editor.can-scroll-up::before {
    opacity: 1;
  }

  .editor.can-scroll-down::after {
    opacity: 1;
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
    caret-color: var(--color-verdigris);
  }

  .capture-field::selection {
    background-color: color-mix(in srgb, var(--color-verdigris) 35%, transparent);
  }

  .capture-field::placeholder {
    color: var(--color-ash);
  }

  .capture-field:disabled {
    opacity: 0.6;
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

  .action-button:disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }

  .custom-row {
    display: flex;
    gap: 6px;
  }

  .custom-prompt {
    box-sizing: border-box;
    flex: 1;
    min-width: 0;
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

  .custom-run {
    border: 1px solid color-mix(in srgb, var(--color-attic-clay) 35%, transparent);
    background-color: color-mix(in srgb, var(--color-attic-clay) 14%, transparent);
    color: var(--color-marble);
    border-radius: 6px;
    padding: 5px 10px;
    font-size: 12px;
    cursor: pointer;
  }

  .custom-run:disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }

  .ai-hint {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 6px 10px;
    border-radius: 8px;
    background-color: color-mix(in srgb, var(--color-marble) 6%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-marble) 12%, transparent);
  }

  .ai-hint span {
    color: var(--color-ash);
    font-size: 11px;
  }

  .ai-hint button {
    flex: none;
    border: none;
    border-radius: 6px;
    padding: 4px 10px;
    background-color: var(--color-attic-clay);
    color: var(--color-marble);
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
  }

  .ai-progress {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 6px 10px;
    border-radius: 8px;
    background-color: color-mix(in srgb, var(--color-verdigris) 12%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-verdigris) 30%, transparent);
  }

  .ai-progress-label {
    color: var(--color-marble);
    font-size: 11px;
  }

  .ai-cancel {
    flex: none;
    border: 1px solid color-mix(in srgb, var(--color-marble) 25%, transparent);
    border-radius: 6px;
    padding: 4px 10px;
    background-color: transparent;
    color: var(--color-marble);
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
  }

  .wayland-notice {
    margin: 0;
    color: var(--color-ash);
    font-size: 11px;
    line-height: 1.4;
  }

  .result-row {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .result-button {
    border: 1px solid color-mix(in srgb, var(--color-verdigris) 55%, transparent);
    background-color: color-mix(in srgb, var(--color-verdigris) 16%, transparent);
    color: var(--color-marble);
    border-radius: 6px;
    padding: 5px 10px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }

  .result-button:hover:not(:disabled) {
    background-color: color-mix(in srgb, var(--color-verdigris) 28%, transparent);
  }

  .result-button:disabled {
    border-color: color-mix(in srgb, var(--color-ash) 30%, transparent);
    background-color: transparent;
    color: var(--color-ash);
    font-weight: 400;
    cursor: not-allowed;
  }

  .badge-placeholder {
    flex: 1;
  }

  .action-error {
    flex: 1;
    /* No dedicated "error" token in the palette; attic-clay is the closest
       warm/red-ish accent already in use. AI provider error messages can
       run considerably longer than the replace/copy errors this span was
       originally sized for, so — unlike a single-line ellipsis — it wraps
       up to 3 lines before truncating. */
    color: var(--color-attic-clay);
    font-size: 11px;
    text-align: right;
    overflow: hidden;
    text-overflow: ellipsis;
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 3;
    line-clamp: 3;
  }

  .privacy-badge {
    flex: 1;
    text-align: right;
    font-size: 11px;
    font-weight: 600;
  }

  /* Endpoint stays on this device or the local network — closest to the
     palette's "positive/active" accent. */
  .privacy-badge.local {
    color: var(--color-verdigris);
  }

  /* The request leaves the network — the palette's warning/highlight
     accent, without being as alarming as an error color. */
  .privacy-badge.cloud {
    color: var(--color-electrum);
  }

  .privacy-badge.unknown {
    color: var(--color-ash);
  }

  /* Micro-interaction polish shared across the popover's clickable
     surfaces: color transitions on every button, plus a consistent
     focus-visible ring (also on the custom-instruction input). Decorative
     motion (transform, keyframe animation) lives in the
     prefers-reduced-motion media query below instead. */
  .action-button,
  .result-button,
  .custom-run,
  .check-spelling,
  .ai-cancel,
  .ai-hint button,
  .permission-banner button,
  .suggestion-popup li button {
    transition:
      background-color 120ms ease,
      border-color 120ms ease,
      color 120ms ease;
  }

  .action-button:focus-visible,
  .result-button:focus-visible,
  .custom-run:focus-visible,
  .check-spelling:focus-visible,
  .ai-cancel:focus-visible,
  .ai-hint button:focus-visible,
  .permission-banner button:focus-visible,
  .suggestion-popup li button:focus-visible,
  .custom-prompt:focus-visible {
    outline: 2px solid var(--color-verdigris);
    outline-offset: 1px;
  }

  .custom-prompt {
    caret-color: var(--color-verdigris);
  }

  /* Static (reduced-motion) state of the "Working…" ellipsis: a plain,
     unanimated "…". The no-preference query below animates it. */
  .ai-progress-label::after {
    content: "…";
    display: inline-block;
    width: 1em;
    text-align: left;
  }

  @media (prefers-reduced-motion: no-preference) {
    .action-button,
    .result-button,
    .custom-run,
    .check-spelling,
    .ai-cancel,
    .ai-hint button,
    .permission-banner button,
    .suggestion-popup li button {
      transition:
        background-color 120ms ease,
        border-color 120ms ease,
        color 120ms ease,
        transform 80ms ease;
    }

    .action-button:active:not(:disabled),
    .result-button:active:not(:disabled),
    .custom-run:active:not(:disabled),
    .check-spelling:active:not(:disabled),
    .ai-cancel:active:not(:disabled),
    .ai-hint button:active:not(:disabled),
    .permission-banner button:active:not(:disabled),
    .suggestion-popup li button:active:not(:disabled) {
      transform: scale(0.98);
    }

    @keyframes row-in {
      from {
        opacity: 0;
        transform: translateY(-3px);
      }
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }

    /* Each of these is behind an `{#if}`, so this only ever fires on the
       state change that mounts it — never as an idle/looping animation. */
    .permission-banner,
    .custom-row,
    .ai-hint,
    .ai-progress,
    .suggestion-popup {
      animation: row-in 140ms ease-out;
    }

    @keyframes ai-ellipsis {
      0% {
        content: "";
      }
      25% {
        content: ".";
      }
      50% {
        content: "..";
      }
      75%,
      100% {
        content: "…";
      }
    }

    /* Only exists in the DOM while `aiRunning`, so this never runs idle
       either. The base rule's `content: "…"` above stays in effect as a
       static fallback on engines that can't animate `content`; the
       keyframes below take over `content` once the animation runs. */
    .ai-progress-label::after {
      animation: ai-ellipsis 1.2s steps(4, jump-none) infinite;
    }
  }
</style>
