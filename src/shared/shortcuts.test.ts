import { describe, expect, it } from "vitest";
import {
  acceleratorFromEvent,
  chordFromAccelerator,
  chordFromEvent,
  describeTarget,
  formatAccelerator,
  formatChord,
  formatChordText,
  holderOf,
  holderOfAccelerator,
  nextFreePromptShortcut,
  shortcutWarning,
  validateChord,
} from "./shortcuts";
import type { Os } from "./shortcuts";
import type { CustomPrompt, Settings, ShortcutTarget } from "./types";

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

describe("acceleratorFromEvent", () => {
  // The global recorder's own reference table — note the key always comes
  // from `event.code`, never `event.key`, since the OS matches a global
  // shortcut on the physical key.
  const rows: Array<{ name: string; os: Os; init: KeyboardEventInit; expected: string | null }> = [
    {
      name: "macOS default: Alt+Cmd+K",
      os: "macos",
      init: { key: "k", code: "KeyK", metaKey: true, altKey: true },
      expected: "Alt+Cmd+K",
    },
    {
      name: "Windows/Linux default: Ctrl+Alt+K, even flagged AltGraph on an AltGr layout",
      os: "windows",
      init: {
        key: "k",
        code: "KeyK",
        ctrlKey: true,
        altKey: true,
        modifierAltGraph: true,
      },
      expected: "Ctrl+Alt+K",
    },
    {
      name: "a digit comes from the physical code, not the printed glyph",
      os: "linux",
      init: { key: "1", code: "Digit1", ctrlKey: true },
      expected: "Ctrl+1",
    },
    {
      name: "a punctuation code is emitted by name, unchanged",
      os: "windows",
      init: { key: ",", code: "Comma", ctrlKey: true },
      expected: "Ctrl+Comma",
    },
    {
      name: "a bare function key still needs Alt to have any modifier at all",
      os: "linux",
      init: { key: "F6", code: "F6", altKey: true },
      expected: "Alt+F6",
    },
    {
      name: "Shift alone is not enough — Ctrl/Alt/Cmd is required",
      os: "windows",
      init: { key: "K", code: "KeyK", shiftKey: true },
      expected: null,
    },
    {
      name: "the Windows/Super key is never allowed off macOS",
      os: "windows",
      init: { key: "K", code: "KeyK", metaKey: true, ctrlKey: true },
      expected: null,
    },
    {
      name: "a modifier pressed alone produces nothing",
      os: "macos",
      init: { key: "Control", metaKey: false },
      expected: null,
    },
    {
      name: "a repeat never produces an accelerator",
      os: "macos",
      init: { key: "k", code: "KeyK", metaKey: true, repeat: true },
      expected: null,
    },
  ];

  for (const { name, os, init, expected } of rows) {
    it(name, () => {
      const event = new KeyboardEvent("keydown", init);
      expect(acceleratorFromEvent(event, os)).toBe(expected);
    });
  }

  it("on macOS, Cmd maps to the literal Cmd token, not Mod", () => {
    const event = new KeyboardEvent("keydown", { key: "l", code: "KeyL", metaKey: true });
    expect(acceleratorFromEvent(event, "macos")).toBe("Cmd+L");
  });
});

describe("formatAccelerator", () => {
  it("formats the macOS default with symbols", () => {
    expect(formatAccelerator("Alt+Cmd+K", "macos")).toEqual(["⌥", "⌘", "K"]);
  });

  it("formats the Windows/Linux default spelled out", () => {
    expect(formatAccelerator("Ctrl+Alt+K", "windows")).toEqual(["Ctrl", "Alt", "K"]);
  });

  it("resolves CmdOrCtrl per platform", () => {
    expect(formatAccelerator("CmdOrCtrl+Comma", "macos")).toEqual(["⌘", ","]);
    expect(formatAccelerator("CmdOrCtrl+Comma", "windows")).toEqual(["Ctrl", ","]);
  });

  it("renders Enter as the glyph on macOS and spelled out elsewhere", () => {
    expect(formatAccelerator("CmdOrCtrl+Enter", "macos")).toEqual(["⌘", "↩"]);
    expect(formatAccelerator("CmdOrCtrl+Enter", "windows")).toEqual(["Ctrl", "Enter"]);
  });

  it("accepts Key-/Digit-prefixed tokens the same as bare ones", () => {
    expect(formatAccelerator("CmdOrCtrl+KeyK", "macos")).toEqual(["⌘", "K"]);
    expect(formatAccelerator("CmdOrCtrl+Digit1", "macos")).toEqual(["⌘", "1"]);
  });

  it("returns the raw string as a single token when it doesn't parse", () => {
    expect(formatAccelerator("not a real accelerator", "macos")).toEqual([
      "not a real accelerator",
    ]);
  });
});

describe("chordFromAccelerator", () => {
  it("maps the platform default to Mod+Alt+K on every OS", () => {
    expect(chordFromAccelerator("Alt+Cmd+K", "macos")).toBe("Mod+Alt+K");
    expect(chordFromAccelerator("Ctrl+Alt+K", "windows")).toBe("Mod+Alt+K");
    expect(chordFromAccelerator("Ctrl+Alt+K", "linux")).toBe("Mod+Alt+K");
  });

  it("macOS Ctrl has no popover equivalent", () => {
    expect(chordFromAccelerator("Ctrl+K", "macos")).toBeNull();
  });

  it("the Super/Meta/Cmd key has no popover equivalent off macOS", () => {
    expect(chordFromAccelerator("Super+K", "windows")).toBeNull();
    expect(chordFromAccelerator("Meta+K", "linux")).toBeNull();
  });

  it("CmdOrCtrl always maps to Mod, on every OS", () => {
    expect(chordFromAccelerator("CmdOrCtrl+Comma", "macos")).toBe("Mod+,");
    expect(chordFromAccelerator("CmdOrCtrl+Comma", "windows")).toBe("Mod+,");
  });

  it("recognizes Key-/Digit-/F-prefixed tokens", () => {
    expect(chordFromAccelerator("CmdOrCtrl+KeyK", "macos")).toBe("Mod+K");
    expect(chordFromAccelerator("CmdOrCtrl+Digit1", "macos")).toBe("Mod+1");
    expect(chordFromAccelerator("CmdOrCtrl+F6", "macos")).toBe("Mod+F6");
  });

  it("Space has no chord equivalent", () => {
    expect(chordFromAccelerator("CmdOrCtrl+Space", "macos")).toBeNull();
  });
});

// ---- Settings-aware helpers --------------------------------------------

function prompt(id: string, label: string, shortcut: string | null): CustomPrompt {
  return { id, label, instruction: "Do something.", shortcut };
}

function settingsWith(overrides: Partial<Settings> = {}): Settings {
  return {
    activeProfileId: null,
    shortcut: "Alt+Cmd+K",
    spellcheckEnabled: true,
    popoverPinned: false,
    accessibilityOnboardingShown: false,
    profiles: [],
    waylandRestoreToken: null,
    inputSynthesisEnabled: true,
    autoCopyResult: false,
    onboardingCompleted: false,
    popoverPosition: null,
    prompts: [
      prompt("a", "Rewrite", "Mod+1"),
      prompt("b", "Shorten", "Mod+2"),
      prompt("c", "Improve clarity", "Mod+3"),
    ],
    updateChannel: "stable",
    updateCheckFrequency: "daily",
    popoverShortcuts: {
      replace: "Mod+Enter",
      copy: "Mod+Shift+C",
      customPrompt: "Mod+L",
      openSettings: "Mod+,",
      checkSpelling: null,
    },
    promptShortcutsSeeded: true,
    ...overrides,
  };
}

describe("describeTarget", () => {
  it("names every popover action", () => {
    const settings = settingsWith();
    expect(describeTarget(settings, { kind: "action", action: "replace" })).toBe("Replace");
    expect(describeTarget(settings, { kind: "action", action: "copy" })).toBe("Copy");
    expect(describeTarget(settings, { kind: "action", action: "customPrompt" })).toBe(
      "Custom prompt",
    );
    expect(describeTarget(settings, { kind: "action", action: "openSettings" })).toBe(
      "Open Settings",
    );
    expect(describeTarget(settings, { kind: "action", action: "checkSpelling" })).toBe(
      "Check spelling",
    );
  });

  it("names a prompt by its own label", () => {
    const settings = settingsWith();
    expect(describeTarget(settings, { kind: "prompt", id: "a" })).toBe("Rewrite");
  });

  it("falls back for a prompt id that no longer exists", () => {
    const settings = settingsWith();
    expect(describeTarget(settings, { kind: "prompt", id: "gone" })).toBe("a prompt");
  });

  it("names the global shortcut", () => {
    const settings = settingsWith();
    expect(describeTarget(settings, { kind: "global" })).toBe("Open Kallilex");
  });
});

describe("holderOf", () => {
  it("finds a popover action, tolerating a differently-cased/ordered chord", () => {
    const settings = settingsWith();
    expect(holderOf(settings, "mod+l", "macos")).toEqual({
      kind: "action",
      action: "customPrompt",
    });
    expect(holderOf(settings, "shift+mod+c", "macos")).toEqual({ kind: "action", action: "copy" });
  });

  it("finds a prompt", () => {
    const settings = settingsWith();
    expect(holderOf(settings, "Mod+2", "macos")).toEqual({ kind: "prompt", id: "b" });
  });

  it("finds the global shortcut via chordFromAccelerator, not a string match", () => {
    const settings = settingsWith({ shortcut: "Ctrl+Alt+K" });
    expect(holderOf(settings, "Mod+Alt+K", "windows")).toEqual({ kind: "global" });
  });

  it("returns null for a free chord", () => {
    const settings = settingsWith();
    expect(holderOf(settings, "Mod+9", "macos")).toBeNull();
  });

  it("ignores an unparseable stored shortcut rather than reporting it as a holder", () => {
    const settings = settingsWith({
      prompts: [prompt("a", "Rewrite", "totally not a shortcut")],
    });
    expect(holderOf(settings, "Mod+1", "macos")).toBeNull();
  });

  it("excludes the target being edited from its own current value", () => {
    const settings = settingsWith();
    const self: ShortcutTarget = { kind: "prompt", id: "b" };
    expect(holderOf(settings, "Mod+2", "macos", self)).toBeNull();
    // A different prompt's shortcut is still reported even with an exclude set.
    expect(holderOf(settings, "Mod+1", "macos", self)).toEqual({ kind: "prompt", id: "a" });
  });
});

describe("holderOfAccelerator", () => {
  it("finds the popover action the accelerator's chord would collide with", () => {
    const settings = settingsWith();
    expect(holderOfAccelerator(settings, "Ctrl+L", "windows")).toEqual({
      kind: "action",
      action: "customPrompt",
    });
  });

  it("returns null when the accelerator doesn't map into chord space", () => {
    const settings = settingsWith();
    expect(holderOfAccelerator(settings, "Ctrl+K", "macos")).toBeNull();
  });

  it("returns null when nothing holds the mapped chord", () => {
    const settings = settingsWith();
    expect(holderOfAccelerator(settings, "Ctrl+9", "windows")).toBeNull();
  });
});

describe("nextFreePromptShortcut", () => {
  it("returns the first free Mod+N", () => {
    const settings = settingsWith();
    expect(nextFreePromptShortcut(settings, "macos")).toBe("Mod+4");
  });

  it("returns null once Mod+1..9 are all taken", () => {
    const settings = settingsWith({
      prompts: Array.from({ length: 9 }, (_, i) =>
        prompt(`p${i}`, `Prompt ${i}`, `Mod+${i + 1}`),
      ),
    });
    expect(nextFreePromptShortcut(settings, "macos")).toBeNull();
  });
});

describe("shortcutWarning", () => {
  it("warns about Mod+Alt+F-keys on Linux only", () => {
    expect(shortcutWarning("Mod+Alt+F6", "linux")).toBe(
      "Many Linux desktops use Ctrl+Alt+F-keys to switch virtual terminals.",
    );
    expect(shortcutWarning("Mod+Alt+F6", "macos")).toBeNull();
    expect(shortcutWarning("Mod+Alt+F6", "windows")).toBeNull();
  });

  it("does not warn about an unrelated Linux chord", () => {
    expect(shortcutWarning("Mod+L", "linux")).toBeNull();
    expect(shortcutWarning("Mod+Alt+Shift+F6", "linux")).toBeNull();
  });
});
