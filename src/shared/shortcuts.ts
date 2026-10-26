/**
 * The popover's keyboard-shortcut grammar, entirely in the frontend's own
 * terms: `chordFromEvent` is the one place a `KeyboardEvent` turns into a
 * chord string, shared by everything that records or matches shortcuts, so
 * they can never disagree about what a keystroke means. Alongside it:
 * turning a chord string into display tokens (`formatChord`/
 * `formatChordText`), and checking a chord against the same rules
 * `src-tauri/src/core/shortcuts.rs` enforces (`validateChord`) so instant
 * feedback never needs a round trip. The stored grammar itself —
 * `[Mod+][Alt+][Shift+]Key`, `Mod` meaning ⌘ on macOS and Ctrl elsewhere —
 * is defined there; this module mirrors it rather than owning it, and the
 * Rust side stays authoritative for anything actually written to disk.
 *
 * The global shortcut lives in a second, overlapping grammar — a Tauri
 * accelerator string rather than a popover chord, because that's what the
 * OS itself parses — so it gets its own event-to-string direction
 * (`acceleratorFromEvent`), its own display tokens (`formatAccelerator`),
 * and a bridge back into chord space (`chordFromAccelerator`, mirroring
 * `chord_for_global`) so the two grammars can still be compared. `holderOf`/
 * `holderOfAccelerator`/`describeTarget`/`nextFreePromptShortcut` are the
 * instant-feedback mirrors of the equivalent Rust lookups, used by
 * `ShortcutRecorder.svelte` and (eventually) the Shortcuts tab.
 */

import type { PlatformInfo, Settings, ShortcutTarget } from "./types";

export type Os = PlatformInfo["os"];

/** A parsed chord: `key` is already canonical (`A`-`Z`, `0`-`9`, `F1`-`F12`,
 * `Enter`, or one of `BINDABLE_PUNCTUATION`). */
export interface Chord {
  mod: boolean;
  alt: boolean;
  shift: boolean;
  key: string;
}

/** Keys that only ever show up as modifiers themselves — pressing one alone
 * can never be the key half of a chord. */
const MODIFIER_ONLY_KEYS = new Set([
  "Meta",
  "Control",
  "Alt",
  "Shift",
  "AltGraph",
  "CapsLock",
  "Hyper",
  "Super",
  "OS",
  "ScrollLock",
  "NumLock",
  "Fn",
  "FnLock",
  "Symbol",
  "SymbolLock",
]);

/** The same closed set `is_bindable_punctuation` in `core/shortcuts.rs`
 * accepts — see that function's doc comment for why it's closed rather than
 * "every ASCII punctuation character". */
const BINDABLE_PUNCTUATION = new Set([
  ",",
  ".",
  "-",
  "=",
  ";",
  "'",
  "/",
  "\\",
  "[",
  "]",
  "`",
  "#",
  "<",
]);

function stringifyChord(mod: boolean, alt: boolean, shift: boolean, key: string): string {
  const parts: string[] = [];
  if (mod) parts.push("Mod");
  if (alt) parts.push("Alt");
  if (shift) parts.push("Shift");
  parts.push(key);
  return parts.join("+");
}

/** Resolves the key half of a live `keydown` into its canonical token, or
 * `null` when the event can't be expressed in the chord grammar at all. See
 * this module's doc comment and `chordFromEvent` for the resolution order. */
function resolveKeyToken(event: KeyboardEvent): string | null {
  const key = event.key;
  if (key.length === 1 && /[a-zA-Z0-9]/.test(key)) {
    return key.toUpperCase();
  }

  const code = event.code ?? "";
  const letterMatch = /^Key([A-Z])$/.exec(code);
  if (letterMatch) return letterMatch[1]!;
  const digitMatch = /^Digit([0-9])$/.exec(code);
  if (digitMatch) return digitMatch[1]!;

  if (key === "Enter") return "Enter";
  if (/^F([1-9]|1[0-2])$/.test(key)) return key;

  if (BINDABLE_PUNCTUATION.has(key) && !event.shiftKey && !event.altKey) return key;

  return null;
}

/**
 * The only place a `KeyboardEvent` becomes a chord string — shared by the
 * popover's matcher and the shortcut recorder so recording and matching can
 * never disagree. Returns `null` for anything that can't be a
 * shortcut: a modifier pressed on its own, a held-down repeat, mid-IME
 * composition, AltGraph (Windows reports AltGr as Ctrl+Alt — without this
 * check a Ctrl+Alt+Q shortcut would eat every @ typed on a German layout),
 * the wrong platform's modifier for "Mod", or a key the grammar has no token
 * for. Does *not* reject a chord that would fail `validateChord` (e.g. a
 * bare letter with no `Mod`) — that's a stored-bindings-only concern, and
 * rejecting it here would make it impossible to ever notice such a chord was
 * pressed.
 */
export function chordFromEvent(event: KeyboardEvent, os: Os): string | null {
  if (event.repeat || event.isComposing) return null;
  if (event.getModifierState?.("AltGraph")) return null;
  if (MODIFIER_ONLY_KEYS.has(event.key)) return null;

  const wrongMod = os === "macos" ? event.ctrlKey : event.metaKey;
  if (wrongMod) return null;

  const mod = os === "macos" ? event.metaKey : event.ctrlKey;
  const key = resolveKeyToken(event);
  if (key === null) return null;

  return stringifyChord(mod, event.altKey, event.shiftKey, key);
}

interface ParseSuccess {
  ok: true;
  chord: Chord;
}

interface ParseFailure {
  ok: false;
  error: string;
}

function parseKeyToken(token: string): string | null {
  if (token.length === 1) {
    if (/[a-zA-Z]/.test(token)) return token.toUpperCase();
    if (/[0-9]/.test(token)) return token;
    if (BINDABLE_PUNCTUATION.has(token)) return token;
    return null;
  }

  if (token.toLowerCase() === "enter") return "Enter";

  if (/^f\d+$/i.test(token)) {
    const n = Number(token.slice(1));
    if (n >= 1 && n <= 12) return `F${n}`;
  }

  return null;
}

/** Parses a stored (or candidate) shortcut string, mirroring `Chord::parse`
 * in `core/shortcuts.rs` closely enough to raise the exact same class of
 * error — modifier tokens case-insensitive and in any order, exactly one key
 * token required. */
function parseChordDetailed(raw: string): ParseSuccess | ParseFailure {
  if (raw.trim() === "") {
    return { ok: false, error: "A shortcut can't be empty." };
  }

  let mod = false;
  let alt = false;
  let shift = false;
  let key: string | null = null;

  for (const part of raw.split("+")) {
    if (part === "") {
      return { ok: false, error: `"${raw}" isn't a valid shortcut.` };
    }
    switch (part.toLowerCase()) {
      case "mod":
        mod = true;
        break;
      case "alt":
        alt = true;
        break;
      case "shift":
        shift = true;
        break;
      default: {
        if (key !== null) {
          return { ok: false, error: "A shortcut can only have one key." };
        }
        const parsed = parseKeyToken(part);
        if (parsed === null) {
          return { ok: false, error: `"${part}" isn't a bindable key.` };
        }
        key = parsed;
      }
    }
  }

  if (key === null) {
    return { ok: false, error: "A shortcut needs a key." };
  }
  return { ok: true, chord: { mod, alt, shift, key } };
}

/** Parses a stored shortcut string into a `Chord`, or `null` if it isn't
 * one — the detailed reason is only needed by `validateChord`. */
export function parseChord(raw: string): Chord | null {
  const result = parseChordDetailed(raw);
  return result.ok ? result.chord : null;
}

/** Re-renders `raw` in the canonical `[Mod+][Alt+][Shift+]Key` form, or
 * `null` if it doesn't parse — the same canonicalization `Chord`'s `Display`
 * impl does on the Rust side. */
export function canonicalizeChord(raw: string): string | null {
  const chord = parseChord(raw);
  if (!chord) return null;
  return stringifyChord(chord.mod, chord.alt, chord.shift, chord.key);
}

/**
 * Display tokens for `chord` on `os` — macOS: `⌘ ⌥ ⇧` plus `↩` for Enter,
 * joined directly against each other by `Kbd.svelte`; elsewhere: `Ctrl`,
 * `Alt`, `Shift`, `Enter`, joined with `+`. Returns `[]` for an unparseable
 * chord (nothing sensible to show).
 */
export function formatChord(chord: string, os: Os): string[] {
  const parsed = parseChord(chord);
  if (!parsed) return [];

  const tokens: string[] = [];
  if (os === "macos") {
    if (parsed.mod) tokens.push("⌘");
    if (parsed.alt) tokens.push("⌥");
    if (parsed.shift) tokens.push("⇧");
    tokens.push(parsed.key === "Enter" ? "↩" : parsed.key);
  } else {
    if (parsed.mod) tokens.push("Ctrl");
    if (parsed.alt) tokens.push("Alt");
    if (parsed.shift) tokens.push("Shift");
    tokens.push(parsed.key);
  }
  return tokens;
}

/** `formatChord`'s tokens joined the way this OS reads them: no separator on
 * macOS (`⌘⇧C`), `+` everywhere else (`Ctrl+Shift+C`). */
export function formatChordText(chord: string, os: Os): string {
  const tokens = formatChord(chord, os);
  return os === "macos" ? tokens.join("") : tokens.join("+");
}

function modSymbol(os: Os): string {
  return os === "macos" ? "⌘" : "Ctrl";
}

interface ReservedRule {
  mod: boolean;
  alt: boolean;
  shift: boolean;
  key: string;
  reason: string;
}

/** Mirrors `reserved_reason` in `core/shortcuts.rs`: text editing, macOS
 * system shortcuts, and webview accelerators, reserved on every platform so
 * a stored setting stays portable across machines. */
const RESERVED: ReservedRule[] = [
  { mod: true, alt: false, shift: false, key: "C", reason: "is reserved for copying text." },
  { mod: true, alt: false, shift: false, key: "V", reason: "is reserved for pasting text." },
  { mod: true, alt: false, shift: false, key: "X", reason: "is reserved for cutting text." },
  { mod: true, alt: false, shift: false, key: "A", reason: "is reserved for select all." },
  { mod: true, alt: false, shift: false, key: "Z", reason: "is reserved for undo." },
  { mod: true, alt: false, shift: true, key: "Z", reason: "is reserved for redo." },
  { mod: true, alt: false, shift: false, key: "Y", reason: "is reserved for redo." },
  { mod: true, alt: false, shift: false, key: "Q", reason: "is reserved for quitting." },
  { mod: true, alt: false, shift: false, key: "W", reason: "is reserved for closing the window." },
  { mod: true, alt: false, shift: false, key: "H", reason: "is reserved for hiding the app." },
  { mod: true, alt: false, shift: false, key: "M", reason: "is reserved for minimizing the window." },
  { mod: true, alt: false, shift: false, key: "R", reason: "is reserved for reloading." },
  { mod: true, alt: false, shift: false, key: "P", reason: "is reserved for printing." },
  { mod: true, alt: false, shift: false, key: "F", reason: "is reserved for find." },
  { mod: true, alt: false, shift: false, key: "G", reason: "is reserved for find next." },
  { mod: false, alt: false, shift: false, key: "F5", reason: "is reserved for reloading." },
  { mod: false, alt: false, shift: false, key: "F7", reason: "is reserved for spell-check." },
  { mod: false, alt: false, shift: false, key: "F12", reason: "is reserved for developer tools." },
];

function validateParsedChord(chord: Chord, os: Os): string | null {
  const isFunctionKey = /^F\d+$/.test(chord.key);
  if (!chord.mod && !isFunctionKey) {
    return `Add ${modSymbol(os)} — plain keys would get in the way of typing.`;
  }

  const reserved = RESERVED.find(
    (rule) =>
      rule.mod === chord.mod &&
      rule.alt === chord.alt &&
      rule.shift === chord.shift &&
      rule.key === chord.key,
  );
  if (reserved) {
    const display = stringifyChord(chord.mod, chord.alt, chord.shift, chord.key);
    return `${formatChordText(display, os)} ${reserved.reason}`;
  }

  return null;
}

/**
 * Validates `raw` against the chord grammar and the reserved list — the
 * same rules `validate` (plus `Chord::parse`) applies in
 * `core/shortcuts.rs`, with the same user-facing messages, for instant
 * feedback before a round trip. Returns the reason it's rejected, or `null`
 * if it's fine. Doesn't check conflicts with other shortcuts or the global
 * shortcut — that's `holderOf`'s job, once the settings recorder needs it.
 */
export function validateChord(raw: string, os: Os): string | null {
  const result = parseChordDetailed(raw);
  if (!result.ok) return result.error;
  return validateParsedChord(result.chord, os);
}

/**
 * Maps `event.code` (the *physical* key) to the token
 * `acceleratorFromEvent` emits for it: `KeyA`-`KeyZ` to a bare letter,
 * `Digit0`-`Digit9` to a bare digit, `F1`-`F12`/`Enter`/`Space` as
 * themselves, and the punctuation codes Tauri's own parser already
 * recognizes by name, emitted unchanged. Anything else (arrows, Tab,
 * Escape, …) has no accelerator token and returns `null`.
 */
const ACCELERATOR_PUNCTUATION_CODES = new Set([
  "Comma",
  "Period",
  "Minus",
  "Equal",
  "Semicolon",
  "Quote",
  "Slash",
  "Backslash",
  "BracketLeft",
  "BracketRight",
  "Backquote",
]);

function acceleratorKeyFromCode(code: string): string | null {
  const letterMatch = /^Key([A-Z])$/.exec(code);
  if (letterMatch) return letterMatch[1]!;
  const digitMatch = /^Digit([0-9])$/.exec(code);
  if (digitMatch) return digitMatch[1]!;
  if (/^F([1-9]|1[0-2])$/.test(code)) return code;
  if (code === "Enter" || code === "Space") return code;
  if (ACCELERATOR_PUNCTUATION_CODES.has(code)) return code;
  return null;
}

/**
 * Records the **global** shortcut from a live `keydown`, in Tauri's
 * accelerator format (`Ctrl+Alt+Shift+Cmd+K` order, `Cmd` only on macOS) —
 * the counterpart to `chordFromEvent` for the one shortcut the OS itself
 * matches rather than the popover. The OS matches a registered global
 * shortcut on *physical* keys, so unlike `chordFromEvent` the key always
 * comes from `event.code`, never `event.key` — this is also why, on
 * non-macOS, `metaKey` (the Windows/Super key) is never allowed: there is no
 * accelerator token for it at all, not even one that would simply go
 * unmatched.
 *
 * Deliberately does *not* reject `event.getModifierState("AltGraph")` the
 * way `chordFromEvent` does: on a German (or other AltGr) Windows layout,
 * physically pressing Ctrl+Alt reports `AltGraph` as part of the event, and
 * `Ctrl+Alt+K` is the non-macOS default global shortcut. Rejecting AltGraph
 * here would make that default impossible to ever (re-)record on such a
 * layout — the popover's own chords stay AltGraph-sensitive (see
 * `chordFromEvent`'s doc comment) because *that* rejection protects typing;
 * nothing is typed into the global shortcut.
 */
export function acceleratorFromEvent(event: KeyboardEvent, os: Os): string | null {
  if (event.repeat || event.isComposing) return null;
  if (MODIFIER_ONLY_KEYS.has(event.key)) return null;
  if (os !== "macos" && event.metaKey) return null;

  const key = acceleratorKeyFromCode(event.code ?? "");
  if (key === null) return null;

  const cmd = os === "macos" && event.metaKey;
  if (!event.ctrlKey && !event.altKey && !cmd) return null;

  const parts: string[] = [];
  if (event.ctrlKey) parts.push("Ctrl");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  if (cmd) parts.push("Cmd");
  parts.push(key);
  return parts.join("+");
}

/** The punctuation character a global-accelerator token names, keyed by its
 * lowercased name — shared by `formatAccelerator` (as a display character)
 * and `chordFromAccelerator` (as a chord's `Punct` key), the same way
 * `parse_global_key` in `core/shortcuts.rs` recognizes them. */
const ACCELERATOR_PUNCTUATION: Record<string, string> = {
  comma: ",",
  period: ".",
  minus: "-",
  equal: "=",
  semicolon: ";",
  quote: "'",
  slash: "/",
  backslash: "\\",
  bracketleft: "[",
  bracketright: "]",
  backquote: "`",
};

interface AcceleratorKeyToken {
  kind: "letter" | "digit" | "function" | "enter" | "space" | "punct";
  value: string;
}

/** Parses one non-modifier accelerator token (`K`, `KeyK`, `1`, `Digit1`,
 * `F6`, `Comma`, `Enter`/`Return`, `Space`, …), mirroring
 * `parse_global_key` in `core/shortcuts.rs` closely enough to agree on
 * every token it recognizes — `kind` additionally distinguishes `Enter`
 * (→ `↩` on macOS) and `Space` (never a chord key) for `formatAccelerator`
 * and `chordFromAccelerator` respectively. */
function parseAcceleratorKeyToken(token: string): AcceleratorKeyToken | null {
  const lower = token.toLowerCase();
  if (lower === "enter" || lower === "return") return { kind: "enter", value: "Enter" };
  if (lower === "space") return { kind: "space", value: "Space" };

  const letterMatch = /^key([a-z])$/i.exec(token);
  if (letterMatch) return { kind: "letter", value: letterMatch[1]!.toUpperCase() };
  const digitMatch = /^digit([0-9])$/i.exec(token);
  if (digitMatch) return { kind: "digit", value: digitMatch[1]! };
  const functionMatch = /^f([1-9]|1[0-2])$/i.exec(token);
  if (functionMatch) return { kind: "function", value: `F${functionMatch[1]}` };

  if (token.length === 1) {
    if (/[a-zA-Z]/.test(token)) return { kind: "letter", value: token.toUpperCase() };
    if (/[0-9]/.test(token)) return { kind: "digit", value: token };
  }

  if (lower in ACCELERATOR_PUNCTUATION) {
    return { kind: "punct", value: ACCELERATOR_PUNCTUATION[lower]! };
  }

  return null;
}

/**
 * Display tokens for a stored Tauri accelerator string — the
 * `acceleratorFromEvent` counterpart to `formatChord`, for the global
 * shortcut row. Tokens are case-insensitive; `Cmd`/`Command`/`Super`/`Meta`/
 * `CmdOrCtrl`/`CommandOrControl` are all accepted as the "super" modifier
 * family, `Ctrl`/`Control` as the literal Ctrl key, `Alt`/`Option` as Alt —
 * `CmdOrCtrl`/`CommandOrControl` additionally collapse onto whichever one
 * this OS would actually show (⌘ on macOS, Ctrl elsewhere), since the user
 * never sees the platform-neutral spelling, only what their own OS does
 * with it. Returns `[accelerator]` unchanged when it doesn't parse — there
 * is nothing sensible to tokenize, but something must still be shown.
 */
export function formatAccelerator(accelerator: string, os: Os): string[] {
  const macos = os === "macos";
  let ctrl = false;
  let alt = false;
  let shift = false;
  let superMod = false;
  let key: AcceleratorKeyToken | null = null;

  for (const token of accelerator.split("+")) {
    if (token === "") return [accelerator];
    switch (token.toLowerCase()) {
      case "cmdorctrl":
      case "commandorcontrol":
        if (macos) superMod = true;
        else ctrl = true;
        break;
      case "cmd":
      case "command":
      case "super":
      case "meta":
        superMod = true;
        break;
      case "ctrl":
      case "control":
        ctrl = true;
        break;
      case "alt":
      case "option":
        alt = true;
        break;
      case "shift":
        shift = true;
        break;
      default: {
        if (key !== null) return [accelerator];
        const parsed = parseAcceleratorKeyToken(token);
        if (parsed === null) return [accelerator];
        key = parsed;
      }
    }
  }

  if (key === null) return [accelerator];

  const tokens: string[] = [];
  if (macos) {
    if (ctrl) tokens.push("⌃");
    if (alt) tokens.push("⌥");
    if (shift) tokens.push("⇧");
    if (superMod) tokens.push("⌘");
    tokens.push(key.kind === "enter" ? "↩" : key.value);
  } else {
    if (ctrl) tokens.push("Ctrl");
    if (alt) tokens.push("Alt");
    if (shift) tokens.push("Shift");
    if (superMod) tokens.push("Super");
    tokens.push(key.value);
  }
  return tokens;
}

/**
 * TS mirror of `chord_for_global` in `core/shortcuts.rs`: maps a global
 * accelerator string onto the same canonical chord space `parseChord`
 * occupies for the current OS, so "equals the global shortcut" is a chord
 * comparison rather than a string one. `CmdOrCtrl`/`CommandOrControl` always
 * become `Mod`, since both platforms have *some* key for it; a literal
 * `Cmd`/`Super`/`Meta` only becomes `Mod` on macOS (elsewhere there is no
 * popover equivalent for the Super key), and a literal `Ctrl`/`Control`
 * only becomes `Mod` off macOS (macOS ⌃ has no popover equivalent either) —
 * in both of those cases this returns `null`, not a chord with `mod: false`,
 * because the accelerator still names a real, distinct modifier that must
 * never silently collapse onto a popover chord that omits it.
 */
export function chordFromAccelerator(accelerator: string, os: Os): string | null {
  const macos = os === "macos";
  let mod = false;
  let alt = false;
  let shift = false;
  let key: string | null = null;

  for (const token of accelerator.split("+")) {
    if (token === "") return null;
    switch (token.toLowerCase()) {
      case "cmdorctrl":
      case "commandorcontrol":
        mod = true;
        break;
      case "cmd":
      case "command":
      case "super":
      case "meta":
        if (!macos) return null;
        mod = true;
        break;
      case "ctrl":
      case "control":
        if (macos) return null;
        mod = true;
        break;
      case "alt":
      case "option":
        alt = true;
        break;
      case "shift":
        shift = true;
        break;
      default: {
        if (key !== null) return null;
        const parsed = parseAcceleratorKeyToken(token);
        if (parsed === null || parsed.kind === "space") return null;
        key = parsed.value;
      }
    }
  }

  if (key === null) return null;
  return stringifyChord(mod, alt, shift, key);
}

/** The popover-action half of `ShortcutTarget["action"]`, listed once so
 * `holderOf`/`holderOfAccelerator`/`nextFreePromptShortcut` all walk the
 * same five slots in the same order. */
const POPOVER_ACTIONS = [
  "replace",
  "copy",
  "customPrompt",
  "openSettings",
  "checkSpelling",
] as const;

const ACTION_LABELS: Record<(typeof POPOVER_ACTIONS)[number], string> = {
  replace: "Replace",
  copy: "Copy",
  customPrompt: "Custom prompt",
  openSettings: "Open Settings",
  checkSpelling: "Check spelling",
};

function targetsEqual(a: ShortcutTarget, b: ShortcutTarget): boolean {
  if (a.kind === "action" && b.kind === "action") return a.action === b.action;
  if (a.kind === "prompt" && b.kind === "prompt") return a.id === b.id;
  return a.kind === "global" && b.kind === "global";
}

/**
 * The display name for whatever `target` points at — a popover action's
 * fixed label, a prompt's own label (or "a prompt" if it no longer exists),
 * or "Open Kallilex" for the global shortcut. Used by the recorder for
 * conflict messages and by the Shortcuts tab for row labels.
 */
export function describeTarget(settings: Settings, target: ShortcutTarget): string {
  switch (target.kind) {
    case "action":
      return ACTION_LABELS[target.action];
    case "prompt":
      return settings.prompts.find((p) => p.id === target.id)?.label ?? "a prompt";
    case "global":
      return "Open Kallilex";
  }
}

/**
 * Whichever target currently holds `chord` — a popover action, a prompt, or
 * the global shortcut (via `chordFromAccelerator`, not a string comparison)
 * — or `null` if it's free. Stored values are compared canonically
 * (`canonicalizeChord`), so a differently-ordered or differently-cased
 * stored string still counts as the same chord; a stored value that doesn't
 * parse at all is silently skipped rather than reported as a holder, same
 * as the Rust side. `exclude` is the target being edited — it must never
 * conflict with its own current value.
 */
export function holderOf(
  settings: Settings,
  chord: string,
  os: Os,
  exclude?: ShortcutTarget,
): ShortcutTarget | null {
  const canonical = canonicalizeChord(chord);
  if (!canonical) return null;

  for (const action of POPOVER_ACTIONS) {
    const target: ShortcutTarget = { kind: "action", action };
    if (exclude && targetsEqual(exclude, target)) continue;
    const raw = settings.popoverShortcuts[action];
    if (raw !== null && canonicalizeChord(raw) === canonical) return target;
  }

  for (const prompt of settings.prompts) {
    const target: ShortcutTarget = { kind: "prompt", id: prompt.id };
    if (exclude && targetsEqual(exclude, target)) continue;
    if (prompt.shortcut !== null && canonicalizeChord(prompt.shortcut) === canonical) return target;
  }

  const globalTarget: ShortcutTarget = { kind: "global" };
  if (!(exclude && targetsEqual(exclude, globalTarget))) {
    if (chordFromAccelerator(settings.shortcut, os) === canonical) return globalTarget;
  }

  return null;
}

/**
 * Which popover action or prompt the *global* accelerator `accelerator`
 * would collide with, were it saved — the recorder for the global shortcut
 * needs this instead of `holderOf` because the candidate it records is an
 * accelerator string, not a chord, and because the global shortcut can
 * never conflict with itself. Returns `null` when the accelerator doesn't
 * map into chord space at all (nothing to collide with) or nothing holds
 * it.
 */
export function holderOfAccelerator(
  settings: Settings,
  accelerator: string,
  os: Os,
): ShortcutTarget | null {
  const chord = chordFromAccelerator(accelerator, os);
  if (chord === null) return null;

  for (const action of POPOVER_ACTIONS) {
    const raw = settings.popoverShortcuts[action];
    if (raw !== null && canonicalizeChord(raw) === chord) return { kind: "action", action };
  }
  for (const prompt of settings.prompts) {
    if (prompt.shortcut !== null && canonicalizeChord(prompt.shortcut) === chord) {
      return { kind: "prompt", id: prompt.id };
    }
  }
  return null;
}

/**
 * The first of `Mod+1`…`Mod+9` that `holderOf` reports free — what a newly
 * created prompt is pre-filled with, and `null` once all nine are taken (a
 * new prompt then simply starts unbound).
 */
export function nextFreePromptShortcut(settings: Settings, os: Os): string | null {
  for (let n = 1; n <= 9; n++) {
    const candidate = `Mod+${n}`;
    if (holderOf(settings, candidate, os) === null) return candidate;
  }
  return null;
}

/**
 * A non-blocking warning for an otherwise-valid chord, shown alongside a
 * successful commit rather than instead of one. Linux-only today:
 * `Mod+Alt+F1`-`F12` is allowed (see `core/shortcuts.rs`'s rules) but many
 * desktops reserve Ctrl+Alt+F-keys for switching virtual terminals, so a
 * user binding one should at least know why it might not reach Kallilex.
 */
export function shortcutWarning(chord: string, os: Os): string | null {
  if (os !== "linux") return null;
  const parsed = parseChord(chord);
  if (!parsed) return null;
  if (parsed.mod && parsed.alt && !parsed.shift && /^F([1-9]|1[0-2])$/.test(parsed.key)) {
    return "Many Linux desktops use Ctrl+Alt+F-keys to switch virtual terminals.";
  }
  return null;
}
