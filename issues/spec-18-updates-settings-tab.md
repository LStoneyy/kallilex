# Spec 18 — Settings → Updates tab

Status: ready-for-agent
Phase: distribution (third of five; the user-facing surface for spec-16/17)
Depends on: spec-16 (settings fields, TS mirror), spec-17 (`UpdateStatus`,
the four commands, the `update:status` and `settings:show-tab` events).

## Problem Statement

After spec-17 the app checks for updates, knows the answer, and can install
— but the only visible trace is a tray label. There is no place to choose
the channel or the schedule, no button, no progress, no error text, and the
running version is shown nowhere in the app (only in the tray's native
About dialog). The Settings window is the obvious home; it just has no tab
for it.

## Solution

A new **Updates** tab in `src/settings/App.svelte`, placed after Prompts
and before Accessibility, containing — top to bottom — the current version,
the channel select, the automatic-check select, and the "Check for Updates"
control with its status line and, when applicable, the install / release
page actions. It renders live from `UpdateStatus` (initial `getUpdateStatus`
+ `update:status` events) and reacts to `settings:show-tab` so the tray entry
lands on it. Existing patterns only: the fetch-then-spread save, the
`TestState`-style status rendering, `.hint` explanations under each control.

## User Stories

1. As a user, I want to see which version I'm running at the top of the
   Updates tab, so that bug reports and "am I current?" questions have an
   answer.
2. As a user, I want to pick Stable or Preview and read in one line what
   each means, so that I can opt into pre-releases knowingly — or out again.
3. As a user, I want to pick Never / When Kallilex starts / Daily / Weekly
   and read what a check sends, so that the network behavior is a choice I
   understand.
4. As a user, I want "Check for Updates" to show *Checking…*, then either
   *You're up to date* with the time of the check, or the available version
   with a *What's new* link, so that the outcome is never ambiguous.
5. As a macOS / Windows / AppImage user, I want a *Download & install*
   button with a progress indicator, so that I can watch the update happen
   and know when the restart is coming.
6. As a deb/rpm user, I want an *Open release page* button and a short
   explanation why the update isn't installed in place, so that the missing
   button reads as intentional.
7. As a user whose check fails, I want the error sentence next to the button
   and the button still enabled, so that retrying is obvious.
8. As a user clicking the tray's update entry, I want Settings to open
   directly on the Updates tab, so that the tray label leads somewhere.

## Implementation Decisions

### Tab and state

- `type Tab` gains `"updates"`; a tab button "Updates" is added after
  "Prompts" in `<nav class="tabs">`. `selectTab` is reused unchanged.
- `updateStatus = $state<UpdateStatus | null>(null)`, loaded via
  `getUpdateStatus()` in the existing `onMount`, then kept current by
  `listen("update:status", …)`. A second `listen("settings:show-tab", …)`
  calls `selectTab(payload)` when the payload is a known `Tab`. Both
  listeners are registered in `onMount` and released in the returned
  cleanup, mirroring `src/popover/App.svelte`'s `capture:done` listener.
- Version line: `Kallilex {updateStatus.currentVersion}` plus a small
  channel badge (`Preview` / `Stable`) reflecting the *saved* channel.

### Controls

- **Update channel** — a `<select>` bound to `settings.updateChannel`,
  options *Stable* and *Preview*. Saved on change through the
  fetch-then-spread pattern (`getSettings()` → spread → `setSettings`).
  Hint (adjust to the surrounding voice): *"Stable offers final releases
  only. Preview also offers pre-releases ahead of stable — expect rough
  edges. Switching to Stable while on a pre-release keeps this build until
  a newer stable release exists."*
- **Check for updates automatically** — a `<select>` bound to
  `settings.updateCheckFrequency`, options *Never*, *When Kallilex starts*,
  *Daily*, *Weekly*. Hint: *"A check asks GitHub (api.github.com) for the
  release list. It sends nothing but the request — no identifiers, no
  usage data."*
- **Check for Updates** — a button, disabled while `phase` is `checking` or
  `downloading`, label *Checking…* while checking. Below it, one status
  line keyed on `phase`:
  - `idle` → *Last checked: {time}* or *Never checked* ;
  - `upToDate` → `.confirm` *You're up to date (checked {time}).* ;
  - `available` → *Version {version} is available.* + link-button *What's
    new* (`openUpdateReleasePage`) + either **Download & install**
    (`installUpdate`) when `installable`, or **Open release page**
    (`openUpdateReleasePage`) with the hint *"This Kallilex was installed
    from a .deb/.rpm package, so it isn't updated in place — download the
    new package from the release page and install it the same way."* ;
  - `downloading` → progress: `{percent}%` when `total` is known, otherwise
    *Downloading…*; the note *"Kallilex restarts when the download
    finishes."* ;
  - `error` → `.error` with `updateStatus.error`.
- `{time}` formatting: a small helper `formatCheckTime(epochSeconds)` using
  `Intl.DateTimeFormat` with `dateStyle: "medium", timeStyle: "short"`; no
  date library.
- Notes text (`available.notes`, GitHub's release body, markdown) is **not**
  rendered — the *What's new* link opens the release page. Rendering
  markdown safely is out of scope.

### Wiring

- `invoke.ts` wrappers from spec-17 are the only imports; the component
  never imports the event module except for `listen`, which
  `App.test.ts` mocks like the popover test does.
- No new CSS vocabulary: `.toggle-row`/select rows, `.hint`, `.confirm`,
  `.error`, existing button styles. A minimal progress element (a `<progress>`
  or a styled bar using existing tokens) is allowed.

## Testing Decisions

`src/settings/App.test.ts`, following the existing mock + `openXTab` helper
conventions, with `@tauri-apps/api/event` mocked so `listen` captures the
handler for the test to invoke:

- The Updates tab renders the current version and the saved channel badge.
- Changing the channel select calls `setSettings` with only `updateChannel`
  changed and the rest of a freshly fetched settings object preserved.
- Changing the frequency select likewise for `updateCheckFrequency`.
- Clicking *Check for Updates* calls `checkForUpdates`; a resolved
  `upToDate` status renders the confirm line with a formatted time.
- An `available` + `installable` status renders *Download & install*,
  and clicking it calls `installUpdate`.
- An `available` + not installable status renders *Open release page* and
  the deb/rpm hint, not the install button.
- A `downloading` status with `total` renders the percentage and disables
  the check button.
- An `error` status renders the message and leaves the button enabled.
- Emitting a `update:status` event through the captured listener updates
  the rendering without a re-fetch.
- Emitting `settings:show-tab` with `"updates"` switches to the tab.
- `pnpm check` and `pnpm test` green.

## Out of Scope

- Rendering release notes inline.
- Any change to the popover or onboarding windows (onboarding does not get
  an update-channel step; the build default covers testers).
- A "skip this version" control, or a per-check "remind me later".
- New visual language, icons, or a redesign of the tabs.

## Further Notes

- The `settings:show-tab` event is deliberately generic (payload is a tab
  name) so a future tray or onboarding entry can deep-link to any tab
  without a second event.
- If the window is opened by the tray entry *before* `onMount` has
  registered the listener, the event is lost; spec-17's handler therefore
  calls `show_settings` first and emits afterwards, and the window is
  created at startup (hidden), so in practice the listener is already
  there. Document this ordering in a comment rather than adding a
  handshake.
