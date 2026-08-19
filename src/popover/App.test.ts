import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import type { CaptureResult } from "../shared/types";

const { hidePopover, captureSelection, openAccessibilitySettings } = vi.hoisted(() => ({
  hidePopover: vi.fn(),
  captureSelection: vi.fn(),
  openAccessibilitySettings: vi.fn(),
}));

const { listen } = vi.hoisted(() => ({
  listen: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  hidePopover,
  captureSelection,
  openAccessibilitySettings,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen,
}));

function emptyResult(): CaptureResult {
  return { text: "", reason: null, sourceApp: null };
}

describe("popover App", () => {
  beforeEach(() => {
    hidePopover.mockClear();
    captureSelection.mockClear();
    openAccessibilitySettings.mockClear();
    listen.mockClear();
    captureSelection.mockResolvedValue(emptyResult());
    listen.mockResolvedValue(() => {});
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

  it("invokes hidePopover when Escape is pressed", async () => {
    render(App);
    await fireEvent.keyDown(window, { key: "Escape" });
    expect(hidePopover).toHaveBeenCalledTimes(1);
  });

  it("does not invoke hidePopover for other keys", async () => {
    render(App);
    await fireEvent.keyDown(window, { key: "Enter" });
    expect(hidePopover).not.toHaveBeenCalled();
  });
});
