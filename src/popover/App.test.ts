import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import { resetPlatformInfoForTests } from "../shared/platform";
import type {
  ActionContext,
  CaptureResult,
  CustomPrompt,
  Misspelling,
  PlatformInfo,
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
  setSettings,
  getActionContext,
  runAction,
  cancelAction,
  openSettings,
  getPlatformInfo,
  beginPopoverDrag,
} = vi.hoisted(() => ({
  hidePopover: vi.fn(),
  captureSelection: vi.fn(),
  openAccessibilitySettings: vi.fn(),
  spellcheck: vi.fn(),
  replaceBack: vi.fn(),
  copyResult: vi.fn(),
  getSettings: vi.fn(),
  setSettings: vi.fn(),
  getActionContext: vi.fn(),
  runAction: vi.fn(),
  cancelAction: vi.fn(),
  openSettings: vi.fn(),
  getPlatformInfo: vi.fn(),
  beginPopoverDrag: vi.fn(),
}));

const { listen } = vi.hoisted(() => ({
  listen: vi.fn(),
}));

const { onFocusChanged, startDragging } = vi.hoisted(() => ({
  onFocusChanged: vi.fn(),
  startDragging: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  hidePopover,
  captureSelection,
  openAccessibilitySettings,
  spellcheck,
  replaceBack,
  copyResult,
  getSettings,
  setSettings,
  getActionContext,
  runAction,
  cancelAction,
  openSettings,
  getPlatformInfo,
  beginPopoverDrag,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen,
}));

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({ onFocusChanged, startDragging }),
}));

function emptyResult(): CaptureResult {
  return { text: "", reason: null, sourceApp: null };
}

function emptySpellcheck(): SpellcheckResult {
  return { misspellings: [] };
}

function seededPrompts(): CustomPrompt[] {
  return [
    {
      id: "builtin-rewrite",
      label: "Rewrite",
      instruction:
        "Rewrite the user's text to improve phrasing and flow while preserving its meaning and tone.",
      shortcut: "Mod+1",
    },
    {
      id: "builtin-shorten",
      label: "Shorten",
      instruction:
        "Make the user's text noticeably shorter while keeping its essential meaning and tone.",
      shortcut: "Mod+2",
    },
    {
      id: "builtin-improve-clarity",
      label: "Improve clarity",
      instruction:
        "Make the user's text clearer and easier to understand without changing its meaning.",
      shortcut: "Mod+3",
    },
  ];
}

function defaultSettings(): Settings {
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
    prompts: seededPrompts(),
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
  };
}

function notConfiguredContext(): ActionContext {
  return { configured: false, profileName: null, privacy: null };
}

function macosPlatformInfo(): PlatformInfo {
  return {
    os: "macos",
    session: null,
    replaceBackAvailable: true,
    permissionRequired: true,
    defaultShortcut: "Alt+Cmd+K",
    wayland: null,
  };
}

function windowsPlatformInfo(): PlatformInfo {
  return {
    os: "windows",
    session: null,
    replaceBackAvailable: true,
    permissionRequired: false,
    defaultShortcut: "Ctrl+Alt+K",
    wayland: null,
  };
}

const waylandNoticeNoCapabilitiesText =
  "Wayland session: your compositor doesn't offer the GlobalShortcuts or RemoteDesktop portals — open Kallilex from the tray to capture, and copy results manually.";
const waylandNoticeNoGlobalShortcutText =
  "Wayland session: your compositor doesn't offer the GlobalShortcuts portal — open Kallilex from the tray to capture your selection.";
const waylandNoticeNoInputSynthesisText =
  "Wayland session: your compositor doesn't offer the RemoteDesktop portal — automatic replace is unavailable; copy the result instead.";

const misspelledText = "I halp you";
const halpMisspelling: Misspelling = {
  start: 2,
  length: 4,
  word: "halp",
  suggestions: ["help", "halt"],
};

describe("popover App", () => {
  beforeEach(() => {
    resetPlatformInfoForTests();
    hidePopover.mockClear();
    captureSelection.mockClear();
    openAccessibilitySettings.mockClear();
    spellcheck.mockClear();
    replaceBack.mockClear();
    copyResult.mockClear();
    getSettings.mockClear();
    setSettings.mockClear();
    getActionContext.mockClear();
    runAction.mockClear();
    cancelAction.mockClear();
    openSettings.mockClear();
    getPlatformInfo.mockClear();
    beginPopoverDrag.mockClear();
    listen.mockClear();
    onFocusChanged.mockClear();
    startDragging.mockClear();
    captureSelection.mockResolvedValue(emptyResult());
    spellcheck.mockResolvedValue(emptySpellcheck());
    replaceBack.mockResolvedValue(undefined);
    copyResult.mockResolvedValue(undefined);
    getSettings.mockResolvedValue(defaultSettings());
    setSettings.mockImplementation((settings: Settings) => Promise.resolve(settings));
    getActionContext.mockResolvedValue(notConfiguredContext());
    runAction.mockResolvedValue({ status: "ok", text: "" });
    cancelAction.mockResolvedValue(undefined);
    openSettings.mockResolvedValue(undefined);
    getPlatformInfo.mockResolvedValue(macosPlatformInfo());
    beginPopoverDrag.mockResolvedValue(undefined);
    listen.mockResolvedValue(() => {});
    onFocusChanged.mockResolvedValue(() => {});
    startDragging.mockResolvedValue(undefined);
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

  it("renders the action row from the seeded prompts and a disabled result row", async () => {
    render(App);

    expect(await screen.findByRole("button", { name: "Rewrite" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Shorten" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Improve clarity" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Custom" })).toBeInTheDocument();

    expect(screen.getByRole("button", { name: "Replace" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Copy" })).toBeDisabled();
  });

  it("renders a button for every user-added prompt, alongside the seeded ones", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      prompts: [
        ...seededPrompts(),
        { id: "custom-1", label: "Translate", instruction: "Translate to French." },
      ],
    });

    render(App);

    expect(await screen.findByRole("button", { name: "Translate" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Rewrite" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Shorten" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Improve clarity" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Custom" })).toBeInTheDocument();
  });

  it("clicking a user-added prompt calls runAction with its instruction", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      prompts: [
        ...seededPrompts(),
        { id: "custom-1", label: "Translate", instruction: "Translate to French." },
      ],
    });
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
    runAction.mockResolvedValue({ status: "ok", text: "texte traduit" });

    render(App);

    const translateButton = await screen.findByRole("button", { name: "Translate" });
    await fireEvent.click(translateButton);

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "prompt",
        instruction: "Translate to French.",
      });
    });
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

  it("hides the Replace button entirely when the platform doesn't support replace-back", async () => {
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      replaceBackAvailable: false,
    });

    render(App);

    await waitFor(() => {
      expect(getPlatformInfo).toHaveBeenCalled();
    });
    await waitFor(() => {
      expect(screen.queryByRole("button", { name: "Replace" })).not.toBeInTheDocument();
    });
    // Copy is unaffected — still rendered and eventually enabled.
    expect(screen.getByRole("button", { name: "Copy" })).toBeInTheDocument();
  });

  it("clicking Copy invokes copy_result with the current text and does not hide the popover", async () => {
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
    // The popover now stays open so the user can see the "Copied ✓"
    // confirmation — see the copy-feedback tests below.
    expect(hidePopover).not.toHaveBeenCalled();
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

  it("clicking a seeded prompt calls runAction with its instruction and applies the returned text", async () => {
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "prompt",
        instruction: seededPrompts()[0]!.instruction,
      });
    });
    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some rewritten text");
    });
  });

  it("preserves multi-line structure and indentation in the text an AI action returns", async () => {
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
      status: "ok",
      text: "Para one.\n\nPara two.\n  indented",
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("Para one.\n\nPara two.\n  indented");
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("first captured text", {
        kind: "prompt",
        instruction: seededPrompts()[0]!.instruction,
      });
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
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

  it("shows a 'Copied ✓' confirmation after Copy, reverts after 1.5s, and a second copy before expiry restarts the timer", async () => {
    captureSelection.mockResolvedValue({
      text: "result text",
      reason: null,
      sourceApp: null,
    });

    render(App);

    // Let the initial (real-timer) capture settle before switching to fake
    // timers for the Copy-confirmation timeout itself.
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    });

    vi.useFakeTimers();
    try {
      await fireEvent.click(screen.getByRole("button", { name: "Copy" }));
      // Flush the microtasks from the resolved `copyResult` promise so
      // `copied` flips to true and the confirmation timeout gets armed.
      await vi.advanceTimersByTimeAsync(0);
      expect(screen.getByRole("button", { name: "Copied ✓" })).toBeInTheDocument();

      await vi.advanceTimersByTimeAsync(1000);
      expect(screen.getByRole("button", { name: "Copied ✓" })).toBeInTheDocument();

      // A second copy before the first timeout expires restarts the timer
      // instead of stacking with it.
      await fireEvent.click(screen.getByRole("button", { name: "Copied ✓" }));
      await vi.advanceTimersByTimeAsync(0);
      expect(screen.getByRole("button", { name: "Copied ✓" })).toBeInTheDocument();

      await vi.advanceTimersByTimeAsync(1000);
      // 1000ms after the restart — the original 1500ms window would have
      // already elapsed by now, so this only passes if the timer restarted.
      expect(screen.getByRole("button", { name: "Copied ✓" })).toBeInTheDocument();

      await vi.advanceTimersByTimeAsync(500);
      expect(screen.getByRole("button", { name: "Copy" })).toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("renders the character count for captured text and updates it while typing", async () => {
    captureSelection.mockResolvedValue({
      text: "hello",
      reason: null,
      sourceApp: null,
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByText("5 chars")).toBeInTheDocument();
    });

    const textarea = screen.getByRole("textbox");
    await fireEvent.input(textarea, { target: { value: "hello world" } });

    expect(screen.getByText("11 chars")).toBeInTheDocument();
  });

  it("does not render a character count when the editor is empty", async () => {
    captureSelection.mockResolvedValue(emptyResult());

    render(App);

    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    expect(screen.queryByText(/chars$/)).not.toBeInTheDocument();
  });

  it("refreshes the scroll shadow classes after an AI action replaces the text", async () => {
    captureSelection.mockResolvedValue({
      text: "some long captured text that overflows the editor",
      reason: null,
      sourceApp: null,
    });
    getActionContext.mockResolvedValue({
      configured: true,
      profileName: "Llama",
      privacy: "local",
    });
    runAction.mockResolvedValue({ status: "ok", text: "short" });

    const { container } = render(App);

    const textarea = (await screen.findByRole("textbox")) as HTMLTextAreaElement;

    // Stub the textarea's scroll metrics via a mutable flag so the same
    // getters can report "overflowing" before the AI run and "not
    // overflowing" after it, without needing a real layout engine.
    let overflowing = true;
    Object.defineProperty(textarea, "scrollTop", { configurable: true, value: 0 });
    Object.defineProperty(textarea, "clientHeight", { configurable: true, get: () => 100 });
    Object.defineProperty(textarea, "scrollHeight", {
      configurable: true,
      get: () => (overflowing ? 200 : 100),
    });

    // The initial capture already called `updateScrollShadows()` before
    // these getters were installed; refresh the classes against the stub.
    await fireEvent.scroll(textarea);

    const editor = container.querySelector(".editor") as HTMLElement;
    expect(editor).toHaveClass("can-scroll-down");

    overflowing = false;
    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("short");
    });

    await waitFor(() => {
      expect(editor).not.toHaveClass("can-scroll-down");
    });
  });

  it("clears the 'Copied ✓' confirmation when the text changes underneath it", async () => {
    captureSelection.mockResolvedValue({
      text: "result text",
      reason: null,
      sourceApp: null,
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    });

    await fireEvent.click(screen.getByRole("button", { name: "Copy" }));

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Copied ✓" })).toBeInTheDocument();
    });

    const textarea = screen.getByRole("textbox");
    await fireEvent.input(textarea, { target: { value: "edited text" } });

    expect(screen.getByRole("button", { name: "Copy" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Copied ✓" })).not.toBeInTheDocument();
  });

  it("exposes a stable 'Working…' accessible name on the progress indicator while an AI action is in flight", async () => {
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    expect(await screen.findByLabelText("Working…")).toBeInTheDocument();

    resolveRun?.({ status: "ok", text: "rewritten text" });
    await waitFor(() => {
      expect(screen.queryByLabelText("Working…")).not.toBeInTheDocument();
    });
  });

  it("shows no Wayland notice when the compositor offers both portals", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: true,
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: false },
    });

    render(App);

    await waitFor(() => {
      expect(getPlatformInfo).toHaveBeenCalled();
    });
    expect(screen.queryByText(waylandNoticeNoCapabilitiesText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoGlobalShortcutText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoInputSynthesisText)).not.toBeInTheDocument();
  });

  it("Replace is enabled on Wayland with input synthesis, using the focus-return source app placeholder", async () => {
    // On Wayland with the RemoteDesktop portal's
    // input-synthesis capability live, `frontmost_app()` returns the
    // documented focus-return placeholder (`bundleId: null, pid: 0,
    // name: null`) instead of `null`, so the same `canReplace` gating that
    // already requires text + a non-null `sourceApp` keeps working
    // unchanged — Replace should be enabled exactly as it is with a real
    // source app on X11/macOS.
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: true,
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: false },
    });
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: null, pid: 0, name: null },
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });
  });

  it("shows the combined notice when the compositor offers neither portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: false,
      wayland: { globalShortcut: false, inputSynthesis: false, canPersistSession: false },
    });

    render(App);

    expect(await screen.findByText(waylandNoticeNoCapabilitiesText)).toBeInTheDocument();
  });

  it("shows the GlobalShortcuts-missing notice when only the shortcut portal is unavailable", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: true,
      wayland: { globalShortcut: false, inputSynthesis: true, canPersistSession: false },
    });

    render(App);

    expect(await screen.findByText(waylandNoticeNoGlobalShortcutText)).toBeInTheDocument();
  });

  it("shows the RemoteDesktop-missing notice when only the replace portal is unavailable", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: false,
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });

    render(App);

    expect(await screen.findByText(waylandNoticeNoInputSynthesisText)).toBeInTheDocument();
  });

  it("does not show any Wayland notice on the default (macOS) platform info", async () => {
    render(App);

    await waitFor(() => {
      expect(getPlatformInfo).toHaveBeenCalled();
    });
    expect(screen.queryByText(waylandNoticeNoCapabilitiesText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoGlobalShortcutText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoInputSynthesisText)).not.toBeInTheDocument();
  });

  it("offers Replace and shows no Wayland notice on Windows platform info", async () => {
    // Windows has no session/portal concept at all, so
    // Replace is offered purely off `replaceBackAvailable` (true, a final
    // platform capability) and no Wayland notice
    // should ever render regardless of session.
    getPlatformInfo.mockResolvedValue(windowsPlatformInfo());
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: null, pid: 123, name: "Notepad" },
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });
    expect(screen.queryByText(waylandNoticeNoCapabilitiesText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoGlobalShortcutText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoInputSynthesisText)).not.toBeInTheDocument();
  });

  // The input-synthesis opt-out.

  it("hides Replace on Wayland when the compositor is capable but the user switched input synthesis off", async () => {
    // `replaceBackAvailable: true` here simulates `loadPlatformInfo()`'s
    // per-window cache being stale (populated before the user toggled the
    // setting) — the frontend's own `inputSynthesisOffByChoice` guard, not
    // just the backend-computed flag, must still hide Replace.
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: true,
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: false },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: false });
    captureSelection.mockResolvedValue({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: null, pid: 0, name: null },
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });
    expect(screen.queryByRole("button", { name: "Replace" })).not.toBeInTheDocument();
  });

  it("shows no Wayland notice when input synthesis is off by choice and the GlobalShortcuts portal still works", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: false,
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: false },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: false });

    render(App);

    await waitFor(() => {
      expect(getPlatformInfo).toHaveBeenCalled();
    });
    expect(screen.queryByText(waylandNoticeNoCapabilitiesText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoGlobalShortcutText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoInputSynthesisText)).not.toBeInTheDocument();
  });

  it("names only the missing GlobalShortcuts portal when input synthesis is off by choice and the shortcut portal is also missing", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      session: "wayland",
      replaceBackAvailable: false,
      wayland: { globalShortcut: false, inputSynthesis: true, canPersistSession: false },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: false });

    render(App);

    expect(await screen.findByText(waylandNoticeNoGlobalShortcutText)).toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoCapabilitiesText)).not.toBeInTheDocument();
    expect(screen.queryByText(waylandNoticeNoInputSynthesisText)).not.toBeInTheDocument();
  });

  // Auto-copying results.

  it("copies the result automatically after a successful AI action when auto-copy is enabled", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), autoCopyResult: true });
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("some rewritten text");
    });
  });

  it("does not copy the result automatically after a successful AI action when auto-copy is disabled (the default)", async () => {
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some rewritten text");
    });

    expect(copyResult).not.toHaveBeenCalled();
  });

  it("copies the corrected text automatically when applying a spellcheck suggestion and auto-copy is enabled", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), autoCopyResult: true });
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

    spellcheck.mockResolvedValueOnce({ misspellings: [] });
    await fireEvent.click(helpButton);

    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("I help you");
    });
  });

  it("does not copy automatically on the Replace path even when auto-copy is enabled", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), autoCopyResult: true });
    captureSelection.mockResolvedValue({
      text: "original text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Replace" })).toBeEnabled();
    });

    const replaceButton = screen.getByRole("button", { name: "Replace" });
    await fireEvent.click(replaceButton);

    await waitFor(() => {
      expect(replaceBack).toHaveBeenCalledWith("original text");
    });
    expect(copyResult).not.toHaveBeenCalled();
  });

  it("does not surface an automatic-copy failure that belongs to a superseded capture", async () => {
    let capturedHandler: ((event: unknown) => void) | undefined;
    listen.mockImplementation((_event: string, handler: (event: unknown) => void) => {
      capturedHandler = handler;
      return Promise.resolve(() => {});
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), autoCopyResult: true });
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

    // Hold the auto-copy open so a fresh capture can supersede the session
    // while it is still in flight.
    let rejectCopy: ((reason: unknown) => void) | undefined;
    copyResult.mockReturnValueOnce(
      new Promise((_resolve, reject) => {
        rejectCopy = reject;
      }),
    );

    render(App);

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("some captured text");
    });

    await fireEvent.click(await screen.findByRole("button", { name: "Rewrite" }));

    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("some rewritten text");
    });

    captureSelection.mockResolvedValue({
      text: "a newer capture",
      reason: null,
      sourceApp: null,
    });
    capturedHandler?.({});

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("a newer capture");
    });

    rejectCopy?.(new Error("clipboard write failed"));

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("a newer capture");
    });
    expect(
      screen.queryByText("The result couldn't be copied automatically — use Copy."),
    ).not.toBeInTheDocument();
  });

  // Pinning.

  it("renders the pin button in its active state when popoverPinned is true", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), popoverPinned: true });

    render(App);

    const pinButton = await screen.findByRole("button", { name: "Pin popover" });
    await waitFor(() => {
      expect(pinButton).toHaveAttribute("aria-pressed", "true");
    });
    expect(pinButton).toHaveClass("active");
  });

  it("renders the pin button unpressed when popoverPinned is false (the default)", async () => {
    render(App);

    const pinButton = await screen.findByRole("button", { name: "Pin popover" });
    await waitFor(() => {
      expect(getSettings).toHaveBeenCalled();
    });
    expect(pinButton).toHaveAttribute("aria-pressed", "false");
    expect(pinButton).not.toHaveClass("active");
  });

  it("clicking the pin button re-fetches settings and persists the flipped popoverPinned flag", async () => {
    render(App);

    const pinButton = await screen.findByRole("button", { name: "Pin popover" });
    await waitFor(() => {
      expect(pinButton).toHaveAttribute("aria-pressed", "false");
    });

    getSettings.mockClear();
    await fireEvent.click(pinButton);

    await waitFor(() => {
      expect(getSettings).toHaveBeenCalledTimes(1);
    });
    expect(setSettings).toHaveBeenCalledWith(
      expect.objectContaining({ popoverPinned: true }),
    );
    await waitFor(() => {
      expect(pinButton).toHaveAttribute("aria-pressed", "true");
    });
  });

  it("Escape still hides the popover while pinned", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), popoverPinned: true });

    render(App);

    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });
    await fireEvent.keyDown(window, { key: "Escape" });
    expect(hidePopover).toHaveBeenCalledTimes(1);
  });

  it("surfaces a failure of the automatic copy instead of swallowing it silently", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), autoCopyResult: true });
    copyResult.mockRejectedValueOnce(new Error("clipboard write failed"));
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

    const rewriteButton = await screen.findByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(
        screen.getByText("The result couldn't be copied automatically — use Copy."),
      ).toBeInTheDocument();
    });
  });

  // Drag-to-move.

  it("mousedown on the toolbar begins a drag and starts the native window drag", async () => {
    const { container } = render(App);
    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });

    const toolbar = container.querySelector(".toolbar") as HTMLElement;
    await fireEvent.mouseDown(toolbar, { button: 0 });

    await waitFor(() => {
      expect(beginPopoverDrag).toHaveBeenCalledTimes(1);
    });
    expect(startDragging).toHaveBeenCalledTimes(1);
  });

  it("mousedown on the Check spelling button does not start a drag", async () => {
    render(App);
    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });

    const button = screen.getByRole("button", { name: "Check spelling" });
    await fireEvent.mouseDown(button, { button: 0 });

    expect(beginPopoverDrag).not.toHaveBeenCalled();
    expect(startDragging).not.toHaveBeenCalled();
  });

  it("mousedown on the Pin button does not start a drag", async () => {
    render(App);
    const pinButton = await screen.findByRole("button", { name: "Pin popover" });

    await fireEvent.mouseDown(pinButton, { button: 0 });

    expect(beginPopoverDrag).not.toHaveBeenCalled();
    expect(startDragging).not.toHaveBeenCalled();
  });

  it("a non-primary-button mousedown on the toolbar does not start a drag", async () => {
    const { container } = render(App);
    await waitFor(() => {
      expect(captureSelection).toHaveBeenCalled();
    });

    const toolbar = container.querySelector(".toolbar") as HTMLElement;
    // Right-click.
    await fireEvent.mouseDown(toolbar, { button: 2 });

    expect(beginPopoverDrag).not.toHaveBeenCalled();
    expect(startDragging).not.toHaveBeenCalled();
  });

  // Keyboard shortcuts.

  function pressDown(init: KeyboardEventInit) {
    return fireEvent.keyDown(window, init);
  }

  async function renderWithCapture(capture: CaptureResult) {
    captureSelection.mockResolvedValue(capture);
    render(App);
    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue(capture.text);
    });
    await waitFor(() => {
      expect(getPlatformInfo).toHaveBeenCalled();
    });
  }

  function configuredContext(): ActionContext {
    return { configured: true, profileName: "Llama", privacy: "local" };
  }

  it("pressing a prompt's shortcut runs it with the matching instruction", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    runAction.mockResolvedValue({ status: "ok", text: "rewritten" });
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "2", metaKey: true });

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "prompt",
        instruction: seededPrompts()[1]!.instruction,
      });
    });
  });

  it("⌘↩ replaces, ⌘⇧C copies, and ⌘L opens the custom row and focuses it", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    await renderWithCapture({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    pressDown({ key: "Enter", metaKey: true });
    await waitFor(() => {
      expect(replaceBack).toHaveBeenCalledWith("some captured text");
    });

    pressDown({ key: "c", metaKey: true, shiftKey: true });
    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("some captured text");
    });

    pressDown({ key: "l", metaKey: true });
    const customInput = await screen.findByPlaceholderText("Describe what to do…");
    await waitFor(() => {
      expect(customInput).toHaveFocus();
    });
  });

  it("⌘, opens Settings", async () => {
    await renderWithCapture(emptyResult());

    pressDown({ key: ",", metaKey: true });

    await waitFor(() => {
      expect(openSettings).toHaveBeenCalledTimes(1);
    });
  });

  it("the Check spelling shortcut runs it when bound, and does nothing when unbound (the default)", async () => {
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });
    spellcheck.mockClear();

    // Unbound by default — the chord must not trigger anything.
    pressDown({ key: "s", metaKey: true });
    expect(spellcheck).not.toHaveBeenCalled();
  });

  it("binding Check spelling makes its shortcut run it", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverShortcuts: { ...defaultSettings().popoverShortcuts, checkSpelling: "Mod+Shift+S" },
    });
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });
    spellcheck.mockClear();

    pressDown({ key: "s", metaKey: true, shiftKey: true });

    await waitFor(() => {
      expect(spellcheck).toHaveBeenCalledWith("some captured text");
    });
  });

  it("a user-changed binding replaces the default", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverShortcuts: { ...defaultSettings().popoverShortcuts, copy: "Mod+K" },
    });
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    // The old default no longer does anything...
    pressDown({ key: "c", metaKey: true, shiftKey: true });
    expect(copyResult).not.toHaveBeenCalled();

    // ...and the new binding does.
    pressDown({ key: "k", metaKey: true });
    await waitFor(() => {
      expect(copyResult).toHaveBeenCalledWith("some captured text");
    });
  });

  it("a prompt shortcut does nothing (and flashes key-denied) when there's no text to act on", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    await renderWithCapture(emptyResult());

    pressDown({ key: "1", metaKey: true });

    expect(runAction).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Rewrite" })).toHaveClass("key-denied");
  });

  it("a prompt shortcut does nothing while another action is already busy", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    let resolveRun: ((outcome: { status: "ok"; text: string }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "1", metaKey: true });
    await waitFor(() => {
      expect(runAction).toHaveBeenCalledTimes(1);
    });

    pressDown({ key: "2", metaKey: true });
    expect(runAction).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Shorten" })).toHaveClass("key-denied");

    resolveRun?.({ status: "ok", text: "rewritten" });
  });

  it("the Replace shortcut does nothing (and flashes key-denied) without a remembered source app", async () => {
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "Enter", metaKey: true });

    expect(replaceBack).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Replace" })).toHaveClass("key-denied");
  });

  it("a successful shortcut flashes key-pressed on its button", async () => {
    await renderWithCapture({ text: "result text", reason: null, sourceApp: null });

    pressDown({ key: "c", metaKey: true, shiftKey: true });

    expect(screen.getByRole("button", { name: "Copy" })).toHaveClass("key-pressed");
    await waitFor(() => {
      expect(copyResult).toHaveBeenCalled();
    });
  });

  it("⌘↩ in the custom field replaces instead of running the custom prompt, and a bare ↩ still runs it", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    runAction.mockResolvedValue({ status: "ok", text: "translated" });
    await renderWithCapture({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: "com.example.app", pid: 123, name: "Example" },
    });

    const customButton = screen.getByRole("button", { name: "Custom" });
    await fireEvent.click(customButton);
    const customInput = screen.getByPlaceholderText("Describe what to do…");
    await fireEvent.input(customInput, { target: { value: "Translate to French" } });

    await fireEvent.keyDown(customInput, { key: "Enter", metaKey: true });
    await waitFor(() => {
      expect(replaceBack).toHaveBeenCalledWith("some captured text");
    });
    expect(runAction).not.toHaveBeenCalled();

    await fireEvent.keyDown(customInput, { key: "Enter" });
    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "custom",
        instruction: "Translate to French",
      });
    });
  });

  it("an AltGraph-reported combination never triggers a shortcut", async () => {
    getPlatformInfo.mockResolvedValue(windowsPlatformInfo());
    getActionContext.mockResolvedValue(configuredContext());
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "@", code: "KeyQ", ctrlKey: true, altKey: true, modifierAltGraph: true });

    expect(runAction).not.toHaveBeenCalled();
    expect(copyResult).not.toHaveBeenCalled();
    expect(replaceBack).not.toHaveBeenCalled();
  });

  it("a repeated keydown never triggers a shortcut", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "1", metaKey: true, repeat: true });

    expect(runAction).not.toHaveBeenCalled();
  });

  it("works with Ctrl instead of ⌘ on Windows", async () => {
    getPlatformInfo.mockResolvedValue(windowsPlatformInfo());
    getActionContext.mockResolvedValue(configuredContext());
    runAction.mockResolvedValue({ status: "ok", text: "rewritten" });
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "1", ctrlKey: true });

    await waitFor(() => {
      expect(runAction).toHaveBeenCalledWith("some captured text", {
        kind: "prompt",
        instruction: seededPrompts()[0]!.instruction,
      });
    });
  });

  it("focuses the textarea with the caret at the end after a fresh capture", async () => {
    await renderWithCapture({ text: "hello world", reason: null, sourceApp: null });

    const textarea = screen.getByRole("textbox") as HTMLTextAreaElement;
    expect(textarea).toHaveFocus();
    expect(textarea.selectionStart).toBe("hello world".length);
    expect(textarea.selectionEnd).toBe("hello world".length);
  });

  it("re-focuses the textarea with the caret at the end once an AI action settles", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    let resolveRun: ((outcome: { status: "ok"; text: string }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    const textarea = screen.getByRole("textbox") as HTMLTextAreaElement;
    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    await waitFor(() => {
      expect(textarea).toBeDisabled();
    });

    resolveRun?.({ status: "ok", text: "rewritten text" });

    await waitFor(() => {
      expect(textarea).toHaveFocus();
    });
    expect(textarea.selectionStart).toBe("rewritten text".length);
  });

  it("shows shortcut badges after holding Mod for 400ms, hides them on keyup, and never shows one for an unbound button", async () => {
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    vi.useFakeTimers();
    try {
      await fireEvent.keyDown(window, { key: "Meta", metaKey: true });
      await vi.advanceTimersByTimeAsync(399);
      expect(document.querySelector(".shortcut-badge")).not.toBeInTheDocument();

      await vi.advanceTimersByTimeAsync(1);
      expect(document.querySelectorAll(".shortcut-badge").length).toBeGreaterThan(0);
      // Check spelling has no shortcut by default — no badge on its button.
      const checkSpellingButton = screen.getByRole("button", { name: "Check spelling" });
      expect(checkSpellingButton.querySelector(".shortcut-badge")).toBeNull();

      await fireEvent.keyUp(window, { key: "Meta" });
      expect(document.querySelector(".shortcut-badge")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("hides shortcut badges on window blur", async () => {
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    vi.useFakeTimers();
    try {
      await fireEvent.keyDown(window, { key: "Meta", metaKey: true });
      await vi.advanceTimersByTimeAsync(400);
      expect(document.querySelectorAll(".shortcut-badge").length).toBeGreaterThan(0);

      await fireEvent.blur(window);
      expect(document.querySelector(".shortcut-badge")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it("an invalid stored shortcut (a bare key with no Mod) is never matched, so it doesn't eat the character while typing", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverShortcuts: { ...defaultSettings().popoverShortcuts, customPrompt: "L" },
    });
    await renderWithCapture(emptyResult());

    const textarea = screen.getByRole("textbox");
    const event = new KeyboardEvent("keydown", { key: "l", bubbles: true, cancelable: true });
    textarea.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(false);
    expect(screen.queryByPlaceholderText("Describe what to do…")).not.toBeInTheDocument();
  });

  it("a stored lowercase shortcut still matches once canonicalized", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverShortcuts: { ...defaultSettings().popoverShortcuts, customPrompt: "mod+l" },
    });
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    pressDown({ key: "l", metaKey: true });

    const customInput = await screen.findByPlaceholderText("Describe what to do…");
    await waitFor(() => {
      expect(customInput).toHaveFocus();
    });
  });

  it("the Replace shortcut does nothing and flashes nothing when Replace is hidden", async () => {
    getPlatformInfo.mockResolvedValue({ ...windowsPlatformInfo(), replaceBackAvailable: false });
    await renderWithCapture({
      text: "some captured text",
      reason: null,
      sourceApp: { bundleId: null, pid: 123, name: "Notepad" },
    });
    expect(screen.queryByRole("button", { name: "Replace" })).not.toBeInTheDocument();

    pressDown({ key: "Enter", ctrlKey: true });

    expect(replaceBack).not.toHaveBeenCalled();
    expect(document.querySelector(".key-pressed")).not.toBeInTheDocument();
    expect(document.querySelector(".key-denied")).not.toBeInTheDocument();
  });

  it("does not steal focus back from a control the user moved to while an AI action was running", async () => {
    getActionContext.mockResolvedValue(configuredContext());
    let resolveRun: ((outcome: { status: "ok"; text: string }) => void) | undefined;
    runAction.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveRun = resolve;
        }),
    );
    await renderWithCapture({ text: "some captured text", reason: null, sourceApp: null });

    const rewriteButton = screen.getByRole("button", { name: "Rewrite" });
    await fireEvent.click(rewriteButton);

    const pinButton = screen.getByRole("button", { name: "Pin popover" });
    pinButton.focus();
    expect(pinButton).toHaveFocus();

    resolveRun?.({ status: "ok", text: "rewritten text" });

    await waitFor(() => {
      expect(screen.getByRole("textbox")).toHaveValue("rewritten text");
    });
    expect(pinButton).toHaveFocus();
  });
});
