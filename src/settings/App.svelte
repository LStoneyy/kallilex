<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import {
    accessibilityStatus,
    deleteProfile,
    disableAutostart,
    enableAutostart,
    getPresets,
    getSettings,
    getWaylandShortcutTrigger,
    isAutostartEnabled,
    listProfiles,
    openAccessibilitySettings,
    saveProfile,
    setActiveProfile,
    setSettings,
    testConnection,
  } from "../shared/invoke";
  import { loadPlatformInfo } from "../shared/platform";
  import type { HeaderEntry, PlatformInfo, Preset, ProviderProfile, Settings } from "../shared/types";

  const POLL_INTERVAL_MS = 1000;

  type Tab = "general" | "providers" | "accessibility";

  // ---- tabs -----------------------------------------------------------

  let activeTab = $state<Tab>("general");

  // ---- platform info ----------------------------------------------------

  // `null` until `loadPlatformInfo()` resolves; the macOS-shaped fallback
  // below keeps the shortcut hint/placeholder looking right in the
  // meantime, since macOS is the default look.
  let platformInfo = $state<PlatformInfo | null>(null);
  const defaultShortcut = $derived(platformInfo?.defaultShortcut ?? "Alt+Cmd+K");

  // The Wayland GlobalShortcuts portal, when the running
  // compositor offers it, is the sole owner of the "capture" shortcut: the
  // General tab's shortcut field switches to a read-only display of
  // whatever the portal reports instead of the free-text input/Save flow.
  const portalManagedShortcut = $derived(
    platformInfo?.session === "wayland" && (platformInfo.wayland?.globalShortcut ?? false),
  );

  // The input-synthesis opt-out is only meaningful on
  // Wayland — macOS and X11 synthetic input needs no permission, so there is
  // nothing to opt out of there. It also requires the probed RemoteDesktop
  // capability (like `portalManagedShortcut` above combines session +
  // GlobalShortcuts capability): with no RemoteDesktop portal (e.g. Sway,
  // Hyprland) `caps.input_synthesis` and thus `replace_back_available` are
  // always `false` regardless of this setting, so the toggle would be inert
  // and its hint would promise a permission dialog that compositor can never
  // show. The setting itself stays persisted and untouched either way — only
  // its surfacing here is gated, so a user who later moves to a
  // portal-capable compositor keeps whatever they chose.
  const showInputSynthesisToggle = $derived(
    platformInfo?.session === "wayland" && (platformInfo.wayland?.inputSynthesis ?? false),
  );

  // ---- shared settings (General + Providers both need it) -------------

  let settings = $state<Settings | null>(null);

  async function loadSettings() {
    settings = await getSettings();
    shortcutDraft = settings.shortcut;
  }

  // ---- General: shortcut ------------------------------------------------

  let shortcutDraft = $state("");
  let shortcutSaving = $state(false);
  let shortcutError = $state<string | null>(null);
  let shortcutSaved = $state(false);

  // Portal-reported trigger for the read-only display (see
  // `portalManagedShortcut`). The settings window is created hidden at app
  // startup, well before the portal bind (which can involve a compositor
  // confirmation dialog) has had a chance to complete, so a single fetch on
  // mount would often stick at "not currently bound" forever. Polled on the
  // same interval as the accessibility status below instead, for the
  // window's whole lifetime, so it also picks up a later bind, a stream
  // that ends at runtime (cleared back to `null`), and mid-run rebinds.
  let portalTrigger = $state<string | null>(null);

  async function handleSaveShortcut() {
    shortcutError = null;
    shortcutSaved = false;
    shortcutSaving = true;
    try {
      // Always re-fetch immediately before mutating, so a stale in-memory
      // `settings` (e.g. profiles changed from the Providers tab) never
      // gets clobbered by this save.
      const fresh = await getSettings();
      const updated: Settings = { ...fresh, shortcut: shortcutDraft };
      settings = await setSettings(updated);
      shortcutDraft = settings.shortcut;
      shortcutSaved = true;
    } catch (error) {
      shortcutError = error instanceof Error ? error.message : String(error);
    } finally {
      shortcutSaving = false;
    }
  }

  // ---- General: spellcheck ----------------------------------------------

  let spellcheckError = $state<string | null>(null);

  async function handleSpellcheckToggle(event: Event) {
    const checked = (event.currentTarget as HTMLInputElement).checked;
    spellcheckError = null;
    try {
      const fresh = await getSettings();
      const updated: Settings = { ...fresh, spellcheckEnabled: checked };
      settings = await setSettings(updated);
    } catch (error) {
      spellcheckError = error instanceof Error ? error.message : String(error);
    }
  }

  // ---- General: results (input synthesis + auto-copy) -------------------

  let inputSynthesisError = $state<string | null>(null);

  async function handleInputSynthesisToggle(event: Event) {
    const checked = (event.currentTarget as HTMLInputElement).checked;
    inputSynthesisError = null;
    try {
      // Re-fetch immediately before mutating — see `handleSpellcheckToggle`.
      const fresh = await getSettings();
      const updated: Settings = { ...fresh, inputSynthesisEnabled: checked };
      settings = await setSettings(updated);
    } catch (error) {
      inputSynthesisError = error instanceof Error ? error.message : String(error);
    }
  }

  let autoCopyError = $state<string | null>(null);

  async function handleAutoCopyToggle(event: Event) {
    const checked = (event.currentTarget as HTMLInputElement).checked;
    autoCopyError = null;
    try {
      const fresh = await getSettings();
      const updated: Settings = { ...fresh, autoCopyResult: checked };
      settings = await setSettings(updated);
    } catch (error) {
      autoCopyError = error instanceof Error ? error.message : String(error);
    }
  }

  // ---- General: autostart ------------------------------------------------

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

  // ---- Providers: list ----------------------------------------------------

  let profiles = $state<ProviderProfile[]>([]);
  let presets = $state<Preset[]>([]);
  let listError = $state<string | null>(null);
  let deleteConfirmId = $state<string | null>(null);

  async function loadProviders() {
    try {
      [profiles, presets] = await Promise.all([listProfiles(), getPresets()]);
    } catch (error) {
      listError = error instanceof Error ? error.message : String(error);
    }
  }

  async function handleSetActive(id: string) {
    listError = null;
    try {
      await setActiveProfile(id);
      if (settings) {
        settings = { ...settings, activeProfileId: id };
      }
    } catch (error) {
      listError = error instanceof Error ? error.message : String(error);
    }
  }

  async function handleToggleEnabled(profile: ProviderProfile) {
    listError = null;
    try {
      profiles = await saveProfile({ ...profile, enabled: !profile.enabled }, null);
    } catch (error) {
      listError = error instanceof Error ? error.message : String(error);
    }
  }

  function handleDeleteClick(id: string) {
    if (deleteConfirmId === id) {
      void confirmDelete(id);
    } else {
      deleteConfirmId = id;
    }
  }

  async function confirmDelete(id: string) {
    listError = null;
    try {
      profiles = await deleteProfile(id);
    } catch (error) {
      listError = error instanceof Error ? error.message : String(error);
    } finally {
      deleteConfirmId = null;
    }
  }

  // ---- Providers: test connection -----------------------------------------

  type TestState =
    | { status: "testing" }
    | { status: "ok"; latencyMs: number }
    | { status: "error"; message: string };

  let testStates = $state<Record<string, TestState>>({});

  async function handleTestConnection(id: string) {
    testStates = { ...testStates, [id]: { status: "testing" } };
    try {
      const latencyMs = await testConnection(id);
      testStates = { ...testStates, [id]: { status: "ok", latencyMs } };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      testStates = { ...testStates, [id]: { status: "error", message } };
    }
  }

  // ---- Providers: add/edit form --------------------------------------------

  type ProfileDraft = {
    id: string;
    name: string;
    baseUrl: string;
    model: string;
    timeoutSecs: number;
    customHeaders: HeaderEntry[];
    enabled: boolean;
    hasApiKey: boolean;
  };

  function emptyDraft(): ProfileDraft {
    return {
      id: "",
      name: "",
      baseUrl: "",
      model: "",
      timeoutSecs: 30,
      customHeaders: [],
      enabled: true,
      hasApiKey: false,
    };
  }

  let view = $state<"list" | "presetPicker" | "form">("list");
  let draft = $state<ProfileDraft>(emptyDraft());
  let apiKeyDraft = $state("");
  let apiKeyTouched = $state(false);
  let removeKeyChecked = $state(false);
  let formError = $state<string | null>(null);
  let formSaving = $state(false);

  function resetFormState() {
    apiKeyDraft = "";
    apiKeyTouched = false;
    removeKeyChecked = false;
    formError = null;
  }

  function openAddProfile() {
    listError = null;
    view = "presetPicker";
  }

  function selectPreset(preset: Preset) {
    draft = { ...emptyDraft(), baseUrl: preset.baseUrl };
    resetFormState();
    view = "form";
  }

  function openEditProfile(profile: ProviderProfile) {
    draft = {
      id: profile.id,
      name: profile.name,
      baseUrl: profile.baseUrl,
      model: profile.model,
      timeoutSecs: profile.timeoutSecs,
      customHeaders: profile.customHeaders.map((h) => ({ ...h })),
      enabled: profile.enabled,
      hasApiKey: profile.hasApiKey,
    };
    resetFormState();
    view = "form";
  }

  function handleCancelForm() {
    view = "list";
  }

  function addHeaderRow() {
    draft.customHeaders = [...draft.customHeaders, { name: "", value: "" }];
  }

  function removeHeaderRow(index: number) {
    draft.customHeaders = draft.customHeaders.filter((_, i) => i !== index);
  }

  async function handleSaveProfile() {
    formError = null;
    formSaving = true;
    try {
      const apiKeyToSend = removeKeyChecked ? "" : apiKeyTouched ? apiKeyDraft : null;
      const profileToSave: ProviderProfile = {
        id: draft.id,
        name: draft.name,
        baseUrl: draft.baseUrl,
        model: draft.model,
        timeoutSecs: draft.timeoutSecs,
        customHeaders: draft.customHeaders,
        enabled: draft.enabled,
        hasApiKey: draft.hasApiKey,
      };
      profiles = await saveProfile(profileToSave, apiKeyToSend);
      view = "list";
    } catch (error) {
      formError = error instanceof Error ? error.message : String(error);
    } finally {
      formSaving = false;
    }
  }

  // ---- Accessibility ------------------------------------------------------

  let granted = $state(false);
  let intervalId: ReturnType<typeof setInterval> | undefined;
  let portalTriggerIntervalId: ReturnType<typeof setInterval> | undefined;
  let destroyed = false;

  async function refreshAccessibilityStatus() {
    granted = await accessibilityStatus();
  }

  async function refreshPortalTrigger() {
    portalTrigger = await getWaylandShortcutTrigger();
  }

  onMount(() => {
    void loadSettings();
    void loadProviders();
    void loadAutostart();
    void loadPlatformInfo().then((info) => {
      if (destroyed) {
        return;
      }
      platformInfo = info;
      // The polling loop below is only meaningful on platforms with a
      // grantable permission to poll for; starting it before `platformInfo`
      // resolves would have already begun on platforms where it should
      // never run, so it's started here instead of unconditionally at mount.
      if (info.permissionRequired) {
        void refreshAccessibilityStatus();
        intervalId = setInterval(() => {
          void refreshAccessibilityStatus();
        }, POLL_INTERVAL_MS);
      }
      // Likewise, only meaningful once we know the portal-managed shortcut
      // applies; started here (not unconditionally at mount) for the same
      // reason, and polled for the window's whole lifetime rather than
      // fetched once — see `portalTrigger`'s comment above.
      if (info.session === "wayland" && info.wayland?.globalShortcut) {
        void refreshPortalTrigger();
        portalTriggerIntervalId = setInterval(() => {
          void refreshPortalTrigger();
        }, POLL_INTERVAL_MS);
      }
    });
  });

  onDestroy(() => {
    destroyed = true;
    if (intervalId !== undefined) {
      clearInterval(intervalId);
    }
    if (portalTriggerIntervalId !== undefined) {
      clearInterval(portalTriggerIntervalId);
    }
  });
</script>

<main class="settings">
  <h1>Settings</h1>

  <nav class="tabs">
    <button
      type="button"
      class="tab"
      class:active={activeTab === "general"}
      onclick={() => (activeTab = "general")}
    >
      General
    </button>
    <button
      type="button"
      class="tab"
      class:active={activeTab === "providers"}
      onclick={() => (activeTab = "providers")}
    >
      Providers
    </button>
    <button
      type="button"
      class="tab"
      class:active={activeTab === "accessibility"}
      onclick={() => (activeTab = "accessibility")}
    >
      Accessibility
    </button>
  </nav>

  <div class="tab-content">
    {#if activeTab === "general"}
      <section class="general">
        <h2>Shortcut</h2>
        {#if portalManagedShortcut}
          <p class="hint">
            The global shortcut that opens Kallilex from anywhere.
          </p>
          {#if portalTrigger}
            <p><code>{portalTrigger}</code></p>
            <p class="hint">
              This shortcut is managed by your system — change it in your desktop's keyboard
              settings.
            </p>
          {:else}
            <p class="hint">
              Not currently bound — your system declined or hasn't confirmed the shortcut. You can
              still open Kallilex from the tray.
            </p>
          {/if}
        {:else}
          <p class="hint">
            The global shortcut that opens Kallilex from anywhere, e.g. <code>{defaultShortcut}</code>.
          </p>
          <div class="row">
            <input
              class="text-input"
              type="text"
              bind:value={shortcutDraft}
              placeholder={defaultShortcut}
            />
            <button type="button" disabled={shortcutSaving} onclick={() => void handleSaveShortcut()}>
              {shortcutSaving ? "Saving…" : "Save"}
            </button>
          </div>
          {#if shortcutError}
            <p class="error">{shortcutError}</p>
          {:else if shortcutSaved}
            <p class="confirm">Shortcut saved and active.</p>
          {/if}
        {/if}

        <h2>Autostart</h2>
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

        <h2>Spell check</h2>
        <label class="toggle-row">
          <input
            type="checkbox"
            checked={settings?.spellcheckEnabled ?? true}
            onchange={(event) => void handleSpellcheckToggle(event)}
          />
          Automatically check spelling in the popover
        </label>
        <p class="hint">
          The "Check spelling" button in the popover still works on demand even with this
          switched off.
        </p>
        {#if spellcheckError}
          <p class="error">{spellcheckError}</p>
        {/if}

        <h2>Results</h2>
        {#if showInputSynthesisToggle}
          <label class="toggle-row">
            <input
              type="checkbox"
              checked={settings?.inputSynthesisEnabled ?? true}
              onchange={(event) => void handleInputSynthesisToggle(event)}
            />
            Use automatic paste-back
          </label>
          <p class="hint">
            Lets Kallilex press Ctrl+C and Ctrl+V for you so Replace can put the result straight
            back where you were. Your desktop asks for input permission once. Turn it off and
            Kallilex never asks: capture then uses only the text you have selected, and results
            are copied instead.
          </p>
          <p class="hint">
            Turning this off doesn't revoke the permission itself — that stays something you do
            in your desktop's own settings.
          </p>
          {#if inputSynthesisError}
            <p class="error">{inputSynthesisError}</p>
          {/if}
        {/if}
        <label class="toggle-row">
          <input
            type="checkbox"
            checked={settings?.autoCopyResult ?? false}
            onchange={(event) => void handleAutoCopyToggle(event)}
          />
          Copy the result automatically
        </label>
        <p class="hint">
          Puts the result on the clipboard as soon as Kallilex changes the text, so you can close
          the popover and paste. This replaces what was on the clipboard; edits you type yourself
          afterwards still need the Copy button.
        </p>
        {#if autoCopyError}
          <p class="error">{autoCopyError}</p>
        {/if}
      </section>
    {:else if activeTab === "providers"}
      <section class="providers">
        {#if view === "list"}
          <div class="row providers-header">
            <h2>Provider profiles</h2>
            <button type="button" onclick={openAddProfile}>Add profile</button>
          </div>
          {#if listError}
            <p class="error">{listError}</p>
          {/if}
          {#if profiles.length === 0}
            <p class="hint">No provider profiles yet — add one to enable AI actions.</p>
          {/if}
          <ul class="profile-list">
            {#each profiles as profile (profile.id)}
              {@const testState = testStates[profile.id]}
              <li class="profile-row">
                <label class="active-marker">
                  <input
                    type="radio"
                    name="active-profile"
                    checked={settings?.activeProfileId === profile.id}
                    onchange={() => void handleSetActive(profile.id)}
                  />
                </label>
                <div class="profile-info">
                  <span class="profile-name">{profile.name}</span>
                  <span class="profile-model">{profile.model || "(no model set)"}</span>
                </div>
                <label class="toggle-row inline">
                  <input
                    type="checkbox"
                    checked={profile.enabled}
                    onchange={() => void handleToggleEnabled(profile)}
                  />
                  Enabled
                </label>
                <button type="button" onclick={() => void handleTestConnection(profile.id)}>
                  {testState?.status === "testing" ? "Testing…" : "Test"}
                </button>
                {#if testState?.status === "ok"}
                  <span class="test-result ok">OK · {testState.latencyMs} ms</span>
                {:else if testState?.status === "error"}
                  <span class="test-result error">{testState.message}</span>
                {/if}
                <button type="button" onclick={() => openEditProfile(profile)}>Edit</button>
                <button type="button" class="danger" onclick={() => handleDeleteClick(profile.id)}>
                  {deleteConfirmId === profile.id ? "Confirm delete?" : "Delete"}
                </button>
              </li>
            {/each}
          </ul>
        {:else if view === "presetPicker"}
          <h2>Add profile</h2>
          <p class="hint">Start from a preset — you can change every field afterward.</p>
          <ul class="preset-list">
            {#each presets as preset (preset.id)}
              <li>
                <button type="button" class="preset-button" onclick={() => selectPreset(preset)}>
                  {preset.label}
                </button>
              </li>
            {/each}
          </ul>
          <button type="button" onclick={handleCancelForm}>Cancel</button>
        {:else if view === "form"}
          <h2>{draft.id ? "Edit profile" : "New profile"}</h2>
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
            Timeout (seconds)
            <input class="text-input" type="number" min="1" bind:value={draft.timeoutSecs} />
          </label>
          <label class="field">
            API key
            <input
              class="text-input"
              type="password"
              placeholder={draft.hasApiKey ? "unchanged — leave empty to keep" : "no key set"}
              disabled={removeKeyChecked}
              bind:value={apiKeyDraft}
              oninput={() => (apiKeyTouched = true)}
            />
          </label>
          {#if draft.hasApiKey}
            <label class="toggle-row">
              <input type="checkbox" bind:checked={removeKeyChecked} />
              Remove stored key
            </label>
          {/if}

          <h3>Custom headers</h3>
          {#each draft.customHeaders as header, index (index)}
            <div class="row header-row">
              <input class="text-input" type="text" placeholder="Name" bind:value={header.name} />
              <input
                class="text-input"
                type="text"
                placeholder="Value"
                bind:value={header.value}
              />
              <button type="button" onclick={() => removeHeaderRow(index)}>Remove</button>
            </div>
          {/each}
          <button type="button" onclick={addHeaderRow}>Add header</button>

          <label class="toggle-row">
            <input type="checkbox" bind:checked={draft.enabled} />
            Enabled
          </label>

          {#if formError}
            <p class="error">{formError}</p>
          {/if}

          <div class="row form-actions">
            <button type="button" disabled={formSaving} onclick={() => void handleSaveProfile()}>
              {formSaving ? "Saving…" : "Save"}
            </button>
            <button type="button" onclick={handleCancelForm}>Cancel</button>
          </div>
        {/if}
      </section>
    {:else if activeTab === "accessibility"}
      <section class="accessibility">
        <h2>Accessibility permission</h2>
        {#if platformInfo === null || platformInfo.permissionRequired}
          <p>
            Kallilex reads the text you've selected in whatever app you're writing in, so pressing
            the shortcut captures it instantly instead of asking you to copy it first. Capture
            happens entirely on this Mac — nothing leaves your machine until you choose to process
            it.
          </p>

          <p class="status" class:granted class:not-granted={!granted}>
            {granted ? "Granted" : "Not granted"}
          </p>

          <button type="button" onclick={() => void openAccessibilitySettings()}>
            Open System Settings
          </button>

          <p class="hint">
            If macOS doesn't pick up the change right away, quit and reopen Kallilex.
          </p>
        {:else}
          <p>
            No system permission is needed to capture selections on this platform.
          </p>
          {#if platformInfo?.session === "wayland"}
            <p class="hint">Wayland capabilities (detected via your desktop's XDG portals):</p>
            <p>
              <strong>Global shortcut:</strong>
              {#if platformInfo.wayland?.globalShortcut}
                Managed by your system (GlobalShortcuts portal).
              {:else}
                Unavailable — your compositor doesn't offer the GlobalShortcuts portal. Use "Open
                Kallilex" in the tray menu to capture.
              {/if}
            </p>
            <p>
              <strong>Replace:</strong>
              {#if !platformInfo.wayland?.inputSynthesis}
                Unavailable — your compositor doesn't offer the RemoteDesktop portal. Results can
                still be copied.
              {:else if settings?.inputSynthesisEnabled === false}
                Available, but switched off in Settings → General ("Use automatic paste-back").
                Results can still be copied.
              {:else}
                Available (RemoteDesktop portal).
              {/if}
            </p>
          {/if}
        {/if}
      </section>
    {/if}
  </div>
</main>

<style>
  :global(html),
  :global(body) {
    margin: 0;
    padding: 0;
    height: 100%;
  }

  .settings {
    box-sizing: border-box;
    width: 100%;
    height: 100vh;
    background-color: var(--color-basalt);
    color: var(--color-marble);
    padding: 20px 24px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    font-family:
      -apple-system,
      BlinkMacSystemFont,
      "Segoe UI",
      sans-serif;
  }

  h1 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: var(--color-marble);
    flex: none;
  }

  .tabs {
    display: flex;
    gap: 4px;
    border-bottom: 1px solid color-mix(in srgb, var(--color-marble) 12%, transparent);
    flex: none;
  }

  .tab {
    border: none;
    background: transparent;
    color: var(--color-ash);
    font-size: 13px;
    font-weight: 600;
    padding: 6px 10px;
    cursor: pointer;
    border-bottom: 2px solid transparent;
  }

  .tab.active {
    color: var(--color-marble);
    border-bottom-color: var(--color-attic-clay);
  }

  .tab-content {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
  }

  h2 {
    margin: 16px 0 6px;
    font-size: 14px;
    font-weight: 600;
    color: var(--color-marble);
  }

  h2:first-child {
    margin-top: 0;
  }

  h3 {
    margin: 12px 0 6px;
    font-size: 12px;
    font-weight: 600;
    color: var(--color-ash);
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

  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
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
    flex: 1;
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

  .toggle-row.inline {
    margin-bottom: 0;
    font-size: 12px;
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

  button.danger {
    background-color: transparent;
    border: 1px solid color-mix(in srgb, var(--color-attic-clay) 60%, transparent);
    color: var(--color-attic-clay);
  }

  .accessibility button {
    display: block;
    margin: 14px 0 8px;
  }

  .error {
    color: var(--color-attic-clay);
    font-size: 12px;
  }

  .confirm {
    color: var(--color-verdigris);
    font-size: 12px;
  }

  .providers-header {
    justify-content: space-between;
  }

  .providers-header h2 {
    margin: 0;
  }

  .profile-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .profile-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 8px;
    border: 1px solid color-mix(in srgb, var(--color-marble) 10%, transparent);
    border-radius: 8px;
    flex-wrap: wrap;
  }

  .active-marker {
    display: flex;
    align-items: center;
  }

  .profile-info {
    display: flex;
    flex-direction: column;
    min-width: 100px;
  }

  .profile-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--color-marble);
  }

  .profile-model {
    font-size: 11px;
    color: var(--color-ash);
  }

  .test-result {
    font-size: 11px;
  }

  .test-result.ok {
    color: var(--color-verdigris);
  }

  .test-result.error {
    color: var(--color-attic-clay);
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

  .header-row {
    max-width: 400px;
  }

  .form-actions {
    margin-top: 12px;
  }
</style>
