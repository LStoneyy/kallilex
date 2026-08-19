# Spec 06 — Release: build, distribution & docs

Status: ready-for-agent
Phase: P5 of the Kallilex macOS MVP (source: PRD.md, approved 2026-08-19)
Depends on: specs 01–05 (all feature phases complete)

## Problem Statement

From the user's perspective: an app they can't install safely isn't an app. Without a downloadable build, clear Gatekeeper instructions, and CI proving the code works, Kallilex stays a developer's curiosity. The README also still contains contradictions with the approved product decisions (a diff view that won't exist in v1, an ambiguous paste-or-capture story) that would mislead users about what the app actually does.

## Solution

Kallilex v1 ships as an ad-hoc signed build via GitHub Releases. The README explains the one-time Privacy & Security approval and describes exactly the shipped behavior. CI runs the full check suite (Rust tests, clippy, frontend lint/typecheck, tauri build) on macOS, and a manual test pass over the app matrix precedes each release.

## User Stories

1. As a user, I want to download a release build from GitHub Releases, so that I can install Kallilex without building it myself.
2. As a user, I want clear README instructions for the one-time Gatekeeper approval, so that ad-hoc signing doesn't block or scare me.
3. As a user, I want the app to run on a clean Mac after that one approval, so that installation just works.
4. As a user, I want the README to match the shipped behavior exactly, so that I'm never misled by outdated descriptions (no diff view in v1; capture is automatic with a clipboard fallback).
5. As a contributor, I want CI to run Rust tests, clippy, frontend lint/typecheck, and a tauri build on macOS, so that breakage is caught before release.
6. As a maintainer, I want a repeatable release workflow, so that shipping a version is boring.
7. As a maintainer, I want a manual test pass over the app matrix before each release, so that platform regressions don't reach users.
8. As an open-source user, I want the Apache-2.0 license and the no-accounts/no-telemetry promises visible, so that I can trust the tool before installing it.
9. As a privacy-conscious user, I want assurance that logs (if any) contain no selection content, so that installing the app doesn't create a data trail.

## Implementation Decisions

- Ad-hoc signed build (signing identity set to "-") distributed via GitHub Releases; users must allow the app once under System Settings → Privacy & Security, documented in the README.
- No Apple Developer account requirement in v1; Developer-ID signing + notarization and a Homebrew cask are roadmap items.
- CI (GitHub Actions) on macOS: cargo test + cargo clippy + frontend lint/typecheck + tauri build.
- README updates resolve the diff-view and paste-or-capture contradictions against the PRD: no diff view in v1 (result replaces the editable text); capture is automatic (Accessibility API with clipboard fallback).
- Manual test pass over the app matrix per release: capture + replace in TextEdit, Notes, Mail, Safari, Chrome, VS Code, Terminal, Slack, and one password-secure field (expected fallback/failure behavior); clipboard restoration verified in each.
- Release candidate gates: CI green, manual matrix pass, README accuracy check.
- No telemetry, crash reporting, or analytics of any kind; logs (if any) contain no selection content.

## Testing Decisions

- The release process is the test surface: CI must be green; the manual matrix is the acceptance test; a clean-Mac smoke run verifies the Gatekeeper path.
- Good release verification checks observable behavior only (install → allow once → launch → tray → full select/shortcut/action/replace workflow), never build internals.
- Prior art: the phase acceptance criteria in specs 01–05 define the per-feature checks; this phase re-verifies them as a whole.

## Out of Scope

- Developer-ID signing, notarization, and a Homebrew cask (roadmap).
- Mac App Store distribution.
- Auto-updater (undecided: Sparkle vs Tauri updater — deferred until the notarization decision).
- Linux/Windows builds.

## Further Notes

- This is phase P5, the final phase of the vertical slice.
- Acceptance (from PRD): a downloaded release runs on a clean Mac after the documented one-time approval; the README matches the shipped behavior.
- Open items (non-blocking, from PRD): final default shortcut (⌥⌘K assumed; confirm before release if conflicts surface); exact popover dimensions and tray-icon artwork; updater mechanism choice; trademark/domain check for "Kallilex" before any public launch; whether clipboard restore should be optional per profile.
- Source of truth: PRD.md in the repo root.
