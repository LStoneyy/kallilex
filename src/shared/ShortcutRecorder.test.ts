import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { describe, expect, it, vi } from "vitest";
import ShortcutRecorder from "./ShortcutRecorder.svelte";
import type { Os } from "./shortcuts";

function baseProps(overrides: Record<string, unknown> = {}) {
  return {
    value: null as string | null,
    os: "macos" as Os,
    mode: "chord" as const,
    label: "Replace",
    validate: () => null,
    findConflict: () => null,
    onCommit: vi.fn(),
    ...overrides,
  };
}

function recorderButton(container: HTMLElement): HTMLButtonElement {
  return container.querySelector(".shortcut-recorder") as HTMLButtonElement;
}

describe("idle rendering", () => {
  it("shows the formatted chord when a value is set", () => {
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+Enter" }),
    });
    expect(recorderButton(container).textContent).toContain("⌘");
    expect(recorderButton(container).textContent).toContain("↩");
  });

  it("shows \"Not set\" when there is no value", () => {
    const { container } = render(ShortcutRecorder, { props: baseProps() });
    expect(recorderButton(container).textContent).toContain("Not set");
  });
});

describe("entering recording", () => {
  it("by click", async () => {
    const { container } = render(ShortcutRecorder, { props: baseProps() });
    await fireEvent.click(recorderButton(container));
    expect(screen.getByText("Press a shortcut…")).toBeInTheDocument();
  });

  it("by Enter", async () => {
    const { container } = render(ShortcutRecorder, { props: baseProps() });
    await fireEvent.keyDown(recorderButton(container), { key: "Enter" });
    expect(screen.getByText("Press a shortcut…")).toBeInTheDocument();
  });
});

describe("Escape", () => {
  it("cancels recording without committing", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", onCommit }),
    });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "Escape" });

    expect(screen.queryByText("Press a shortcut…")).not.toBeInTheDocument();
    expect(button.textContent).toContain("L");
    expect(onCommit).not.toHaveBeenCalled();
  });
});

describe("Backspace / Delete", () => {
  it("clears when bare and clearable", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", onCommit }),
    });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "Backspace" });

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith(null, false));
  });

  it("is ignored when not clearable", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", onCommit, clearable: false }),
    });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "Backspace" });

    expect(onCommit).not.toHaveBeenCalled();
    expect(screen.getByText("Press a shortcut…")).toBeInTheDocument();
  });
});

describe("recording a candidate", () => {
  it("commits a valid, free chord with takeOver=false", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, { props: baseProps({ onCommit }) });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+S", false));
  });

  it("shows the validation error and does not commit", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          validate: () => "Add ⌘ — plain keys would get in the way of typing.",
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "l", code: "KeyL" });

    expect(
      screen.getByText("Add ⌘ — plain keys would get in the way of typing."),
    ).toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
    expect(screen.getByText("Press a shortcut…")).toBeInTheDocument();
  });

  it("a take-over-able conflict offers Take over / Cancel", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();
    const takeOverButton = screen.getByText("Take over");
    await fireEvent.click(takeOverButton);

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+S", true));
  });

  it("Cancel on a conflict commits nothing", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    await fireEvent.click(screen.getByText("Cancel"));

    expect(onCommit).not.toHaveBeenCalled();
    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
  });

  it("a conflict that can't be taken over blocks instead of offering Take over", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: false }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    expect(
      screen.getByText('⌘S is already used by Rewrite and can\'t be taken over.'),
    ).toBeInTheDocument();
    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
  });
});

describe("reset (↺)", () => {
  it("proposes the default value through the same flow", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", defaultValue: "Mod+K", onCommit }),
    });
    const resetButton = screen.getByLabelText("Reset shortcut for Replace to its default");
    await fireEvent.click(resetButton);

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+K", false));
    void container;
  });

  it("surfaces a conflict for the proposed default just like a recorded value", async () => {
    const onCommit = vi.fn();
    render(ShortcutRecorder, {
      props: baseProps({
        value: "Mod+L",
        defaultValue: "Mod+K",
        onCommit,
        findConflict: (candidate: string) =>
          candidate === "Mod+K" ? { holder: "Rewrite", canTakeOver: true } : null,
      }),
    });
    const resetButton = screen.getByLabelText("Reset shortcut for Replace to its default");
    await fireEvent.click(resetButton);

    expect(screen.getByText('⌘K is used by "Rewrite".')).toBeInTheDocument();
    await fireEvent.click(screen.getByText("Take over"));

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+K", true));
  });

  it("is not shown when the value already equals the default", () => {
    render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+K", defaultValue: "Mod+K" }),
    });
    expect(
      screen.queryByLabelText("Reset shortcut for Replace to its default"),
    ).not.toBeInTheDocument();
  });
});

describe("clear (✕)", () => {
  it("commits null", async () => {
    const onCommit = vi.fn();
    render(ShortcutRecorder, { props: baseProps({ value: "Mod+L", onCommit }) });
    const clearButton = screen.getByLabelText("Clear shortcut for Replace");
    await fireEvent.click(clearButton);

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith(null, false));
  });

  it("is not shown when there is no value", () => {
    render(ShortcutRecorder, { props: baseProps({ value: null }) });
    expect(screen.queryByLabelText("Clear shortcut for Replace")).not.toBeInTheDocument();
  });

  it("is not shown when not clearable", () => {
    render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", clearable: false }),
    });
    expect(screen.queryByLabelText("Clear shortcut for Replace")).not.toBeInTheDocument();
  });
});

describe("warn", () => {
  it("commits and shows the warning as a non-blocking hint", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          warn: () => "Many Linux desktops use Ctrl+Alt+F-keys to switch virtual terminals.",
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+S", false));
    expect(
      screen.getByText("Many Linux desktops use Ctrl+Alt+F-keys to switch virtual terminals."),
    ).toBeInTheDocument();
  });
});

describe("onCommit rejection", () => {
  it("shows the error inline and returns to idle", async () => {
    const onCommit = vi.fn().mockRejectedValue(new Error("Could not save."));
    const { container } = render(ShortcutRecorder, { props: baseProps({ onCommit }) });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() => expect(screen.getByText("Could not save.")).toBeInTheDocument());
    expect(screen.queryByText("Press a shortcut…")).not.toBeInTheDocument();
  });
});

describe("accelerator mode", () => {
  it("records Ctrl+Alt+K on Windows, including an AltGraph-flagged event", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ mode: "accelerator", os: "windows", onCommit }),
    });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, {
      key: "k",
      code: "KeyK",
      ctrlKey: true,
      altKey: true,
      modifierAltGraph: true,
    });

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Ctrl+Alt+K", false));
  });
});

describe("blur", () => {
  it("cancels recording without committing", async () => {
    const onCommit = vi.fn();
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+L", onCommit }),
    });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.blur(button);

    expect(screen.queryByText("Press a shortcut…")).not.toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
  });

  it("does not cancel a pending conflict", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    // Mousedown on "Take over" blurs the main button before the click lands
    // (the real-world Chromium/WebView2 order) — the conflict must survive.
    await fireEvent.blur(button);

    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();
    await fireEvent.click(screen.getByText("Take over"));

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+S", true));
  });
});

describe("pending conflict focus and keyboard handling", () => {
  it("moves focus to Take over once the conflict appears", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() => expect(screen.getByText("Take over")).toBe(document.activeElement));
  });

  it("a Tab reaching the (now blurred) main button does not cancel the conflict", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    await fireEvent.keyDown(button, { key: "Tab" });

    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();
  });

  it("Escape cancels the conflict even while a Take over/Cancel button has focus", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    const takeOverButton = await screen.findByText("Take over");
    await fireEvent.keyDown(takeOverButton, { key: "Escape" });

    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
    await waitFor(() => expect(document.activeElement).toBe(button));
  });

  it("clicking the main button while a conflict is pending does nothing", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    await fireEvent.click(button);

    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();
  });
});

describe("abandoning a pending conflict", () => {
  async function renderWithConflict(onCommit = vi.fn()) {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    const takeOverButton = await screen.findByText("Take over");
    return { container, button, takeOverButton, onCommit };
  }

  it("a real outside pointerdown cancels it", async () => {
    const { onCommit } = await renderWithConflict();
    const outside = document.createElement("button");
    document.body.appendChild(outside);

    await fireEvent.pointerDown(outside);

    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
    outside.remove();
  });

  it("tabbing out to an outside element cancels it", async () => {
    const { takeOverButton, onCommit } = await renderWithConflict();
    const outside = document.createElement("button");
    document.body.appendChild(outside);

    await fireEvent.focusOut(takeOverButton, { relatedTarget: outside });

    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
    outside.remove();
  });

  it("a blur with a null relatedTarget (WebKit's click-without-focus order) keeps it", async () => {
    const { takeOverButton, onCommit } = await renderWithConflict();

    await fireEvent.focusOut(takeOverButton, { relatedTarget: null });

    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();
    expect(onCommit).not.toHaveBeenCalled();
  });

  it("a pointerdown on Take over itself keeps it, and the click still commits", async () => {
    const { takeOverButton, onCommit } = await renderWithConflict();

    await fireEvent.pointerDown(takeOverButton);
    expect(screen.getByText('⌘S is used by "Rewrite".')).toBeInTheDocument();

    await fireEvent.click(takeOverButton);

    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Mod+S", true));
  });
});

describe("overlapping commits", () => {
  function deferred<T>() {
    let resolve!: (value: T) => void;
    let reject!: (reason?: unknown) => void;
    const promise = new Promise<T>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  }

  it("ignores a second keypress while a commit is in flight", async () => {
    const first = deferred<void>();
    const onCommit = vi.fn().mockReturnValueOnce(first.promise);
    const { container } = render(ShortcutRecorder, { props: baseProps({ onCommit }) });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    expect(onCommit).toHaveBeenCalledTimes(1);

    // A stray keypress while the first commit is still pending must not
    // start a second one.
    await fireEvent.keyDown(button, { key: "t", code: "KeyT", metaKey: true });
    expect(onCommit).toHaveBeenCalledTimes(1);

    first.resolve();
    await waitFor(() => expect(onCommit).toHaveBeenCalledTimes(1));
  });

  it("ignores clicking Clear while a commit is in flight", async () => {
    const first = deferred<void>();
    const onCommit = vi.fn().mockReturnValueOnce(first.promise);
    render(ShortcutRecorder, { props: baseProps({ value: "Mod+L", onCommit }) });
    const clearButton = screen.getByLabelText("Clear shortcut for Replace");
    await fireEvent.click(clearButton);

    expect(onCommit).toHaveBeenCalledTimes(1);
    // The icon buttons disappear while committing, but guard the handler too.
    expect(screen.queryByLabelText("Clear shortcut for Replace")).not.toBeInTheDocument();

    first.resolve();
    await waitFor(() => expect(onCommit).toHaveBeenCalledTimes(1));
  });

  it("ignores Take over clicked twice while the first commit is in flight", async () => {
    const first = deferred<void>();
    const onCommit = vi.fn().mockReturnValueOnce(first.promise);
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    const takeOverButton = await screen.findByText("Take over");
    await fireEvent.click(takeOverButton);
    expect(onCommit).toHaveBeenCalledTimes(1);

    await fireEvent.click(takeOverButton);
    expect(onCommit).toHaveBeenCalledTimes(1);

    first.resolve();
    await waitFor(() => expect(onCommit).toHaveBeenCalledTimes(1));
  });
});

describe("focus restoration", () => {
  it("returns focus to the main button after a successful commit started from a conflict", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    const takeOverButton = await screen.findByText("Take over");
    await fireEvent.click(takeOverButton);

    await waitFor(() => expect(document.activeElement).toBe(button));
  });

  it("returns focus to the main button after cancelling a conflict", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });
    await fireEvent.click(screen.getByText("Cancel"));

    await waitFor(() => expect(document.activeElement).toBe(button));
  });

  it("returns focus to the main button after a failed commit", async () => {
    const onCommit = vi.fn().mockRejectedValue(new Error("Could not save."));
    const { container } = render(ShortcutRecorder, { props: baseProps({ onCommit }) });
    const button = recorderButton(container);
    await fireEvent.click(button);
    // jsdom's `click` doesn't focus the element the way a real click does —
    // focus it explicitly, matching what a mouse click actually leaves
    // focused in a browser before the next keydown is sent to it.
    button.focus();
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() => expect(screen.getByText("Could not save.")).toBeInTheDocument());
    await waitFor(() => expect(document.activeElement).toBe(button));
  });
});

describe("aria-label reflects state", () => {
  it("names the current value while idle", () => {
    const { container } = render(ShortcutRecorder, {
      props: baseProps({ value: "Mod+Enter" }),
    });
    expect(recorderButton(container).getAttribute("aria-label")).toBe(
      "Shortcut for Replace: ⌘↩. Press Enter to record a new one.",
    );
  });

  it("describes the recording state", async () => {
    const { container } = render(ShortcutRecorder, { props: baseProps() });
    const button = recorderButton(container);
    await fireEvent.click(button);

    expect(button.getAttribute("aria-label")).toBe(
      "Recording a shortcut for Replace. Press the keys, or Escape to cancel.",
    );
  });

  it("describes a pending conflict", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({ holder: "Rewrite", canTakeOver: true }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    await waitFor(() =>
      expect(button.getAttribute("aria-label")).toBe(
        'Shortcut conflict for Replace: ⌘S is used by "Rewrite".',
      ),
    );
  });
});

describe("held-modifier preview", () => {
  it("clears on keyup as modifiers are released", async () => {
    const { container } = render(ShortcutRecorder, { props: baseProps() });
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "Shift", shiftKey: true });

    expect(container.querySelector(".held-preview")).not.toBeNull();

    await fireEvent.keyUp(button, { key: "Shift", shiftKey: false });

    expect(container.querySelector(".held-preview")).toBeNull();
  });
});

describe("findConflict message override", () => {
  it("shows the caller's own wording for a take-over-able conflict", async () => {
    const onCommit = vi.fn();
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          onCommit,
          findConflict: () => ({
            holder: "Open Kallilex",
            canTakeOver: true,
            message: "Already used to open Kallilex.",
          }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    expect(screen.getByText("Already used to open Kallilex.")).toBeInTheDocument();
  });

  it("shows the caller's own wording for a blocked conflict", async () => {
    const { container } = render(
      ShortcutRecorder,
      {
        props: baseProps({
          findConflict: () => ({
            holder: "Open Kallilex",
            canTakeOver: false,
            message: "Already used to open Kallilex.",
          }),
        }),
      },
    );
    const button = recorderButton(container);
    await fireEvent.click(button);
    await fireEvent.keyDown(button, { key: "s", code: "KeyS", metaKey: true });

    expect(screen.getByText("Already used to open Kallilex.")).toBeInTheDocument();
    expect(screen.queryByText("Take over")).not.toBeInTheDocument();
  });
});
