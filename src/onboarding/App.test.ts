import { render, screen, fireEvent, waitFor } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import { resetPlatformInfoForTests } from "../shared/platform";
import type { PlatformInfo, Preset, ProviderProfile, Settings } from "../shared/types";

const {
  accessibilityStatus,
  openAccessibilitySettings,
  getSettings,
  getPresets,
  saveProfile,
  testConnection,
  isAutostartEnabled,
  enableAutostart,
  disableAutostart,
  getPlatformInfo,
  completeOnboarding,
  setInputSynthesis,
} = vi.hoisted(() => ({
  accessibilityStatus: vi.fn(),
  openAccessibilitySettings: vi.fn(),
  getSettings: vi.fn(),
  getPresets: vi.fn(),
  saveProfile: vi.fn(),
  testConnection: vi.fn(),
  isAutostartEnabled: vi.fn(),
  enableAutostart: vi.fn(),
  disableAutostart: vi.fn(),
  getPlatformInfo: vi.fn(),
  completeOnboarding: vi.fn(),
  setInputSynthesis: vi.fn(),
}));

vi.mock("../shared/invoke", () => ({
  accessibilityStatus,
  openAccessibilitySettings,
  getSettings,
  getPresets,
  saveProfile,
  testConnection,
  isAutostartEnabled,
  enableAutostart,
  disableAutostart,
  getPlatformInfo,
  completeOnboarding,
  setInputSynthesis,
}));

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

function x11PlatformInfo(): PlatformInfo {
  return {
    os: "linux",
    session: "x11",
    replaceBackAvailable: true,
    permissionRequired: false,
    defaultShortcut: "Ctrl+Alt+K",
    wayland: null,
  };
}

function waylandPlatformInfo(overrides: Partial<NonNullable<PlatformInfo["wayland"]>> = {}): PlatformInfo {
  return {
    os: "linux",
    session: "wayland",
    replaceBackAvailable: true,
    permissionRequired: false,
    defaultShortcut: "Ctrl+Alt+K",
    wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: true, ...overrides },
  };
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

async function clickButton(name: string) {
  const button = await screen.findByRole("button", { name });
  await fireEvent.click(button);
}

describe("onboarding App", () => {
  beforeEach(() => {
    resetPlatformInfoForTests();
    accessibilityStatus.mockClear();
    openAccessibilitySettings.mockClear();
    getSettings.mockClear();
    getPresets.mockClear();
    saveProfile.mockClear();
    testConnection.mockClear();
    isAutostartEnabled.mockClear();
    enableAutostart.mockClear();
    disableAutostart.mockClear();
    getPlatformInfo.mockClear();
    completeOnboarding.mockClear();
    setInputSynthesis.mockClear();

    accessibilityStatus.mockResolvedValue(false);
    getSettings.mockResolvedValue(defaultSettings());
    getPresets.mockResolvedValue(defaultPresets());
    saveProfile.mockResolvedValue([sampleProfile()]);
    testConnection.mockResolvedValue(42);
    isAutostartEnabled.mockResolvedValue(false);
    enableAutostart.mockResolvedValue(undefined);
    disableAutostart.mockResolvedValue(undefined);
    getPlatformInfo.mockResolvedValue(macosPlatformInfo());
    completeOnboarding.mockResolvedValue(undefined);
    setInputSynthesis.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows the platform's default shortcut on the welcome step", async () => {
    getPlatformInfo.mockResolvedValue({ ...macosPlatformInfo(), defaultShortcut: "Alt+Cmd+K" });

    render(App);

    expect(await screen.findByText("Alt+Cmd+K", { selector: "code" })).toBeInTheDocument();
  });

  it("disables Get started until platform info resolves", async () => {
    let resolvePlatformInfo!: (info: PlatformInfo) => void;
    getPlatformInfo.mockReturnValue(
      new Promise<PlatformInfo>((resolve) => {
        resolvePlatformInfo = resolve;
      }),
    );

    render(App);

    const button = await screen.findByRole("button", { name: "Get started" });
    expect(button).toBeDisabled();

    resolvePlatformInfo(macosPlatformInfo());

    await waitFor(() => {
      expect(button).not.toBeDisabled();
    });
  });

  describe("macOS", () => {
    it("shows the permission step with a live-polling status pill and the deep-link button", async () => {
      vi.useFakeTimers();
      accessibilityStatus.mockResolvedValue(false);

      render(App);
      await clickButton("Get started");

      await vi.waitFor(() => {
        expect(accessibilityStatus).toHaveBeenCalledTimes(1);
      });
      expect(screen.getByText("Not granted")).toBeInTheDocument();

      accessibilityStatus.mockResolvedValue(true);
      await vi.advanceTimersByTimeAsync(1000);
      expect(screen.getByText("Granted")).toBeInTheDocument();

      await fireEvent.click(screen.getByRole("button", { name: "Open System Settings" }));
      expect(openAccessibilitySettings).toHaveBeenCalledTimes(1);
    });

    it("Continue on the permission step is never disabled", async () => {
      render(App);
      await clickButton("Get started");

      const button = await screen.findByRole("button", { name: "Continue" });
      expect(button).not.toBeDisabled();
    });
  });

  describe("Windows", () => {
    it("shows the spell-check note instead of the permission step and never polls accessibilityStatus", async () => {
      getPlatformInfo.mockResolvedValue(windowsPlatformInfo());

      render(App);
      await clickButton("Get started");

      expect(await screen.findByText(/native Windows spell checker|Windows spell check/i)).toBeInTheDocument();
      expect(screen.queryByText("Not granted")).not.toBeInTheDocument();
      expect(accessibilityStatus).not.toHaveBeenCalled();
    });
  });

  describe("Linux X11", () => {
    it("goes straight from welcome to the provider step", async () => {
      getPlatformInfo.mockResolvedValue(x11PlatformInfo());

      render(App);
      await clickButton("Get started");

      expect(await screen.findByText("Set up AI actions")).toBeInTheDocument();
      expect(accessibilityStatus).not.toHaveBeenCalled();
    });
  });

  describe("Linux Wayland", () => {
    it("shows the paste-back step before Provider", async () => {
      getPlatformInfo.mockResolvedValue(waylandPlatformInfo());

      render(App);
      await clickButton("Get started");

      expect(await screen.findByText("Automatic paste-back")).toBeInTheDocument();
    });

    it("initializes the toggle from persisted settings (on by default) and toggling calls setInputSynthesis", async () => {
      getPlatformInfo.mockResolvedValue(waylandPlatformInfo());
      getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: true });

      render(App);
      await clickButton("Get started");

      const checkbox = await screen.findByLabelText("Use automatic paste-back");
      await waitFor(() => {
        expect(checkbox).toBeChecked();
      });

      await fireEvent.click(checkbox);

      await waitFor(() => {
        expect(setInputSynthesis).toHaveBeenCalledWith(false);
      });
    });

    it("shows a not-available note instead of the toggle when the compositor has no input synthesis", async () => {
      getPlatformInfo.mockResolvedValue(waylandPlatformInfo({ inputSynthesis: false }));

      render(App);
      await clickButton("Get started");

      expect(await screen.findByText(/not available on this desktop/i)).toBeInTheDocument();
      expect(screen.queryByLabelText("Use automatic paste-back")).not.toBeInTheDocument();
    });
  });

  describe("Provider step", () => {
    async function goToProviderStep() {
      getPlatformInfo.mockResolvedValue(x11PlatformInfo());
      render(App);
      await clickButton("Get started");
      await screen.findByText("Set up AI actions");
    }

    it("renders presets and pre-fills the base URL on selection", async () => {
      await goToProviderStep();

      await clickButton("Ollama");

      const baseUrlInput = await screen.findByLabelText("Base URL");
      expect(baseUrlInput).toHaveValue("http://localhost:11434/v1");
    });

    it("Save calls saveProfile with the draft and API key, and success shows the saved view", async () => {
      await goToProviderStep();
      await clickButton("Custom (OpenAI-compatible)");

      await fireEvent.input(screen.getByLabelText("Name"), { target: { value: "My Model" } });
      await fireEvent.input(screen.getByLabelText("Base URL"), {
        target: { value: "http://localhost:9999/v1" },
      });
      await fireEvent.input(screen.getByLabelText("Model"), { target: { value: "phi3" } });
      await fireEvent.input(screen.getByLabelText("API key"), { target: { value: "secret-key" } });

      await clickButton("Save");

      await waitFor(() => {
        expect(saveProfile).toHaveBeenCalledWith(
          expect.objectContaining({
            id: "",
            name: "My Model",
            baseUrl: "http://localhost:9999/v1",
            model: "phi3",
          }),
          "secret-key",
        );
      });

      expect(await screen.findByText("Profile saved and set as active.")).toBeInTheDocument();
    });

    it("Skip never calls saveProfile", async () => {
      await goToProviderStep();

      await clickButton("Skip for now");

      expect(saveProfile).not.toHaveBeenCalled();
      expect(await screen.findByText("You're all set")).toBeInTheDocument();
    });

    it("a save failure stays on the step and Skip remains available", async () => {
      saveProfile.mockRejectedValueOnce(new Error("Base URL is required."));
      await goToProviderStep();
      await clickButton("Custom (OpenAI-compatible)");

      await clickButton("Save");

      expect(await screen.findByText("Base URL is required.")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Skip for now" })).toBeInTheDocument();
    });

    it("test connection success and failure never block", async () => {
      await goToProviderStep();
      await clickButton("Custom (OpenAI-compatible)");
      await clickButton("Save");
      await screen.findByText("Profile saved and set as active.");

      testConnection.mockResolvedValue(17);
      await clickButton("Test connection");
      expect(await screen.findByText("OK · 17 ms")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Continue" })).toBeInTheDocument();

      testConnection.mockRejectedValueOnce(new Error("connection refused"));
      await clickButton("Test connection");
      expect(await screen.findByText("connection refused")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Continue" })).toBeInTheDocument();
    });
  });

  describe("Finish step", () => {
    async function goToFinishStep() {
      getPlatformInfo.mockResolvedValue(x11PlatformInfo());
      render(App);
      await clickButton("Get started");
      await screen.findByText("Set up AI actions");
      await clickButton("Skip for now");
      await screen.findByText("You're all set");
    }

    it("defaults the autostart toggle to off and toggling calls enableAutostart", async () => {
      isAutostartEnabled.mockResolvedValue(false);
      await goToFinishStep();

      const checkbox = await screen.findByLabelText("Launch Kallilex at login");
      await waitFor(() => {
        expect(checkbox).not.toBeChecked();
      });

      await fireEvent.click(checkbox);

      await waitFor(() => {
        expect(enableAutostart).toHaveBeenCalledTimes(1);
      });
    });

    it("an autostart error is shown inline and does not block Done", async () => {
      enableAutostart.mockRejectedValueOnce(new Error("autostart failed"));
      await goToFinishStep();

      const checkbox = await screen.findByLabelText("Launch Kallilex at login");
      await fireEvent.click(checkbox);

      expect(await screen.findByText("autostart failed")).toBeInTheDocument();

      await clickButton("Done");
      expect(completeOnboarding).toHaveBeenCalledTimes(1);
    });

    it("Done calls completeOnboarding", async () => {
      await goToFinishStep();

      await clickButton("Done");

      expect(completeOnboarding).toHaveBeenCalledTimes(1);
    });
  });
});
