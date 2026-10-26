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
 */

import type { PlatformInfo } from "./types";

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
