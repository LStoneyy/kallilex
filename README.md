# Kallilex

[![CI](https://github.com/LStoneyy/kallilex/actions/workflows/ci.yml/badge.svg)](https://github.com/LStoneyy/kallilex/actions/workflows/ci.yml)

> A tiny, local-first writing utility for spelling, rewriting, and polishing text from anywhere on your desktop.

## Idea

Kallilex lives quietly in the macOS menu bar. Instead of opening a browser, switching to a chatbot, or installing a large writing suite, you select some text, press a shortcut, and Kallilex captures it automatically, edits it in a small popover, and puts the result straight back where it came from.

The workflow is:

1. Select text in any application.
2. Press the global shortcut (**⌥⌘K** by default, configurable in Settings).
3. Kallilex captures the selection automatically and opens a popover with that text.
4. Run a local spell check or an AI action: **Rewrite**, **Shorten**, **Improve clarity**, or a custom prompt.
5. **Copy** the result to the clipboard, or **Replace** it back into the app you started from.

Kallilex stays fast, unobtrusive, privacy-conscious, free, and open source.

## Installation (macOS)

Kallilex ships as a macOS app, distributed as a zip on [GitHub Releases](../../releases).

1. Download `Kallilex-vX.Y.Z-macos-universal.zip` from the latest release.
2. Unzip it and drag `Kallilex.app` to `/Applications`.
3. On first launch, macOS blocks the app because it is ad-hoc signed (there is no Apple Developer notarization in v1): a dialog says the app could not be verified, offering only **Done** and **Move to Trash**. Click **Done**, then open **System Settings → Privacy & Security**, scroll down to the security section, and click **"Open Anyway"**; confirm the follow-up prompt. This approval is only needed once. (On macOS 15 Sequoia and later, the old right-click → Open shortcut no longer works for unnotarized apps.)
4. On the first capture, macOS prompts for **Accessibility** permission — grant it under **System Settings → Privacy & Security → Accessibility**. Kallilex needs this to read the selected text from the frontmost app.

Notarized builds and a Homebrew cask are on the roadmap; see [Later](#later).

## Linux

Kallilex also ships for Linux, distributed as `.deb`, `.rpm`, and AppImage packages on [GitHub Releases](../../releases).

Support depends on your session type:

- **X11 sessions** — full functionality: global shortcut, automatic capture, and Replace all work as on macOS.
- **Wayland sessions** — support depends on which XDG desktop portals your compositor provides; Kallilex detects this at startup and enables each feature independently. Settings → Accessibility shows which capabilities are live.
  - KDE Plasma and GNOME 48+: the full loop — global shortcut (bound through the system; rebind it in your desktop's keyboard settings) and automatic Replace. The first Replace asks for the remote-desktop input permission once via your desktop's own dialog; the grant persists until you revoke it in system settings. That permission is optional: turn "Use automatic paste-back" off in Settings → General and Kallilex never asks for it — capture keeps working from your current selection, and results are copied instead, automatically if you also turn on "Copy the result automatically".
  - Hyprland: global shortcut works; Replace is unavailable (no RemoteDesktop portal) — use Copy.
  - Sway and other wlroots compositors: degraded mode — open Kallilex from the tray ("Open Kallilex") to capture the primary selection, use Copy.

Install:

- **Debian/Ubuntu:** `sudo apt install ./Kallilex-*.deb`
- **Fedora:** `sudo dnf install ./Kallilex-*.rpm`
- **AppImage:** download it, `chmod +x Kallilex-*.AppImage`, then run it directly. On Wayland, prefer the `.deb`/`.rpm`: the portal-bound global shortcut requires an installed desktop entry whose basename matches the bundle identifier, which only those packages ship — an AppImage run under Wayland falls back to opening Kallilex from the tray for capture. On X11 the AppImage is fully equivalent to the other packages.

On GNOME, the tray icon requires the AppIndicator extension (`gnome-shell-extension-appindicator`) — without it, the icon simply won't show up; that's the extension missing, not the app being broken.

Kallilex picks up system Hunspell dictionaries from `/usr/share/hunspell` and `/usr/share/myspell` automatically and prefers them; it also bundles fallback `en_US` and German dictionaries for machines without system dictionaries installed. The bundled dictionaries carry their own licenses (the German dictionary is GPL-licensed), with the license texts included in the package; the app itself remains Apache-2.0.

## Windows

Kallilex also ships for Windows, distributed as a single NSIS installer on [GitHub Releases](../../releases).

Supported: Windows 10 21H2+ and Windows 11, x86_64.

Install:

1. Download `Kallilex-vX.Y.Z-windows-x86_64-setup.exe` from the latest release.
2. Run it — the installer installs Kallilex per-user, with no admin prompt.
3. On first launch, because the binary is unsigned (no code-signing certificate in v1), Windows SmartScreen shows a "Windows protected your PC" dialog: click **More info**, then **Run anyway**. This approval is only needed once.

Kallilex lives in the notification area, never the taskbar or Alt-Tab, with `Ctrl+Alt+K` as the default global shortcut.

Spell checking uses the built-in Windows Spell Checking API, fully offline, with the spell-check languages installed for your display languages. To add one, go to **Settings → Time & Language → Language & region**, add or select a language, and enable its "Basic typing" feature.

Provider API keys are stored in Windows Credential Manager — never written to config files.

Two honest limitations: apps running as administrator (elevated) are off-limits to Kallilex, because Windows' User Interface Privilege Isolation (UIPI) blocks synthetic input and accessibility reads across integrity levels — capture reports no selection and Replace reports a clear failure rather than silently doing nothing; and apps that expose no accessible text (some Electron and custom-toolkit apps) fall back to the synthetic-copy capture path described below.

## Capture

Capture is automatic — there is no manual paste step. On macOS:

- **Primary path:** the macOS Accessibility API reads the current selection directly from the frontmost app. This requires the one-time Accessibility permission above.
- **Fallback:** for apps that don't expose their selection through Accessibility, Kallilex falls back to a clipboard-based capture (a synthetic ⌘C). The clipboard is backed up before the fallback runs and restored afterwards, so your existing clipboard contents are never lost.

See [Linux](#linux) for the Linux capture paths. On Windows, capture reads the current selection via UI Automation (`TextPattern`), with the same clipboard-backed-up-and-restored synthetic-copy fallback for apps that expose no accessible text — see [Windows](#windows) for the platform's honest limitations.

## Popover

The popover shows the captured text as editable content, plus:

- local spell check, powered by macOS's native `NSSpellChecker` (a Hunspell-compatible engine on Linux, the Windows Spell Checking API on Windows) — fully offline;
- action buttons: **Rewrite**, **Shorten**, **Improve clarity**, and **Custom prompt**;
- a privacy badge showing whether the active AI provider is **Local**, **LAN**, or **Cloud**, derived from its base URL before any request is sent.

There is no diff view in v1 — running an action replaces the editable text in the popover with the result, in place.

## Results: Copy or Replace

Once you're happy with the result:

- **Copy** leaves the result on the clipboard for you to paste manually.
- **Replace** pastes the result back into the app you captured it from (via a synthetic ⌘V on macOS, Ctrl+V on Linux and Windows), then restores your original clipboard contents afterwards. On Linux, Replace needs X11, or a Wayland compositor with the RemoteDesktop portal and "Use automatic paste-back" left on — see [Linux](#linux). On Windows, Replace activates the source window (`SetForegroundWindow`) before pasting; it does not work against apps running elevated — see [Windows](#windows).

## Privacy

- **Local-first spell check.** Spell checking is fully offline and works without an AI provider or network access — macOS's native `NSSpellChecker`, on Linux a Hunspell-compatible engine, or on Windows the built-in Windows Spell Checking API.
- **Local / LAN / Cloud badge.** Before any AI request, the popover classifies the active provider from its base URL and shows whether it's local, on your LAN, or a cloud endpoint — so you always know where your text is about to go.
- **System-keychain-only API keys.** Provider API keys are stored in the macOS Keychain, on Linux the Secret Service (gnome-keyring / KWallet), or on Windows Credential Manager — never written to config files.
- **No accounts, no telemetry, no analytics.** Kallilex has no cloud backend and does not phone home.
- **No logs of your text.** The app does not log the content you select or edit.
- Text only leaves your machine when you explicitly invoke an AI action against a provider configured with a remote base URL.

## Name

**Kallilex** is the working project name.

It is inspired by Greek *kalli-* ("beautiful") and *lexis* ("word / expression"), with a nod to the ancient term *kallilexia* for elegant expression.

A preliminary web/package/app search did not reveal an obvious existing software project named Kallilex. This is not a trademark clearance, so a proper trademark and domain check should happen before a public launch.

## Visual identity — “Attic Oxide”

The UI avoids the usual pastel developer palettes. The direction combines dark basalt, oxidized bronze, Attic pottery, marble, and restrained purple.

| Token | Color | Use |
| --- | --- | --- |
| Basalt | `#17161A` | Main dark background |
| Marble | `#F2EEE6` | Primary light text / light surface |
| Verdigris | `#2FAF9B` | Primary accent, active states |
| Attic Clay | `#E46846` | Main action / emphasis |
| Tyrian | `#7D5778` | Secondary accent |
| Electrum | `#D7B45B` | Warnings, highlights |
| Ash | `#9C989F` | Muted text |

Design principles:

- compact rather than dashboard-like;
- typography and spacing do most of the work;
- almost no decorative gradients;
- one strong accent per state;
- dark mode first, with a marble-based light theme later.

## Tech stack

### Desktop shell

- **Tauri 2**
- **Rust** for native integrations, provider calls, clipboard/selection logic, and local checking
- **Svelte + TypeScript** for the small popover and settings UI

Tauri keeps the desktop shell small while leaving a realistic path to macOS, Linux, and Windows.

### Native desktop features

Kallilex uses Tauri's desktop capabilities for:

- system tray / menu bar icon;
- a configurable global shortcut;
- clipboard access;
- opt-in autostart (launch at login, off by default);
- single-instance behavior;
- persistent non-secret settings.

On macOS, selected-text capture and replacement live behind a platform abstraction backed by the Accessibility APIs, with a clipboard-based fallback for applications that don't expose their selection cleanly.

On Linux, the same abstraction has two backends. On X11, it's fully supported: `x11rb` queries the active window for frontmost-app identity, and key synthesis (for the clipboard fallback and Replace) and window activation both work directly. On Wayland, it runs through XDG desktop portals: the GlobalShortcuts portal binds the global shortcut, and the RemoteDesktop portal synthesizes the copy/paste keystrokes Replace needs, both only where the compositor supports them; primary-selection reads go through `arboard`'s data-control backend. Wayland has no cross-client window query protocol, so there is no way to read another app's window identity there.

On Windows, capture uses UI Automation (`IUIAutomation`/`TextPattern`) to read the current selection from the focused element directly, with a synthetic Ctrl+C clipboard fallback for apps that expose no accessible text; frontmost-app identity comes from `GetForegroundWindow`. Replace activates the remembered source window with `SetForegroundWindow` and pastes via `SendInput` (synthetic Ctrl+V). Both capture and Replace are blocked by Windows' User Interface Privilege Isolation (UIPI) against apps running at a higher integrity level (elevated/administrator), which is reported as a clear failure rather than silent no-ops.

### Spell checking

Spell checking is independent from AI.

On macOS, Kallilex uses the native spell-checking facilities so it benefits from the user's installed/preferred languages without loading a model.

On Linux, the same `SpellChecker` seam is backed by `spellbook` — a pure-Rust Hunspell-compatible engine — reading system Hunspell/MySpell dictionaries with bundled `en_US`/`de_DE` fallbacks (see [Linux](#linux) for the dictionary lookup). On Windows, the same seam is backed by the native Windows Spell Checking API, using the spell-check languages installed for your display languages — no bundled dictionaries needed.

### AI provider layer

Kallilex has one internal provider interface backed by a single OpenAI-compatible adapter (Chat Completions API), with presets for:

```text
Provider
└── OpenAI-compatible (Chat Completions)
    ├── OpenAI
    ├── Ollama       (http://localhost:11434/v1)
    ├── LM Studio    (http://localhost:1234/v1)
    └── Custom base URL
```

Each provider profile is configured with:

- name;
- base URL;
- model;
- timeout;
- optional custom headers;
- optional API key (stored in the macOS Keychain, on Linux the Secret Service via gnome-keyring/KWallet, or on Windows Credential Manager — never in config files).

Ollama and LM Studio expose OpenAI-compatible APIs, so they reuse the generic adapter rather than getting separate hard-coded implementations.

Rust pieces involved:

- `reqwest` — HTTP
- `serde` / `serde_json` — configuration and API payloads
- `tokio` — async work
- Tauri Store — non-secret preferences

## Suggested architecture

```text
src/
  ui/
    popover
    settings

src-tauri/
  core/
    actions.rs
    providers/
    spellcheck/
    selection/
    clipboard/
    secrets/
    settings/

  platform/
    macos/
    linux/
    windows/
```

Keep UI commands independent from provider implementation. A command such as `rewrite(text, preset, provider)` should not care whether the request goes to OpenAI, Ollama, LM Studio, or another compatible endpoint.

## Building from source

Prerequisites:

- Rust (stable toolchain)
- Node 22+
- pnpm 11

```sh
pnpm install
pnpm tauri dev     # run in development
pnpm tauri build   # build a release app bundle
```

CI (`.github/workflows/ci.yml`) runs `pnpm check` (Svelte/TypeScript typecheck), `pnpm test` (frontend tests), `cargo clippy` and `cargo test` for the Rust side, and a full `tauri build`, on macOS, Linux, and Windows.

## v1 feature set

The first macOS release stays intentionally small:

- menu bar application;
- configurable global shortcut (default ⌥⌘K);
- automatic capture of the current selection via the Accessibility API, with a clipboard-based fallback (clipboard is backed up and restored);
- local, offline spelling suggestions;
- Rewrite / Shorten / Improve clarity actions;
- custom prompt;
- OpenAI-compatible provider configuration, with presets for OpenAI, Ollama, and LM Studio;
- a Local/LAN/Cloud privacy badge for the active provider;
- copy result to clipboard;
- replace result back into the previous app (no diff view — the result replaces the editable text in the popover);
- opt-in launch-at-login, off by default;
- no accounts, telemetry, subscriptions, or cloud backend.

## Later

- Developer-ID signing and notarization;
- Homebrew cask;
- auto-updater;
- richer diff view and one-click suggestion acceptance;
- user-defined rewrite presets;
- per-app presets;
- optional Harper integration for English grammar/style;
- llama.cpp process management instead of requiring an external server;
- plugin/provider SDK;
- import/export of configuration without secrets.

## Principles

1. **Local first.** Spell checking works without internet access.
2. **Provider agnostic.** Users choose where AI requests go.
3. **Fast path first.** Select → shortcut → action → replace.
4. **No browser extension required.** Kallilex works across applications.
5. **Minimal footprint.** No Electron-style always-running web application.
6. **Transparent.** Open source, free, and explicit about when text leaves the machine.
7. **No telemetry by default.**
8. **Text belongs to the user.**

## License

The project is free and open source under the Apache 2.0 licence. See [LICENSE](LICENSE).
