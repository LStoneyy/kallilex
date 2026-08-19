import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";

const { accessibilityStatus, openAccessibilitySettings } = vi.hoisted(() => ({
  accessibilityStatus: vi.fn(),
  openAccessibilitySettings: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  accessibilityStatus,
  openAccessibilitySettings,
}));

describe("settings App", () => {
  beforeEach(() => {
    accessibilityStatus.mockClear();
    openAccessibilitySettings.mockClear();
    accessibilityStatus.mockResolvedValue(false);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders the not-granted status from accessibilityStatus", async () => {
    accessibilityStatus.mockResolvedValue(false);

    render(App);

    await waitFor(() => {
      expect(screen.getByText("Not granted")).toBeInTheDocument();
    });
  });

  it("updates the status badge when a later poll returns a different value", async () => {
    vi.useFakeTimers();
    accessibilityStatus.mockResolvedValue(false);

    render(App);

    await vi.waitFor(() => {
      expect(accessibilityStatus).toHaveBeenCalledTimes(1);
    });
    expect(screen.getByText("Not granted")).toBeInTheDocument();

    accessibilityStatus.mockResolvedValue(true);
    await vi.advanceTimersByTimeAsync(1000);

    expect(screen.getByText("Granted")).toBeInTheDocument();
  });

  it("invokes openAccessibilitySettings when the deep-link button is clicked", async () => {
    render(App);

    const button = await screen.findByRole("button", { name: "Open System Settings" });
    await fireEvent.click(button);

    expect(openAccessibilitySettings).toHaveBeenCalledTimes(1);
  });
});
