# Spec 22 — Ship popover shortcuts as 0.7.0-beta.1, then 0.7.0

Status: ready-for-agent (the agent prepares; the maintainer tags, publishes
and runs the device matrix)
Phase: distribution (the first release delivered through the in-app updater
to existing installs)
Depends on: spec-21 merged on `main`, CI green on its last commit, and the
device-side updater proof from spec-20 reported back (a 0.6.0-beta.1
install updating itself to 0.6.0 on macOS, Windows and AppImage; deb/rpm
notify-only; the offline error path). If that proof failed, the fix ships
as 0.6.1 first and this spec waits.

## Problem Statement

`main` now carries spec-21: assignable keyboard shortcuts for every popover
action and prompt, a Shortcuts tab in Settings that also hosts the global
shortcut, a key recorder, hold-⌘/Ctrl hints and a one-time migration that
gives existing prompts ⌘1–⌘9. None of this has run on a real device yet.

Two things make this release different from 0.6.0:

- It is the first feature release that existing users receive **through the
  app**, not by downloading it. Every 0.6.0 install will see 0.7.0 in the
  tray. A broken migration or a shortcut that swallows typing would reach
  everyone at once, with no reinstall step in between that might have
  caught it.
- Keyboard handling depends on things CI cannot see: physical layouts
  (German: ⌥L is `@` on macOS, AltGr+Q on Windows), WebView defaults
  (Ctrl+R / Ctrl+P in WebView2), and Wayland focus behaviour.

## Solution

1. **0.7.0-beta.1** — version bump on `main`, tag `v0.7.0-beta.1`, the
   workflow builds a draft flagged pre-release. The maintainer runs the
   gates below, publishes, and lets 0.6.0 installs that are switched to
   *Preview* pick it up in the app.
2. **0.7.0** — once beta.1 has passed (plus whatever fixes it needed,
   shipped as beta.2, beta.3, … under the same gates), bump to `0.7.0`, tag,
   publish. Every 0.6.0 install on *Stable* is offered it.

No beta.2 is planned up front; the updater itself was proven with
0.6.0-beta.1 → 0.6.0.

## User Stories

1. As a 0.6.0 user on Stable, I want nothing to change until 0.7.0, so that
   the pre-release is invisible to me.
2. As a tester on 0.6.0 who switches to Preview, I want beta.1 to arrive in
   the tray and install with one click, so that the release is tested the
   way users will get it.
3. As a tester updating from 0.6.0, I want my prompts to come out with
   ⌘1–⌘9 (Ctrl+1–Ctrl+9) in their existing order and my global shortcut
   untouched, so that I can use the keyboard immediately without setting
   anything up.
4. As a tester on a German layout, I want ⌥ / AltGr characters to keep
   typing in the popover, so that shortcuts never cost me an `@` or `€`.
5. As a tester on beta.1, I want 0.7.0 offered in the app once it ships, so
   that I end up on the stable line without doing anything.

## Implementation Decisions

### Version and tag conventions

- Version string in `package.json`, `src-tauri/tauri.conf.json`,
  `src-tauri/Cargo.toml`; `Cargo.lock` follows via `cargo check`. One
  commit per release, no other changes in it.
- Commit messages, matching `fc61128` and `8fd8228`:
  - `Release 0.7.0-beta.1: keyboard shortcuts in the popover`
  - `Release 0.7.0: keyboard shortcuts in the popover`
  Body: one or two sentences on what the release is for (pre-release on the
  preview channel; final with the same content as the last beta, or which
  fixes it adds).
- Tags `v0.7.0-beta.1` and `v0.7.0`. The `-` suffix is what flags the draft
  as a pre-release and makes the build default to *Preview*.

### Agent-prepared, maintainer-executed

- The agent's work per release: the version bump commit (on the
  maintainer's explicit go), a release-notes draft (below), and running the
  local checks on the bump commit. The agent does **not** tag, push tags,
  publish, or delete releases.
- The maintainer pushes the tag, waits for the workflow jobs, and runs the
  matrix. The agent may then verify the draft's asset list and
  `latest.json` via `gh` (read-only).

### Release notes draft

To paste over `--generate-notes`, adjusted for the beta (first line) or the
final (drop the first line):

> Pre-release for testing. Stable installs are not offered this version.
>
> **Keyboard shortcuts in the popover.** After the global shortcut opens
> the popover, everything else works from the keyboard: run a prompt,
> replace, copy, open the custom prompt or Settings. Hold ⌘ (Ctrl on
> Windows and Linux) to see which key does what.
>
> - Prompts get ⌘1–⌘9 (Ctrl+1–Ctrl+9) in their current order; new prompts
>   take the next free number.
> - Replace is ⌘↩, Copy ⌘⇧C, custom prompt ⌘L, Settings ⌘,.
> - Every shortcut can be changed in the new **Shortcuts** tab in Settings,
>   which now also holds the global shortcut. A prompt's shortcut can also
>   be set in its edit form.

### beta.1 gates (before publishing the draft)

- Draft exists, is flagged *Pre-release*, carries the same asset set as
  0.6.0 (macOS zip and `.app.tar.gz` + `.sig`; deb/rpm/AppImage + `.sha256`
  + `.sig`s; Windows `-setup.exe` + `.sha256` + `.sig`) and a `latest.json`
  whose URLs resolve.
- Fresh install on each platform: onboarding runs and its last step
  mentions the popover shortcuts; Settings → Updates shows `0.7.0-beta.1`,
  *Preview*; Settings → Shortcuts lists the defaults.
- The keyboard sections of `docs/release-checklist.md` (macOS §2, Linux §3,
  Windows §4) and the onboarding item in §5a, on each platform.
- Migration from 0.6.0, by **in-app update** on at least one platform (a
  0.6.0 install switched to *Preview* → check → install) and by hand on the
  others:
  - prompts get ⌘1–⌘9 / Ctrl+1–Ctrl+9 in list order, any beyond nine have
    none;
  - the global shortcut is the one set before the update and shows in
    Settings → Shortcuts;
  - profiles, popover position and pin state survive;
  - removing a prompt's shortcut and restarting does not bring it back (the
    migration runs once).
- Layout checks on a German layout: macOS ⌥L types `@` in the popover;
  Windows AltGr+Q types `@` and AltGr+E `€`; neither triggers a shortcut.
- Windows: Ctrl+R and Ctrl+P in the popover do not reload or open a print
  dialog. If they do, that is a blocker; the fix suppresses the WebView2
  default for those chords and ships as beta.2.
- Publish. Then confirm a 0.6.0 install on *Stable* still says up to date.

### 0.7.0 gates

- Content equals the last published beta (no new features between the last
  beta and the final).
- Bump, tag, publish. On a beta install (Preview) and on a 0.6.0 install
  (Stable): the tray offers 0.7.0, install works, and the migration result
  from beta.1 is unchanged (a beta install must not be re-seeded).
- The website needs no change: it links to the releases page, not to a
  version. The keyboard feature card is already on `main`, so the Pages
  deploy shows it before 0.7.0 ships; if that matters, hold the website
  commit back next time rather than reverting it now.

## Testing Decisions

- The agent runs `pnpm check`, `pnpm test`,
  `cargo clippy --all-targets -- -D warnings` and `cargo test` on each bump
  commit and reports the results before the maintainer tags.
- Everything in the gates above is manual. Findings from the matrix that
  need code changes get their own bounded fix, review and tests, like any
  other change, before the next beta.

## Out of Scope

- New shortcut features (Pin, keyboard navigation of spelling suggestions,
  per-profile shortcuts).
- Announcing the release beyond the GitHub release and the website card
  that already exists.
- Reformatting the repository with `cargo fmt`.

## Further Notes

- Downgrade: 0.6.0 ignores the new settings fields and drops them the next
  time it saves. Going 0.7 → 0.6 → 0.7 therefore resets popover shortcuts
  to their defaults and re-seeds prompt shortcuts. This is acceptable for a
  manual downgrade and needs no code; mention it only if a tester runs into
  it.
- Rollback is the same as for 0.6.0: unpublishing a release removes it from
  every future check immediately.
