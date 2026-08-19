import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import type {
  ActionContext,
  CaptureResult,
  Misspelling,
  Settings,
  SpellcheckResult,
} from "../shared/types";

const {
  hidePopover,
  captureSelection,
  openAccessibilitySettings,
  spellcheck,
  replaceBack,
  copyResult,
  getSettings,
  getActionContext,
  runAction,
  cancelAction,
  openSettings,
} = vi.hoisted(() => ({
  hidePopover: vi.fn(),
  captureSelection: vi.fn(),
  openAccessibilitySettings: vi.fn(),
  spellcheck: vi.fn(),
  replaceBack: vi.fn(),
  copyResult: vi.fn(),
  getSettings: vi.fn(),
  getActionContext: vi.fn(),
  runAction: vi.fn(),
  cancelAction: vi.fn(),
  openSettings: vi.fn(),
}));

const { listen } = vi.hoisted(() => ({
  listen: vi.fn(),
}));

const { onFocusChanged } = vi.hoisted(() => ({
  onFocusChanged: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  hidePopover,
  captureSelection,
  openAccessibilitySettings,
  spellcheck,
  replaceBack,
  copyResult,
  getSettings,
  getActionContext,
  runAction,
  cancelAction,
  openSettings,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen,
}));

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ onFocusChanged }),
}));

function emptyResult(): CaptureResult {
  return { text: "", reason: null, sourceApp: null };
}

function emptySpellcheck(): SpellcheckResult {
  return { misspellings: [] };
}

function defaultSettings(): Settings {
  return {
    activeProfileId: null,
    shortcut: "Alt+Cmd+K",
    spellcheckEnabled: true,
    popoverPinned: false,
    accessibilityOnboardingShown: false,
    profiles: [],
  };
}

function notConfiguredContext(): ActionContext {
  return { configured: false, profileName: null, privacy: null };
}

const misspelledText = "I halp you";
const halpMisspelling: Misspelling = {
  start: 2,
  length: 4,
  word: "halp",
  suggestions: ["help", "halt"],
};

describe("popover App", () => {
  beforeEach(() => {
    hidePopover.mockClear();
    captureSelection.mockClear();
    openAccessibilitySettings.mockClear();
    spellcheck.mockClear();
    replaceBack.mockClear();
    copyResult.mockClear();
    getSettings.mockClear();
    getActionContext.mockClear();
    runAction.mockClear();
    cancelAction.mockClear();
    openSettings.mockClear();
    listen.mockClear();
    onFocusChanged.mockClear();
    captureSelection.mockResolvedValue(emptyResult());
    spellcheck.mockResolvedValue(emptySpellcheck());
    replaceBack.mockResolvedValue(undefined);
    copyResult.mockResolvedValue(undefined);
    getSettings.mockResolvedValue(defaultSettings());
    getActionContext.mockResolvedValue(notConfiguredContext());
    runAction.mockResolvedValue({ status: "ok", text: "" });
    cancelAction.mockResolvedValue(undefined);
    openSettings.mockResolvedValue(undefined);
    listen.mockResolvedValue(() => {});
    onFocusChanged.mockResolvedValue(() => {});
  });

  it("renders captured text from captureSelection on mount", async () => {
    captureSelection.mockResolvedValue({
      text: "hello from Safari",
      reason: null,
      sourceApp: null,
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("hello from Safari");
    });
  });

  it("shows the empty-hint placeholder when capture is empty", async () => {
    captureSelection.mockResolvedValue(emptyResult());

    render(App);

    await waitFor(() => {
      expect(screen.getByPlaceholderText("No text captured — paste or type here.")).toBeInTheDocument();
    });
  });

  it("shows the permission banner when reason is permissionMissing and the button opens settings", async () => {
    captureSelection.mockResolvedValue({
      text: "",
      reason: "permissionMissing",
      sourceApp: null,
    });

    render(App);

    const button = await screen.findByRole("button", { name: "Open System Settings" });
    await fireEvent.click(button);

    expect(openAccessibilitySettings).toHaveBeenCalledTimes(1);
  });

  it("refreshes captured text when capture:done is emitted", async () => {
    let capturedHandler: ((event: unknown) => void) | undefined;
    listen.mockImplementation((_event: string, handler: (event: unknown) => void) => {
      capturedHandler = handler;
      return Promise.resolve(() => {});
    });
    captureSelection.mockResolvedValueOnce(emptyResult());

    render(App);

    await waitFor(() => {
      expect(listen).toHaveBeenCalledWith("capture:done", expect.any(Function));
    });

    captureSelection.mockResolvedValueOnce({
      text: "second capture",
      reason: null,
      sourceApp: null,
    });
    capturedHandler?.({});

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("second capture");
    });
  });

  it("unlistens immediately if the component unmounts before listen resolves", async () => {
    const fakeUnlisten = vi.fn();
    let resolveListen: ((fn: () => void) => void) | undefined;
    listen.mockImplementation(
      () =>
        new Promise<() => void>((resolve) => {
          resolveListen = resolve;
        }),
    );

    const { unmount } = render(App);

    await waitFor(() => {
      expect(listen).toHaveBeenCalledWith("capture:done", expect.any(Function));
    });

    unmount();
    resolveListen?.(fakeUnlisten);

    await waitFor(() => {
      expect(fakeUnlisten).toHaveBeenCalledTimes(1);
    });
  });

  it("invokes hidePopover when Escape is pressed with nothing else open", async () => {
    render(App);
    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    await fireEvent.keyDown(window, { key: "Escape" });
    expect(hidePopover).toHaveBeenCalledTimes(1);
  });

  it("does not invoke hidePopover for other keys", async () => {
    render(App);
    await fireEvent.keyDown(window, { key: "Enter" });
    expect(hidePopover).not.toHaveBeenCalled();
  });

  it("runs spellcheck with the captured text on mount and renders misspellings as marks", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValue({ misspellings: [halpMisspelling] });

    const { container } = render(App);

    await waitFor(() => {
      expect(spellcheck).toHaveBeenCalledWith(misspelledText);
    });

    await waitFor(() => {
      const marks = container.querySelectorAll(".mark");
      expect(marks).toHaveLength(1);
      expect(marks[0]?.textContent).toBe("halp");
    });
  });

  it("does not invoke spellcheck when the capture is empty", async () => {
    captureSelection.mockResolvedValue(emptyResult());

    render(App);

    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    expect(spellcheck).not.toHaveBeenCalled();
  });

  it("clicking a mark shows the suggestion popup and applying a suggestion corrects the text", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValueOnce({ misspellings: [halpMisspelling] });

    const { container } = render(App);

    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(1);
    });

    const mark = container.querySelector(".mark") as HTMLElement;
    await fireEvent.click(mark);

    const helpButton = await screen.findByRole("button", { name: "help" });
    expect(screen.getByRole("button", { name: "halt" })).toBeInTheDocument();

    spellcheck.mockResolvedValueOnce({ misspellings: [] });
    await fireEvent.click(helpButton);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("I help you");
    });
    expect(spellcheck).toHaveBeenCalledWith("I help you");
    expect(screen.queryByRole("button", { name: "help" })).not.toBeInTheDocument();
  });

  it("shows 'No suggestions' when a misspelling has none", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValue({
      misspellings: [{ ...halpMisspelling, suggestions: [] }],
    });

    const { container } = render(App);

    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(1);
    });

    const mark = container.querySelector(".mark") as HTMLElement;
    await fireEvent.click(mark);

    expect(await screen.findByText("No suggestions")).toBeInTheDocument();
  });

  it("clears marks when the user types in the textarea", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValueOnce({ misspellings: [halpMisspelling] });

    const { container } = render(App);

    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(1);
    });

    const textarea = screen.getByRole("textbox");
    await fireEvent.input(textarea, { target: { value: "I halp you now" } });

    expect(container.querySelectorAll(".mark")).toHaveLength(0);
  });

  it("re-invokes spellcheck with the current text when Check spelling is clicked", async () => {
    render(App);
    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });

    const textarea = screen.getByRole("textbox");
    await fireEvent.input(textarea, { target: { value: "manually typed text" } });

    spellcheck.mockClear();
    const button = screen.getByRole("button", { name: "Check spelling" });
    await fireEvent.click(button);

    await waitFor(() => {
      expect(spellcheck).toHaveBeenCalledWith("manually typed text");
    });
  });

  it("opens the custom prompt input and closes it on a second click or Escape", async () => {
    render(App);

    const customButton = screen.getByRole("button", { name: "Custom" });
    await fireEvent.click(customButton);

    expect(screen.getByPlaceholderText("Describe what to do…")).toBeInTheDocument();

    await fireEvent.click(customButton);
    expect(screen.queryByPlaceholderText("Describe what to do…")).not.toBeInTheDocument();

    await fireEvent.click(customButton);
    expect(screen.getByPlaceholderText("Describe what to do…")).toBeInTheDocument();

    await fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByPlaceholderText("Describe what to do…")).not.toBeInTheDocument();
    expect(hidePopover).not.toHaveBeenCalled();
  });

  it("renders the action row and a disabled result row", async () => {
    render(App);

    expect(screen.getByRole("button", { name: "Rewrite" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Shorten" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Improve clarity" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Custom" })).toBeInTheDocument();

    expect(screen.getByRole("button", { name: "Replace" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Copy" })).toBeDisabled();
  });

  it("survives a rejected spellcheck call without crashing or rendering marks", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockRejectedValueOnce(new Error("spellcheck backend failed"));
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});

    const { container } = render(App);

    await waitFor(() => {
      expect(spellcheck).toHaveBeenCalledWith(misspelledText);
    });

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue(misspelledText);
    });
    expect(container.querySelectorAll(".mark")).toHaveLength(0);
    expect(consoleError).toHaveBeenCalled();

    consoleError.mockRestore();
  });

  it("clears marks immediately after applying a suggestion, before the follow-up spellcheck resolves", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValueOnce({ misspellings: [halpMisspelling] });

    const { container } = render(App);

    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(1);
    });

    const mark = container.querySelector(".mark") as HTMLElement;
    await fireEvent.click(mark);
    const helpButton = await screen.findByRole("button", { name: "help" });

    let resolveFollowUp: ((result: SpellcheckResult) => void) | undefined;
    spellcheck.mockImplementationOnce(
      () =>
        new Promise<SpellcheckResult>((resolve) => {
          resolveFollowUp = resolve;
        }),
    );

    await fireEvent.click(helpButton);

    // The corrected text is applied and stale marks are cleared
    // synchronously, before the follow-up spellcheck call has resolved.
    expect(screen.getByRole("textbox")).toHaveValue("I help you");
    expect(container.querySelectorAll(".mark")).toHaveLength(0);

    resolveFollowUp?.({ misspellings: [] });
    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(0);
    });
  });

  it("Replace stays disabled without a remembered source app even with text present", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });
    expect(screen.getByRole("button", { name: "Replace" })).toBeDisabled();
  });

  it("Replace stays disabled with a source app but empty text", async () => {
    captureSelection.mockResolvedValue({
      text: "",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    render(App);

    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    expect(screen.getByRole("button", { name: "Replace" })).toBeDisabled();
  });

  it("Replace becomes enabled once text and a source app are both present", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });
  });

  it("clicking Replace invokes replace_back with the current edited text and hides the popover", async () => {
    captureSelection.mockResolvedValue({
      text: "original text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    render(App);

    const textarea = await screen.findByRole("textbox");
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });

    await fireEvent.input(textarea, { target: { value: "edited text" } });

    const replaceButton = screen.getByRole("button", { name: "Replace" });
    await fireEvent.click(replaceButton);

    await waitFor(() => {
      expect(replaceBack).toHaveBeenCalledWith("edited text");
    });
    expect(hidePopover).toHaveBeenCalledTimes(1);
  });

  it("clicking Copy invokes copy_result with the current text and hides the popover", async () => {
    captureSelection.mockResolvedValue({
      text: "result text",
      reason: null,
      sourceApp: null,
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    });

    const copyButton = screen.getByRole("button", { name: "Copy" });
    await fireEvent.click(copyButton);

    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("result text");
    });
    expect(hidePopover).toHaveBeenCalledTimes(1);
  });

  it("a rejected replace_back shows the error and does not hide the popover", async () => {
    captureSelection.mockResolvedValue({
      text: "original text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });
    replaceBack.mockRejectedValueOnce(new Error("no source application remembered"));

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });

    const replaceButton = screen.getByRole("button", { name: "Replace" });
    await fireEvent.click(replaceButton);

    await waitFor(() => {
      expect(screen.getByText("no source application remembered")).toBeInTheDocument();
    });
    expect(hidePopover).not.toHaveBeenCalled();
    // Busy is cleared after the failure, so Replace becomes clickable again.
    expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
  });

  it("disables both Replace and Copy while a replace is in flight, and completes once it resolves", async () => {
    captureSelection.mockResolvedValue({
      text: "original text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    let resolveReplace: (() => void) | undefined;
    replaceBack.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          resolveReplace = resolve;
        }),
    );

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });

    const replaceButton = screen.getByRole("button", { name: "Replace" });
    const copyButton = screen.getByRole("button", { name: "Copy" });
    await fireEvent.click(replaceButton);

    await waitFor(() => {
      expect(replaceButton).toBeDisabled();
    });
    expect(copyButton).toBeDisabled();

    resolveReplace?.();

    await waitFor(() => {
      expect(hidePopover).toHaveBeenCalledTimes(1);
    });
  });

  it("a rejected copyResult shows the error inline and does not hide the popover", async () => {
    captureSelection.mockResolvedValue({
      text: "result text",
      reason: null,
      sourceApp: null,
    });
    copyResult.mockRejectedValueOnce(new Error("clipboard write failed"));

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    });

    const copyButton = screen.getByRole("button", { name: "Copy" });
    await fireEvent.click(copyButton);

    await waitFor(() => {
      expect(screen.getByText("clipboard write failed")).toBeInTheDocument();
    });
    expect(hidePopover).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
  });

  it("clears a previously shown action error when the window regains focus", async () => {
    captureSelection.mockResolvedValue({
      text: "original text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });
    replaceBack.mockRejectedValueOnce(new Error("no source application remembered"));

    let focusHandler: ((event: { payload: boolean }) => void) | undefined;
    onFocusChanged.mockImplementation((handler: (event: { payload: boolean }) => void) => {
      focusHandler = handler;
      return Promise.resolve(() => {});
    });

    render(App);

    await waitFor(() => {
      expect(onFocusChanged).toHaveBeenCalled();
    });

    const replaceButton = screen.getByRole("button", { name: "Replace" });
    await fireEvent.click(replaceButton);

    await waitFor(() => {
      expect(screen.getByText("no source application remembered")).toBeInTheDocument();
    });

    focusHandler?.({ payload: true });

    await waitFor(() => {
      expect(screen.queryByText("no source application remembered")).not.toBeInTheDocument();
    });
  });

  it("Escape closes an open suggestion popup instead of hiding the popover", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    spellcheck.mockResolvedValueOnce({ misspellings: [halpMisspelling] });

    const { container } = render(App);

    await waitFor(() => {
      expect(container.querySelectorAll(".mark")).toHaveLength(1);
    });

    const mark = container.querySelector(".mark") as HTMLElement;
    await fireEvent.click(mark);
    expect(screen.getByRole("button", { name: "help" })).toBeInTheDocument();

    await fireEvent.keyDown(window, { key: "Escape" });

    expect(screen.queryByRole("button", { name: "help" })).not.toBeInTheDocument();
    expect(hidePopover).not.toHaveBeenCalled();
  });

  it("clicking Rewrite calls runAction with the current text and applies the returned text", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });
    runAction.mockResolvedValue({ status: "ok", text: "some rewritten text" });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", { kind: "rewrite" });
    });
    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some rewritten text");
    });
  });

  it("clicking an action button when not configured shows a settings hint instead of calling runAction", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue(notConfiguredContext());

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    expect(runAction).not.toHaveBeenCalled();
    const settingsButton = await screen.findByRole("button", { name: "Open Settings" });

    await fireEvent.click(settingsButton);
    expect(openSettings).toHaveBeenCalledTimes(1);
  });

  it("renders the message from an error outcome", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });
    runAction.mockResolvedValue({
      status: "error",
      kind: "unreachable",
      message: "Can't reach the endpoint — is the server running? (connection refused)",
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(
        screen.getByText("Can't reach the endpoint — is the server running? (connection refused)"),
      ).toBeInTheDocument();
    });
  });

  it("shows a Cancel affordance while an AI action is in flight and cancels it on click", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });

    let resolveRun: ((outcome: { status: "cancelled" }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    const cancelButton = await screen.findByRole("button", { name: "Cancel" });
    await fireEvent.click(cancelButton);

    expect(cancelAction).toHaveBeenCalledTimes(1);

    resolveRun?.({ status: "cancelled" });
    await waitFor(() => {
      expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
    });
  });

  it("discards a stale AI action result after a fresh capture supersedes it, and cancels the in-flight request", async () => {
    let capturedHandler: ((event: unknown) => void) | undefined;
    listen.mockImplementation((_event: string, handler: (event: unknown) => void) => {
      capturedHandler = handler;
      return Promise.resolve(() => {});
    });

    captureSelection.mockResolvedValueOnce({
      text: "first captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });

    let resolveRun: ((outcome: { status: "ok"; text: string }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("first captured text");
    });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("first captured text", { kind: "rewrite" });
    });

    // A fresh capture arrives while the action is still in flight.
    captureSelection.mockResolvedValueOnce({
      text: "second captured text",
      reason: null,
      sourceApp: null,
    });
    cancelAction.mockClear();
    capturedHandler?.({});

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("second captured text");
    });
    expect(cancelAction).toHaveBeenCalled();

    // The stale request finally resolves — it must not clobber the fresh
    // capture, or surface as an error.
    resolveRun?.({ status: "ok", text: "stale ai result" });

    // Let the now-resolved promise's continuation run.
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(screen.getByRole("textbox")).toHaveValue("second captured text");
    expect(screen.queryByText("stale ai result")).not.toBeInTheDocument();
  });

  it("disables the capture textarea while an AI action is in flight and re-enables it once it resolves", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });

    let resolveRun: ((outcome: { status: "ok"; text: string }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });
    const textarea = screen.getByRole("textbox");
    expect(textarea).toBeEnabled();

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(textarea).toBeDisabled();
    });

    resolveRun?.({ status: "ok", text: "rewritten text" });

    await waitFor(() => {
      expect(textarea).toBeEnabled();
    });
  });

  it("renders the LAN privacy badge with the profile name", async () => {
    captureSelection.mockResolvedValue(emptyResult());
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "lan",
    });

    render(App);

    expect(await screen.findByText("Llama · LAN")).toBeInTheDocument();
  });

  it("renders the Local privacy badge without a profile name", async () => {
    captureSelection.mockResolvedValue(emptyResult());
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });

    render(App);

    expect(await screen.findByText("Local")).toBeInTheDocument();
  });

  it("renders no badge when no provider is configured", async () => {
    captureSelection.mockResolvedValue(emptyResult());
    getActionContext.mockResolvedValue(notConfiguredContext());

    render(App);

    await waitFor(() => {
      expect(getActionContext).toHaveBeenCalled();
    });
    expect(screen.queryByText("Local")).not.toBeInTheDocument();
    expect(screen.queryByText(/· LAN/)).not.toBeInTheDocument();
    expect(screen.queryByText(/· Cloud/)).not.toBeInTheDocument();
  });

  it("running a custom instruction on Enter calls runAction with the instruction", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });
    runAction.mockResolvedValue({ status: "ok", text: "translated text" });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const customButton = screen.getByRole("button", { name: "Custom" });
    await fireEvent.click(customButton);

    const customInput = screen.getByPlaceholderText("Describe what to do…");
    await fireEvent.input(customInput, { target: { value: "Translate to French" } });
    await fireEvent.keyDown(customInput, { key: "Enter" });

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "custom",
        instruction: "Translate to French",
      });
    });
  });

  it("does not run automatic spellcheck after capture when spellcheck is disabled in settings", async () => {
    captureSelection.mockResolvedValue({
      text: misspelledText,
      reason: null,
      sourceApp: null,
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), spellcheckEnabled: false });

    render(App);

    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    await waitFor(() => {
      expect(getSettings).toHaveBeenCalled();
    });
    expect(spellcheck).not.toHaveBeenCalled();
  });
});
