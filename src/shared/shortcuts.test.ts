import { describe, expect, it } from "vitest";
import { chordFromEvent, formatChord, formatChordText, validateChord } from "./shortcuts";
import type { Os } from "./shortcuts";

describe("chordFromEvent", () => {
  // The reference table for `chordFromEvent`: every row doubles as the
  // contract between the popover's matcher and the recorder, so a live
  // `KeyboardEvent` always means the same chord string wherever it's read.
  const rows: Array<{ name: string; os: Os; init: KeyboardEventInit; expected: string | null }> = [
    {
      name: "macOS: Mod+1 from the printed digit",
      os: "macos",
      init: { key: "1", code: "Digit1", metaKey: true },
      expected: "Mod+1",
    },
    {
      name: "macOS: Mod+Shift+1 from a shifted glyph, derived via code",
      os: "macos",
      init: { key: "!", code: "Digit1", metaKey: true, shiftKey: true },
      expected: "Mod+Shift+1",
    },
    {
      name: "macOS: Mod+Alt+A from an Option-typed glyph, derived via code",
      os: "macos",
      init: { key: "å", code: "KeyA", metaKey: true, altKey: true },
      expected: "Mod+Alt+A",
    },
    {
      name: "macOS: Mod+Z from a German-layout Y/Z swap — event.key wins over event.code",
      os: "macos",
      init: { key: "z", code: "KeyY", metaKey: true },
      expected: "Mod+Z",
    },
    {
      name: "macOS: Mod+Enter",
      os: "macos",
      init: { key: "Enter", metaKey: true },
      expected: "Mod+Enter",
    },
    {
      name: "macOS: Mod+, from punctuation",
      os: "macos",
      init: { key: ",", code: "Comma", metaKey: true },
      expected: "Mod+,",
    },
    {
      name: "macOS: Ctrl alone is not Mod on macOS — unbindable",
      os: "macos",
      init: { key: "a", ctrlKey: true },
      expected: null,
    },
    {
      name: "macOS: Meta pressed alone is a modifier-only press",
      os: "macos",
      init: { key: "Meta", metaKey: true },
      expected: null,
    },
    {
      name: "Windows: AltGr (reported as Ctrl+Alt) never produces a chord",
      os: "windows",
      init: {
        key: "@",
        code: "KeyQ",
        ctrlKey: true,
        altKey: true,
        modifierAltGraph: true,
      },
      expected: null,
    },
    {
      name: "Windows: Mod+Shift+C from Ctrl",
      os: "windows",
      init: { key: "C", ctrlKey: true, shiftKey: true },
      expected: "Mod+Shift+C",
    },
    {
      name: "Linux: a bare F-key needs no Mod",
      os: "linux",
      init: { key: "F6" },
      expected: "F6",
    },
    {
      name: "a repeat never produces a chord",
      os: "macos",
      init: { key: "1", metaKey: true, repeat: true },
      expected: null,
    },
  ];

  for (const { name, os, init, expected } of rows) {
    it(name, () => {
      const event = new KeyboardEvent("keydown", init);
      expect(chordFromEvent(event, os)).toBe(expected);
    });
  }

  it("never produces a chord mid-IME-composition", () => {
    const event = new KeyboardEvent("keydown", { key: "a", metaKey: true, isComposing: true });
    expect(chordFromEvent(event, "macos")).toBeNull();
  });

  it("an unrelated modifier-only key (e.g. CapsLock) never produces a chord", () => {
    const event = new KeyboardEvent("keydown", { key: "CapsLock" });
    expect(chordFromEvent(event, "macos")).toBeNull();
  });

  it("a plain letter with no modifier still resolves (grammar validity is a separate concern)", () => {
    // `chordFromEvent` is not the place that rejects a chord for failing
    // `validateChord`'s "needs Mod" rule — a bare keystroke while typing
    // must still resolve to *some* chord string so the popover's matcher
    // can look it up (and, finding no binding for it, leave it alone).
    const event = new KeyboardEvent("keydown", { key: "l" });
    expect(chordFromEvent(event, "macos")).toBe("L");
  });
});

describe("formatChord / formatChordText", () => {
  it("renders macOS tokens with symbols and the Enter glyph", () => {
    expect(formatChord("Mod+Shift+Enter", "macos")).toEqual(["⌘", "⇧", "↩"]);
  });

  it("renders Windows/Linux tokens spelled out", () => {
    expect(formatChord("Mod+Shift+C", "windows")).toEqual(["Ctrl", "Shift", "C"]);
    expect(formatChord("Mod+Alt+F6", "linux")).toEqual(["Ctrl", "Alt", "F6"]);
  });

  it("joins macOS tokens with no separator and other platforms with +", () => {
    expect(formatChordText("Mod+Shift+C", "macos")).toBe("⌘⇧C");
    expect(formatChordText("Mod+Shift+C", "windows")).toBe("Ctrl+Shift+C");
  });

  it("returns no tokens for an unparseable chord", () => {
    expect(formatChord("not a chord", "macos")).toEqual([]);
  });
});

describe("validateChord", () => {
  it("requires Mod unless the key is a bare function key", () => {
    expect(validateChord("L", "macos")).toBe(
      "Add ⌘ — plain keys would get in the way of typing.",
    );
    expect(validateChord("Shift+L", "windows")).toBe(
      "Add Ctrl — plain keys would get in the way of typing.",
    );
    expect(validateChord("F6", "macos")).toBeNull();
    expect(validateChord("Shift+F6", "macos")).toBeNull();
  });

  it("rejects every reserved chord with the matching platform-formatted reason", () => {
    expect(validateChord("Mod+C", "macos")).toBe("⌘C is reserved for copying text.");
    expect(validateChord("Mod+C", "windows")).toBe("Ctrl+C is reserved for copying text.");
    expect(validateChord("Mod+Shift+Z", "macos")).toBe("⌘⇧Z is reserved for redo.");
    expect(validateChord("Mod+Y", "windows")).toBe("Ctrl+Y is reserved for redo.");
    expect(validateChord("F12", "macos")).toBe("F12 is reserved for developer tools.");
  });

  it("accepts a free, valid chord", () => {
    expect(validateChord("Mod+9", "macos")).toBeNull();
    expect(validateChord("mod+shift+s", "windows")).toBeNull();
  });

  it("rejects malformed input with the same messages core/shortcuts.rs uses", () => {
    expect(validateChord("", "macos")).toBe("A shortcut can't be empty.");
    expect(validateChord("Mod+!", "macos")).toBe('"!" isn\'t a bindable key.');
    expect(validateChord("Mod+Space", "macos")).toBe('"Space" isn\'t a bindable key.');
    expect(validateChord("Mod+L+C", "macos")).toBe("A shortcut can only have one key.");
    expect(validateChord("Mod+Shift", "macos")).toBe("A shortcut needs a key.");
  });
});
