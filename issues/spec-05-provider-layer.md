# Spec 05 — Provider layer: AI actions, profiles, settings window & privacy badge

Status: ready-for-agent
Phase: P4 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)
Depends on: spec-03 (popover action UI), spec-04 (Replace/Copy flow)

## Problem Statement

From the user's perspective: spellcheck covers typos, but the real leverage is AI transformation — rewriting, shortening, clarifying, custom instructions. Today that means a browser tab with a chatbot, an account, and text silently shipped to someone else's cloud. The user wants the same power from the popover, but with full control over where the text goes, what it costs, and what errors mean — including running everything on their own machine or LAN. Configuration so far also has no home: the shortcut cannot be changed, and there is no place to manage providers or preferences.

## Solution

The four actions (Rewrite, Shorten, Improve clarity, Custom) are wired to a provider layer that talks to any OpenAI-compatible endpoint. The user manages named provider profiles (exactly one active) in a proper settings window, created from convenience presets (Ollama, LM Studio, OpenAI, custom base URL). API keys live in the macOS Keychain, never in config files. Before any request runs, a privacy badge shows Local / LAN / Cloud derived from the endpoint, so the user always knows whether text stays on the machine. Requests are non-streaming with a visible cancel; errors are distinct and actionable. The result replaces the editable text and flows into the existing Replace/Copy workflow. The settings window also becomes home to General settings: shortcut, autostart, spellcheck toggle.

## User Stories

1. As a writer, I want Rewrite to work end-to-end, so that I can improve phrasing without leaving the app I'm in.
2. As a writer, I want Shorten to work end-to-end, so that I can tighten long passages in one click.
3. As a writer, I want Improve clarity to work end-to-end, so that fuzzy text becomes clear.
4. As a writer, I want Custom to combine my one-line instruction with the text, so that I can transform text my own way.
5. As a writer, I want the AI to return only the transformed text, so that I don't have to strip preamble or commentary.
6. As a writer, I want the result to replace the editable field and remain editable, so that I can review and tweak before Replace/Copy.
7. As a user, I want to cancel an in-flight request, so that I'm never stuck waiting on a slow model.
8. As a user, I want a configurable per-profile timeout (default 30 s), so that slow endpoints don't hang the popover.
9. As a local-model user, I want an Ollama preset, so that setup is essentially one click.
10. As a local-model user, I want an LM Studio preset, so that setup is essentially one click.
11. As a user of a custom server, I want to enter any OpenAI-compatible base URL, so that my llama.cpp server (or any other) works.
12. As an OpenAI user, I want an OpenAI preset where I just add my key, so that cloud use is possible when I choose it.
13. As a user, I want multiple named profiles, so that I can keep local, LAN, and cloud endpoints side by side.
14. As a user, I want exactly one active profile at a time, so that I always know which endpoint will be used.
15. As a user, I want to edit profile fields (name, base URL, model, timeout, custom headers, enabled flag), so that the layer fits my setup.
16. As a user, I want optional custom headers per profile, so that endpoints behind proxies or gateways work.
17. As a user with an API-key provider, I want my key stored in the macOS Keychain, so that it never sits in a plain config file.
18. As a user, I want a Test connection button that sends a minimal request and reports success, latency, or a specific error, so that I can debug setup immediately.
19. As a privacy-conscious user, I want a Local badge when the endpoint is localhost, so that I can see the text stays on this machine.
20. As a privacy-conscious user, I want a Private network badge (profile name + "LAN") when the endpoint is on my LAN, so that I can see the text leaves this machine but not my network.
21. As a privacy-conscious user, I want a Cloud badge (profile name + "Cloud") for everything else, so that there are no surprises.
22. As a privacy-conscious user, I want the badge shown before any request runs, so that I can abort before text leaves the machine.
23. As a user, I want a clear error when the endpoint is unreachable or the connection is refused, so that I know to start the server.
24. As a user, I want a clear timeout error, so that I know the endpoint is slow rather than broken.
25. As a user, I want HTTP error statuses surfaced with a body snippet, so that I can see what the server actually said.
26. As a user, I want a clear error when the model is missing or empty, so that misconfiguration is obvious.
27. As a user, I want a clear error when the base URL is invalid, so that typos fail fast.
28. As a user, I want provider settings in the settings window (separate from the popover), so that the popover stays small.
29. As a user, I want to change the global shortcut in Settings, so that it fits my muscle memory.
30. As a user, I want opt-in autostart (default off), so that the shortcut works after a reboot if I want it.
31. As a user, I want to toggle spell checking in Settings, so that I can turn it off if it distracts.
32. As a developer, I want one generic OpenAI-compatible adapter behind a `Provider` trait, so that presets are configuration, not code paths.
33. As a developer, I want the UI to never know which provider backend runs a request, so that provider changes never touch the UI.
34. As a developer, I want the adapter integration-tested against a mock server, so that request/response handling is verified without a real endpoint.
35. As a user, I want non-streaming requests in v1, so that behavior is simple and predictable (one request, full result).
36. As a first-time user without any configured provider, I want the action buttons to show a friendly hint pointing me to Settings instead of failing with a network error, so that setup is discoverable and spellcheck-only use never feels broken.

## Implementation Decisions

- Provider layer: a `Provider` trait plus one generic OpenAI-compatible adapter (Chat Completions: POST `{base_url}/chat/completions`). Ollama, LM Studio, and llama.cpp are presets (pre-filled base URLs), not separate code paths.
- Actions: Rewrite, Shorten, Improve clarity with hard-coded English system prompts; Custom combines the user's one-line instruction with the text. The user text is sent verbatim; prompts instruct the model to return only the transformed text.
- Non-streaming in v1: one request, full result, timeout/cancel/error handling with a visible cancel affordance.
- Profile fields: name, base URL, model, timeout (default 30 s), optional API key, optional custom headers (simple key/value rows), enabled flag. Exactly one profile is active; the active profile serves all AI actions.
- Bundled presets: Ollama (localhost:11434/v1), LM Studio (localhost:1234/v1), custom/OpenAI-compatible (empty base URL), OpenAI (with key).
- Secrets: API keys are stored in the macOS Keychain (keyring crate), never in the Tauri Store or any plain config file; future settings export/import never includes secrets.
- Privacy badge: classification derives from the base URL host — Local for localhost/127.0.0.1; Private network for LAN endpoints (profile name + "LAN"); Cloud otherwise (profile name + "Cloud"). Shown in the popover while an AI action is possible, before any request runs. Spell checking never carries a badge.
- Error taxonomy: unreachable endpoint / connection refused; timeout; HTTP error status with body snippet; missing/empty model; invalid base URL. Surfaced inline in the popover — never a generic "failed".
- "No active provider profile" is not a request error: no request is attempted; the popover shows a hint pointing to Settings. The app remains fully usable for spellcheck without any profile.
- Command surface: `run_action(text, action)`; profile CRUD; a test-connection command. The UI never touches providers directly.
- Settings window (separate from the popover): General (shortcut, autostart, spellcheck on/off) and Providers (profile list, edit dialog, Test connection).
- Autostart is opt-in (default off) via the official autostart plugin.
- Non-secret settings persisted via Tauri Store: active profile id, shortcut, spellcheck on/off, popover behavior, window placement hints.
- Development and integration testing run against the developer's local llama.cpp OpenAI-compatible endpoint on the LAN AI server.
- Rust pieces: reqwest for HTTP, serde/serde_json for payloads, tokio for async work.

## Testing Decisions

- Good tests assert external behavior only: `run_action(text, action)` against a fake provider returns transformed text or a specific error; the adapter is tested over real HTTP against a mock server, not by inspecting its internals.
- Unit (Rust): provider adapter against a local mock OpenAI-compatible server (wiremock) — success, connection refused, timeout, HTTP error status with body snippet, missing model, invalid base URL; prompt assembly for all four actions (verbatim user text, transformed-text-only instruction); privacy badge classification from base URLs (localhost → Local, LAN → LAN, everything else → Cloud); profile validation.
- Command surface: run_action with a fake Provider; run_action with no active profile returns the not-configured hint without any request being attempted; profile CRUD round-trips via fake settings store and fake keychain; secrets never appear in store output.
- Manual: all four AI actions end-to-end against the developer's llama.cpp LAN endpoint; API keys appear only in the Keychain (store and config contents verified secret-free); badge correctness per base URL.
- Prior art: the command-surface-with-fakes pattern from specs 01–04; wiremock is the integration approach named in the PRD.

## Out of Scope

- Streaming responses (v1 decision: none).
- User-defined action presets and per-app presets (roadmap).
- The Responses API or provider-specific API modes (v1 targets Chat Completions only — supported by Ollama, LM Studio, and llama.cpp; revisit later).
- llama.cpp process management (external server only).
- Settings import/export (later; must never include secrets).
- Notarization and release packaging (spec-06).

## Further Notes

- This is phase P4 of the vertical slice: the best-specified, most isolated layer lands last.
- Acceptance (from PRD): all four AI actions work end-to-end against the developer's llama.cpp endpoint (LAN) and a mock provider in tests; API keys appear only in the Keychain; the badge shows Local/LAN/Cloud correctly per base URL.
- Risk (from PRD): provider API divergence (Responses vs Chat Completions) — mitigated by targeting Chat Completions only in v1.
- Source of truth: PRD.md in the repo root.
