# Kallilex

> A tiny, local-first writing utility for spelling, rewriting, and polishing text from anywhere on your desktop.

## Idea

Kallilex lives quietly in the macOS menu bar. Instead of opening a browser, switching to a chatbot, or installing a large writing suite, you invoke Kallilex with a click or global shortcut, edit the current text, and put the result straight back where it came from.

The intended workflow is:

1. Select text in any application.
2. Trigger Kallilex with a configurable global shortcut.
3. The selected text appears in a small popover.
4. Run a local spell check or an AI action such as **Rewrite**, **Shorten**, **Improve clarity**, or a custom prompt.
5. Copy the result or replace/paste it back into the previous application.

Kallilex should stay fast, unobtrusive, privacy-conscious, free, and open source.

## Name

**Kallilex** is the working project name.

It is inspired by Greek *kalli-* ("beautiful") and *lexis* ("word / expression"), with a nod to the ancient term *kallilexia* for elegant expression.

A preliminary web/package/app search did not reveal an obvious existing software project named Kallilex. This is not a trademark clearance, so a proper trademark and domain check should happen before a public launch.

## Visual identity — “Attic Oxide”

The UI should avoid the usual pastel developer palettes. The direction combines dark basalt, oxidized bronze, Attic pottery, marble, and restrained purple.

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
- diff/suggestion views remain readable at a glance;
- dark mode first, with a marble-based light theme later.

## Tech stack

### Desktop shell

- **Tauri 2**
- **Rust** for native integrations, provider calls, clipboard/selection logic, and local checking
- **Svelte + TypeScript** for the small popover and settings UI

Tauri keeps the desktop shell small while leaving a realistic path to macOS, Linux, and Windows.

### Native desktop features

Use Tauri's desktop capabilities for:

- system tray / menu bar icon;
- configurable global shortcuts;
- clipboard access;
- autostart;
- single-instance behavior;
- persistent non-secret settings.

On macOS, selected-text capture and replacement should live behind a platform abstraction using the Accessibility APIs. This requires explicit Accessibility permission. A clipboard-based fallback can be provided for applications that do not expose their selection cleanly.

### Spell checking

Spell checking should remain independent from AI.

For macOS v1, use the native spell-checking facilities so Kallilex can benefit from the user's installed/preferred languages without loading a model.

The core API should be abstracted so future Linux/Windows builds can plug in another local checker. Harper can optionally be added for richer English grammar/style checking, but should not be the only checker because its current language coverage is English-focused.

### AI provider layer

Create one internal provider interface, for example:

```text
Provider
├── OpenAI
├── OpenAI-compatible
├── Ollama
├── LM Studio
└── llama.cpp / custom local server
```

Most integrations should be configurable through:

- base URL;
- optional API key;
- model;
- endpoint/API mode;
- timeout;
- optional custom headers.

Ollama and LM Studio already expose OpenAI-compatible APIs, so they should reuse the generic OpenAI-compatible adapter whenever possible rather than receiving separate hard-coded implementations.

Suggested Rust pieces:

- `reqwest` — HTTP
- `serde` / `serde_json` — configuration and API payloads
- `tokio` — async work
- Tauri Store — non-secret preferences

API keys must never be written to plain configuration files. Keep secret storage behind a platform abstraction and use the operating system's credential storage.

## Suggested architecture

```text
src/
  ui/
    popover
    settings
    diff-view

src-tauri/
  core/
    actions.rs
    providers/
    spellcheck/
    selection/
    clipboard/
    settings/

  platform/
    macos/
    linux/
    windows/
```

Keep UI commands independent from provider implementation. A command such as `rewrite(text, preset, provider)` should not care whether the request goes to OpenAI, Ollama, LM Studio, llama.cpp, or another compatible endpoint.

## MVP

The first macOS release should stay intentionally small:

- menu bar application;
- configurable global shortcut;
- paste or capture selected text;
- local spelling suggestions;
- Rewrite / Shorten / Improve clarity actions;
- custom prompt;
- OpenAI-compatible provider configuration;
- Ollama / LM Studio via compatible base URLs;
- copy result;
- replace or paste result back into the previous app;
- no accounts, telemetry, subscriptions, or cloud backend.

## Later

- Linux and Windows builds;
- richer diff view and one-click suggestion acceptance;
- user-defined rewrite presets;
- per-app presets;
- optional Harper integration for English grammar/style;
- llama.cpp process management instead of requiring an external server;
- plugin/provider SDK;
- import/export of configuration without secrets.

## Principles

1. **Local first.** Spell checking should work without internet access.
2. **Provider agnostic.** Users choose where AI requests go.
3. **Fast path first.** Select → shortcut → action → replace.
4. **No browser extension required.** Kallilex works across applications.
5. **Minimal footprint.** No Electron-style always-running web application.
6. **Transparent.** Open source, free, and explicit about when text leaves the machine.
7. **No telemetry by default.**
8. **Text belongs to the user.**

## License

The project is free and open source under the Apache 2.0 licence.
