import { render, screen, fireEvent, waitFor, within } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";
import { resetPlatformInfoForTests } from "../shared/platform";
import type {
  CustomPrompt,
  PlatformInfo,
  Preset,
  ProviderProfile,
  Settings,
  UpdateStatus,
} from "../shared/types";

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
  getPlatformInfo,
  getWaylandShortcutTrigger,
  resetPopoverPosition,
  listPrompts,
  savePrompt,
  deletePrompt,
  getUpdateStatus,
  checkForUpdates,
  installUpdate,
  openUpdateReleasePage,
  assignShortcut,
  resetPopoverShortcuts,
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
  getPlatformInfo: vi.fn(),
  getWaylandShortcutTrigger: vi.fn(),
  resetPopoverPosition: vi.fn(),
  listPrompts: vi.fn(),
  savePrompt: vi.fn(),
  deletePrompt: vi.fn(),
  getUpdateStatus: vi.fn(),
  checkForUpdates: vi.fn(),
  installUpdate: vi.fn(),
  openUpdateReleasePage: vi.fn(),
  assignShortcut: vi.fn(),
  resetPopoverShortcuts: vi.fn(),
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
  getPlatformInfo,
  getWaylandShortcutTrigger,
  resetPopoverPosition,
  listPrompts,
  savePrompt,
  deletePrompt,
  getUpdateStatus,
  checkForUpdates,
  installUpdate,
  openUpdateReleasePage,
  assignShortcut,
  resetPopoverShortcuts,
}));

const { listen } = vi.hoisted(() => ({
  listen: vi.fn(),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen,
}));

function defaultPrompts(): CustomPrompt[] {
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

function defaultPopoverShortcuts(): Settings["popoverShortcuts"] {
  return {
    replace: "Mod+Enter",
    copy: "Mod+Shift+C",
    customPrompt: "Mod+L",
    openSettings: "Mod+,",
    checkSpelling: null,
  };
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
    prompts: defaultPrompts(),
    updateChannel: "stable",
    updateCheckFrequency: "daily",
    popoverShortcuts: defaultPopoverShortcuts(),
    promptShortcutsSeeded: true,
  };
}

function updateStatus(overrides: Partial<UpdateStatus> = {}): UpdateStatus {
  return {
    currentVersion: "0.6.0-beta.1",
    channel: "stable",
    lastCheckAt: null,
    phase: "idle",
    available: null,
    progress: null,
    error: null,
    ...overrides,
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
    resetPlatformInfoForTests();
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
    getPlatformInfo.mockClear();
    getWaylandShortcutTrigger.mockClear();
    resetPopoverPosition.mockClear();
    listPrompts.mockClear();
    savePrompt.mockClear();
    deletePrompt.mockClear();
    getUpdateStatus.mockClear();
    checkForUpdates.mockClear();
    installUpdate.mockClear();
    openUpdateReleasePage.mockClear();
    assignShortcut.mockClear();
    resetPopoverShortcuts.mockClear();
    listen.mockClear();

    accessibilityStatus.mockResolvedValue(false);
    getSettings.mockResolvedValue(defaultSettings());
    setSettings.mockImplementation((settings: Settings) => Promise.resolve(settings));
    listProfiles.mockResolvedValue([]);
    getPresets.mockResolvedValue(defaultPresets());
    isAutostartEnabled.mockResolvedValue(false);
    enableAutostart.mockResolvedValue(undefined);
    disableAutostart.mockResolvedValue(undefined);
    getPlatformInfo.mockResolvedValue(macosPlatformInfo());
    getWaylandShortcutTrigger.mockResolvedValue(null);
    resetPopoverPosition.mockResolvedValue(defaultSettings());
    listPrompts.mockResolvedValue(defaultPrompts());
    getUpdateStatus.mockResolvedValue(updateStatus());
    checkForUpdates.mockResolvedValue(updateStatus());
    installUpdate.mockResolvedValue(undefined);
    openUpdateReleasePage.mockResolvedValue(undefined);
    listen.mockResolvedValue(() => {});
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  async function openAccessibilityTab() {
    const tab = await screen.findByRole("button", { name: "Accessibility" });
    await fireEvent.click(tab);
  }

  async function openShortcutsTab() {
    const tab = await screen.findByRole("button", { name: "Shortcuts" });
    await fireEvent.click(tab);
  }

  async function openProvidersTab() {
    const tab = await screen.findByRole("button", { name: "Providers" });
    await fireEvent.click(tab);
  }

  async function openPromptsTab() {
    const tab = await screen.findByRole("button", { name: "Prompts" });
    await fireEvent.click(tab);
  }

  async function openUpdatesTab() {
    const tab = await screen.findByRole("button", { name: "Updates" });
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

  it("does not start accessibility polling if the component is unmounted before platform info resolves", async () => {
    vi.useFakeTimers();
    let resolvePlatformInfo!: (info: PlatformInfo) => void;
    getPlatformInfo.mockReturnValue(
      new Promise<PlatformInfo>((resolve) => {
        resolvePlatformInfo = resolve;
      }),
    );

    const { unmount } = render(App);
    unmount();

    resolvePlatformInfo(macosPlatformInfo());
    await vi.advanceTimersByTimeAsync(5000);

    expect(accessibilityStatus).not.toHaveBeenCalled();
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

  // ---- Prompts tab -------------------------------------------------------

  it("renders the seeded prompts from listPrompts", async () => {
    render(App);
    await openPromptsTab();

    expect(await screen.findByText("Rewrite")).toBeInTheDocument();
    expect(screen.getByText("Shorten")).toBeInTheDocument();
    expect(screen.getByText("Improve clarity")).toBeInTheDocument();
  });

  it("adding a prompt calls savePrompt and shows the new entry", async () => {
    savePrompt.mockResolvedValue([
      ...defaultPrompts(),
      { id: "prompt-new", label: "Translate", instruction: "Translate to French.", shortcut: "Mod+4" },
    ]);

    render(App);
    await openPromptsTab();

    const addButton = await screen.findByRole("button", { name: "Add prompt" });
    await fireEvent.click(addButton);

    const labelInput = await screen.findByLabelText("Label");
    await fireEvent.input(labelInput, { target: { value: "Translate" } });

    const instructionInput = screen.getByLabelText("Instruction");
    await fireEvent.input(instructionInput, { target: { value: "Translate to French." } });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    // ⌘1-⌘3 are already taken by the three seeded prompts, so the new one
    // was pre-filled with the next free slot.
    await waitFor(() => {
      expect(savePrompt).toHaveBeenCalledWith(
        {
          id: "",
          label: "Translate",
          instruction: "Translate to French.",
          shortcut: "Mod+4",
        },
        false,
      );
    });
    expect(await screen.findByText("Translate")).toBeInTheDocument();
  });

  it("the new-prompt form is pre-filled with the next free ⌘N", async () => {
    render(App);
    await openPromptsTab();

    const addButton = await screen.findByRole("button", { name: "Add prompt" });
    await fireEvent.click(addButton);

    expect(
      await screen.findByLabelText(
        "Shortcut for this prompt: ⌘4. Press Enter to record a new one.",
      ),
    ).toBeInTheDocument();
  });

  it("the new-prompt form leaves the shortcut unset once all nine slots are taken", async () => {
    listPrompts.mockResolvedValue(
      Array.from({ length: 9 }, (_, i) => ({
        id: `prompt-${i + 1}`,
        label: `Prompt ${i + 1}`,
        instruction: "Do something.",
        shortcut: `Mod+${i + 1}`,
      })),
    );
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      prompts: Array.from({ length: 9 }, (_, i) => ({
        id: `prompt-${i + 1}`,
        label: `Prompt ${i + 1}`,
        instruction: "Do something.",
        shortcut: `Mod+${i + 1}`,
      })),
    });

    render(App);
    await openPromptsTab();

    const addButton = await screen.findByRole("button", { name: "Add prompt" });
    await fireEvent.click(addButton);

    expect(
      await screen.findByLabelText(
        "Shortcut for this prompt: not set. Press Enter to record a new one.",
      ),
    ).toBeInTheDocument();
  });

  it("editing a prompt prefills the form with its current values", async () => {
    render(App);
    await openPromptsTab();

    await screen.findByText("Rewrite");
    const editButtons = screen.getAllByRole("button", { name: "Edit" });
    await fireEvent.click(editButtons[0]!);

    const labelInput = await screen.findByLabelText("Label");
    expect(labelInput).toHaveValue("Rewrite");
    const instructionInput = screen.getByLabelText("Instruction");
    expect(instructionInput).toHaveValue(defaultPrompts()[0]!.instruction);
  });

  it("editing a prompt and saving preserves its existing shortcut", async () => {
    savePrompt.mockResolvedValue(defaultPrompts());

    render(App);
    await openPromptsTab();

    await screen.findByText("Rewrite");
    const editButtons = screen.getAllByRole("button", { name: "Edit" });
    await fireEvent.click(editButtons[0]!);

    const saveButton = await screen.findByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    await waitFor(() => {
      expect(savePrompt).toHaveBeenCalledWith(
        {
          id: "builtin-rewrite",
          label: "Rewrite",
          instruction: defaultPrompts()[0]!.instruction,
          shortcut: "Mod+1",
        },
        false,
      );
    });
  });

  it("deleting a prompt requires a second confirming click, then calls deletePrompt", async () => {
    deletePrompt.mockResolvedValue(
      defaultPrompts().filter((p) => p.id !== "builtin-rewrite"),
    );

    render(App);
    await openPromptsTab();

    await screen.findByText("Rewrite");
    const deleteButtons = screen.getAllByRole("button", { name: "Delete" });
    await fireEvent.click(deleteButtons[0]!);

    expect(deletePrompt).not.toHaveBeenCalled();
    const confirmButton = await screen.findByRole("button", { name: "Confirm delete?" });
    await fireEvent.click(confirmButton);

    await waitFor(() => {
      expect(deletePrompt).toHaveBeenCalledWith("builtin-rewrite");
    });
    await waitFor(() => {
      expect(screen.queryByText("Rewrite")).not.toBeInTheDocument();
    });
  });

  it("switching tabs clears an armed delete confirmation on the Prompts tab", async () => {
    render(App);
    await openPromptsTab();

    await screen.findByText("Rewrite");
    const deleteButtons = screen.getAllByRole("button", { name: "Delete" });
    await fireEvent.click(deleteButtons[0]!);
    await screen.findByRole("button", { name: "Confirm delete?" });

    await openAccessibilityTab();
    await openPromptsTab();

    expect(screen.queryByRole("button", { name: "Confirm delete?" })).not.toBeInTheDocument();
    expect(deletePrompt).not.toHaveBeenCalled();
  });

  it("opening the add-prompt form clears an armed delete confirmation", async () => {
    render(App);
    await openPromptsTab();

    await screen.findByText("Rewrite");
    const deleteButtons = screen.getAllByRole("button", { name: "Delete" });
    await fireEvent.click(deleteButtons[0]!);
    await screen.findByRole("button", { name: "Confirm delete?" });

    const addButton = await screen.findByRole("button", { name: "Add prompt" });
    await fireEvent.click(addButton);
    const cancelButton = await screen.findByRole("button", { name: "Cancel" });
    await fireEvent.click(cancelButton);

    expect(screen.queryByRole("button", { name: "Confirm delete?" })).not.toBeInTheDocument();
    expect(deletePrompt).not.toHaveBeenCalled();
  });

  it("shows a validation error when saving a prompt with a blank label", async () => {
    savePrompt.mockRejectedValueOnce(new Error("Prompt label must not be empty."));

    render(App);
    await openPromptsTab();

    const addButton = await screen.findByRole("button", { name: "Add prompt" });
    await fireEvent.click(addButton);

    const instructionInput = await screen.findByLabelText("Instruction");
    await fireEvent.input(instructionInput, { target: { value: "Do something." } });

    const saveButton = screen.getByRole("button", { name: "Save" });
    await fireEvent.click(saveButton);

    expect(await screen.findByText("Prompt label must not be empty.")).toBeInTheDocument();
  });

  it("recording a new global shortcut calls assignShortcut with the accelerator", async () => {
    assignShortcut.mockResolvedValue({ ...defaultSettings(), shortcut: "Shift+Cmd+K" });

    render(App);
    await openShortcutsTab();

    const recorderButton = await screen.findByRole("button", {
      name: /Open Kallilex \(global\)/,
    });
    await fireEvent.click(recorderButton);
    await fireEvent.keyDown(recorderButton, {
      key: "k",
      code: "KeyK",
      metaKey: true,
      shiftKey: true,
    });

    await waitFor(() => {
      expect(assignShortcut).toHaveBeenCalledWith({ kind: "global" }, "Shift+Cmd+K", false);
    });
  });

  it("a rejected global shortcut save shows the returned message and re-fetches settings", async () => {
    assignShortcut.mockRejectedValueOnce(
      new Error(
        "Settings were saved, but the new shortcut could not be registered: already in use",
      ),
    );

    render(App);
    await openShortcutsTab();

    expect(getSettings).toHaveBeenCalledTimes(1);

    const recorderButton = await screen.findByRole("button", {
      name: /Open Kallilex \(global\)/,
    });
    await fireEvent.click(recorderButton);
    await fireEvent.keyDown(recorderButton, {
      key: "k",
      code: "KeyK",
      metaKey: true,
      shiftKey: true,
    });

    expect(
      await screen.findByText(
        "Settings were saved, but the new shortcut could not be registered: already in use",
      ),
    ).toBeInTheDocument();
    // The command can save the shortcut and still fail to register it at
    // the OS level — local state is re-fetched either way so it never
    // disagrees with what was actually persisted.
    await waitFor(() => {
      expect(getSettings).toHaveBeenCalledTimes(2);
    });
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

  it("reflects the platform's default shortcut in the hint", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      defaultShortcut: "Ctrl+Alt+K",
    });

    render(App);
    await openShortcutsTab();

    expect(await screen.findByText("Ctrl+Alt+K", { selector: "code" })).toBeInTheDocument();
  });

  it("replaces the Accessibility grant UI with a platform note when no permission is required", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
    });

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText("No system permission is needed to capture selections on this platform."),
    ).toBeInTheDocument();
    expect(screen.queryByText("Not granted")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open System Settings" })).not.toBeInTheDocument();
    expect(accessibilityStatus).not.toHaveBeenCalled();
  });

  it("reflects Windows' default shortcut in the hint", async () => {
    getPlatformInfo.mockResolvedValue(windowsPlatformInfo());

    render(App);
    await openShortcutsTab();

    expect(await screen.findByText("Ctrl+Alt+K", { selector: "code" })).toBeInTheDocument();
  });

  it("shows the no-permission-needed platform note on Windows without any Wayland sub-block", async () => {
    getPlatformInfo.mockResolvedValue(windowsPlatformInfo());

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText("No system permission is needed to capture selections on this platform."),
    ).toBeInTheDocument();
    expect(screen.queryByText("Not granted")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open System Settings" })).not.toBeInTheDocument();
    expect(accessibilityStatus).not.toHaveBeenCalled();
    expect(
      screen.queryByText(/Wayland capabilities \(detected via your desktop's XDG portals\)/),
    ).not.toBeInTheDocument();
  });

  it("shows both Wayland capability rows as unavailable when the compositor offers neither portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: false, inputSynthesis: false, canPersistSession: false },
    });

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText(
        /Unavailable — your compositor doesn't offer the GlobalShortcuts portal/,
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Unavailable — your compositor doesn't offer the RemoteDesktop portal/),
    ).toBeInTheDocument();
  });

  it("shows both Wayland capability rows as available when the compositor offers both portals", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: true },
    });

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText(/Managed by your system \(GlobalShortcuts portal\)/),
    ).toBeInTheDocument();
    expect(screen.getByText(/Available \(RemoteDesktop portal\)/)).toBeInTheDocument();
  });

  it("does not show the Wayland capability list on an x11 session", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "x11",
    });

    render(App);
    await openAccessibilityTab();

    await screen.findByText("No system permission is needed to capture selections on this platform.");
    expect(
      screen.queryByText(/Wayland capabilities \(detected via your desktop's XDG portals\)/),
    ).not.toBeInTheDocument();
  });

  it("shows the portal-reported trigger read-only when the compositor offers the GlobalShortcuts portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });
    getWaylandShortcutTrigger.mockResolvedValue("CTRL+ALT+k");

    render(App);
    await openShortcutsTab();

    expect(await screen.findByText("CTRL+ALT+k", { selector: "code" })).toBeInTheDocument();
    expect(
      screen.getByText(/This shortcut is managed by your system/),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Open Kallilex \(global\)/ }),
    ).not.toBeInTheDocument();
  });

  it("shows a not-bound hint when the portal declined or hasn't confirmed the shortcut", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });
    getWaylandShortcutTrigger.mockResolvedValue(null);

    render(App);
    await openShortcutsTab();

    expect(
      await screen.findByText(/Not currently bound/),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Open Kallilex \(global\)/ }),
    ).not.toBeInTheDocument();
  });

  it("picks up a later-confirmed portal trigger by polling, since the bind can still be pending when the window mounts", async () => {
    vi.useFakeTimers();
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });
    getWaylandShortcutTrigger.mockResolvedValue(null);

    render(App);
    await openShortcutsTab();

    await vi.waitFor(() => {
      expect(getWaylandShortcutTrigger).toHaveBeenCalledTimes(1);
    });
    expect(screen.getByText(/Not currently bound/)).toBeInTheDocument();

    getWaylandShortcutTrigger.mockResolvedValue("CTRL+ALT+k");
    await vi.advanceTimersByTimeAsync(1000);

    expect(screen.getByText("CTRL+ALT+k", { selector: "code" })).toBeInTheDocument();
    expect(screen.queryByText(/Not currently bound/)).not.toBeInTheDocument();
  });

  it("keeps the shortcut recorder on Wayland when the compositor has no GlobalShortcuts portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: false, inputSynthesis: false, canPersistSession: false },
    });

    render(App);
    await openShortcutsTab();

    expect(
      await screen.findByRole("button", { name: /Open Kallilex \(global\)/ }),
    ).toBeInTheDocument();
    expect(getWaylandShortcutTrigger).not.toHaveBeenCalled();
  });

  it("does not render the input-synthesis opt-out on macOS", async () => {
    render(App);

    await screen.findByLabelText("Automatically check spelling in the popover");
    expect(screen.queryByLabelText("Use automatic paste-back")).not.toBeInTheDocument();
  });

  it("does not render the input-synthesis opt-out on an X11 session", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "x11",
    });

    render(App);

    await screen.findByLabelText("Automatically check spelling in the popover");
    expect(screen.queryByLabelText("Use automatic paste-back")).not.toBeInTheDocument();
  });

  it("does not render the input-synthesis opt-out on a Wayland session whose compositor offers no RemoteDesktop portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });

    render(App);

    await screen.findByLabelText("Automatically check spelling in the popover");
    expect(screen.queryByLabelText("Use automatic paste-back")).not.toBeInTheDocument();
  });

  it("renders the input-synthesis opt-out on a Wayland session, reflecting the persisted value", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: true },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: false });

    render(App);

    const checkbox = await screen.findByLabelText("Use automatic paste-back");
    await waitFor(() => {
      expect(checkbox).not.toBeChecked();
    });
  });

  it("toggling the input-synthesis opt-out re-fetches settings and saves only the flipped field", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: true },
    });
    const initial: Settings = { ...defaultSettings(), shortcut: "Ctrl+Alt+K", inputSynthesisEnabled: true };
    const changedElsewhere: Settings = {
      ...defaultSettings(),
      shortcut: "Ctrl+Alt+K",
      inputSynthesisEnabled: true,
      activeProfileId: "profile-from-another-tab",
      profiles: [
        {
          id: "profile-from-another-tab",
          name: "Added elsewhere",
          baseUrl: "http://localhost:5555/v1",
          model: "phi3",
          timeoutSecs: 20,
          customHeaders: [],
          enabled: true,
          hasApiKey: false,
        },
      ],
    };
    getSettings.mockResolvedValueOnce(initial).mockResolvedValueOnce(changedElsewhere);

    render(App);

    const checkbox = await screen.findByLabelText("Use automatic paste-back");
    await waitFor(() => {
      expect(checkbox).toBeChecked();
    });

    await fireEvent.click(checkbox);

    await waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith({
        ...changedElsewhere,
        inputSynthesisEnabled: false,
      });
    });
  });

  it("renders the auto-copy checkbox on macOS and toggling it re-fetches settings and saves only the flipped field", async () => {
    const initial: Settings = { ...defaultSettings(), shortcut: "Ctrl+Alt+K" };
    const changedElsewhere: Settings = {
      ...defaultSettings(),
      shortcut: "Ctrl+Alt+K",
      activeProfileId: "profile-from-another-tab",
      profiles: [
        {
          id: "profile-from-another-tab",
          name: "Added elsewhere",
          baseUrl: "http://localhost:5555/v1",
          model: "phi3",
          timeoutSecs: 20,
          customHeaders: [],
          enabled: true,
          hasApiKey: false,
        },
      ],
    };
    getSettings.mockResolvedValueOnce(initial).mockResolvedValueOnce(changedElsewhere);

    render(App);

    const checkbox = await screen.findByLabelText("Copy the result automatically");
    expect(checkbox).not.toBeChecked();

    await fireEvent.click(checkbox);

    await waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith({
        ...changedElsewhere,
        autoCopyResult: true,
      });
    });
  });

  // Popover position reset.

  it("renders the reset-position button disabled when the popover has no saved position", async () => {
    getSettings.mockResolvedValue({ ...defaultSettings(), popoverPosition: null });

    render(App);

    const button = await screen.findByRole("button", { name: "Reset position to automatic" });
    expect(button).toBeDisabled();
  });

  it("renders the reset-position button enabled when the popover has a saved position", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverPosition: { x: 120, y: 340 },
    });

    render(App);

    const button = await screen.findByRole("button", { name: "Reset position to automatic" });
    await waitFor(() => {
      expect(button).toBeEnabled();
    });
  });

  it("clicking the reset-position button calls resetPopoverPosition and updates local state", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverPosition: { x: 120, y: 340 },
    });
    resetPopoverPosition.mockResolvedValue({ ...defaultSettings(), popoverPosition: null });

    render(App);

    const button = await screen.findByRole("button", { name: "Reset position to automatic" });
    await waitFor(() => {
      expect(button).toBeEnabled();
    });

    await fireEvent.click(button);

    await waitFor(() => {
      expect(resetPopoverPosition).toHaveBeenCalledTimes(1);
    });
    await waitFor(() => {
      expect(button).toBeDisabled();
    });
  });

  it("shows an error and leaves the setting unchanged when resetPopoverPosition fails", async () => {
    getSettings.mockResolvedValue({
      ...defaultSettings(),
      popoverPosition: { x: 120, y: 340 },
    });
    resetPopoverPosition.mockRejectedValueOnce(new Error("failed to persist popover position"));

    render(App);

    const button = await screen.findByRole("button", { name: "Reset position to automatic" });
    await waitFor(() => {
      expect(button).toBeEnabled();
    });

    await fireEvent.click(button);

    await waitFor(() => {
      expect(screen.getByText("failed to persist popover position")).toBeInTheDocument();
    });
    expect(button).toBeEnabled();
  });

  it("Accessibility tab reads Replace as switched off in Settings when the capability is present but the setting is off", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: true, canPersistSession: true },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: false });

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText(/switched off in Settings/),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/doesn't offer the RemoteDesktop portal/),
    ).not.toBeInTheDocument();
  });

  it("Accessibility tab still reads Replace as unavailable when the compositor genuinely lacks the portal", async () => {
    getPlatformInfo.mockResolvedValue({
      ...macosPlatformInfo(),
      os: "linux",
      permissionRequired: false,
      session: "wayland",
      wayland: { globalShortcut: true, inputSynthesis: false, canPersistSession: false },
    });
    getSettings.mockResolvedValue({ ...defaultSettings(), inputSynthesisEnabled: true });

    render(App);
    await openAccessibilityTab();

    expect(
      await screen.findByText(/doesn't offer the RemoteDesktop portal/),
    ).toBeInTheDocument();
    expect(screen.queryByText(/switched off in Settings/)).not.toBeInTheDocument();
  });

  describe("Shortcuts tab", () => {
    it("General tab no longer shows a shortcut section", async () => {
      render(App);
      await screen.findByRole("heading", { name: "Autostart" });
      expect(screen.queryByRole("heading", { name: "Shortcut" })).not.toBeInTheDocument();
    });

    it("renders every row with its formatted tokens", async () => {
      render(App);
      await openShortcutsTab();

      expect(
        await screen.findByRole("button", { name: /Open Kallilex \(global\)/ }),
      ).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Replace: ⌘↩/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Copy: ⌘⇧C/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Custom prompt: ⌘L/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Check spelling: not set/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Open Settings: ⌘,/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Rewrite: ⌘1/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Shorten: ⌘2/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Improve clarity: ⌘3/ })).toBeInTheDocument();
    });

    it("shows the Replace hint when replaceBackAvailable is false, while still editable", async () => {
      getPlatformInfo.mockResolvedValue({ ...macosPlatformInfo(), replaceBackAvailable: false });

      render(App);
      await openShortcutsTab();

      expect(await screen.findByText("Not available on this system")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Replace: ⌘↩/ })).toBeInTheDocument();
    });

    it("shows the no-prompts hint when there are none", async () => {
      listPrompts.mockResolvedValue([]);
      getSettings.mockResolvedValue({ ...defaultSettings(), prompts: [] });

      render(App);
      await openShortcutsTab();

      expect(
        await screen.findByText("No prompts yet — add them in the Prompts tab."),
      ).toBeInTheDocument();
    });

    it("recording a free chord on Replace calls assignShortcut with the action target", async () => {
      assignShortcut.mockResolvedValue(defaultSettings());

      render(App);
      await openShortcutsTab();

      const replaceButton = await screen.findByRole("button", { name: /Replace: ⌘↩/ });
      await fireEvent.click(replaceButton);
      await fireEvent.keyDown(replaceButton, { key: "k", code: "KeyK", metaKey: true });

      await waitFor(() => {
        expect(assignShortcut).toHaveBeenCalledWith(
          { kind: "action", action: "replace" },
          "Mod+K",
          false,
        );
      });
    });

    it("a reserved chord shows the reason and does not call assignShortcut", async () => {
      render(App);
      await openShortcutsTab();

      const copyButton = await screen.findByRole("button", { name: /Copy: ⌘⇧C/ });
      await fireEvent.click(copyButton);
      await fireEvent.keyDown(copyButton, { key: "c", code: "KeyC", metaKey: true });

      expect(await screen.findByText("⌘C is reserved for copying text.")).toBeInTheDocument();
      expect(assignShortcut).not.toHaveBeenCalled();
    });

    it("a taken chord shows the conflict line, and Take over calls assignShortcut with takeOver: true", async () => {
      assignShortcut.mockResolvedValue(defaultSettings());

      render(App);
      await openShortcutsTab();

      const customPromptButton = await screen.findByRole("button", { name: /Custom prompt: ⌘L/ });
      await fireEvent.click(customPromptButton);
      await fireEvent.keyDown(customPromptButton, { key: "1", code: "Digit1", metaKey: true });

      expect(await screen.findByText('⌘1 is used by "Rewrite".')).toBeInTheDocument();
      await fireEvent.click(screen.getByText("Take over"));

      await waitFor(() => {
        expect(assignShortcut).toHaveBeenCalledWith(
          { kind: "action", action: "customPrompt" },
          "Mod+1",
          true,
        );
      });
    });

    it("a conflict with the global shortcut blocks with its own message instead of offering Take over", async () => {
      render(App);
      await openShortcutsTab();

      const replaceButton = await screen.findByRole("button", { name: /Replace: ⌘↩/ });
      await fireEvent.click(replaceButton);
      // The default macOS global shortcut, Alt+Cmd+K, maps onto Mod+Alt+K.
      await fireEvent.keyDown(replaceButton, {
        key: "k",
        code: "KeyK",
        metaKey: true,
        altKey: true,
      });

      expect(await screen.findByText("Already used to open Kallilex.")).toBeInTheDocument();
      expect(screen.queryByText("Take over")).not.toBeInTheDocument();
      expect(assignShortcut).not.toHaveBeenCalled();
    });

    it("↺ resets a changed popover shortcut to its default, and ✕ clears it", async () => {
      assignShortcut.mockResolvedValue(defaultSettings());
      getSettings.mockResolvedValue({
        ...defaultSettings(),
        popoverShortcuts: { ...defaultPopoverShortcuts(), replace: "Mod+K" },
      });

      render(App);
      await openShortcutsTab();

      const resetButton = await screen.findByLabelText("Reset shortcut for Replace to its default");
      await fireEvent.click(resetButton);
      await waitFor(() => {
        expect(assignShortcut).toHaveBeenCalledWith(
          { kind: "action", action: "replace" },
          "Mod+Enter",
          false,
        );
      });

      const clearButton = await screen.findByLabelText("Clear shortcut for Replace");
      await fireEvent.click(clearButton);
      await waitFor(() => {
        expect(assignShortcut).toHaveBeenCalledWith(
          { kind: "action", action: "replace" },
          null,
          false,
        );
      });
    });

    it("Reset popover shortcuts needs two clicks and calls resetPopoverShortcuts", async () => {
      resetPopoverShortcuts.mockResolvedValue(defaultSettings());

      render(App);
      await openShortcutsTab();

      const resetButton = await screen.findByRole("button", { name: "Reset popover shortcuts" });
      await fireEvent.click(resetButton);
      expect(resetPopoverShortcuts).not.toHaveBeenCalled();

      const confirmButton = await screen.findByRole("button", { name: "Confirm reset?" });
      await fireEvent.click(confirmButton);

      await waitFor(() => {
        expect(resetPopoverShortcuts).toHaveBeenCalledTimes(1);
      });
    });

    it("recording a chord on a prompt row calls assignShortcut with the prompt target", async () => {
      assignShortcut.mockResolvedValue(defaultSettings());

      render(App);
      await openShortcutsTab();

      const rewriteButton = await screen.findByRole("button", { name: /Rewrite: ⌘1/ });
      await fireEvent.click(rewriteButton);
      await fireEvent.keyDown(rewriteButton, { key: "9", code: "Digit9", metaKey: true });

      await waitFor(() => {
        expect(assignShortcut).toHaveBeenCalledWith(
          { kind: "prompt", id: "builtin-rewrite" },
          "Mod+9",
          false,
        );
      });
    });

    it("switches to the Shortcuts tab on a settings:show-tab event", async () => {
      const handlers: Record<string, (event: { payload: unknown }) => void> = {};
      listen.mockImplementation((event: string, handler: (event: { payload: unknown }) => void) => {
        handlers[event] = handler;
        return Promise.resolve(() => {});
      });

      render(App);
      await screen.findByRole("button", { name: "General" });

      handlers["settings:show-tab"]({ payload: "shortcuts" });

      expect(await screen.findByRole("heading", { name: "Shortcuts" })).toBeInTheDocument();
    });
  });

  describe("Prompts tab shortcuts", () => {
    it("shows the shortcut chip on a prompt row", async () => {
      render(App);
      await openPromptsTab();

      const label = await screen.findByText("Rewrite");
      const row = label.closest("li")!;
      expect(within(row).getByText("⌘")).toBeInTheDocument();
      expect(within(row).getByText("1")).toBeInTheDocument();
    });

    it("deleting a prompt frees its shortcut for the next new-prompt prefill", async () => {
      deletePrompt.mockResolvedValue(defaultPrompts().filter((p) => p.id !== "builtin-shorten"));

      render(App);
      await openPromptsTab();

      await screen.findByText("Shorten");
      const deleteButtons = screen.getAllByRole("button", { name: "Delete" });
      // Prompts render in list order: Rewrite (Mod+1), Shorten (Mod+2), …
      await fireEvent.click(deleteButtons[1]!);
      const confirmButton = await screen.findByRole("button", { name: "Confirm delete?" });
      await fireEvent.click(confirmButton);

      await waitFor(() => {
        expect(screen.queryByText("Shorten")).not.toBeInTheDocument();
      });

      const addButton = await screen.findByRole("button", { name: "Add prompt" });
      await fireEvent.click(addButton);

      // Mod+2 is free again now that Shorten (its old holder) is gone — the
      // deleted prompt's shortcut must not still read as held via a stale
      // `settings.prompts`.
      expect(
        await screen.findByRole("button", { name: /this prompt: ⌘2/ }),
      ).toBeInTheDocument();
    });

    it("the new-prompt form is pre-filled with the next free ⌘N", async () => {
      render(App);
      await openPromptsTab();

      const addButton = await screen.findByRole("button", { name: "Add prompt" });
      await fireEvent.click(addButton);

      expect(
        await screen.findByRole("button", { name: /this prompt: ⌘4/ }),
      ).toBeInTheDocument();
    });

    it("leaves the new-prompt shortcut unset once all nine slots are taken", async () => {
      const nineTaken: CustomPrompt[] = Array.from({ length: 9 }, (_, i) => ({
        id: `prompt-${i + 1}`,
        label: `Prompt ${i + 1}`,
        instruction: "Do something.",
        shortcut: `Mod+${i + 1}`,
      }));
      listPrompts.mockResolvedValue(nineTaken);
      getSettings.mockResolvedValue({ ...defaultSettings(), prompts: nineTaken });

      render(App);
      await openPromptsTab();

      const addButton = await screen.findByRole("button", { name: "Add prompt" });
      await fireEvent.click(addButton);

      expect(
        await screen.findByRole("button", { name: /this prompt: not set/ }),
      ).toBeInTheDocument();
    });

    it("Take over in the form stages the take-over and Save passes takeOverShortcut: true", async () => {
      savePrompt.mockResolvedValue(defaultPrompts());

      render(App);
      await openPromptsTab();

      await screen.findByText("Rewrite");
      const editButtons = screen.getAllByRole("button", { name: "Edit" });
      await fireEvent.click(editButtons[1]!); // Shorten, currently Mod+2

      const shortcutButton = await screen.findByRole("button", { name: /Shorten: ⌘2/ });
      await fireEvent.click(shortcutButton);
      await fireEvent.keyDown(shortcutButton, { key: "1", code: "Digit1", metaKey: true });

      expect(await screen.findByText('⌘1 is used by "Rewrite".')).toBeInTheDocument();
      await fireEvent.click(screen.getByText("Take over"));

      const saveButton = await screen.findByRole("button", { name: "Save" });
      await fireEvent.click(saveButton);

      await waitFor(() => {
        expect(savePrompt).toHaveBeenCalledWith(
          {
            id: "builtin-shorten",
            label: "Shorten",
            instruction: defaultPrompts()[1]!.instruction,
            shortcut: "Mod+1",
          },
          true,
        );
      });
    });
  });

  describe("Updates tab", () => {
    it("renders the current version and the saved channel badge", async () => {
      getSettings.mockResolvedValue({ ...defaultSettings(), updateChannel: "preview" });
      getUpdateStatus.mockResolvedValue(updateStatus({ currentVersion: "0.6.0-beta.1" }));

      render(App);
      await openUpdatesTab();

      expect(await screen.findByText("Kallilex 0.6.0-beta.1")).toBeInTheDocument();
      expect(screen.getByText("Preview", { selector: ".channel-badge" })).toBeInTheDocument();
    });

    it("saves only updateChannel through the fetch-then-spread pattern", async () => {
      const fresh: Settings = { ...defaultSettings(), shortcut: "Ctrl+Alt+U" };
      getSettings.mockResolvedValueOnce(defaultSettings());
      getSettings.mockResolvedValueOnce(fresh);

      render(App);
      await openUpdatesTab();
      const select = await screen.findByLabelText("Update channel");
      await fireEvent.change(select, { target: { value: "preview" } });

      await waitFor(() => {
        expect(setSettings).toHaveBeenCalledTimes(1);
      });
      expect(setSettings).toHaveBeenCalledWith({ ...fresh, updateChannel: "preview" });
    });

    it("saves only updateCheckFrequency through the fetch-then-spread pattern", async () => {
      const fresh: Settings = { ...defaultSettings(), shortcut: "Ctrl+Alt+U" };
      getSettings.mockResolvedValueOnce(defaultSettings());
      getSettings.mockResolvedValueOnce(fresh);

      render(App);
      await openUpdatesTab();
      const select = await screen.findByLabelText("Check for updates automatically");
      await fireEvent.change(select, { target: { value: "weekly" } });

      await waitFor(() => {
        expect(setSettings).toHaveBeenCalledTimes(1);
      });
      expect(setSettings).toHaveBeenCalledWith({ ...fresh, updateCheckFrequency: "weekly" });
    });

    it("checks for updates and renders the up-to-date confirmation with a formatted time", async () => {
      const lastCheckAt = 1_700_000_000;
      checkForUpdates.mockResolvedValue(updateStatus({ phase: "upToDate", lastCheckAt }));

      render(App);
      await openUpdatesTab();
      const button = await screen.findByRole("button", { name: "Check for Updates" });
      await fireEvent.click(button);

      await waitFor(() => {
        expect(checkForUpdates).toHaveBeenCalledTimes(1);
      });

      const formatted = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(new Date(lastCheckAt * 1000));

      expect(
        await screen.findByText(`You're up to date (checked ${formatted}).`),
      ).toBeInTheDocument();
    });

    it("renders Download & install for an installable available update and calls installUpdate", async () => {
      getUpdateStatus.mockResolvedValue(
        updateStatus({
          phase: "available",
          available: {
            version: "0.7.0",
            tag: "v0.7.0",
            releaseUrl: "https://example.com/releases/v0.7.0",
            notes: "notes",
            publishedAt: null,
            installable: true,
          },
        }),
      );

      render(App);
      await openUpdatesTab();

      const installButton = await screen.findByRole("button", { name: "Download & install" });
      expect(screen.queryByRole("button", { name: "Open release page" })).not.toBeInTheDocument();

      await fireEvent.click(installButton);
      await waitFor(() => {
        expect(installUpdate).toHaveBeenCalledTimes(1);
      });
    });

    it("renders Open release page and the deb/rpm hint for a non-installable available update", async () => {
      getUpdateStatus.mockResolvedValue(
        updateStatus({
          phase: "available",
          available: {
            version: "0.7.0",
            tag: "v0.7.0",
            releaseUrl: "https://example.com/releases/v0.7.0",
            notes: "notes",
            publishedAt: null,
            installable: false,
          },
        }),
      );

      render(App);
      await openUpdatesTab();

      expect(
        await screen.findByRole("button", { name: "Open release page" }),
      ).toBeInTheDocument();
      expect(
        screen.getByText(/isn't updated in place/),
      ).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: "Download & install" }),
      ).not.toBeInTheDocument();
    });

    it("renders a percentage for a downloading status with a known total and disables the check button", async () => {
      getUpdateStatus.mockResolvedValue(
        updateStatus({ phase: "downloading", progress: { downloaded: 50, total: 200 } }),
      );

      render(App);
      await openUpdatesTab();

      expect(await screen.findByText("25%")).toBeInTheDocument();
      const button = screen.getByRole("button", { name: "Check for Updates" });
      expect(button).toBeDisabled();
    });

    it("renders the error message for an error status and leaves the check button enabled", async () => {
      getUpdateStatus.mockResolvedValue(
        updateStatus({ phase: "error", error: "Could not reach GitHub." }),
      );

      render(App);
      await openUpdatesTab();

      expect(await screen.findByText("Could not reach GitHub.")).toBeInTheDocument();
      const button = screen.getByRole("button", { name: "Check for Updates" });
      expect(button).not.toBeDisabled();
    });

    it("updates the rendering from an update:status event without a re-fetch", async () => {
      const handlers: Record<string, (event: { payload: unknown }) => void> = {};
      listen.mockImplementation((event: string, handler: (event: { payload: unknown }) => void) => {
        handlers[event] = handler;
        return Promise.resolve(() => {});
      });

      render(App);
      await openUpdatesTab();
      await screen.findByText("Kallilex 0.6.0-beta.1");

      expect(getUpdateStatus).toHaveBeenCalledTimes(1);

      handlers["update:status"]({
        payload: updateStatus({
          phase: "available",
          available: {
            version: "0.9.0",
            tag: "v0.9.0",
            releaseUrl: "https://example.com/releases/v0.9.0",
            notes: null,
            publishedAt: null,
            installable: true,
          },
        }),
      });

      expect(await screen.findByText("Version 0.9.0 is available.")).toBeInTheDocument();
      expect(getUpdateStatus).toHaveBeenCalledTimes(1);
    });

    it("switches to the Updates tab on a settings:show-tab event", async () => {
      const handlers: Record<string, (event: { payload: unknown }) => void> = {};
      listen.mockImplementation((event: string, handler: (event: { payload: unknown }) => void) => {
        handlers[event] = handler;
        return Promise.resolve(() => {});
      });

      render(App);
      await screen.findByRole("button", { name: "General" });

      handlers["settings:show-tab"]({ payload: "updates" });

      expect(await screen.findByText("Kallilex 0.6.0-beta.1")).toBeInTheDocument();
    });

    it("ignores a settings:show-tab event with an unknown tab name", async () => {
      const handlers: Record<string, (event: { payload: unknown }) => void> = {};
      listen.mockImplementation((event: string, handler: (event: { payload: unknown }) => void) => {
        handlers[event] = handler;
        return Promise.resolve(() => {});
      });

      render(App);
      await screen.findByRole("button", { name: "General" });

      handlers["settings:show-tab"]({ payload: "bogus" });

      // Still on General: its Autostart heading is present, the Updates
      // version line is not.
      expect(await screen.findByRole("heading", { name: "Autostart" })).toBeInTheDocument();
      expect(screen.queryByText("Kallilex 0.6.0-beta.1")).not.toBeInTheDocument();
    });

    it("opens the release page from the What's new link", async () => {
      getUpdateStatus.mockResolvedValue(
        updateStatus({
          phase: "available",
          available: {
            version: "0.7.0",
            tag: "v0.7.0",
            releaseUrl: "https://example.com/releases/v0.7.0",
            notes: null,
            publishedAt: null,
            installable: true,
          },
        }),
      );

      render(App);
      await openUpdatesTab();

      await fireEvent.click(await screen.findByRole("button", { name: "What's new" }));
      await waitFor(() => {
        expect(openUpdateReleasePage).toHaveBeenCalledTimes(1);
      });
    });
  });
});
