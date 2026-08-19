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

## Installation

Kallilex ships as a macOS app, distributed as a zip on [GitHub Releases](../../releases).

1. Download `Kallilex-vX.Y.Z-macos-universal.zip` from the latest release.
2. Unzip it and drag `Kallilex.app` to `/Applications`.
3. On first launch, macOS blocks the app because it is ad-hoc signed (there is no Apple Developer notarization in v1): a dialog says the app could not be verified, offering only **Done** and **Move to Trash**. Click **Done**, then open **System Settings → Privacy & Security**, scroll down to the security section, and click **"Open Anyway"**; confirm the follow-up prompt. This approval is only needed once. (On macOS 15 Sequoia and later, the old right-click → Open shortcut no longer works for unnotarized apps.)
4. On the first capture, macOS prompts for **Accessibility** permission — grant it under **System Settings → Privacy & Security → Accessibility**. Kallilex needs this to read the selected text from the frontmost app.

Notarized builds and a Homebrew cask are on the roadmap; see [Later](#later).

## Capture

Capture is automatic — there is no manual paste step:

- **Primary path:** the macOS Accessibility API reads the current selection directly from the frontmost app. This requires the one-time Accessibility permission above.
- **Fallback:** for apps that don't expose their selection through Accessibility, Kallilex falls back to a clipboard-based capture (a synthetic ⌘C). The clipboard is backed up before the fallback runs and restored afterwards, so your existing clipboard contents are never lost.

## Popover

The popover shows the captured text as editable content, plus:

- local spell check, powered by macOS's native `NSSpellChecker` — fully offline;
- action buttons: **Rewrite**, **Shorten**, **Improve clarity**, and **Custom prompt**;
- a privacy badge showing whether the active AI provider is **Local**, **LAN**, or **Cloud**, derived from its base URL before any request is sent.

There is no diff view in v1 — running an action replaces the editable text in the popover with the result, in place.

## Results: Copy or Replace

Once you're happy with the result:

- **Copy** leaves the result on the clipboard for you to paste manually.
- **Replace** pastes the result back into the app you captured it from (via a synthetic ⌘V), then restores your original clipboard contents afterwards.

## Privacy

- **Local-first spell check.** Spell checking uses macOS's native, fully offline `NSSpellChecker` and works without an AI provider or network access.
- **Local / LAN / Cloud badge.** Before any AI request, the popover classifies the active provider from its base URL and shows whether it's local, on your LAN, or a cloud endpoint — so you always know where your text is about to go.
- **Keychain-only API keys.** Provider API keys are stored in the macOS Keychain and are never written to config files.
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

### Spell checking

Spell checking is independent from AI.

On macOS, Kallilex uses the native spell-checking facilities so it benefits from the user's installed/preferred languages without loading a model.

The core API is abstracted so future Linux/Windows builds can plug in another local checker.

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
- optional API key (stored in the Keychain, never in config files).

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

CI (`.github/workflows/ci.yml`) runs `pnpm check` (Svelte/TypeScript typecheck), `pnpm test` (frontend tests), `cargo clippy` and `cargo test` for the Rust side, and a full `tauri build`, all on macOS.

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
- Linux and Windows builds;
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
