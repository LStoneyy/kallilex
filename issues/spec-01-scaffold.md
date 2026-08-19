# Spec 01 — Scaffold: menu-bar shell & popover frame

Status: ready-for-agent
Phase: P0 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)

## Problem Statement

Kallilex exists only as a concept: there is no application yet. Before any writing feature can be built, the app must exist as a macOS menu-bar application that launches unobtrusively, shows a small popover on demand, and can be developed and built reliably. From the user's perspective: today there is nothing to launch, nothing to click, and nothing for later features to hang on.

## Solution

A Tauri 2 application that runs as a menu-bar-only app: no dock icon, a tray icon in the menu bar, and a small borderless dark popover anchored directly under the tray icon. Left-clicking the tray icon shows and hides the (for now empty) popover; right-clicking offers Settings, About, and Quit. Launching the app a second time focuses the existing instance instead of spawning a duplicate. The visual foundation — the "Attic Oxide" design tokens — is in place from day one.

## User Stories

1. As a user, I want Kallilex to appear as an icon in my menu bar when I launch it, so that it is reachable from anywhere without cluttering my desktop.
2. As a user, I want no dock icon, so that the app stays completely out of the way.
3. As a user, I want left-click on the tray icon to show a compact popover under the icon, so that mouse users have the same fast path as keyboard users.
4. As a user, I want left-click again to hide the popover, so that toggling feels natural.
5. As a user, I want the popover to take keyboard focus when it opens, so that I can type without clicking first.
6. As a user, I want the popover to close when it loses focus, so that it never lingers in the way.
7. As a user, I want right-click on the tray icon to offer Settings, About, and Quit, so that everything is discoverable from one place.
8. As a user, I want a second launch of the app to focus the running instance, so that I never end up with two copies fighting over the tray.
9. As a user, I want the popover to appear in a predictable place directly under the tray icon, so that my eyes always know where to look.
10. As a user, I want a dark, restrained, high-contrast look, so that the tool feels calm and intentional rather than like a generic dashboard app.
11. As a developer, I want a working dev loop and a working production build, so that every later phase builds on a solid foundation.
12. As a developer, I want the design tokens (Basalt, Marble, Verdigris, Attic Clay, Tyrian, Electrum, Ash) defined once and shared, so that every screen uses consistent colors.
13. As a developer, I want non-secret settings persisted from day one, so that later features have somewhere to store state.
14. As a developer, I want window capabilities to follow least privilege, so that security is the default rather than an afterthought.
15. As a developer, I want the frontend split into popover, settings, and shared layers, so that later phases slot in without restructuring.

## Implementation Decisions

- Desktop shell: Tauri 2 with Rust for native integration and Svelte + TypeScript (Vite) for the UI.
- Menu-bar-only presence: tray icon via the Tauri tray-icon feature; dock icon hidden via the accessory activation policy.
- Single instance via the official single-instance plugin; a second launch focuses the existing instance.
- Popover window: borderless, always-on-top, non-resizable, roughly 380–420 px wide, positioned directly under the tray icon via the positioner plugin (tray-anchored).
- Popover takes keyboard focus on open; focus loss hides the window; Escape closes without side effects.
- Tray menu: Settings, About, Quit. In this phase Settings opens an empty settings-window shell (the real content arrives in spec-05) and About shows a minimal native about panel with name, version, and license; Quit is fully functional.
- Settings persistence: Tauri Store for non-secret settings only (active profile id, shortcut, spellcheck on/off, popover behavior, window placement hints).
- Frontend structure: popover UI, settings UI, and a shared layer for types, invoke wrappers, and design tokens.
- Visual identity: "Attic Oxide" palette — Basalt main background, Marble primary text, Verdigris accent for active states, Attic Clay for the main action, Tyrian secondary accent, Electrum for warnings/highlights, Ash for muted text. Dark mode first; typography and spacing do the work; no decorative gradients; one strong accent per state.
- Tauri capabilities follow least privilege: each window gets only the plugin permissions it actually uses.
- Command surface is implementation-agnostic from the start; the UI never talks to providers or platform internals directly.

## Testing Decisions

- Good tests assert external behavior only (what a command returns or what the app observably does), never internal state or private functions.
- This phase is mostly shell: acceptance is verified by launch behavior — app launches to tray only; clicking the icon shows/hides an empty popover anchored under it; a second launch focuses the existing instance; dev and production build both work.
- The seams established here and used by all later phases: the Tauri command surface as the primary seam (commands backed by the `Provider`, `SpellChecker`, `SelectionBackend`, and `SettingsStore` traits, which are the injection points for fakes), plus Svelte component tests for the popover state machine as the secondary seam.
- Any settings-store behavior introduced here gets unit tests at the command surface against a fake store.
- Prior art: none — this is the first code in the repo; these tests set the pattern for everything that follows.

## Out of Scope

- Global shortcut, text capture, clipboard fallback, permission onboarding (spec-02).
- Text editing, spell checking, action buttons (spec-03).
- Replace/Copy write-back (spec-04).
- AI provider layer, settings window UI (spec-05).
- Release builds, CI, signing, README rework (spec-06).
- Light theme, Linux/Windows, resizable or freely positionable popover, autostart.

## Further Notes

- This is phase P0 of the vertical-slice build order: platform risk first, provider layer last.
- Acceptance (from PRD): app launches to tray only; clicking the icon shows/hides an empty popover anchored under it; second app launch focuses the existing instance; `tauri dev` and `tauri build` work.
- Source of truth: PRD.md in the repo root (approved for implementation).
