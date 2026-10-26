<script lang="ts">
  import { onDestroy, onMount, tick } from "svelte";
  import { listen, type UnlistenFn } from "@tauri-apps/api/event";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import {
    beginPopoverDrag,
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
    setSettings,
    spellcheck as spellcheckInvoke,
  } from "../shared/invoke";
  import { loadPlatformInfo } from "../shared/platform";
  import { canonicalizeChord, chordFromEvent, formatChordText, validateChord } from "../shared/shortcuts";
  import Kbd from "../shared/Kbd.svelte";
  import type {
    Action,
    ActionContext,
    CaptureFailureReason,
    CustomPrompt,
    Misspelling,
    PlatformInfo,
    PopoverShortcuts,
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
  // The user's "keep this open" preference: while pinned, the popover no
  // longer auto-hides on focus loss (see `should_hide_on_blur` in
  // `lib.rs`) — it can still be closed via Escape, the global shortcut
  // toggle, or the tray. Defaults to `false`, matching the setting's own
  // default and `spellcheckEnabled`'s convention above.
  let pinned = $state(false);
  // The user's saved prompts, rendered as buttons in the action row ahead
  // of the always-present "Custom" toggle. Populated from `refreshContext()`
  // the same way `pinned` is above — it can change while the user was away
  // in Settings' Prompts tab.
  let prompts = $state<CustomPrompt[]>([]);
  // The popover's per-action keyboard shortcuts, refreshed alongside
  // `prompts` above so the two keep building the same `keymap` together.
  // Defaults to every slot unbound until the first `refreshContext()`
  // resolves — matching `prompts`' own empty-until-loaded convention.
  let popoverShortcuts = $state<PopoverShortcuts>({
    replace: null,
    copy: null,
    customPrompt: null,
    openSettings: null,
    checkSpelling: null,
  });
  // The user's opt-out from Wayland input synthesis. Defaults to `true` (permissive) so nothing flashes away before the
  // first `refreshContext()` resolves, matching `spellcheckEnabled`'s
  // convention above.
  let inputSynthesisEnabled = $state(true);
  // The user's auto-copy preference. Defaults to `false`
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
  // Whether a button's shortcut badge should be showing — true while the
  // `Mod` key has been held alone for ≥ 400ms, see `armHintTimer`/`hideHints`
  // below.
  let showHints = $state(false);
  // Per-button key-press feedback, keyed by a stable id (`prompt:<id>`,
  // `replace`, `copy`, `custom`, `spelling`) rather than a DOM query, since
  // the button a shortcut targets may not even be mounted by anything else
  // that could hold a reference to it directly. See `flash` below.
  let flashState = $state<Record<string, "pressed" | "denied">>({});

  let unlisten: UnlistenFn | undefined;
  let unlistenFocus: UnlistenFn | undefined;
  let destroyed = false;

  let editorEl: HTMLDivElement | undefined;
  let textareaEl: HTMLTextAreaElement | undefined;
  let backdropEl: HTMLDivElement | undefined;
  let customInputEl: HTMLInputElement | undefined = $state();

  // Not `$state`: both only ever drive a `setTimeout`/`clearTimeout` pair,
  // never render directly — same convention as `copiedTimeoutId` above.
  let modHoldTimeoutId: ReturnType<typeof setTimeout> | undefined;
  const flashTimeouts: Record<string, ReturnType<typeof setTimeout>> = {};

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
   * copied automatically. Called only where *Kallilex
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
    pinned = settings.popoverPinned;
    prompts = settings.prompts;
    popoverShortcuts = settings.popoverShortcuts;
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
    focusTextareaCaretEnd();
  }

  /** Focuses the capture textarea with the caret at the end of its current
   * value — a no-op if it isn't mounted or already lost to something else by
   * the time this runs. Called after a fresh capture, after an AI action
   * settles, and on window focus gain when nothing else already has focus;
   * see each call site for why. */
  function focusTextareaCaretEnd() {
    if (!textareaEl) return;
    textareaEl.focus();
    const end = textareaEl.value.length;
    textareaEl.setSelectionRange(end, end);
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
          // Covers a reopen that doesn't go through `capture:done` (a tray
          // click): if nothing else already claimed focus, put the caret
          // back where a keyboard user expects it.
          if (document.activeElement === document.body || document.activeElement === null) {
            void tick().then(() => focusTextareaCaretEnd());
          }
        } else {
          // Holding `Mod` and then switching away (Alt-Tab, another app's
          // window) must not leave the hint badges showing over a popover
          // the user isn't even looking at.
          hideHints();
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
    if (modHoldTimeoutId !== undefined) {
      clearTimeout(modHoldTimeoutId);
    }
    for (const id of Object.keys(flashTimeouts)) {
      clearTimeout(flashTimeouts[id]);
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

  // Re-fetches immediately before mutating, so a stale in-memory `pinned`
  // never clobbers a change made elsewhere (e.g. the Settings window) —
  // same concurrency convention as the toggles in `settings/App.svelte`.
  async function handlePinToggle() {
    try {
      const fresh = await getSettings();
      const updated = await setSettings({ ...fresh, popoverPinned: !fresh.popoverPinned });
      pinned = updated.popoverPinned;
    } catch (error) {
      console.error("setSettings (popoverPinned) failed", error);
    }
  }

  /**
   * Starts a native window drag when the user mousedowns on empty
   * `.toolbar` space (not one of its buttons). `begin_popover_drag` sets
   * the backend's drag flag *before* `startDragging()` is called, so the
   * native drag's first `WindowEvent::Moved` is already recognized as a
   * user drag rather than the popover's own positioning — see
   * `PopoverDrag`'s doc comment in `lib.rs`.
   */
  async function handleToolbarMouseDown(event: MouseEvent) {
    if (event.button !== 0) return;
    if ((event.target as HTMLElement).closest("button, input")) return;
    event.preventDefault();
    try {
      await beginPopoverDrag();
      await getCurrentWindow().startDragging();
    } catch (error) {
      console.error("startDragging failed", error);
    }
  }

  const canReplace = $derived(text.trim() !== "" && sourceApp !== null && !busy);
  // True when the user has switched input synthesis off on a Wayland session — the only session type the setting is honored on.
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
  // depend on which XDG portals the running compositor implements
  // — this is a plain factual notice about what's missing, not an error
  // state, so it renders unconditionally (when anything is missing) rather
  // than behind any dismiss/error affordance. Replace being off is a
  // separate case: when it's off because the *user* switched input
  // synthesis off, that's a deliberate choice, not something wrong with the
  // session, so it is never reported here at all — only the shortcut
  // dimension still matters in that case.
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

  // `null` until `platformInfo` resolves — every shortcut-handling path
  // below treats that the same as "no shortcuts yet" rather than guessing a
  // platform, since guessing wrong would mean matching the wrong modifier
  // key for `Mod`.
  const os = $derived(platformInfo?.os ?? null);

  type ShortcutAction =
    | { kind: "prompt"; prompt: CustomPrompt }
    | {
        kind: "action";
        action: "replace" | "copy" | "customPrompt" | "openSettings" | "checkSpelling";
      };

  /** Canonicalizes a stored shortcut and returns it only if it's actually
   * valid, else `null` — settings on disk can hold a value this app would
   * never write itself (a hand edit, or a chord left over from before it
   * was reserved), and a bare-key chord like `"L"` would otherwise sit in
   * the keymap eating that character every time the user types it. Validity
   * doesn't depend on `os` (only the wording of the rejection reason
   * does), so any platform works here. */
  function validBoundChord(raw: string): string | null {
    const canonical = canonicalizeChord(raw);
    if (!canonical) return null;
    return validateChord(canonical, "macos") === null ? canonical : null;
  }

  // Built straight from the stored chord strings — matching doesn't need
  // `os` at all, only turning a live keystroke into one of these strings
  // does (see `handleWindowKeydown`).
  const keymap = $derived.by(() => {
    const map = new Map<string, ShortcutAction>();
    const actionShortcuts: Array<
      [string | null, "replace" | "copy" | "customPrompt" | "openSettings" | "checkSpelling"]
    > = [
      [popoverShortcuts.replace, "replace"],
      [popoverShortcuts.copy, "copy"],
      [popoverShortcuts.customPrompt, "customPrompt"],
      [popoverShortcuts.openSettings, "openSettings"],
      [popoverShortcuts.checkSpelling, "checkSpelling"],
    ];
    for (const [chord, action] of actionShortcuts) {
      if (!chord) continue;
      const canonical = validBoundChord(chord);
      if (canonical) map.set(canonical, { kind: "action", action });
    }
    for (const prompt of prompts) {
      if (!prompt.shortcut) continue;
      const canonical = validBoundChord(prompt.shortcut);
      if (canonical) map.set(canonical, { kind: "prompt", prompt });
    }
    return map;
  });

  /** Flashes `.key-pressed` (~150ms) or `.key-denied` (~300ms) on whichever
   * button `id` names, restarting the timer if it's already flashing — the
   * visible response every shortcut press gives, whether or not it actually
   * ran anything. */
  function flash(id: string, kind: "pressed" | "denied") {
    const existing = flashTimeouts[id];
    if (existing !== undefined) clearTimeout(existing);
    flashState = { ...flashState, [id]: kind };
    flashTimeouts[id] = setTimeout(
      () => {
        delete flashTimeouts[id];
        const { [id]: _removed, ...rest } = flashState;
        flashState = rest;
      },
      kind === "pressed" ? 150 : 300,
    );
  }

  /** Runs whatever `action` a matched chord points at, through the same
   * guard its button already enforces via `disabled` — a keyboard-triggered
   * call can never bypass it just because there's no click event involved.
   * See each case for the guard it mirrors. */
  function dispatchAction(action: ShortcutAction) {
    if (action.kind === "prompt") {
      const id = `prompt:${action.prompt.id}`;
      if (!canRunAction) {
        flash(id, "denied");
        return;
      }
      flash(id, "pressed");
      // `runAiAction` itself shows the "No AI provider" hint when nothing
      // is configured — same as clicking the button would.
      void runAiAction({ kind: "prompt", instruction: action.prompt.instruction });
      return;
    }

    switch (action.action) {
      case "replace":
        // Replace being hidden (no platform support, or input synthesis
        // switched off) means there's no button to flash and nothing to run.
        if (!showReplace) return;
        if (!canReplace) {
          flash("replace", "denied");
          return;
        }
        flash("replace", "pressed");
        void handleReplaceClick();
        return;
      case "copy":
        if (!canCopy) {
          flash("copy", "denied");
          return;
        }
        flash("copy", "pressed");
        void handleCopyClick();
        return;
      case "customPrompt":
        if (busy) {
          flash("custom", "denied");
          return;
        }
        flash("custom", "pressed");
        void openCustomForShortcut();
        return;
      case "openSettings":
        // No visible button for this one — just run it.
        void handleOpenSettingsClick();
        return;
      case "checkSpelling":
        flash("spelling", "pressed");
        handleCheckSpellingClick();
        return;
    }
  }

  /** `title` text for a button with a configurable shortcut: the label
   * alone when unbound or before `os` is known, `"Label (⌘1)"` once it is. */
  function shortcutTitle(label: string, chord: string | null): string {
    if (!chord || os === null) return label;
    return `${label} (${formatChordText(chord, os)})`;
  }

  function modKeyName(currentOs: NonNullable<typeof os>): "Meta" | "Control" {
    return currentOs === "macos" ? "Meta" : "Control";
  }

  /** Hides the shortcut-badge hints and cancels the hold timer that would
   * have shown them — called on the mod key's own `keyup`, on any other
   * `keydown`, and on window blur (see `handleWindowKeydown`, the
   * `svelte:window` handler below, and `onFocusChanged` above). */
  function hideHints() {
    if (modHoldTimeoutId !== undefined) {
      clearTimeout(modHoldTimeoutId);
      modHoldTimeoutId = undefined;
    }
    showHints = false;
  }

  function handleWindowKeyup(event: KeyboardEvent) {
    if (os !== null && event.key === modKeyName(os)) {
      hideHints();
    }
  }

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
        // The textarea was `disabled` for the duration of the request and
        // dropped focus as a result — every outcome (ok, error, cancelled,
        // not configured) hands it back so a keyboard user can keep editing
        // or immediately press the Replace shortcut. But only if nothing
        // else already has focus: if the user clicked another control (Pin,
        // Check spelling, …) while the request was in flight, re-stealing
        // focus from it would be surprising, so this only fires when focus
        // is still sitting on `body`/nothing, or already on the textarea.
        void tick().then(() => {
          const active = document.activeElement;
          if (active === document.body || active === null || active === textareaEl) {
            focusTextareaCaretEnd();
          }
        });
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
    // A bare Enter runs the custom prompt; Enter with any modifier (⌘↩ most
    // importantly) is left alone so it falls through to the window-level
    // handler below, where ⌘↩ means Replace — without this check, binding
    // Replace to ⌘↩ would run the custom prompt and replace at the same
    // time whenever the custom field has focus.
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || event.isComposing) {
      return;
    }
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

  async function toggleCustom() {
    customOpen = !customOpen;
    if (!customOpen) {
      customValue = "";
      return;
    }
    await tick();
    customInputEl?.focus();
  }

  /** Opens the custom row for the `Mod+L`-style shortcut — unlike
   * `toggleCustom`, it only ever opens it (a shortcut must never close a row
   * the user is about to type into) and always (re)focuses the input,
   * whether or not the row was already open. */
  async function openCustomForShortcut() {
    customOpen = true;
    await tick();
    customInputEl?.focus();
  }

  function handleWindowKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
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
      return;
    }

    if (os !== null && event.key === modKeyName(os)) {
      // Only arm the hold timer on a fresh press — holding the key down
      // generally doesn't repeat `keydown` for a lone modifier, but nothing
      // here depends on that; a repeat simply finds the timer (or
      // `showHints`) already set and does nothing further.
      if (!event.repeat && modHoldTimeoutId === undefined && !showHints) {
        modHoldTimeoutId = setTimeout(() => {
          showHints = true;
          modHoldTimeoutId = undefined;
        }, 400);
      }
    } else {
      // Any other key, pressed while `Mod` may still be held, means the
      // user is mid-shortcut (or just typing) rather than pausing to look —
      // hide the hints instead of leaving them up for the rest of the hold.
      hideHints();
    }

    if (os === null) return;
    const chord = chordFromEvent(event, os);
    if (chord === null) return;
    const action = keymap.get(chord);
    if (!action) return;
    // This runs regardless of which element currently has focus (the text
    // field, the custom field, or a button) — `chordFromEvent` already
    // ignores IME composition and AltGraph, so it never steals a character
    // the user is actually typing.
    event.preventDefault();
    dispatchAction(action);
  }
</script>

<svelte:window
  onkeydown={handleWindowKeydown}
  onkeyup={handleWindowKeyup}
  onclick={handleWindowClick}
  onblur={hideHints}
/>

<main class="popover">
  {#if reason === "permissionMissing"}
    <div class="permission-banner">
      <p>Kallilex needs the Accessibility permission to capture your selection.</p>
      <button type="button" onclick={() => void openAccessibilitySettings()}>
        Open System Settings
      </button>
    </div>
  {/if}

  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="toolbar" onmousedown={(event) => void handleToolbarMouseDown(event)}>
    {#if text.length > 0}
      <span class="char-count">{text.length} chars</span>
    {:else}
      <span class="char-count-placeholder"></span>
    {/if}
    <div class="toolbar-actions">
      <button
        type="button"
        class="check-spelling"
        class:key-pressed={flashState.spelling === "pressed"}
        class:key-denied={flashState.spelling === "denied"}
        title={shortcutTitle("Check spelling", popoverShortcuts.checkSpelling)}
        onclick={handleCheckSpellingClick}
      >
        Check spelling
        {#if showHints && os !== null && popoverShortcuts.checkSpelling}
          <span class="shortcut-badge" aria-hidden="true">
            <Kbd chord={popoverShortcuts.checkSpelling} {os} />
          </span>
        {/if}
      </button>
      <button
        type="button"
        class="pin-button"
        class:active={pinned}
        aria-pressed={pinned}
        aria-label="Pin popover"
        title="Pin popover"
        onclick={() => void handlePinToggle()}
      >
        Pin
      </button>
    </div>
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
    {#each prompts as prompt (prompt.id)}
      <button
        type="button"
        class="action-button"
        class:key-pressed={flashState[`prompt:${prompt.id}`] === "pressed"}
        class:key-denied={flashState[`prompt:${prompt.id}`] === "denied"}
        title={shortcutTitle(prompt.label, prompt.shortcut)}
        disabled={!canRunAction}
        onclick={() => void runAiAction({ kind: "prompt", instruction: prompt.instruction })}
      >
        {prompt.label}
        {#if showHints && os !== null && prompt.shortcut}
          <span class="shortcut-badge" aria-hidden="true">
            <Kbd chord={prompt.shortcut} {os} />
          </span>
        {/if}
      </button>
    {/each}
    <button
      type="button"
      class="action-button"
      class:active={customOpen}
      class:key-pressed={flashState.custom === "pressed"}
      class:key-denied={flashState.custom === "denied"}
      title={shortcutTitle("Custom", popoverShortcuts.customPrompt)}
      disabled={busy}
      onclick={() => void toggleCustom()}
    >
      Custom
      {#if showHints && os !== null && popoverShortcuts.customPrompt}
        <span class="shortcut-badge" aria-hidden="true">
          <Kbd chord={popoverShortcuts.customPrompt} {os} />
        </span>
      {/if}
    </button>
  </div>

  {#if customOpen}
    <div class="custom-row">
      <input
        class="custom-prompt"
        type="text"
        placeholder="Describe what to do…"
        bind:value={customValue}
        bind:this={customInputEl}
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
        class:key-pressed={flashState.replace === "pressed"}
        class:key-denied={flashState.replace === "denied"}
        title={shortcutTitle("Replace", popoverShortcuts.replace)}
        disabled={!canReplace}
        onclick={() => void handleReplaceClick()}
      >
        Replace
        {#if showHints && os !== null && popoverShortcuts.replace}
          <span class="shortcut-badge" aria-hidden="true">
            <Kbd chord={popoverShortcuts.replace} {os} />
          </span>
        {/if}
      </button>
    {/if}
    <button
      type="button"
      class="result-button"
      class:key-pressed={flashState.copy === "pressed"}
      class:key-denied={flashState.copy === "denied"}
      title={shortcutTitle("Copy", popoverShortcuts.copy)}
      disabled={!canCopy}
      onclick={() => void handleCopyClick()}
    >
      {copied ? "Copied ✓" : "Copy"}
      {#if showHints && os !== null && popoverShortcuts.copy}
        <span class="shortcut-badge" aria-hidden="true">
          <Kbd chord={popoverShortcuts.copy} {os} />
        </span>
      {/if}
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

  /* The semi-transparent surface color above relies on macOS's vibrancy
     window effect to actually blur/blend — it's a macOS-only look. X11 has
     no compositor by default (the color would render as garbage without
     one), and WebView2 on Windows has no equivalent vibrancy effect at all,
     so both platforms get the same fully opaque surface instead; macOS is
     untouched. */
  :global(html.platform-linux) .popover,
  :global(html.platform-windows) .popover {
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
    /* Draggable via `onmousedown` (see `handleToolbarMouseDown`) — the
       grab/grabbing cursors are the conventional affordance for that,
       matching what native title bars use. */
    cursor: grab;
  }

  .toolbar:active {
    cursor: grabbing;
  }

  /* The toolbar's own buttons stay clickable with their normal pointer
     cursor — `handleToolbarMouseDown` already excludes them from starting a
     drag, so the cursor should say so too. */
  .toolbar button {
    cursor: pointer;
  }

  .char-count,
  .char-count-placeholder {
    color: var(--color-ash);
    font-size: 11px;
  }

  .toolbar-actions {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .check-spelling {
    position: relative;
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

  .pin-button {
    border: 1px solid transparent;
    border-radius: 4px;
    background: transparent;
    color: var(--color-ash);
    font-size: 11px;
    padding: 2px 6px;
    cursor: pointer;
  }

  .pin-button:hover {
    color: var(--color-marble);
  }

  /* Same highlight treatment as `.action-button.active` below, for the
     same reason: a pressed/active toggle in the palette's "active" accent. */
  .pin-button.active {
    border-color: color-mix(in srgb, var(--color-verdigris) 60%, transparent);
    background-color: color-mix(in srgb, var(--color-verdigris) 18%, transparent);
    color: var(--color-marble);
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
    flex-wrap: wrap;
    gap: 6px;
    max-height: 66px;
    overflow-y: auto;
  }

  .action-button {
    position: relative;
    flex: 1 1 auto;
    min-width: 84px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
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
    position: relative;
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

  /* The hold-⌘-to-see-shortcuts hint: absolutely positioned inside its
     button's own top-right corner (the button is `position: relative`), so
     it never affects layout — important since `.action-row` scrolls and
     must not clip it — and never intercepts the click/keydown the button
     itself handles. */
  .shortcut-badge {
    position: absolute;
    top: 2px;
    right: 2px;
    pointer-events: none;
    line-height: 1;
  }

  /* The visible response to a shortcut press: a quick highlight when it ran
     (`.key-pressed`), or a shake when its guard rejected it (`.key-denied`)
     — both cleared again by `flash()` in the script after ~150ms/~300ms. */
  .key-pressed {
    border-color: var(--color-verdigris);
    background-color: color-mix(in srgb, var(--color-verdigris) 32%, transparent);
  }

  @keyframes key-deny-shake {
    0%,
    100% {
      transform: translateX(0);
    }
    20% {
      transform: translateX(-4px);
    }
    40% {
      transform: translateX(4px);
    }
    60% {
      transform: translateX(-3px);
    }
    80% {
      transform: translateX(3px);
    }
  }

  @media (prefers-reduced-motion: no-preference) {
    .key-denied {
      animation: key-deny-shake 300ms ease-in-out;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .key-denied {
      outline: 2px solid var(--color-attic-clay);
      outline-offset: 1px;
    }
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
  .pin-button,
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
  .pin-button:focus-visible,
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
    .pin-button,
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
    .pin-button:active:not(:disabled),
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
