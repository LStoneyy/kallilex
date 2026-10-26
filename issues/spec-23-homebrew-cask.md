# Spec 23 — Homebrew cask in `lstoneyy/tap`, bumped on every stable release

Status: ready-for-agent (the agent writes the cask, the workflow and the docs;
the maintainer creates the tap repository, the token and the secret, and
runs the device checks)
Phase: distribution (a second install path for macOS next to the zip)
Depends on: 0.7.0 published as the latest stable release (done 2026-10-26).

## Problem Statement

The website already advertises
`brew tap lstoneyy/tap && brew install --cask kallilex` in two places, each
with a "Coming soon" note, and the README lists a Homebrew cask under
"Later". The tap does not exist yet (`LStoneyy/homebrew-tap` is not a
repository), so anyone who copies the command gets an error.

Two constraints shape the cask:

- Kallilex is signed with a stable self-signed certificate and is not
  notarized. Homebrew only runs its signing audit on official taps, so a
  third-party tap is fine, but `--no-quarantine` no longer exists: macOS
  blocks the first launch of a brew-installed Kallilex exactly like a
  downloaded one, and the user approves it once with "Open Anyway".
  Homebrew carries that approval over to later `brew upgrade`s as long as
  the signing identity stays the same, which it does.
- Kallilex updates itself through the in-app updater. Homebrew must not
  fight it, and the tap must still learn about each new stable version so
  that fresh installs get the current one.

## Solution

1. A public repository `LStoneyy/homebrew-tap` holding `Casks/kallilex.rb`
   for 0.7.0 and a short README.
2. A workflow in this repository, `.github/workflows/homebrew.yml`, that
   rewrites `version` and `sha256` in the tap whenever a stable release is
   published.
3. README, website and release checklist updated once the tap works, so the
   "Coming soon" notes disappear only when the command actually works.

## User Stories

1. As a Mac user who installs tools with Homebrew, I want
   `brew install --cask kallilex` to give me the current stable Kallilex, so
   that I don't have to download and unzip it by hand.
2. As that user, I want the cask to tell me about "Open Anyway" and the
   Accessibility permission, so that the first launch doesn't look broken.
3. As a brew user, I want Kallilex to keep updating itself in the app, and
   `brew upgrade` not to reinstall it behind my back.
4. As a user who removes Kallilex with `brew uninstall --zap`, I want its
   settings, caches and login item gone too.
5. As the maintainer, I want publishing a stable release to update the tap
   without another manual step, and pre-releases never to reach it.

## Implementation Decisions

### Tap repository

- Name `LStoneyy/homebrew-tap`, public, default branch `main`. The name is
  what makes `brew tap lstoneyy/tap` resolve.
- Contents: `Casks/kallilex.rb` and a README with the install command, the
  Gatekeeper note and a link back to this repository. No formulae, no CI in
  the tap for now.
- The maintainer creates the repository. The agent prepares the files in a
  local clone; pushing them happens on the maintainer's explicit go.

### Cask

```ruby
cask "kallilex" do
  version "0.7.0"
  sha256 "<sha256 of Kallilex-v0.7.0-macos-universal.zip>"

  url "https://github.com/LStoneyy/kallilex/releases/download/v#{version}/Kallilex-v#{version}-macos-universal.zip"
  name "Kallilex"
  desc "Menu-bar utility for spelling and rewriting selected text"
  homepage "https://kallilex.webcommits.info/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "Kallilex.app"

  uninstall quit: "com.webcommits.kallilex"

  zap trash: [
    "~/Library/Application Support/com.webcommits.kallilex",
    "~/Library/Caches/com.webcommits.kallilex",
    "~/Library/LaunchAgents/Kallilex.plist",
    "~/Library/Preferences/com.webcommits.kallilex.plist",
    "~/Library/WebKit/com.webcommits.kallilex",
  ]

  caveats <<~EOS
    Kallilex is signed but not notarized by Apple. On first launch macOS
    blocks it: click Done, then open System Settings → Privacy & Security
    and click "Open Anyway". This is needed once.

    Kallilex needs the Accessibility permission to read the selected text;
    macOS asks for it on the first capture.
  EOS
end
```

- The zip asset is the source, not the `.app.tar.gz` (that one is the
  updater archive).
- `auto_updates true`: `brew upgrade` leaves Kallilex alone unless the user
  passes `--greedy`; `brew outdated` stays quiet. The in-app updater stays
  the primary update path.
- **No quarantine removal.** No `postflight` with `xattr`; Gatekeeper is
  not bypassed. The caveat explains the one-time approval instead.
- `zap` paths are the ones present on a real install of 0.7.0. API keys
  live in the Keychain and are not removed by `zap`; the README of the tap
  says so.
- `depends_on macos:` is omitted: the bundle sets no minimum beyond Tauri's
  default, and the universal zip runs on both architectures.
- The cask must pass `brew style` and `brew audit --cask --strict --online`
  with no offences. If the audit insists on a different `desc` wording, the
  audit wins.

### Bump workflow (`.github/workflows/homebrew.yml`)

- Triggers: `release: types: [published]` and `workflow_dispatch` with a
  `tag` input (to re-run a bump by hand).
- Skips pre-releases (`github.event.release.prerelease`) and any tag with a
  `-` suffix, so 0.x.y-beta.n never reaches the tap.
- Steps:
  1. Derive the version from the tag (`v0.7.1` → `0.7.1`).
  2. Download `Kallilex-v<version>-macos-universal.zip` from that release
     with `gh release download` and compute its SHA-256.
  3. Check out `LStoneyy/homebrew-tap` with the `HOMEBREW_TAP_TOKEN` secret.
  4. Replace the `version` and `sha256` lines in `Casks/kallilex.rb`; fail
     if either line was not found.
  5. If nothing changed (same version already in the tap), exit
     successfully without a commit.
  6. Commit `kallilex <version>` and push to `main` of the tap.
- The release itself is published by the maintainer, not by
  `GITHUB_TOKEN`, so the `published` event does fire.
- No other step of `release.yml` changes.

### Token and secret

- A fine-grained personal access token, repository access limited to
  `LStoneyy/homebrew-tap`, permission *Contents: Read and write*, one-year
  expiry. The maintainer creates it and stores it as the
  `HOMEBREW_TAP_TOKEN` secret of this repository with
  `gh secret set HOMEBREW_TAP_TOKEN < file`. The agent never sees the
  value.
- The token's expiry date goes into `docs/release-checklist.md`.

### Docs (last, after the tap works)

- README: a "Homebrew" subsection at the top of the macOS installation
  section with the command and the same Gatekeeper note; "Homebrew cask"
  removed from "Later"; the "on the roadmap" sentence keeps only
  notarization.
- Install command everywhere (README, website, tap README):
  `brew install --cask lstoneyy/tap/kallilex`. Homebrew 7 refuses to load
  casks from a tap the user has not trusted; installing by the fully
  qualified name taps and trusts the cask in one go, whereas
  `brew tap lstoneyy/tap && brew install --cask kallilex` fails with
  "Refusing to load cask … from untrusted tap".
- Website: both "Coming soon" notes removed (hero panel and install card)
  and the command (shown text and `data-copy`) replaced as above.
- `docs/release-checklist.md`: after publishing a stable release, check that
  the Homebrew workflow ran and that the tap carries the new version and
  checksum.
- Pages deploys on every push to `main` touching `website/**`, so this
  commit is pushed only after the tap install has been confirmed on a
  device.

## Testing Decisions

- Agent: `brew style` and `brew audit --cask --strict --online` on the cask
  in the local tap clone; `actionlint` (if available) or a careful read of
  the workflow; the workflow's version/sha replacement tested locally
  against a copy of the cask with a fake version.
- Maintainer, on a Mac without Kallilex in `/Applications` (or after moving
  it aside):
  - `brew install --cask lstoneyy/tap/kallilex` installs 0.7.0;
    the caveat is shown;
  - first launch is blocked, "Open Anyway" works, Accessibility can be
    granted, the shortcut flow works;
  - `brew uninstall --zap --cask kallilex` removes the app, its settings
    and the login item.
- The workflow is proven with `workflow_dispatch` on `v0.7.0` (expected: no
  change, no commit) and for real with the next stable release.

## Out of Scope

- Notarization and Developer ID signing.
- Submitting to the official `homebrew/cask` (needs notarization).
- Formulae, Linux packages via Homebrew, winget, Flatpak.
- Offering pre-releases through the tap (e.g. a `kallilex@beta` cask).

## Further Notes

- If the in-app updater has already updated Kallilex past the tap's
  version, Homebrew still lists the old version in `brew info`; with
  `auto_updates true` that is expected and harmless.
- A user who installed by zip and later runs `brew install --cask kallilex`
  gets an "already exists" error for `/Applications/Kallilex.app`; the tap
  README tells them to use `--force` or remove the old copy first.
