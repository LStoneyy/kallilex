# Spec 08 — Homebrew cask: `brew install --cask kallilex` via a personal tap

Status: ready-for-agent
Phase: post-MVP distribution (follow-up to the v0.1.0 release; not part of the PRD vertical slice)
Depends on: spec-06 (release pipeline); requires at least one **published** (non-draft) GitHub release, since the cask URL must be publicly downloadable

## Problem Statement

From the user's perspective: Mac power users install tools with Homebrew, not
by hunting through GitHub release pages. Today installing Kallilex means
finding the repo, downloading a zip, unzipping, and dragging the app to
/Applications — four manual steps for something `brew install --cask` does in
one. The main `homebrew/homebrew-cask` repository is not an option yet: its
notability requirements (stars/forks thresholds) and its handling of
unnotarized apps rule out a young ad-hoc-signed project. A personal tap has no
such gate and is the standard path until a project graduates.

## Solution

A personal tap repository `LStoneyy/homebrew-tap` carries `Casks/kallilex.rb`,
pointing at the versioned universal zip on GitHub Releases with a pinned
sha256. The release workflow starts publishing a `.sha256` checksum asset next
to the zip so cask bumps are copy-paste. The cask's caveats explain the
one-time Gatekeeper approval honestly. README and release checklist gain the
brew path; version bumps are a documented manual step per release.

## User Stories

1. As a Homebrew user, I want `brew tap lstoneyy/tap` followed by `brew install --cask kallilex` to install the app into /Applications, so that installation is one command.
2. As a Homebrew user, I want `brew upgrade --cask kallilex` to pick up new releases after the cask is bumped, so that staying current is routine.
3. As a Homebrew user, I want the cask's caveats to tell me about the one-time "Open Anyway" approval before first launch, so that the Gatekeeper block doesn't surprise me.
4. As a Homebrew user, I want `brew uninstall --cask kallilex` to remove the app and `--zap` to also remove its settings, so that removal is clean.
5. As a security-conscious user, I want the cask to pin the release artifact's sha256, so that Homebrew verifies exactly the bytes the maintainer published.
6. As a security-conscious user, I want a `.sha256` checksum published as a release asset, so that I can verify a manual download too.
7. As a maintainer, I want the cask bump to be a short documented step in the release checklist, so that shipping stays boring.
8. As a maintainer, I want `brew audit` and `brew style` to pass on the cask, so that the tap stays healthy and a future move to homebrew-cask core is easy.

## Implementation Decisions

- Distribution channel: a personal tap in a **separate** GitHub repository
  `LStoneyy/homebrew-tap` (Homebrew's naming convention; users add it as
  `brew tap lstoneyy/tap`). The kallilex repo itself gains no Ruby code.
- Cask file `Casks/kallilex.rb` with: `version` (e.g. `0.1.0`), `sha256`
  (pinned, from the published asset), `url` pointing at
  `https://github.com/LStoneyy/kallilex/releases/download/v#{version}/Kallilex-v#{version}-macos-universal.zip`,
  `name "Kallilex"`, `desc` (one line, matches the README tagline),
  `homepage "https://github.com/LStoneyy/kallilex"`, `app "Kallilex.app"`.
- No `depends_on arch` (the artifact is universal) and no
  `depends_on macos` constraint in v1 (the build targets Tauri's default
  minimum; add a constraint only if a concrete incompatibility surfaces).
- `livecheck` stanza using the GitHub releases strategy (`:url :github_latest`)
  so `brew livecheck` flags pending bumps.
- `caveats` block stating: the app is ad-hoc signed and not notarized; on
  first launch macOS shows "Not Opened" — click Done, then System Settings →
  Privacy & Security → "Open Anyway" (one time); Kallilex also asks for
  Accessibility permission on first capture. No instruction to disable
  Gatekeeper or to pass `--no-quarantine` — the supported path is the
  documented approval.
- `zap trash:` entries for the app's data:
  `~/Library/Application Support/com.xr-essential.kallilex`,
  `~/Library/Caches/com.xr-essential.kallilex`,
  `~/Library/WebKit/com.xr-essential.kallilex`, and
  `~/Library/Preferences/com.xr-essential.kallilex.plist` (verify the exact
  set on disk before finalizing; list only paths the app actually creates).
  Keychain entries cannot be zapped by Homebrew; the caveats note that a saved
  API key stays in the Keychain until removed manually.
- Kallilex repo changes (the only in-repo work):
  1. `.github/workflows/release.yml`: after zipping, generate
     `Kallilex-v*-macos-universal.zip.sha256` via `shasum -a 256` and attach
     it to the draft release alongside the zip.
  2. `README.md` Installation section: add the brew path
     (`brew tap lstoneyy/tap && brew install --cask kallilex`) above the
     manual-download path; the Gatekeeper steps apply to both.
  3. `docs/release-checklist.md` Shipping steps: add a final step — after
     publishing the release, bump `version` and `sha256` in the tap's cask
     (source the hash from the published `.sha256` asset) and push the tap.
- Version bumps are manual in v1 (edit + push in the tap repo). Automation
  (a release-workflow job opening a tap PR via PAT, or `brew bump-cask-pr`)
  is explicitly deferred: it requires a cross-repo secret, which is not worth
  managing at the current release cadence.
- The tap repo contains: `Casks/kallilex.rb` and a minimal `README.md`
  (what the tap is, install command, link back to the main repo). Apache-2.0
  license, matching the main project.

## Testing Decisions

- Good verification is end-to-end against the real published artifact — the
  cask has no unit seams: `brew audit --cask kallilex` and
  `brew style` pass in the tap; `brew install --cask kallilex` on a machine
  (or fresh user account) installs to /Applications, shows the caveats, and
  the documented Gatekeeper flow launches the app; `brew uninstall` removes
  the app; `brew uninstall --zap` also removes the Application Support data.
- sha256 discipline: the value in the cask must equal the published `.sha256`
  asset, which must equal `shasum -a 256` of a freshly downloaded zip —
  checked once per release as part of the checklist's cask-bump step.
- In the kallilex repo, the only automatable check is the workflow change:
  the next tag's release must carry both the zip and its `.sha256` asset with
  matching contents.
- No changes to existing Rust/frontend tests; CI must stay green.

## Out of Scope

- Submission to `homebrew/homebrew-cask` core (blocked by notability and the
  unnotarized binary; revisit after Developer-ID signing + notarization).
- Automated cask bumps from the release workflow (deferred — cross-repo PAT).
- A Homebrew formula (CLI-style install); Kallilex is a GUI app, cask only.
- Notarization itself (separate decision; PRD roadmap).
- Any change to app code, bundle identifier, or artifact naming — the cask
  adapts to the shipped artifact, not the other way around.

## Further Notes

- Hard prerequisite: the v0.1.0 (or later) GitHub release must be **published**
  before the cask can work — draft-release asset URLs are not publicly
  downloadable. The cask's initial `version`/`sha256` come from that first
  published release.
- The `sha256` asset addition to `release.yml` lands in the kallilex repo and
  takes effect from the next tag; for an already-published release the hash
  can be computed locally for the initial cask.
- Creating the `LStoneyy/homebrew-tap` repository is a one-time manual step by
  the maintainer (or via `gh repo create` with the maintainer's approval) —
  agents must not create public repositories unprompted.
- Renaming risk: the PRD's trademark/domain check for "Kallilex" is still
  open; a later rename would ripple into the tap (cask token, repo). Ship the
  cask anyway — a rename is a mechanical bump — but resolve the check before
  wider promotion.
- Source of truth: PRD.md in the repo root; release mechanics in
  `.github/workflows/release.yml` and `docs/release-checklist.md`.
