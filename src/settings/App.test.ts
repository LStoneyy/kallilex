import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import type { Preset, ProviderProfile, Settings } from "../shared/types";

const {
  accessibilityStatus,
  openAccessibilitySettings,
  getSettings,
  setSettings,
  listProfiles,
  saveProfile,
  deleteProfile,
  setActiveProfile,
  getPresets,
  testConnection,
  isAutostartEnabled,
  enableAutostart,
  disableAutostart,
} = vi.hoisted(() => ({
  accessibilityStatus: vi.fn(),
  openAccessibilitySettings: vi.fn(),
  getSettings: vi.fn(),
  setSettings: vi.fn(),
  listProfiles: vi.fn(),
  saveProfile: vi.fn(),
  deleteProfile: vi.fn(),
  setActiveProfile: vi.fn(),
  getPresets: vi.fn(),
  testConnection: vi.fn(),
  isAutostartEnabled: vi.fn(),
  enableAutostart: vi.fn(),
  disableAutostart: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  accessibilityStatus,
  openAccessibilitySettings,
  getSettings,
  setSettings,
  listProfiles,
  saveProfile,
  deleteProfile,
  setActiveProfile,
  getPresets,
  testConnection,
  isAutostartEnabled,
  enableAutostart,
  disableAutostart,
}));

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

function defaultPresets(): Preset[] {
  return [
    { id: "ollama", label: "Ollama", baseUrl: "http://localhost:11434/v1", needsApiKey: false },
    { id: "lmstudio", label: "LM Studio", baseUrl: "http://localhost:1234/v1", needsApiKey: false },
    { id: "openai", label: "OpenAI", baseUrl: "https://api.openai.com/v1", needsApiKey: true },
    { id: "custom", label: "Custom (OpenAI-compatible)", baseUrl: "", needsApiKey: false },
  ];
}

function sampleProfile(overrides: Partial<ProviderProfile> = {}): ProviderProfile {
  return {
    id: "profile-1",
    name: "Llama",
    baseUrl: "http://localhost:11434/v1",
    model: "llama3",
    timeoutSecs: 30,
    customHeaders: [],
    enabled: true,
    hasApiKey: false,
    ...overrides,
  };
}

describe("settings App", () => {
  beforeEach(() => {
    accessibilityStatus.mockClear();
    openAccessibilitySettings.mockClear();
    getSettings.mockClear();
    setSettings.mockClear();
    listProfiles.mockClear();
    saveProfile.mockClear();
    deleteProfile.mockClear();
    setActiveProfile.mockClear();
    getPresets.mockClear();
    testConnection.mockClear();
    isAutostartEnabled.mockClear();
    enableAutostart.mockClear();
    disableAutostart.mockClear();

    accessibilityStatus.mockResolvedValue(false);
    getSettings.mockResolvedValue(defaultSettings());
    setSettings.mockImplementation((settings: Settings) => Promise.resolve(settings));
    listProfiles.mockResolvedValue([]);
    getPresets.mockResolvedValue(defaultPresets());
    isAutostartEnabled.mockResolvedValue(false);
    enableAutostart.mockResolvedValue(undefined);
    disableAutostart.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  async function openAccessibilityTab() {
    const tab = await screen.findByRole("button", { name: "Accessibility" });
    await fireEvent.click(tab);
  }

  async function openProvidersTab() {
    const tab = await screen.findByRole("button", { name: "Providers" });
    await fireEvent.click(tab);
  }

  it("renders the not-granted status from accessibilityStatus", async () => {
    accessibilityStatus.mockResolvedValue(false);

    render(App);
    await openAccessibilityTab();

    await waitFor(() => {
      expect(screen.getByText("Not granted")).toBeInTheDocument();
    });
  });

  it("updates the status badge when a later poll returns a different value", async () => {
    vi.useFakeTimers();
    accessibilityStatus.mockResolvedValue(false);

    render(App);
    const tab = await screen.findByRole("button", { name: "Accessibility" });
    await fireEvent.click(tab);

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
    await openAccessibilityTab();

    const button = await screen.findByRole("button", { name: "Open System Settings" });
    await fireEvent.click(button);

    expect(openAccessibilitySettings).toHaveBeenCalledTimes(1);
  });

  it("renders profiles from listProfiles", async () => {
    listProfiles.mockResolvedValue([sampleProfile()]);

    render(App);
    await openProvidersTab();

    expect(await screen.findByText("Llama")).toBeInTheDocument();
    expect(screen.getByText("llama3")).toBeInTheDocument();
  });

  it("preset selection pre-fills the base URL", async () => {
    render(App);
    await openProvidersTab();

    const addButton = await screen.findByRole("button", { name: "Add profile" });
    await fireEvent.click(addButton);

    const ollamaButton = await screen.findByRole("button", { name: "Ollama" });
    await fireEvent.click(ollamaButton);

    const baseUrlInput = await screen.findByLabelText("Base URL");
    expect(baseUrlInput).toHaveValue("http://localhost:11434/v1");
  });

  it("filling the form and saving calls saveProfile with the entered values and a null apiKey when untouched", async () => {
    saveProfile.mockResolvedValue([sampleProfile()]);

    render(App);
    await openProvidersTab();

    const addButton = await screen.findByRole("button", { name: "Add profile" });
    await fireEvent.click(addButton);

    const customButton = await screen.findByRole("button", { name: "Custom (OpenAI-compatible)" });
    await fireEvent.click(customButton);

    const nameInput = await screen.findByLabelText("Name");
    await fireEvent.input(nameInput, { target: { value: "My Local Model" } });

    const baseUrlInput = screen.getByLabelText("Base URL");
    await fireEvent.input(baseUrlInput, { target: { value: "http://localhost:9999/v1" } });

    const modelInput = screen.getByLabelText("Model");
    await fireEvent.input(modelInput, { target: { value: "phi3" } });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    await waitFor(() => {
      expect(saveProfile).toHaveBeenCalledWith(
        expect.objectContaining({
          id: "",
          name: "My Local Model",
          baseUrl: "http://localhost:9999/v1",
          model: "phi3",
          timeoutSecs: 30,
        }),
        null,
      );
    });
  });

  it("test connection success renders the returned latency", async () => {
    listProfiles.mockResolvedValue([sampleProfile()]);
    testConnection.mockResolvedValue(42);

    render(App);
    await openProvidersTab();

    const testButton = await screen.findByRole("button", { name: "Test" });
    await fireEvent.click(testButton);

    expect(await screen.findByText("OK · 42 ms")).toBeInTheDocument();
    expect(testConnection).toHaveBeenCalledWith("profile-1");
  });

  it("test connection failure renders the rejection message", async () => {
    listProfiles.mockResolvedValue([sampleProfile()]);
    testConnection.mockRejectedValue(new Error("Can't reach the endpoint — is the server running? (connection refused)"));

    render(App);
    await openProvidersTab();

    const testButton = await screen.findByRole("button", { name: "Test" });
    await fireEvent.click(testButton);

    expect(
      await screen.findByText("Can't reach the endpoint — is the server running? (connection refused)"),
    ).toBeInTheDocument();
  });

  it("saving the shortcut calls setSettings with the new shortcut", async () => {
    render(App);

    const shortcutInput = await screen.findByPlaceholderText("Alt+Cmd+K");
    await fireEvent.input(shortcutInput, { target: { value: "Cmd+Shift+K" } });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    await waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith(
        expect.objectContaining({ shortcut: "Cmd+Shift+K" }),
      );
    });
  });

  it("a rejected shortcut save shows the returned message", async () => {
    setSettings.mockRejectedValueOnce(
      new Error('Kallilex couldn\'t understand the shortcut "garbage": parse error'),
    );

    render(App);

    const shortcutInput = await screen.findByPlaceholderText("Alt+Cmd+K");
    await fireEvent.input(shortcutInput, { target: { value: "garbage" } });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    expect(
      await screen.findByText('Kallilex couldn\'t understand the shortcut "garbage": parse error'),
    ).toBeInTheDocument();
  });

  it("toggling spellcheck calls setSettings with the flipped flag", async () => {
    render(App);

    const checkbox = await screen.findByLabelText(
      "Automatically check spelling in the popover",
    );
    expect(checkbox).toBeChecked();

    await fireEvent.click(checkbox);

    await waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith(
        expect.objectContaining({ spellcheckEnabled: false }),
      );
    });
  });

  it("toggling autostart calls the enable wrapper", async () => {
    isAutostartEnabled.mockResolvedValue(false);

    render(App);

    const checkbox = await screen.findByLabelText("Launch Kallilex at login");
    await waitFor(() => {
      expect(checkbox).not.toBeChecked();
    });

    await fireEvent.click(checkbox);

    await waitFor(() => {
      expect(enableAutostart).toHaveBeenCalledTimes(1);
    });
  });

  it("toggling autostart off calls the disable wrapper", async () => {
    isAutostartEnabled.mockResolvedValue(true);

    render(App);

    const checkbox = await screen.findByLabelText("Launch Kallilex at login");
    await waitFor(() => {
      expect(checkbox).toBeChecked();
    });

    await fireEvent.click(checkbox);

    await waitFor(() => {
      expect(disableAutostart).toHaveBeenCalledTimes(1);
    });
  });
});
