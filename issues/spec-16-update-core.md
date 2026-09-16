# Spec 16 — Update core: channel and schedule settings, release resolution against GitHub

Status: ready-for-agent
Phase: distribution (first of five specs that give Kallilex in-app updates
and a preview channel; spec-16 … spec-20 land in order)
Depends on: nothing new. Builds on the `Settings` / `SettingsStore` seam
(`src-tauri/src/core/settings/`) and the `reqwest` + `wiremock` setup the
provider layer already uses.

## Problem Statement

Kallilex has no notion of updates. A user learns about a new version by
visiting GitHub Releases, downloads a zip / installer / package by hand, and
on macOS re-approves Gatekeeper. Nothing in the app knows which version is
current, which is newest, or whether the user would like to be told.

At the same time the maintainer wants to ship **pre-releases** for testing
without pushing them on everyone: testers should follow a *preview* channel,
everyone else a *stable* one. GitHub already models this distinction
(`prerelease: true|false` on a release) and already hosts every artifact, so
no update server is needed — but somebody has to turn "the list of releases"
into "the one release this user should see", and that logic has to be pure,
testable, and independent of any UI or updater plugin.

This spec builds exactly that: the persisted preferences, the small piece of
machine-local state, and the release-resolution logic. It introduces no
network call at runtime yet (nothing calls it until spec-17) and no UI
(spec-18).

## Solution

Three additions, all in `src-tauri/src/core/`:

- **Settings** gain `update_channel` (`stable` | `preview`) and
  `update_check_frequency` (`never` | `onLaunch` | `daily` | `weekly`).
- **Update state** — `last_check_at` — lives under its own key in the
  existing store file, not in `Settings`: it is machine-local bookkeeping,
  not a preference, and keeping it out of `Settings` keeps the Settings
  window's fetch-then-spread saves and the round-trip tests untouched by
  something that changes every day.
- **`core::updates`** — a new module with the pure logic: fetch the release
  list from the GitHub REST API, pick the newest release for a channel, and
  decide whether it is newer than the running build; plus the "is a
  scheduled check due?" rule. The module ends at "here is the newest
  release, its version, its notes URL and the URL of its `latest.json`
  update manifest"; downloading and installing is spec-17's job.

Two consequences worth stating up front:

- **The channel's default depends on the build.** A build whose version
  carries a semver pre-release suffix (`0.6.0-beta.1`) defaults to
  `preview`; a build without one defaults to `stable`. So a tester who
  installs a pre-release keeps following pre-releases with no setup, and a
  stable install never sees one unless the user opts in. A persisted choice
  always wins over the build default.
- **Semver decides everything.** `0.6.0-beta.2` on the stable channel sees
  `0.5.0` as older and stays put until `0.6.0` final exists; the same build
  on preview sees `0.6.0-beta.3` *and* `0.6.0` final. No special cases.

## User Stories

1. As a tester who installed a preview build, I want the app to follow
   pre-releases by default, so that I don't have to find a setting before
   my first test update arrives.
2. As a regular user, I want the app to follow stable releases only unless
   I say otherwise, so that a pre-release never lands on my machine by
   surprise.
3. As a user who switched to preview and back, I want the app to keep
   whatever I chose last, so that a build default never overrides me.
4. As a preview user, I want a stable release that is newer than my
   pre-release to count as an update, so that I'm never stranded on a beta
   after the final ships.
5. As a user on a pre-release with the stable channel selected, I want the
   older stable release **not** to be offered as an "update", so that
   channel switching never means a downgrade.
6. As a user, I want to decide whether Kallilex looks for updates never, at
   launch, daily or weekly, so that network activity is on my terms.
7. As the maintainer, I want draft releases and releases without an update
   manifest to be invisible to the app, so that an unfinished release can
   never be offered.
8. As the maintainer, I want the resolution logic covered by unit tests
   against a fake GitHub, so that the channel rules can't regress silently.

## Implementation Decisions

### Settings fields

- `Settings` gains, in `src-tauri/src/core/settings/mod.rs`:
  - `update_channel: UpdateChannel` with
    `#[serde(default = "crate::core::updates::default_update_channel")]`.
  - `update_check_frequency: UpdateCheckFrequency` with `#[serde(default)]`,
    where `impl Default` is `Daily`.
- Both enums live in `core::updates` (they are the module's vocabulary and
  `Settings` merely stores them), derive `Serialize`/`Deserialize`/`Copy`/
  `PartialEq`/`Debug` with `#[serde(rename_all = "camelCase")]`, so the JSON
  reads `"stable"|"preview"` and `"never"|"onLaunch"|"daily"|"weekly"`.
- `default_update_channel()` is a thin wrapper over the pure
  `channel_for_build_version(&semver::Version) -> UpdateChannel`
  (`Preview` iff `version.pre` is non-empty), evaluated on
  `env!("CARGO_PKG_VERSION")`. Document at the field why the default is
  build-dependent (see Solution) and that this is deliberate, not an
  oversight — the doc-comment style at `input_synthesis_enabled` is the
  model.
- `impl Default for Settings` sets both accordingly. The existing tests
  `save_then_load_round_trips_the_full_value`,
  `each_field_is_persisted_independently` and the pre-spec JSON
  back-compat tests are extended, not duplicated.
- `src/shared/types.ts`'s `Settings` mirror gains `updateChannel:
  "stable" | "preview"` and `updateCheckFrequency: "never" | "onLaunch" |
  "daily" | "weekly"`, and `src/settings/App.test.ts`'s `defaultSettings()`
  helper gains both fields so the frontend keeps type-checking. No UI in
  this spec.
- No side effect in `set_settings` yet; spec-17 adds the reaction to a
  channel change.

### Update state

- New `core::updates::state` with
  `UpdateCheckState { last_check_at: Option<u64> }` (seconds since the Unix
  epoch, `#[serde(default)]`, camelCase) and a `UpdateStateStore` trait
  (`load` / `save`) mirroring `SettingsStore`, with an in-memory
  implementation under `#[cfg(test)]` and a Tauri-store implementation that
  writes key `updateState` in the same `settings.json` file
  `TauriStoreSettings` uses (reuse its file-name constant; do not open a
  second store file).
- Epoch seconds rather than a date type: no new time dependency, and the
  only consumers are the due-check arithmetic and a UI label.

### Release resolution (`core::updates`)

- `GithubRelease` / `GithubAsset` are minimal `Deserialize` views of the
  REST payload: `tag_name`, `draft`, `prerelease`, `html_url`, `body`,
  `published_at` (string, passed through), `assets[].name`,
  `assets[].browser_download_url`. Unknown fields are ignored.
- `fetch_releases(client: &reqwest::Client, api_base: &Url) ->
  Result<Vec<GithubRelease>, UpdateError>` requests
  `{api_base}/repos/LStoneyy/kallilex/releases?per_page=30` with headers
  `User-Agent: Kallilex/<version>` (GitHub rejects requests without one),
  `Accept: application/vnd.github+json`,
  `X-GitHub-Api-Version: 2022-11-28`, and a 15 s timeout. The repository
  path is a module constant; `api_base` is a parameter purely so tests can
  point it at `wiremock`. Unauthenticated: 60 requests/hour/IP is far
  above one check per day, and a manual-button burst must degrade into a
  readable error, not a crash.
- `select_release(releases: &[GithubRelease], channel: UpdateChannel) ->
  Option<ResolvedRelease>`:
  - skip `draft == true`;
  - skip `prerelease == true` unless `channel == Preview`;
  - parse the version from the tag by stripping one leading `v`; tags that
    don't parse as semver are skipped, never an error (the repo owns its
    tags, but a stray tag must not brick update checks);
  - **skip releases without an asset named exactly `latest.json`** — a
    release without a manifest predates the updater (0.5.0 and older) or
    isn't finished, and either way must not be offered;
  - return the one with the highest version, as
    `ResolvedRelease { version: semver::Version, tag: String, release_url:
    String, notes: Option<String>, published_at: Option<String>,
    manifest_url: Url }`.
- `evaluate(resolved: Option<&ResolvedRelease>, current: &semver::Version)
  -> Availability` with `Availability::UpToDate` or
  `Availability::Available(ResolvedRelease)`; available iff
  `resolved.version > current` (strict semver, pre-release ordering
  included).
- `UpdateError` (`thiserror`): `Network(String)`, `RateLimited`,
  `InvalidResponse(String)`. `Display` texts are the user-facing sentences
  spec-18 will show verbatim, e.g. *"Kallilex couldn't reach GitHub to
  check for updates."*, *"GitHub is rate-limiting update checks from this
  network — try again in an hour."* A 403 whose
  `x-ratelimit-remaining` header is `0` (or whose body mentions the rate
  limit) maps to `RateLimited`; every other non-2xx is `Network`.
- `semver` becomes a direct dependency (`semver = "1"`); it is already in
  the graph through Tauri, so no new code is compiled.

### Due-check rule

- `pub enum Tick { Startup, Periodic }` and
  `is_check_due(frequency, last_check_at: Option<u64>, now: u64, tick: Tick)
  -> bool`:
  - `Never` → `false`;
  - `OnLaunch` → `true` only for `Tick::Startup`;
  - `Daily` / `Weekly` → `true` when `last_check_at` is `None` or
    `now - last_check_at >= 86_400` / `604_800`, on either tick.
- Pure function; the scheduler that calls it is spec-17.

## Testing Decisions

- `channel_for_build_version`: `0.6.0` → stable, `0.6.0-beta.1` → preview,
  `1.0.0-rc.1` → preview.
- `select_release`, table-driven: drafts skipped; pre-releases skipped on
  stable and included on preview; newest wins regardless of list order;
  a stable newer than a pre-release wins on preview; releases without
  `latest.json` skipped even when newest; unparseable tags skipped; empty
  list → `None`.
- `evaluate`: `0.6.0-beta.2` vs newest stable `0.5.0` → up to date;
  `0.6.0-beta.2` vs `0.6.0` → available; equal → up to date.
- `fetch_releases` against `wiremock`: 200 with a realistic payload
  (including unknown fields) parses; 403 with `x-ratelimit-remaining: 0` →
  `RateLimited`; 500 → `Network`; malformed JSON → `InvalidResponse`; the
  request carries the `User-Agent` and `Accept` headers (assert via a
  wiremock matcher).
- `is_check_due`: full matrix of frequency × tick × (`None`, just now,
  just past the threshold).
- Settings: round-trip of both new fields; a pre-spec-16 JSON without them
  deserializes to `update_check_frequency == Daily` and to the build's
  default channel; `UpdateCheckState` round-trips and a missing
  `updateState` key loads as `last_check_at: None`.
- `pnpm check` and `pnpm test` stay green after the TS mirror change.

## Out of Scope

- Any runtime network call, scheduler, tray item, plugin, or command
  (spec-17).
- Any UI (spec-18).
- Building or publishing `latest.json` (spec-19).
- A "skip this version" preference, release-notes rendering, or update
  history.
- Reading pre-release *kind* (alpha/beta/rc) — one preview channel, no
  sub-channels.

## Further Notes

- The `latest.json` requirement in `select_release` is the contract with
  spec-19: the pipeline uploads exactly that filename to every release from
  0.6.0-beta.1 on. It doubles as the migration boundary — 0.5.0 users must
  update by hand once, and the README (spec-19) says so.
- Reviewers should reject any implementation that makes the channel default
  a fixed value or that reads the persisted channel with a bare
  `#[serde(default)]` (which would silently become `stable` for every
  existing preview install).
