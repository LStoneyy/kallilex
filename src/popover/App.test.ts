import { render, screen, fireEvent } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";

const { hidePopover } = vi.hoisted(() => ({
  hidePopover: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  hidePopover,
}));

describe("popover App", () => {
  beforeEach(() => {
    hidePopover.mockClear();
  });

  it("renders the placeholder shell", () => {
    render(App);
    expect(screen.getByText("Kallilex")).toBeInTheDocument();
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
