# Spec 20 — Cut 0.6.0-beta.1, then prove the update path with 0.6.0-beta.2

Status: ready-for-agent (the agent prepares; the maintainer tags, publishes
and runs the device matrix)
Phase: distribution (fifth and last; the first pre-release, and the first
end-to-end proof of in-app updates)
Depends on: spec-16, spec-17, spec-18, spec-19 all merged on `main`, CI
green, the updater public key in `tauri.conf.json`, and the three GitHub
secrets in place (Apple certificate + password, updater key + password).

## Problem Statement

`main` is well ahead of `v0.5.0`: movable and pinnable popover, preserved
text formatting, user-managed prompts, and — after specs 16–19 — in-app
updates with a preview channel. The maintainer wants to test all of it as a
**pre-release** without pushing it to stable users.

There is a chicken-and-egg problem worth naming: the first release that
*contains* the updater can be checked (the app will say "up to date") but
cannot be *updated into*, because 0.5.0 has no updater. The install path —
download, signature verification, `.app` / AppImage / NSIS replacement,
restart, surviving TCC grant — is only exercised by the **second**
pre-release. So this spec is two releases, deliberately, and the second one
is the actual test of spec-17/19.

## Solution

1. **0.6.0-beta.1** — version bump on `main`, tag `v0.6.0-beta.1`, the
   workflow builds a draft flagged pre-release with `latest.json`; the
   maintainer smoke-tests fresh installs and upgrades-by-hand from 0.5.0 on
   each platform, then publishes.
2. **0.6.0-beta.2** — a minimal follow-up (anything real that came out of
   beta.1 testing, or, failing that, a doc-only change), tagged and
   published the same way; then the beta.1 installs update themselves to
   beta.2 on macOS, Windows and AppImage, and deb/rpm show the notify-only
   path. That is the release gate for the whole updater feature.

## User Stories

1. As the maintainer, I want a pre-release of the current `main` that
   stable users never see, so that I can test with a small group.
2. As a tester installing beta.1 by hand, I want the app to already be on
   the preview channel, so that beta.2 reaches me without configuration.
3. As a tester on beta.1, I want beta.2 to arrive as a tray label and a
   one-click install, so that the update feature is tested the way users
   will use it.
4. As a macOS tester, I want my Accessibility grant to survive beta.1 →
   beta.2 and no new Gatekeeper dialog to appear, so that "updates keep
   working" is proven, not promised.
5. As a stable-channel user on 0.5.0, I want nothing to change until 0.6.0
   final, so that the pre-release is invisible to me.
6. As a tester who switches the channel to Stable on beta.2, I want the app
   to say "up to date" (0.5.0 is older), so that channel switching never
   offers a downgrade.

## Implementation Decisions

### Version and tag conventions

- Version string `0.6.0-beta.1` in `package.json`,
  `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`; `Cargo.lock` follows
  via `cargo check`. One commit, message `Release 0.6.0-beta.1: …`, matching
  `dd41585 Release 0.5.0: first-run onboarding`.
- Tag `v0.6.0-beta.1` — the `-` is what spec-19's workflow keys the
  `--prerelease` flag on, and the suffix is what makes spec-16's build
  default `preview`.
- Subsequent pre-releases count up (`beta.2`, `beta.3`, …); the final is
  `0.6.0`, which every preview install sees as newer and every stable
  install sees as its first update.

### Agent-prepared, maintainer-executed

- The agent's work per release: the version bump commit (on the
  maintainer's explicit go), release-notes draft for the maintainer to
  paste over `--generate-notes` if desired, and a filled-in copy of the
  checklist items below as a tracking list. The agent does **not** tag,
  push tags, publish, or delete releases.
- The maintainer pushes the tag, waits for the four workflow jobs, and
  runs the matrix.

### beta.1 gates (before publishing the draft)

- Draft exists, is flagged *Pre-release*, carries: macOS zip, macOS
  `.app.tar.gz` + `.sig`, deb/rpm/AppImage + `.sha256` + `.sig`s, Windows
  `-setup.exe` + `.sha256` + `.sig`, and `latest.json` with exactly the four
  keys and URLs that resolve (`curl -I` each → 302 to the CDN).
- Fresh install on each platform: onboarding runs; Settings → Updates shows
  `0.6.0-beta.1`, channel *Preview*, frequency *Daily*; *Check for Updates*
  → "You're up to date".
- Upgrade-by-hand from 0.5.0 on each platform: settings survive
  (profiles, prompts, shortcut, popover position), channel shows *Preview*
  (build default, since nothing was persisted), Accessibility on macOS still
  granted (stable signing identity since 0.5.0 — no re-grant expected).
- Regression pass of the 0.5.x → main changes: popover drag / pin /
  reset position, formatting preserved through Replace, prompts CRUD in
  Settings and as popover buttons. Use the existing sections 2–5 of the
  checklist as the frame; this is the first release of that work.
- Publish. Then confirm from a beta.1 install that a check still says up to
  date (published release, same version) and from a 0.5.0 install that
  nothing changed (it has no updater; this is a no-op by construction — the
  point is that the website's "latest" link still shows 0.5.0, since
  pre-releases are excluded from `/releases/latest`).

### beta.2 gates (the updater proof)

- Ship a small change (see Solution), bump to `0.6.0-beta.2`, tag, publish.
- On a beta.1 install on each platform, with frequency *When Kallilex
  starts*: restart → within ~30 s the tray reads *Update to v0.6.0-beta.2
  available…* → click → Settings opens on Updates → *Download & install*
  (macOS, Windows, AppImage) shows progress → app restarts → About / the
  Updates tab shows beta.2.
- macOS specifics after the restart: no Gatekeeper dialog; Accessibility
  still granted (capture works on the first try); the app is still at its
  original path.
- Windows: NSIS runs passively, the app comes back, per-user install
  location unchanged, no admin prompt.
- AppImage: the same file path now contains beta.2; the running instance
  was replaced, not duplicated.
- deb and rpm installs: *Version 0.6.0-beta.2 is available* with *Open
  release page* and the package hint; no install button; the release page
  opens in the browser.
- Channel switch on beta.2 → *Stable* → check → up to date. Switch back →
  Preview → up to date.
- Negative path: with the network off, *Check for Updates* shows the
  "couldn't reach GitHub" sentence and the button stays usable.
- Any failure here is a blocker for the feature, not for beta.2 itself:
  beta.2 can stay published (it is a valid release) while the fix ships as
  beta.3, which then re-runs this section.

## Testing Decisions

- Everything above is manual by nature; CI's role is the usual gates on
  the bump commits. The agent runs `pnpm check`, `pnpm test`,
  `cargo clippy -D warnings`, `cargo test` locally on the bump commit and
  reports results before the maintainer tags.
- The agent verifies the draft's asset list via the GitHub API once the
  maintainer confirms the workflow finished (read-only; `gh` may need to
  be authenticated on the machine first).

## Out of Scope

- Announcing the pre-release (website, social); the website keeps showing
  0.5.0 as latest by design.
- Cutting 0.6.0 final — its own checklist run, later.
- Any code change beyond the version bumps and whatever beta.1 testing
  turns up (those get their own bounded fixes, reviewed like any other
  change).

## Further Notes

- Rollback: unpublishing or deleting a release removes it from every
  future check immediately — the client compares versions each time and
  stores no offers. A published bad build therefore costs "one bad check"
  for whoever checked during the window, nothing more.
- After 0.6.0 final ships, the migration sentence in the README ("installs
  of 0.5.0 or older must update by hand once") stays until 0.5.0 usage is
  plausibly gone; there is no telemetry to know, so leave it for a couple of
  releases.
