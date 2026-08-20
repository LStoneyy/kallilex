# Kallilex — Product Requirements Document

| | |
| --- | --- |
| Status | Approved for implementation |
| Date | 2026-08-19 |
| Source | README concept + research (Tauri 2 docs, Apple docs, provider docs) + decision session |
| Scope | macOS MVP (v1) and near-term roadmap |

## 1. Summary

Kallilex is a tiny, local-first writing utility for the macOS menu bar. The user selects text in any application, triggers Kallilex with a global shortcut, and a compact popover appears at the menu bar. The text can be spell-checked locally or transformed by an AI action (**Rewrite**, **Shorten**, **Improve clarity**, or a custom prompt). The result is either copied or written straight back into the previous application via an explicit button click.

Core properties: fast, unobtrusive, privacy-conscious, free, open source (Apache-2.0). No accounts, no telemetry, no subscriptions, no cloud backend.

## 2. Goals

1. Deliver the fastest possible path: **select → shortcut → action → replace**.
2. Spell checking works fully offline using macOS-native facilities.
3. AI actions are provider-agnostic: any OpenAI-compatible endpoint works (cloud or local).
4. The user always knows whether text stays on the machine or leaves it.
5. Nothing is ever written back into another app without an explicit user action.

## 3. Non-goals (MVP)

- No inline diff view or word-level diff algorithm (result simply replaces the editable text).
- No user-defined or per-app rewrite presets.
- No streaming responses.
- No Harper / grammar-style checking.
- No llama.cpp process management (external server only).
- No light theme, no auto-updater. Platform support: macOS (menu bar, full functionality), Linux X11 (tier 1, full capture/replace loop), Linux Wayland (portal-backed on supported compositors: GlobalShortcuts + RemoteDesktop portals give shortcut and replace; degraded tray-capture/copy-only elsewhere); Windows remains unsupported (planned).
- No Mac App Store distribution, no notarization in v1.
- No telemetry, crash reporting, or analytics of any kind.

## 4. Primary user workflow

1. User selects text in any application.
2. User presses the global shortcut (default ⌥⌘K, configurable).
3. Kallilex captures the selection (Accessibility API; automatic clipboard fallback, see §6.2) and remembers the source application.
4. The popover opens at the menu bar (tray-anchored), shows the text, and takes keyboard focus.
5. User runs a local spell check or an AI action.
   - Spell check: misspelled words are marked; clicking a word shows native suggestions and applies one on click.
   - AI action: the editable text field is replaced by the (editable) result.
6. User clicks **Replace** (writes the result back into the source app) or **Copy** (result to clipboard, nothing written back).
7. **Replace** flow: clipboard is backed up → result placed on clipboard → focus returns to the source app → synthetic ⌘V pastes → original clipboard content is restored.
8. The popover closes; the user continues working where they left off.

Escape or focus loss closes the popover without any side effects.

## 5. Menu bar app & popover

### 5.1 Menu bar presence

- App runs as menu-bar-only: tray icon via Tauri `tray-icon` feature, dock icon hidden (`ActivationPolicy::Accessory`).
- Left-click on tray icon toggles the popover; right-click opens a small menu: **Settings**, **About**, **Quit**.
- Single-instance behavior via `tauri-plugin-single-instance`: a second launch focuses/opens the existing instance.

### 5.2 Popover window

- Borderless, always-on-top, non-resizable (v1), small (~380–420 px wide).
- Positioned directly under the tray icon via `tauri-plugin-positioner` (`tray-icon` feature, `on_tray_event` wiring).
- Takes keyboard focus on open (required for custom prompt input and text editing). Focus loss hides the window.
- Sections (single column, compact):
  1. Editable text area with captured text / result.
  2. Spell-check marks inline (see §7).
  3. Action row: Rewrite, Shorten, Improve clarity, Custom (opens a one-line prompt input).
  4. Result row: **Replace**, **Copy**, and the privacy badge (§9).
- Visual identity: "Attic Oxide" palette from README (Basalt background, Marble text, Verdigris accent for active states, Attic Clay for the main action). Dark mode first; no decorative gradients; typography and spacing do the work.

### 5.3 Global shortcut

- Registered via `tauri-plugin-global-shortcut` (Rust-side handler).
- Default ⌥⌘K, user-configurable in Settings; conflicts with system/other apps must surface an error, not fail silently.
- Trigger works regardless of which application is frontmost.

## 6. Text capture & replace-back (macOS platform layer)

All platform access sits behind a `SelectionBackend` trait so future platforms can plug in different implementations.

### 6.1 Accessibility capture (primary path)

- Read the frontmost application's focused element and its `AXSelectedText` attribute.
- Requires the user to grant Accessibility permission (see §6.4).
- Capture happens at shortcut-trigger time, before the popover takes focus.
- The source application (bundle id / pid) is remembered for replace-back and focus restoration.

### 6.2 Automatic clipboard fallback

If the AX path yields no selection (Terminals, secure text fields, some web/Electron content):

1. Back up the current clipboard content (text + find flags; best-effort for non-text formats).
2. Send a synthetic ⌘C to the source app.
3. Read the clipboard after a short settle delay.
4. Continue with the captured text. Lifecycle of the backup: **Replace** restores it after the paste settles (the user gets their original clipboard back, not the intermediate captured selection); **Copy** discards it (the result intentionally stays on the clipboard); cancel — Escape, focus loss, or closing without an action — restores it immediately.

The fallback runs automatically with no extra user action. If both paths fail, the popover opens with an empty text field and a hint (user can still type/paste manually — Kallilex remains usable).

### 6.3 Replace-back

- **Mechanism: clipboard + synthetic ⌘V only.** No direct AX writing of the target field (unreliable across app categories).
- Triggered exclusively by an explicit **Replace** button click — never automatically.
- Sequence: save clipboard → write result to clipboard → focus the remembered source app → synthetic ⌘V → wait for paste → restore saved clipboard.
- If a clipboard backup from the capture fallback (§6.2) already exists, that backup is the restore target — the clipboard is **not** re-saved (it holds the intermediate captured selection, not the user's original content).
- **Copy** button copies the result to the clipboard (overwriting it; no restore) and closes the popover.
- Formatting is not preserved: Kallilex works on plain text. Replacement in rich-text contexts arrives as plain text (documented behavior, not a bug).

### 6.4 Accessibility permission onboarding

- On first launch, a panel explains why the permission is needed, shows a live status indicator (granted / not granted), and offers a deep link to System Settings → Privacy & Security → Accessibility.
- Status is re-checked live (poll/refresh), so the panel updates as soon as the user grants permission — no app restart required in the happy path; a restart hint is shown if macOS requires it.
- If permission is missing at trigger time, the popover shows a compact prompt with the same deep link.

## 7. Spell checking

- Local, offline, independent from AI. macOS-native `NSSpellChecker` via an `objc2` bridge, dispatched on the main thread.
- Uses the user's system-preferred spell-check languages; no language picker in v1.
- Behavior: misspelled words are marked inline (squiggle/underline in Electrum); clicking a marked word shows the native suggestion list; choosing a suggestion replaces the word in the text field.
- Runs automatically when the popover opens with captured text, and on demand while editing.
- Learn/Ignore-to-dictionary, grammar checking, and Harper integration are deferred (roadmap).

## 8. AI actions & provider layer

### 8.1 Actions

- Built-in actions with hard-coded English system prompts: **Rewrite**, **Shorten**, **Improve clarity**.
- **Custom**: user types a one-line instruction that is combined with the text.
- The user text is sent verbatim; prompts instruct the model to return only the transformed text (no preamble/commentary).
- Requests are non-streaming in v1: one request, full result, simple timeout/cancel/error handling. A visible cancel affordance aborts the request.

### 8.2 Provider profiles

- Multiple named provider profiles; exactly one is **active** at a time. The active profile is used for all AI actions.
- Every profile is served by one generic **OpenAI-compatible adapter** (Chat Completions, POST `{base_url}/chat/completions`). Ollama, LM Studio, and llama.cpp are *presets* (pre-filled base URLs), not separate code paths.
- Profile fields: name, base URL, model, timeout (default 30 s), optional API key, optional custom headers (simple key/value rows), enabled flag.
- Bundled convenience presets: Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`), Custom/OpenAI-compatible (empty base URL), OpenAI (with key).
- Development/integration testing runs against the developer's local llama.cpp OpenAI-compatible endpoint on the LAN AI server.

### 8.3 Secrets

- API keys are stored in the macOS Keychain (`keyring` crate), never in the Tauri Store or any plain config file. Settings export/import (later) never includes secrets.

### 8.4 Error handling

- Distinct, actionable errors: unreachable endpoint / connection refused, timeout, HTTP error status (with body snippet), missing/empty model, invalid base URL. Surfaced inline in the popover, not as generic "failed".
- No active provider profile configured is not a request error: the popover shows a friendly hint pointing to Settings instead of attempting a request. Spell checking remains fully usable without any profile.

## 9. Privacy & transparency

- A compact badge is always visible in the popover while an AI action is possible:
  - **Local** — provider base URL resolves to localhost/127.0.0.1 (e.g. Ollama on this machine).
  - **Private network** — provider reachable on the LAN (e.g. the llama.cpp server); text leaves this machine but stays in the user's network. Badge shows profile name + "LAN".
  - **Cloud** — anything else; badge shows the profile name + "Cloud".
- Classification derives from the base URL host; shown before any request runs.
- Spell checking never leaves the machine and carries no badge.
- No telemetry, no logging of user text. Logs (if any) contain no selection content.

## 10. Settings

- Persisted via Tauri Store (non-secret): active profile id, shortcut, spellcheck on/off, popover behavior, window placement hints.
- Settings UI (separate window from the popover): General (shortcut, autostart, spellcheck), Providers (profile list, edit dialog with fields from §8.2, "Test connection" button that sends a minimal request and reports success/latency/error).
- Autostart via `tauri-plugin-autostart` (opt-in, default off).

## 11. Technical architecture

```text
src/                      # Svelte + TypeScript (Vite)
  popover/                # main popover UI
  settings/               # settings window UI
  shared/                 # types, invoke wrappers, design tokens

src-tauri/
  src/
    main.rs
    lib.rs                # tauri builder, plugins, tray, shortcut handler
    core/
      actions.rs          # rewrite/shorten/improve/custom prompt assembly
      providers/          # Provider trait + OpenAI-compatible adapter
      spellcheck/         # SpellChecker trait + macOS NSSpellChecker impl
      selection/          # SelectionBackend trait + orchestrator
      clipboard/          # backup/restore + synthetic key events
      settings/           # SettingsStore trait + Tauri Store impl
      keychain.rs         # secret storage via keyring
    platform/
      macos/              # AX capture, objc2 glue, activation policy
    commands.rs           # tauri commands (UI never touches providers directly)
  capabilities/           # minimal permission sets per window
```

- Command surface stays implementation-agnostic: e.g. `run_action(text, action)`, `spellcheck(text)`, `capture_selection()`, `replace_back(text)`, profile CRUD — the UI never knows which provider backend runs a request.
- All traits (`Provider`, `SpellChecker`, `SelectionBackend`, `SettingsStore`) are the test seams; unit tests run against fakes.
- Rust pieces: `reqwest`, `serde`/`serde_json`, `tokio`, `objc2`/`objc2-app-kit`, `keyring`, official Tauri plugins (global-shortcut, clipboard-manager, autostart, single-instance, store, positioner).
- Tauri capabilities follow least privilege: only the popover/settings windows get only the plugin permissions they use.

## 12. Release & distribution

- v1 ships as an ad-hoc signed build (`signingIdentity: "-"`) via GitHub Releases. Users must allow the app once under System Settings → Privacy & Security — this is documented in the README.
- No Apple Developer account requirement in v1. Developer-ID signing + notarization and a Homebrew cask are roadmap items.
- CI (GitHub Actions): `cargo test` + `cargo clippy` + frontend lint/typecheck + `tauri build` on macOS.

## 13. Implementation phases (vertical slice)

Platform risk first; the provider layer (best specified, most isolated) last.

### P0 — Scaffold

Tauri 2 + Svelte/TS project, tray icon, hidden dock icon, single instance, borderless popover positioned under the tray, show/hide on tray click, Tauri Store wired, Attic Oxide design tokens in place.

**Acceptance:** App launches to tray only. Clicking the icon shows/hides an empty popover anchored under it. Second app launch focuses the existing instance. `pnpm tauri dev` and `build` work.

### P1 — Capture

Global shortcut (⌥⌘K default), `SelectionBackend` trait, AX capture, automatic clipboard fallback with backup, source-app memory, first-run Accessibility panel with live status + deep link.

**Acceptance:** Shortcut in TextEdit/Safari captures the selection into the popover. In Terminal (no AX selection), the clipboard fallback captures automatically and the clipboard is restored afterwards. Permission panel reflects granting without restart.

### P2 — Popover & spellcheck

Text editing, action buttons, custom prompt input, `NSSpellChecker` integration with inline marks and click-to-correct suggestions.

**Acceptance:** Misspelled words are marked; clicking offers native suggestions; applying one edits the text. All four actions exist as UI (not yet wired to a provider).

### P3 — Replace-back

**Replace** button: clipboard backup → write result → refocus source app → synthetic ⌘V → restore clipboard. **Copy** button. Focus restoration. Cancel/Esc leaves everything untouched.

**Acceptance:** End-to-end without AI: select in Notes/Mail → shortcut → fix a typo via spellcheck → Replace → the corrected text stands in the source app and the previous clipboard content is back.

### P4 — Provider layer

`Provider` trait, OpenAI-compatible adapter (unit-tested against a mock server), profile CRUD + settings UI, Keychain secrets, test-connection button, privacy badge, action wiring, error taxonomy.

**Acceptance:** All four AI actions work end-to-end against the developer's llama.cpp endpoint (LAN) and a mock provider in tests. API keys appear only in the Keychain. Badge shows Local/LAN/Cloud correctly per base URL.

### P5 — Release

Ad-hoc signed build, GitHub Release workflow, README updates (resolve diff-view/paste-or-capture contradictions against this PRD), manual test pass over the app matrix, CI green.

**Acceptance:** A downloaded release runs on a clean Mac after the documented one-time approval; the README matches the shipped behavior.

## 14. Testing strategy

- **Unit (Rust):** every trait against fakes — provider adapter parses/streams nothing, times out, errors; prompt assembly; clipboard backup/restore state machine; profile validation.
- **Integration:** provider adapter against a local mock OpenAI server (wiremock) and manually against the llama.cpp endpoint; spellcheck against fixture strings.
- **Manual matrix (per release):** capture + replace in TextEdit, Notes, Mail, Safari, Chrome, VS Code, Terminal, Slack, and one password-secure field (expected fallback/failure behavior). Verify clipboard restoration in each.
- **UI:** Svelte component tests for popover state machine (idle → checking → result → replaced).

## 15. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| AX selection coverage varies by app | Automatic clipboard fallback; manual paste path keeps app usable |
| Clipboard race (apps that mutate clipboard) | Backup immediately before ⌘C; restore after paste settles; best-effort restore documented |
| Focus restoration flaky | Focus source app by remembered pid before ⌘V; small delay; verify AX focus if needed |
| NSSpellChecker main-thread constraints | All AppKit calls marshalled to main thread; spellcheck treated as request/response |
| Provider API divergence (Responses vs Chat Completions) | v1 targets Chat Completions only — supported by Ollama, LM Studio, llama.cpp; revisit later |
| Ad-hoc signing friction | Clear README instructions for the one-time Privacy & Security approval |

## 16. Roadmap (post-v1)

Diff view with one-click acceptance; user-defined and per-app presets; learn/ignore words; Harper for English grammar/style; llama.cpp process management; Developer-ID signing + notarization + Homebrew; auto-update (Sparkle or Tauri updater — undecided); Linux/Windows builds via the existing platform traits; config import/export without secrets; light (marble) theme.

## 17. Decision log

| # | Decision | Choice |
| --- | --- | --- |
| 1 | Replace mechanism | Clipboard + synthetic ⌘V (no AX writing) |
| 2 | Post-action behavior | Explicit Replace/Copy buttons — never automatic write-back |
| 3 | Popover position | Anchored under the tray icon (positioner) |
| 4 | Focus model | Popover takes focus; source app refocused after Replace |
| 5 | Capture fallback | Automatic clipboard fallback (backup → ⌘C → read → restore) |
| 6 | AX onboarding | First-run panel with live status + System Settings deep link |
| 7 | Spellcheck UX | Mark + click-to-correct via NSSpellChecker suggestions |
| 8 | AI actions | Rewrite / Shorten / Improve clarity / Custom, hard-coded prompts |
| 9 | Result view | Result replaces the editable text field (no before/after, no diff in v1) |
| 10 | Provider config | Multiple named profiles, one active; generic OpenAI-compatible adapter + presets |
| 11 | Streaming | None in v1 |
| 12 | Privacy display | Badge in popover: Local / LAN / Cloud, derived from base URL |
| 13 | Secrets | macOS Keychain via `keyring`; never in store/config files |
| 14 | UI language | English; Attic Oxide palette, dark-first |
| 15 | Distribution | Ad-hoc signing + GitHub Releases; notarization later |
| 16 | Build order | Vertical slice: platform path first, provider layer last |

## 18. Open items (non-blocking)

- Final default shortcut (⌥⌘K assumed; confirm before release if conflicts surface).
- Exact popover dimensions and tray-icon artwork.
- Updater mechanism choice (deferred until notarization decision).
- Trademark/domain check for "Kallilex" before any public launch (per README).
- Whether clipboard restore should be optional per profile (watch for user feedback).
