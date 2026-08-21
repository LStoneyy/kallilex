<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import {
    accessibilityStatus,
    completeOnboarding,
    disableAutostart,
    enableAutostart,
    getPresets,
    getSettings,
    isAutostartEnabled,
    openAccessibilitySettings,
    saveProfile,
    setInputSynthesis,
    testConnection,
  } from "../shared/invoke";
  import { loadPlatformInfo } from "../shared/platform";
  import type { PlatformInfo, Preset, ProviderProfile, Settings } from "../shared/types";

  const POLL_INTERVAL_MS = 1000;

  // ---- step list --------------------------------------------------------

  // The second step is platform-conditional and mutually exclusive: macOS
  // gets the Accessibility permission step, Windows a spell-check note,
  // Wayland the paste-back choice, and X11 nothing (straight to Provider).
  // "welcome" and "finish" always bookend the flow.
  type Step = "welcome" | "permission" | "windowsNote" | "waylandPasteBack" | "provider" | "finish";

  function stepsFor(info: PlatformInfo | null): Step[] {
    const steps: Step[] = ["welcome"];
    if (info !== null) {
      if (info.permissionRequired) {
        steps.push("permission");
      } else if (info.os === "windows") {
        steps.push("windowsNote");
      } else if (info.session === "wayland") {
        steps.push("waylandPasteBack");
      }
    }
    steps.push("provider", "finish");
    return steps;
  }

  // `null` until `loadPlatformInfo()` resolves. The step list is derived
  // from it and only from it, so it never changes mid-wizard once "Get
  // started" (gated on this being non-null) has been clicked.
  let platformInfo = $state<PlatformInfo | null>(null);
  const defaultShortcut = $derived(platformInfo?.defaultShortcut ?? "Alt+Cmd+K");
  const steps = $derived(stepsFor(platformInfo));

  let stepIndex = $state(0);
  const currentStep = $derived<Step>(steps[stepIndex] ?? "welcome");

  function goNext() {
    stepIndex = Math.min(stepIndex + 1, steps.length - 1);
  }

  // ---- settings (Wayland paste-back toggle) ------------------------------

  let settings = $state<Settings | null>(null);

  async function loadSettings() {
    try {
      settings = await getSettings();
    } catch {
      // Leave `settings` null: the Wayland toggle then renders its
      // default-on state, which matches the backend default.
    }
  }

  let inputSynthesisError = $state<string | null>(null);

  async function handleInputSynthesisToggle(event: Event) {
    const checked = (event.currentTarget as HTMLInputElement).checked;
    inputSynthesisError = null;
    if (settings) {
      settings = { ...settings, inputSynthesisEnabled: checked };
    }
    try {
      await setInputSynthesis(checked);
    } catch (error) {
      inputSynthesisError = error instanceof Error ? error.message : String(error);
    }
  }

  // ---- permission polling (macOS) ----------------------------------------

  let granted = $state(false);
  let intervalId: ReturnType<typeof setInterval> | undefined;
  let destroyed = false;

  async function refreshAccessibilityStatus() {
    granted = await accessibilityStatus();
  }

  // ---- provider step ------------------------------------------------------

  type ProviderDraft = {
    id: string;
    name: string;
    baseUrl: string;
    model: string;
  };

  function emptyDraft(): ProviderDraft {
    return { id: "", name: "", baseUrl: "", model: "" };
  }

  let presets = $state<Preset[]>([]);
  let providerView = $state<"pick" | "form" | "saved">("pick");
  let draft = $state<ProviderDraft>(emptyDraft());
  let apiKeyDraft = $state("");
  let formError = $state<string | null>(null);
  let formSaving = $state(false);
  let savedProfileId = $state<string | null>(null);

  type TestState =
    | { status: "idle" }
    | { status: "testing" }
    | { status: "ok"; latencyMs: number }
    | { status: "error"; message: string };

  let testState = $state<TestState>({ status: "idle" });

  async function loadPresets() {
    presets = await getPresets();
  }

  function selectPreset(preset: Preset) {
    draft = { ...emptyDraft(), baseUrl: preset.baseUrl };
    formError = null;
    providerView = "form";
  }

  async function handleSaveDraft() {
    formError = null;
    formSaving = true;
    try {
      const toSave: ProviderProfile = {
        id: draft.id,
        name: draft.name,
        baseUrl: draft.baseUrl,
        model: draft.model,
        timeoutSecs: 30,
        customHeaders: [],
        enabled: true,
        hasApiKey: false,
      };
      // Onboarding only ever shows for installs with no existing profiles
      // (see `evaluate_onboarding`), so the returned list is exactly this
      // one profile — its id is what `save_profile_core` just generated.
      const profiles = await saveProfile(toSave, apiKeyDraft.trim() === "" ? null : apiKeyDraft);
      savedProfileId = profiles[0]?.id ?? null;
      providerView = "saved";
    } catch (error) {
      formError = error instanceof Error ? error.message : String(error);
    } finally {
      formSaving = false;
    }
  }

  async function handleTestConnection() {
    if (!savedProfileId) {
      return;
    }
    testState = { status: "testing" };
    try {
      const latencyMs = await testConnection(savedProfileId);
      testState = { status: "ok", latencyMs };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      testState = { status: "error", message };
    }
  }

  // ---- finish step: autostart ---------------------------------------------

  let autostartEnabled = $state(false);
  let autostartError = $state<string | null>(null);

  async function loadAutostart() {
    try {
      autostartEnabled = await isAutostartEnabled();
    } catch (error) {
      autostartError = error instanceof Error ? error.message : String(error);
    }
  }

  async function handleAutostartToggle(event: Event) {
    const checked = (event.currentTarget as HTMLInputElement).checked;
    autostartError = null;
    try {
      if (checked) {
        await enableAutostart();
      } else {
        await disableAutostart();
      }
      autostartEnabled = checked;
    } catch (error) {
      autostartError = error instanceof Error ? error.message : String(error);
    }
  }

  function handleDone() {
    // The window closes from the Rust side (`complete_onboarding` calls
    // `window.close()` after persisting the flag); an IPC response lost
    // during that teardown is cosmetic, so the rejection is swallowed here
    // rather than surfaced as an error the user would never get to read.
    void completeOnboarding().catch(() => {});
  }

  onMount(() => {
    void loadSettings();
    void loadPresets();
    void loadAutostart();
    void loadPlatformInfo().then((info) => {
      if (destroyed) {
        return;
      }
      platformInfo = info;
      if (info.permissionRequired) {
        void refreshAccessibilityStatus();
        intervalId = setInterval(() => {
          void refreshAccessibilityStatus();
        }, POLL_INTERVAL_MS);
      }
    });
  });

  onDestroy(() => {
    destroyed = true;
    if (intervalId !== undefined) {
      clearInterval(intervalId);
    }
  });
</script>

<main class="onboarding">
  {#if currentStep === "welcome"}
    <section class="step">
      <h1>Welcome to Kallilex</h1>
      <p>
        Select text in any app, press <code>{defaultShortcut}</code>, and a popover opens with
        spell check and AI actions. Choose Replace and the result is written straight back where
        you were.
      </p>
      <div class="footer">
        <button type="button" disabled={platformInfo === null} onclick={goNext}>
          Get started
        </button>
      </div>
    </section>
  {:else if currentStep === "permission"}
    <section class="step">
      <h1>Accessibility permission</h1>
      <p>
        Kallilex reads the text you've selected in whatever app you're writing in, so pressing the
        shortcut captures it instantly instead of asking you to copy it first. Capture happens
        entirely on this Mac — nothing leaves your machine until you choose to process it.
      </p>
      <p class="status" class:granted class:not-granted={!granted}>
        {granted ? "Granted" : "Not granted"}
      </p>
      <button type="button" onclick={() => void openAccessibilitySettings()}>
        Open System Settings
      </button>
      <p class="hint">If macOS doesn't pick up the change right away, quit and reopen Kallilex.</p>
      <p class="hint">
        Spell check inside the popover works without this permission — Continue any time.
      </p>
      <div class="footer">
        <button type="button" onclick={goNext}>Continue</button>
      </div>
    </section>
  {:else if currentStep === "windowsNote"}
    <section class="step">
      <h1>Windows spell check</h1>
      <p>
        Kallilex uses Windows' own spell checker. If suggestions look sparse, install "Basic
        typing" for your language under Settings → Time &amp; Language → Language &amp; region.
      </p>
      <div class="footer">
        <button type="button" onclick={goNext}>Continue</button>
      </div>
    </section>
  {:else if currentStep === "waylandPasteBack"}
    <section class="step">
      <h1>Automatic paste-back</h1>
      <p>
        Replace can paste the result straight back into the app you copied from, using your
        desktop's RemoteDesktop portal. The first time, your desktop asks for a one-time
        confirmation — the global shortcut may ask for a separate one-time confirmation too.
      </p>
      {#if platformInfo?.wayland?.inputSynthesis}
        <label class="toggle-row">
          <input
            type="checkbox"
            checked={settings?.inputSynthesisEnabled ?? true}
            onchange={(event) => void handleInputSynthesisToggle(event)}
          />
          Use automatic paste-back
        </label>
        <p class="hint">
          Turn this off and Replace copies the result to the clipboard instead, for you to paste
          manually — Kallilex never asks your desktop for the permission at all.
        </p>
        {#if inputSynthesisError}
          <p class="error">{inputSynthesisError}</p>
        {/if}
      {:else}
        <p class="hint">
          Not available on this desktop — your compositor doesn't offer the RemoteDesktop portal.
          Results can still be copied.
        </p>
      {/if}
      <div class="footer">
        <button type="button" onclick={goNext}>Continue</button>
      </div>
    </section>
  {:else if currentStep === "provider"}
    <section class="step">
      <h1>Set up AI actions</h1>
      {#if providerView === "pick"}
        <p>Spell check works out of the box. AI actions need a provider.</p>
        <ul class="preset-list">
          {#each presets as preset (preset.id)}
            <li>
              <button type="button" class="preset-button" onclick={() => selectPreset(preset)}>
                {preset.label}
              </button>
            </li>
          {/each}
        </ul>
      {:else if providerView === "form"}
        <label class="field">
          Name
          <input class="text-input" type="text" bind:value={draft.name} />
        </label>
        <label class="field">
          Base URL
          <input class="text-input" type="text" bind:value={draft.baseUrl} />
        </label>
        <label class="field">
          Model
          <input class="text-input" type="text" bind:value={draft.model} />
        </label>
        <label class="field">
          API key
          <input class="text-input" type="password" bind:value={apiKeyDraft} />
        </label>
        <p class="hint">Stored in your system keychain.</p>
        {#if formError}
          <p class="error">{formError}</p>
        {/if}
        <button type="button" disabled={formSaving} onclick={() => void handleSaveDraft()}>
          {formSaving ? "Saving…" : "Save"}
        </button>
      {:else if providerView === "saved"}
        <p class="confirm">Profile saved and set as active.</p>
        <button type="button" onclick={() => void handleTestConnection()}>
          {testState.status === "testing" ? "Testing…" : "Test connection"}
        </button>
        {#if testState.status === "ok"}
          <span class="test-result ok">OK · {testState.latencyMs} ms</span>
        {:else if testState.status === "error"}
          <span class="test-result error">{testState.message}</span>
        {/if}
      {/if}
      <div class="footer">
        {#if providerView === "saved"}
          <button type="button" onclick={goNext}>Continue</button>
        {:else}
          <button type="button" onclick={goNext}>Skip for now</button>
        {/if}
      </div>
    </section>
  {:else if currentStep === "finish"}
    <section class="step">
      <h1>You're all set</h1>
      <label class="toggle-row">
        <input
          type="checkbox"
          checked={autostartEnabled}
          onchange={(event) => void handleAutostartToggle(event)}
        />
        Launch Kallilex at login
      </label>
      {#if autostartError}
        <p class="error">{autostartError}</p>
      {/if}
      <p class="hint">Try it now: select some text and press <code>{defaultShortcut}</code>.</p>
      <div class="footer">
        <button type="button" onclick={handleDone}>Done</button>
      </div>
    </section>
  {/if}
</main>

<style>
  :global(html),
  :global(body) {
    margin: 0;
    padding: 0;
    height: 100%;
  }

  .onboarding {
    box-sizing: border-box;
    width: 100%;
    height: 100vh;
    background-color: var(--color-basalt);
    color: var(--color-marble);
    padding: 24px 28px;
    display: flex;
    flex-direction: column;
    font-family:
      -apple-system,
      BlinkMacSystemFont,
      "Segoe UI",
      sans-serif;
  }

  .step {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
  }

  h1 {
    margin: 0 0 12px;
    font-size: 18px;
    font-weight: 600;
    color: var(--color-marble);
  }

  p {
    margin: 0 0 10px;
    font-size: 13px;
    line-height: 1.5;
    color: var(--color-ash);
    max-width: 520px;
  }

  .hint {
    font-size: 12px;
  }

  code {
    color: var(--color-marble);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 8px;
    font-size: 12px;
    color: var(--color-ash);
    max-width: 400px;
  }

  .text-input {
    box-sizing: border-box;
    border: 1px solid color-mix(in srgb, var(--color-marble) 18%, transparent);
    border-radius: 6px;
    background-color: transparent;
    color: var(--color-marble);
    font-size: 13px;
    padding: 5px 8px;
    outline: none;
    font-family: inherit;
  }

  .toggle-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--color-marble);
    margin-bottom: 8px;
    cursor: pointer;
  }

  .status {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
  }

  .status.granted {
    color: var(--color-verdigris);
    background-color: color-mix(in srgb, var(--color-verdigris) 18%, transparent);
  }

  .status.not-granted {
    color: var(--color-electrum);
    background-color: color-mix(in srgb, var(--color-electrum) 18%, transparent);
  }

  button {
    border: none;
    border-radius: 6px;
    padding: 6px 12px;
    background-color: var(--color-attic-clay);
    color: var(--color-marble);
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    flex: none;
  }

  button:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .error {
    color: var(--color-attic-clay);
    font-size: 12px;
  }

  .confirm {
    color: var(--color-verdigris);
    font-size: 12px;
  }

  .preset-list {
    list-style: none;
    margin: 0 0 10px;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
    max-width: 280px;
  }

  .preset-button {
    width: 100%;
    text-align: left;
  }

  .test-result {
    display: inline-block;
    margin-left: 8px;
    font-size: 11px;
  }

  .test-result.ok {
    color: var(--color-verdigris);
  }

  .test-result.error {
    color: var(--color-attic-clay);
  }

  .footer {
    margin-top: auto;
    padding-top: 16px;
    display: flex;
    justify-content: flex-end;
  }
</style>
