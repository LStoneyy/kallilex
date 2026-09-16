# Spec 19 — Release pipeline: signed updater artifacts, `latest.json`, pre-release flag, docs

Status: ready-for-agent
Phase: distribution (fourth of five; makes releases consumable by the
spec-16/17 client)
Depends on: spec-17 (the public key in `tauri.conf.json`, the manifest key
set), spec-16 (the `latest.json` contract). Independent of spec-18.

## Problem Statement

`release.yml` builds and uploads human-facing artifacts: a macOS zip, deb /
rpm / AppImage, an NSIS installer, plus `.sha256` files. The updater client
needs something else on every release from now on:

- a **minisign signature** for each installable artifact, produced by
  `tauri build` when `createUpdaterArtifacts` is on and the private key is
  in the environment — plus, on macOS, the `.app.tar.gz` the updater
  actually installs (the zip is for humans);
- a single **`latest.json`** manifest on the release, in the plugin's
  format, mapping platform keys to `{ url, signature }` — the exact
  filename spec-16 filters on;
- the **pre-release flag** on GitHub set from the tag, so the stable channel
  ignores betas without anyone remembering a checkbox;
- and the maintainer-facing **documentation**: README (what updates do, what
  they send, who must update by hand once) and the release checklist
  (signing key custody, new artifacts, the update-path gate).

Two more gaps surface once pre-releases are real: `workflow_dispatch` runs
only build macOS today, so a Windows/Linux problem with a `-beta.1` version
string would first appear on the tag run; and nothing checks that the tag
matches the version baked into the three config files.

## Solution

Extend `release.yml` rather than replace it: sign in all three build jobs,
upload the extra artifacts next to the existing ones, add a fourth job that
assembles `latest.json` from the uploaded signatures and attaches it, set
`--prerelease` from the tag, verify tag ↔ version early, and let manual
runs build all three platforms. Add a small `scripts/build-update-manifest.sh`
so the manifest logic is runnable and testable locally. Update README and
`docs/release-checklist.md`.

## User Stories

1. As the maintainer, I want pushing `vX.Y.Z[-pre]` to produce a draft
   release that already carries every signature and `latest.json`, so that
   publishing it is the only manual step.
2. As the maintainer, I want a tag containing `-` to create a pre-release
   automatically, so that a forgotten checkbox can never push a beta to
   stable users.
3. As the maintainer, I want the workflow to fail fast when the tag and
   `package.json` disagree, so that a half-done version bump never ships.
4. As the maintainer, I want a manual workflow run to build all three
   platforms, so that I can rehearse a pre-release version string before
   tagging.
5. As the maintainer, I want the signing key's custody, rotation
   consequences and the update-path gate written down next to the Apple
   certificate notes, so that the second release is as safe as the first.
6. As a user reading the README, I want to know that Kallilex can update
   itself, which channels exist, what a check sends, and that installs
   before 0.6.0 need one manual update, so that nothing about updates is a
   surprise.

## Implementation Decisions

### Bundling

- `src-tauri/tauri.conf.json`: `"bundle": { …, "createUpdaterArtifacts": true }`.
  With the v2 format this yields `Kallilex.app.tar.gz` + `.sig` on macOS,
  `*.AppImage.sig` (and deb/rpm sigs, which are uploaded for completeness
  but not referenced by the manifest) on Linux, and `*-setup.exe.sig` on
  Windows. Local builds without the key env vars still succeed (Tauri only
  signs when the key is present) — verify this, since developers must not
  need the key.

### Secrets and signing

- New GitHub Actions secrets `TAURI_SIGNING_PRIVATE_KEY` (the content of
  the `.key` file from spec-17's prerequisite) and
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, passed as `env:` to the three
  `pnpm tauri build` steps only. Never echoed; never written to disk by the
  workflow.

### Workflow changes (`.github/workflows/release.yml`)

- **Tag ↔ version guard** (first step of `build-release`, tag runs only):
  compare `${GITHUB_REF_NAME#v}` with `package.json`'s `version`,
  `src-tauri/tauri.conf.json`'s `version` and `src-tauri/Cargo.toml`'s
  `version`; fail with `::error::` naming the mismatch.
- **macOS job**: after the existing zip step, copy
  `bundle/macos/Kallilex.app.tar.gz` and `.sig` to
  `Kallilex-${tag}-macos-universal.app.tar.gz` / `.app.tar.gz.sig`; upload
  both alongside the zip. The signature is over the archive content, so
  renaming is safe.
- **Linux job**: also rename/upload `Kallilex-${tag}-linux-x86_64.AppImage.sig`
  (plus the deb/rpm `.sig`s if produced — `find`-based, non-fatal if
  absent). Build on manual runs too: the `if: startsWith(github.ref,
  'refs/tags/')` moves from the job to the *upload* step; on manual runs the
  bundles go to `actions/upload-artifact` like the macOS job already does.
- **Windows job**: same treatment — rename/upload
  `Kallilex-${tag}-windows-x86_64-setup.exe.sig`; build on manual runs,
  upload only on tags.
- **Pre-release flag**: `gh release create … --draft --generate-notes` gains
  `--prerelease` when `"$GITHUB_REF_NAME" == *-*`.
- **New job `publish-update-manifest`** (`ubuntu-latest`, `needs:
  [build-release, build-release-linux, build-release-windows]`, tag runs
  only): `gh release download "$tag" --pattern '*.sig' --dir sigs`, run
  `scripts/build-update-manifest.sh "$tag" sigs > latest.json`, `cat` it
  into the log, `gh release upload "$tag" latest.json`.

### `scripts/build-update-manifest.sh`

- Bash + `jq`, `set -euo pipefail`. Inputs: the tag and a directory
  holding the four required signature files (by their release names).
  Output on stdout:

  ```json
  {
    "version": "<tag without leading v>",
    "notes": "https://github.com/LStoneyy/kallilex/releases/tag/<tag>",
    "pub_date": "<UTC now, RFC 3339>",
    "platforms": {
      "darwin-aarch64": { "url": ".../download/<tag>/Kallilex-<tag>-macos-universal.app.tar.gz", "signature": "<contents of .sig>" },
      "darwin-x86_64":  { "url": "<same>", "signature": "<same>" },
      "linux-x86_64":   { "url": ".../Kallilex-<tag>-linux-x86_64.AppImage", "signature": "…" },
      "windows-x86_64": { "url": ".../Kallilex-<tag>-windows-x86_64-setup.exe", "signature": "…" }
    }
  }
  ```

- Fails with a clear message if any of the four signature files is missing
  — a release must never carry a partial manifest (a platform missing from
  it would show as "available, not installable" forever to those users).
- Keys are exactly the four spec-17 names; deb/rpm are intentionally absent
  (notify-only).
- `url`s are the `releases/download/<tag>/<asset>` form, which GitHub
  redirects to the CDN; the updater follows redirects.

### Documentation

- **README**: new section `## Updates` between `## Windows` and
  `## Capture`: Kallilex checks GitHub Releases for new versions
  (Settings → Updates: channel Stable / Preview, frequency Never / On
  launch / Daily / Weekly, manual button); what a check sends (one request
  to `api.github.com`, no identifiers); in-place install on macOS, Windows
  and AppImage, release-page link for deb/rpm; downloads are verified
  against a signing key built into the app; **installs of 0.5.0 or older
  must update by hand once** — they predate the updater. Add one bullet to
  `## Privacy` pointing at that section (the check is the only network
  activity besides the configured AI provider, and it is off with
  "Never"). Keep the existing "signed with a stable self-signed
  certificate, so the Accessibility permission survives app updates"
  sentence — it is now literally the point.
- **`docs/release-checklist.md`**:
  - Section 1 gains a gate: *Update path verified* — the previous published
    release on the same channel updates in place to this build on macOS,
    Windows and AppImage, deb/rpm show the release-page path, and after the
    macOS update the Accessibility grant is still present and no new
    Gatekeeper approval was needed.
  - Section 6 (shipping steps): pre-release tags carry a semver suffix
    (`v0.6.0-beta.1`) and are flagged automatically; confirm the draft
    carries `latest.json` and one `.sig` per installable artifact; note
    that a **draft is invisible to the app** — only publishing makes the
    update reachable; note that deleting a published release simply makes
    it disappear from checks (the client compares versions, it does not
    remember offers).
  - New section 9 *Update signing key*: what it is, where the private key
    and password live (`~/.kallilex-signing/`, the two secrets), that the
    public key is in `tauri.conf.json`, and that **rotation is not a
    normal operation**: a new key means every existing install must
    reinstall by hand, so rotate only on compromise and announce it.
- Website: no change (`website/main.js` already reads `/releases/latest`,
  which GitHub defines as the newest non-pre-release).

## Testing Decisions

- `scripts/build-update-manifest.sh` run locally against four dummy `.sig`
  files produces the documented shape (`jq` round-trip, four keys, the two
  darwin entries identical); a missing file exits non-zero with the file
  named.
- A **manual `Release` workflow run** (workflow_dispatch) before any tag:
  all three platforms build with signing enabled, `.sig` files appear in
  the uploaded artifacts, the macOS designated-requirement check still
  passes. Do this once with the version temporarily set to a `-beta.0`
  string on a branch to prove NSIS and the macOS bundler accept a
  pre-release version — no tag, no release, revert afterwards.
- Local `pnpm tauri build` on the maintainer's Mac without the key env vars
  still succeeds (no signing, no failure).
- `cargo test`, `pnpm test`, and CI unaffected (the workflow file is not
  exercised by CI; review it line by line instead).

## Out of Scope

- Notarization, a Homebrew cask, winget, Flatpak or any new install
  channel.
- Delta updates, a CDN, or hosting anything on the website.
- Changing the human-facing artifact names or dropping the macOS zip.
- Automating the version bump or the tag.

## Further Notes

- The `latest.json` per release (rather than one rolling file) is what
  lets a single manifest serve both channels: the client picks the release,
  the manifest describes only that release. It also means an old release's
  manifest never has to be edited.
- `pub_date` is informational for the plugin; the client never uses it for
  ordering — versions do.
- Keep the `--generate-notes` behavior: the release body becomes
  `AvailableUpdate.notes`, unused by the UI today but free to have.
